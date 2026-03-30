import XCTest
@testable import API2FileCore

/// End-to-end tests for companion file generation.
///
/// Validates the full lifecycle of companion files:
///   - Pull creates companion .md files alongside primary files
///   - Companion content matches the adapter template with correct field substitution
///   - Companion files are marked isCompanion = true in SyncableFile and FileSyncState
///   - No .objects/ sidecar files are written for companion paths
///   - Companion files are excluded from rawRecordsByFile (no push data)
///   - Works for both collection and one-per-record strategies
///   - SyncEngine writes companions to disk and suppresses push for modified companions
///   - Stale companions are removed when their source record is deleted
///
/// Uses a real DemoAPIServer with inline adapter configs that include companionFiles.
final class CompanionFileE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!
    private let authKey = "api2file.companion.test"

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 37000...40000)
        server = DemoAPIServer(port: port)
        try await server.start()

        var ready = false
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { ready = true; break }
            } catch { continue }
        }
        guard ready else { XCTFail("Server not ready on port \(port!)"); return }
        await server.reset()

        let resolvedTmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        syncRoot = resolvedTmp.appendingPathComponent("api2file-companion-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let metaDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)

        _ = await KeychainManager().save(key: authKey, value: "demo-token")

        try writeAdapterConfig()
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        if let dir = syncRoot { try? FileManager.default.removeItem(at: dir) }
        syncRoot = nil
        serviceDir = nil
        await KeychainManager().delete(key: authKey)
        try await super.tearDown()
    }

    // MARK: - Adapter config

    /// Adapter with companionFiles on both tasks (collection) and contacts (one-per-record).
    private func writeAdapterConfig() throws {
        let json = """
        {
          "service": "demo",
          "displayName": "Demo (Companion test)",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "\(authKey)" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list",
              "pull": { "method": "GET", "url": "\(baseURL)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/tasks" },
                "update": { "method": "PUT",  "url": "\(baseURL)/api/tasks/{id}" },
                "delete": { "method": "DELETE","url": "\(baseURL)/api/tasks/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id",
                "companionFiles": [
                  {
                    "filename": "{name|slugify}.md",
                    "directory": "tasks",
                    "template": "# {name}\\n\\n**Status:** {status}\\n**Priority:** {priority}\\n**Assignee:** {assignee}",
                    "readOnly": true
                  }
                ]
              },
              "sync": { "interval": 5, "fullSyncEvery": 1 }
            },
            {
              "name": "contacts",
              "description": "Contact cards",
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
                "idField": "id",
                "companionFiles": [
                  {
                    "filename": "{firstName|slugify}-{lastName|slugify}.md",
                    "directory": "contact-summaries",
                    "template": "# {firstName} {lastName}\\n\\n**Email:** {email}",
                    "readOnly": true
                  }
                ]
              },
              "sync": { "interval": 5, "fullSyncEvery": 1 }
            }
          ]
        }
        """
        let metaDir = serviceDir.appendingPathComponent(".api2file")
        try json.write(to: metaDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func makeEngine() throws -> AdapterEngine {
        let config = try AdapterEngine.loadConfig(from: serviceDir)
        return AdapterEngine(config: config, serviceDir: serviceDir, httpClient: HTTPClient())
    }

    private func startSyncEngine(generateCompanionFiles: Bool = true) async throws -> SyncEngine {
        let config = GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 5,
            showNotifications: false,
            serverPort: Int(port),
            generateCompanionFiles: generateCompanionFiles
        )
        let eng = SyncEngine(config: config)
        try await eng.start()
        return eng
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(relativePath).path)
    }

    private func readFile(_ relativePath: String) throws -> String {
        try String(contentsOf: serviceDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func getFromAPI(_ path: String) async throws -> [[String: Any]] {
        let r = try await HTTPClient().request(APIRequest(method: .GET, url: "\(baseURL)\(path)"))
        let json = try JSONSerialization.jsonObject(with: r.body)
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }

    private func deleteFromAPI(_ path: String) async throws {
        _ = try await HTTPClient().request(APIRequest(method: .DELETE, url: "\(baseURL)\(path)"))
    }

    private func waitForFile(_ relativePath: String, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileExists(relativePath) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func waitForFileGone(_ relativePath: String, timeout: TimeInterval = 12) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !fileExists(relativePath) { return true }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    // ======================================================================
    // MARK: - 1. Pull generates companion files (AdapterEngine level)
    // ======================================================================

    func testPullProducesCompanionSyncableFiles() async throws {
        let engine = try makeEngine()
        let result = try await engine.pullAll()

        let companions = result.files.filter { $0.isCompanion }

        // 3 tasks → 3 companion MDs
        let taskCompanions = companions.filter { $0.relativePath.hasPrefix("tasks/") }
        XCTAssertEqual(taskCompanions.count, 3, "Should have one companion .md per task")

        for companion in taskCompanions {
            XCTAssertTrue(companion.relativePath.hasSuffix(".md"))
            XCTAssertTrue(companion.readOnly, "Companion files must be read-only")
            XCTAssertTrue(companion.isCompanion)
        }

        // 2 contacts → 2 companion MDs
        let contactCompanions = companions.filter { $0.relativePath.hasPrefix("contact-summaries/") }
        XCTAssertEqual(contactCompanions.count, 2, "Should have one companion .md per contact")
    }

    func testGlobalConfigDefaultsCompanionGenerationToDisabled() {
        XCTAssertFalse(GlobalConfig().generateCompanionFiles)
    }

    // ======================================================================
    // MARK: - 2. Companion content matches template with field substitution
    // ======================================================================

    func testCompanionContentMatchesTemplate_Collection() async throws {
        let engine = try makeEngine()
        let result = try await engine.pullAll()

        let companion = result.files.first(where: {
            $0.isCompanion && $0.relativePath == "tasks/buy-groceries.md"
        })
        XCTAssertNotNil(companion, "Should have companion for 'Buy groceries' task")

        let content = String(data: companion!.content, encoding: .utf8)!
        XCTAssertTrue(content.contains("# Buy groceries"), "Title should be rendered")
        XCTAssertTrue(content.contains("**Status:** todo"), "Status field should be substituted")
        XCTAssertTrue(content.contains("**Priority:**"), "Priority field should be present")
        XCTAssertTrue(content.contains("**Assignee:**"), "Assignee field should be present")
    }

    func testCompanionContentMatchesTemplate_OnePerRecord() async throws {
        let engine = try makeEngine()
        let result = try await engine.pullAll()

        // Contacts have firstName/lastName from the demo server seed
        let contactCompanions = result.files.filter { $0.relativePath.hasPrefix("contact-summaries/") }
        XCTAssertEqual(contactCompanions.count, 2)

        for companion in contactCompanions {
            let content = String(data: companion.content, encoding: .utf8)!
            XCTAssertTrue(content.hasPrefix("# "), "Companion should start with a Markdown heading")
            XCTAssertTrue(content.contains("**Email:**"), "Email field should appear in companion")
        }
    }

    // ======================================================================
    // MARK: - 3. Companions are excluded from rawRecordsByFile
    // ======================================================================

    func testCompanionsHaveNoRawRecords() async throws {
        let engine = try makeEngine()
        let result = try await engine.pullAll()

        let companions = result.files.filter { $0.isCompanion }
        XCTAssertFalse(companions.isEmpty, "Precondition: companions should exist")

        for companion in companions {
            XCTAssertNil(
                result.rawRecordsByFile[companion.relativePath],
                "Companion \(companion.relativePath) must not appear in rawRecordsByFile"
            )
        }
    }

    // ======================================================================
    // MARK: - 4. Primary file rawRecordsByFile is unaffected
    // ======================================================================

    func testPrimaryFileRawRecordsAreUnaffected() async throws {
        let engine = try makeEngine()
        let result = try await engine.pullAll()

        // tasks.csv should still have its raw records
        let rawTasks = result.rawRecordsByFile["tasks.csv"]
        XCTAssertNotNil(rawTasks, "tasks.csv should have raw records")
        XCTAssertEqual(rawTasks?.count, 3, "Should have 3 raw task records")
    }

    func testSyncEngineSkipsCompanionsWhenGenerationDisabled() async throws {
        let eng = try await startSyncEngine(generateCompanionFiles: false)
        defer { Task { await eng.stop() } }

        let primaryAppeared = await waitForFile("tasks.csv")
        XCTAssertTrue(primaryAppeared, "Primary collection file should still sync")

        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(fileExists("tasks/buy-groceries.md"))
        XCTAssertFalse(fileExists("contact-summaries/jane-doe.md"))
    }

    // ======================================================================
    // MARK: - 5. SyncEngine writes companion files to disk
    // ======================================================================

    func testSyncEngineWritesCompanionFilesToDisk() async throws {
        let eng = try await startSyncEngine()
        defer { Task { await eng.stop() } }

        let appeared = await waitForFile("tasks/buy-groceries.md")
        XCTAssertTrue(appeared, "tasks/buy-groceries.md should appear after sync")

        let content = try readFile("tasks/buy-groceries.md")
        XCTAssertTrue(content.contains("Buy groceries"))

        // No .objects/ for companion
        XCTAssertFalse(fileExists("tasks/.objects/buy-groceries.json"),
                       "No object file should be created for a companion")
    }

    func testSyncEngineWritesContactCompanionFiles() async throws {
        let eng = try await startSyncEngine()
        defer { Task { await eng.stop() } }

        // Wait for at least one contact-summary companion to appear
        let appeared = await waitForFile("contact-summaries/")
        XCTAssertTrue(appeared, "contact-summaries/ directory should appear after sync")

        // contact-summaries directory should have .md files
        let summariesDir = serviceDir.appendingPathComponent("contact-summaries")
        let contents = try FileManager.default.contentsOfDirectory(atPath: summariesDir.path)
        let mdFiles = contents.filter { $0.hasSuffix(".md") }
        XCTAssertEqual(mdFiles.count, 2, "Should have 2 companion .md files in contact-summaries/")
    }

    // ======================================================================
    // MARK: - 6. Editing a companion does NOT trigger push
    // ======================================================================

    func testEditingCompanionDoesNotTriggerPush() async throws {
        let eng = try await startSyncEngine()
        defer { Task { await eng.stop() } }

        // Wait for initial sync
        let appeared = await waitForFile("tasks/buy-groceries.md")
        XCTAssertTrue(appeared, "Precondition: companion file should exist")

        // Count tasks on server before edit
        let before = try await getFromAPI("/api/tasks")
        let namesBefore = before.compactMap { $0["name"] as? String }

        // Edit the companion file
        let companionURL = serviceDir.appendingPathComponent("tasks/buy-groceries.md")
        try "# Modified by test — should not push".write(to: companionURL, atomically: true, encoding: .utf8)

        // Wait 3s for any potential push to complete
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Server tasks should be unchanged
        let after = try await getFromAPI("/api/tasks")
        let namesAfter = after.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(namesBefore), Set(namesAfter),
                       "Server task names must not change after editing a companion file")
        XCTAssertEqual(before.count, after.count, "Task count must not change")
    }

    // ======================================================================
    // MARK: - 7. Deleted record companion is removed on full sync
    // ======================================================================

    func testDeletedRecordCompanionIsRemovedOnFullSync() async throws {
        let eng = try await startSyncEngine()
        defer { Task { await eng.stop() } }

        // Wait for companion to appear
        let appeared = await waitForFile("tasks/buy-groceries.md")
        XCTAssertTrue(appeared, "Precondition: companion should exist before deletion")

        // Delete task 1 (Buy groceries) via the API
        try await deleteFromAPI("/api/tasks/1")

        // Wait for the companion to disappear on the next full sync cycle
        let gone = await waitForFileGone("tasks/buy-groceries.md")
        XCTAssertTrue(gone, "Companion file should be removed when its record is deleted")

        // Primary CSV should still exist (other tasks remain)
        XCTAssertTrue(fileExists("tasks.csv"), "tasks.csv should still exist")

        // Other companions should still exist
        let fixBugGone = !fileExists("tasks/fix-login-bug.md")
        XCTAssertFalse(fixBugGone, "Companion for non-deleted task should remain")
    }

    // ======================================================================
    // MARK: - 8. New record gets a companion on next sync
    // ======================================================================

    func testNewRecordGetsCompanionOnSync() async throws {
        let eng = try await startSyncEngine()
        defer { Task { await eng.stop() } }

        // Wait for initial sync
        _ = await waitForFile("tasks/buy-groceries.md")

        // Add a new task via the API
        let body = try JSONSerialization.data(withJSONObject: [
            "name": "Deploy to production",
            "status": "todo",
            "priority": "high",
            "assignee": "DevOps",
            "dueDate": "2026-07-01"
        ])
        _ = try await HTTPClient().request(APIRequest(
            method: .POST,
            url: "\(baseURL)/api/tasks",
            headers: ["Content-Type": "application/json"],
            body: body
        ))

        // Wait for companion to appear for the new task
        let appeared = await waitForFile("tasks/deploy-to-production.md", timeout: 12)
        XCTAssertTrue(appeared, "Companion should appear for newly added task")

        let content = try readFile("tasks/deploy-to-production.md")
        XCTAssertTrue(content.contains("Deploy to production"))
        XCTAssertTrue(content.contains("**Status:** todo"))
        XCTAssertTrue(content.contains("DevOps"))
    }
}
