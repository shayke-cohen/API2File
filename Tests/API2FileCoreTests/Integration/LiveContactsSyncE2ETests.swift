import XCTest
@testable import API2FileCore

/// Live end-to-end tests for contacts sync in both directions.
///
/// Tests the full loop for the VCF/one-per-record strategy:
///
///   Pull direction (server → local):
///     Server adds/updates/deletes a contact → VCF file appears/changes/disappears on disk
///
///   Push direction (local → server):
///     User edits a VCF or object file on disk → change pushed to server within 2.5 s
///
/// No mocks. Real DemoAPIServer, real filesystem, real FSEvents, real SyncEngine.
final class LiveContactsSyncE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!
    private var engine: SyncEngine!
    private let keychain = KeychainManager()
    private let authKey = "api2file.contacts.livetest"

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 33000...36000)
        server = DemoAPIServer(port: port)
        try await server.start()

        var ready = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(
                    from: URL(string: "\(baseURL)/api/contacts")!
                )
                if let r = response as? HTTPURLResponse, r.statusCode == 200 {
                    ready = true; break
                }
            } catch { continue }
        }
        guard ready else {
            XCTFail("DemoAPIServer did not become ready on port \(port!)")
            return
        }

        await server.reset()
        _ = await keychain.save(key: authKey, value: "demo-token")

        // Resolve symlinks — FSEvents reports canonical paths; temp dir on macOS is symlinked
        let resolvedTmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        syncRoot = resolvedTmp.appendingPathComponent("api2file-contacts-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let metaDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)

        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo (Contacts test)",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "\(authKey)" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "contacts",
              "description": "Contact cards (VCF)",
              "pull": { "method": "GET", "url": "\(baseURL)/api/contacts", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/contacts" },
                "update": { "method": "PUT",  "url": "\(baseURL)/api/contacts/{id}" },
                "delete": { "method": "DELETE","url": "\(baseURL)/api/contacts/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "contacts",
                "filename": "{firstName|slugify}-{lastName|slugify}.vcf",
                "format": "vcf",
                "idField": "id"
              },
              "sync": { "interval": 5, "fullSyncEvery": 1 }
            }
          ]
        }
        """
        try adapterConfig.write(
            to: metaDir.appendingPathComponent("adapter.json"),
            atomically: true, encoding: .utf8
        )
    }

    override func tearDown() async throws {
        if let engine { await engine.stop() }
        engine = nil
        if let server { await server.stop() }
        server = nil
        if let dir = syncRoot { try? FileManager.default.removeItem(at: dir) }
        syncRoot = nil
        serviceDir = nil
        await keychain.delete(key: authKey)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func startEngine() async throws {
        let config = GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 5,
            showNotifications: false,
            serverPort: Int(port)
        )
        let eng = SyncEngine(config: config)
        engine = eng
        try await eng.start()
    }

    private var contactsDir: URL { serviceDir.appendingPathComponent("contacts") }
    private var objectsDir: URL  { contactsDir.appendingPathComponent(".objects") }

    private func vcfURL(_ name: String) -> URL { contactsDir.appendingPathComponent("\(name).vcf") }
    private func objURL(_ name: String) -> URL  { objectsDir.appendingPathComponent("\(name).json") }

    private func vcfExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: vcfURL(name).path)
    }

    private func readVCF(_ name: String) throws -> String {
        try String(contentsOf: vcfURL(name), encoding: .utf8)
    }

    private func writeObjFileTriggeringFSEvents(_ name: String, record: [String: Any]) throws {
        let url = objURL(name)
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 0)
        handle.write(data)
        handle.closeFile()
    }

    private func writeVCFTriggeringFSEvents(_ name: String, content: String) throws {
        let url = vcfURL(name)
        let data = content.data(using: .utf8)!
        let handle = try FileHandle(forWritingTo: url)
        handle.truncateFile(atOffset: 0)
        handle.write(data)
        handle.closeFile()
    }

    private func getContacts() async throws -> [[String: Any]] {
        let client = HTTPClient()
        let r = try await client.request(APIRequest(method: .GET, url: "\(baseURL)/api/contacts"))
        let json = try JSONSerialization.jsonObject(with: r.body)
        return json as? [[String: Any]] ?? []
    }

    private func postContact(_ data: [String: Any]) async throws -> [String: Any] {
        let client = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        let r = try await client.request(APIRequest(
            method: .POST, url: "\(baseURL)/api/contacts",
            headers: ["Content-Type": "application/json"], body: body
        ))
        return (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    private func putContact(id: Int, data: [String: Any]) async throws {
        let client = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await client.request(APIRequest(
            method: .PUT, url: "\(baseURL)/api/contacts/\(id)",
            headers: ["Content-Type": "application/json"], body: body
        ))
    }

    private func deleteContact(id: Int) async throws {
        let client = HTTPClient()
        _ = try await client.request(APIRequest(method: .DELETE, url: "\(baseURL)/api/contacts/\(id)"))
    }

    // MARK: - Pull: Server → Local

    func testInitialPull_CreatesTwoVCFFiles() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("alice-johnson"), "alice-johnson.vcf should appear after initial pull")
        XCTAssertTrue(vcfExists("bob-smith"),     "bob-smith.vcf should appear after initial pull")

        let aliceVCF = try readVCF("alice-johnson")
        XCTAssertTrue(aliceVCF.contains("FN:Alice Johnson"))
        XCTAssertTrue(aliceVCF.contains("EMAIL:alice@example.com"))

        let bobVCF = try readVCF("bob-smith")
        XCTAssertTrue(bobVCF.contains("FN:Bob Smith"))
    }

    func testServerAddsContact_VCFAppearsOnDisk() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify initial state
        XCTAssertFalse(vcfExists("carol-white"))

        // Add via server API
        _ = try await postContact([
            "firstName": "Carol", "lastName": "White",
            "email": "carol@example.com", "phone": "+1-555-9999", "company": "ACME"
        ])

        // Wait for next poll cycle (5 s interval + buffer)
        try await Task.sleep(nanoseconds: 8_000_000_000)

        XCTAssertTrue(vcfExists("carol-white"), "carol-white.vcf should appear after server-side create")
        let vcf = try readVCF("carol-white")
        XCTAssertTrue(vcf.contains("FN:Carol White"))
        XCTAssertTrue(vcf.contains("EMAIL:carol@example.com"))
    }

    func testServerUpdatesContact_VCFReflectsChange() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("alice-johnson"))
        let before = try readVCF("alice-johnson")
        XCTAssertFalse(before.contains("alice.updated@example.com"))

        // Update email on the server
        try await putContact(id: 1, data: ["email": "alice.updated@example.com"])

        try await Task.sleep(nanoseconds: 8_000_000_000)

        let after = try readVCF("alice-johnson")
        XCTAssertTrue(after.contains("alice.updated@example.com"),
                      "VCF should reflect the server-side email update")
    }

    func testServerDeletesContact_VCFRemovedFromDisk() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("bob-smith"))

        try await deleteContact(id: 2)

        try await Task.sleep(nanoseconds: 8_000_000_000)

        XCTAssertFalse(vcfExists("bob-smith"),
                       "bob-smith.vcf should be removed after server-side delete")
    }

    // MARK: - Push: Local → Server

    func testEditObjectFile_PushesUpdateToServer() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("alice-johnson"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: objURL("alice-johnson").path),
                      "alice-johnson object file should exist after pull")

        // Read the current object record
        var record = try ObjectFileManager.readRecordObjectFile(from: objURL("alice-johnson"))
        record["email"] = "alice.local.edit@example.com"
        record["company"] = "LocalCorp"

        // Write back — triggers FSEvents
        try writeObjFileTriggeringFSEvents("alice-johnson", record: record)

        // Wait for debounce (500 ms) + immediate push flush
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let contacts = try await getContacts()
        let alice = contacts.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(alice?["email"] as? String, "alice.local.edit@example.com",
                       "Server should reflect the local email edit")
        XCTAssertEqual(alice?["company"] as? String, "LocalCorp")
    }

    func testEditVCFFile_PushesUpdateToServer() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("alice-johnson"))

        // Build a modified VCF with an updated phone number
        let modified = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        FN:Alice Johnson\r
        N:Johnson;Alice;;;\r
        EMAIL:alice@example.com\r
        TEL:+1-555-7777\r
        ORG:NewOrg\r
        END:VCARD\r

        """
        try writeVCFTriggeringFSEvents("alice-johnson", content: modified)

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let contacts = try await getContacts()
        let alice = contacts.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(alice?["phone"] as? String, "+1-555-7777",
                       "Server should reflect the phone edit from the VCF file")
        XCTAssertEqual(alice?["company"] as? String, "NewOrg")
    }

    func testImmediatePush_VCFEditReachesServerWithinTwoAndHalfSeconds() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(vcfExists("alice-johnson"))

        let modified = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        FN:Alice Johnson\r
        N:Johnson;Alice;;;\r
        EMAIL:alice.immediate@example.com\r
        TEL:+1-555-0001\r
        END:VCARD\r

        """
        try writeVCFTriggeringFSEvents("alice-johnson", content: modified)

        // 2.5 s — well below the 5 s poll interval.
        // Without immediate flush this would fail, proving the immediate-push path works.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let contacts = try await getContacts()
        let alice = contacts.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(alice?["email"] as? String, "alice.immediate@example.com",
                       "Server should reflect VCF edit within 2.5 s (immediate push, not next poll)")
    }

    // MARK: - Round-Trip

    func testRoundTrip_LocalEdit_Then_ServerAdd_BothReflected() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // --- Phase 1: Local edit → push ---

        var record = try ObjectFileManager.readRecordObjectFile(from: objURL("alice-johnson"))
        record["company"] = "RoundTripCorp"
        try writeObjFileTriggeringFSEvents("alice-johnson", record: record)

        try await Task.sleep(nanoseconds: 8_000_000_000)

        let apiContacts1 = try await getContacts()
        let alice1 = apiContacts1.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(alice1?["company"] as? String, "RoundTripCorp",
                       "Server should reflect local company edit")

        // --- Phase 2: Server adds a contact → pull to disk ---

        _ = try await postContact([
            "firstName": "Dan", "lastName": "Brown",
            "email": "dan@example.com", "phone": "+1-555-1234", "company": "PubCo"
        ])

        try await Task.sleep(nanoseconds: 8_000_000_000)

        XCTAssertTrue(vcfExists("dan-brown"),
                      "dan-brown.vcf should appear after server-side create (pull phase)")
        let danVCF = try readVCF("dan-brown")
        XCTAssertTrue(danVCF.contains("FN:Dan Brown"))

        // Verify total: 2 seed + 1 new = 3
        let apiContacts2 = try await getContacts()
        XCTAssertEqual(apiContacts2.count, 3)
    }
}
