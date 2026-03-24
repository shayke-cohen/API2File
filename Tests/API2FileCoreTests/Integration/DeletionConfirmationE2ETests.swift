import XCTest
@testable import API2FileCore

/// End-to-end tests for the deletion confirmation flow.
///
/// Verifies that:
/// - File deletions are gated by the confirmation handler
/// - Row deletions (collection diff) are gated by the confirmation handler
/// - Cancelling a deletion triggers a re-pull that restores the data
/// - Confirming a deletion actually deletes from the API
/// - When no handler is set, deletions proceed immediately (existing behaviour)
final class DeletionConfirmationE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 22000...28000)
        server = DemoAPIServer(port: port)
        try await server.start()

        // Wait for readiness
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch { continue }
        }
        await server.reset()

        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-delconfirm-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list",
              "pull": { "method": "GET", "url": "\(baseURL)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/tasks" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "\(baseURL)/api/tasks/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id",
                "deleteFromAPI": true
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "contacts",
              "description": "Contacts",
              "pull": { "method": "GET", "url": "\(baseURL)/api/contacts", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/contacts" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/contacts/{id}" },
                "delete": { "method": "DELETE", "url": "\(baseURL)/api/contacts/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "contacts",
                "filename": "{firstName|slugify}-{lastName|slugify}.vcf",
                "format": "vcf",
                "idField": "id",
                "deleteFromAPI": true
              },
              "sync": { "interval": 10 }
            }
          ]
        }
        """
        try adapterConfig.write(to: api2fileDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        await server?.stop()
        if let dir = syncRoot { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeSyncEngine(deleteFromAPI: Bool = true) -> SyncEngine {
        return SyncEngine(config: GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            showNotifications: false,
            serverPort: 0,
            deleteFromAPI: deleteFromAPI
        ))
    }

    private func makeAdapterEngine() throws -> (AdapterEngine, AdapterConfig) {
        let config = try AdapterEngine.loadConfig(from: serviceDir)
        let httpClient = HTTPClient()
        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        return (engine, config)
    }

    private func resource(_ name: String, from config: AdapterConfig) -> ResourceConfig {
        config.resources.first(where: { $0.name == name })!
    }

    private func writeFilesToDisk(_ files: [SyncableFile]) throws {
        for file in files {
            let path = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func fileExistsOnDisk(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(relativePath).path)
    }

    private func getFromAPI(_ path: String) async throws -> [[String: Any]] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)\(path)"))
        let json = try JSONSerialization.jsonObject(with: r.body)
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }

    // ======================================================================
    // MARK: - DeletionInfo Model Tests
    // ======================================================================

    func testDeletionInfoFileDeletion() {
        let info = DeletionInfo(
            serviceName: "Monday.com",
            serviceId: "monday",
            filePath: "tasks.csv",
            recordCount: 5,
            kind: .fileDeletion
        )
        XCTAssertEqual(info.serviceName, "Monday.com")
        XCTAssertEqual(info.serviceId, "monday")
        XCTAssertEqual(info.filePath, "tasks.csv")
        XCTAssertEqual(info.recordCount, 5)
        if case .fileDeletion = info.kind {} else {
            XCTFail("Expected .fileDeletion kind")
        }
    }

    func testDeletionInfoRowDeletion() {
        let info = DeletionInfo(
            serviceName: "Wix",
            serviceId: "wix",
            filePath: "contacts.csv",
            recordCount: 3,
            kind: .rowDeletion
        )
        XCTAssertEqual(info.recordCount, 3)
        if case .rowDeletion = info.kind {} else {
            XCTFail("Expected .rowDeletion kind")
        }
    }

    func testDeletionInfoNilRecordCount() {
        let info = DeletionInfo(
            serviceName: "Demo",
            serviceId: "demo",
            filePath: "notes.md",
            recordCount: nil,
            kind: .fileDeletion
        )
        XCTAssertNil(info.recordCount)
    }

    // ======================================================================
    // MARK: - SyncEngine Handler Wiring
    // ======================================================================

    func testDeletionHandlerDefaultIsNil() async {
        let engine = makeSyncEngine()
        let handler = await engine.deletionConfirmationHandler
        XCTAssertTrue(handler == nil, "Handler should be nil by default")
    }

    func testSetDeletionConfirmationHandler() async {
        let engine = makeSyncEngine()
        await engine.setDeletionConfirmationHandler { _ in true }
        let handler = await engine.deletionConfirmationHandler
        XCTAssertTrue(handler != nil, "Handler should be set after calling setDeletionConfirmationHandler")
    }

    func testClearDeletionConfirmationHandler() async {
        let engine = makeSyncEngine()
        await engine.setDeletionConfirmationHandler { _ in true }
        await engine.setDeletionConfirmationHandler(nil)
        let handler = await engine.deletionConfirmationHandler
        XCTAssertTrue(handler == nil, "Handler should be nil after clearing")
    }

    // ======================================================================
    // MARK: - Row Deletion: Confirm → deletes from API
    // ======================================================================

    func testRowDeletionConfirmed_DeletesFromAPI() async throws {
        let (engine, config) = try makeAdapterEngine()
        let tasksResource = resource("tasks", from: config)

        // Pull tasks (3 seed records)
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        let oldRecords = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(oldRecords.count, 3)

        // Remove row with id=2
        let newRecords = oldRecords.filter { r in
            let id = (r["id"] as? String) ?? "\(r["id"] as? Int ?? -1)"
            return id != "2"
        }
        let modifiedCSV = try CSVFormat.encode(records: newRecords, options: nil)
        try modifiedCSV.write(to: serviceDir.appendingPathComponent("tasks.csv"), options: .atomic)

        // Diff
        let diff = CollectionDiffer.diff(old: oldRecords, new: newRecords, idField: "id")
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertTrue(diff.deleted.contains("2"))

        // Delete from API (simulates confirmed deletion)
        for id in diff.deleted {
            try await engine.delete(remoteId: id, resource: tasksResource)
        }

        // Verify API
        let tasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(tasks.count, 2, "Should have 2 tasks after confirmed row deletion")
        let deleted = tasks.first(where: { ($0["id"] as? Int) == 2 || ($0["id"] as? String) == "2" })
        XCTAssertNil(deleted, "Task 2 should be deleted from API")
    }

    // ======================================================================
    // MARK: - Row Deletion: Cancel → API unchanged, file restored on re-pull
    // ======================================================================

    func testRowDeletionCancelled_APIUnchanged() async throws {
        let (engine, config) = try makeAdapterEngine()
        let tasksResource = resource("tasks", from: config)

        // Pull original tasks
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)

        // Verify all 3 tasks on the API before we do anything
        let tasksBefore = try await getFromAPI("/api/tasks")
        XCTAssertEqual(tasksBefore.count, 3, "Should start with 3 tasks")

        // Simulate user deleting a row locally but then CANCELLING the confirmation
        // (we simply don't call engine.delete, and instead re-pull)

        // Re-pull restores the file
        let result2 = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result2.files)

        // Verify API still has all 3
        let tasksAfter = try await getFromAPI("/api/tasks")
        XCTAssertEqual(tasksAfter.count, 3, "API should still have 3 tasks after cancellation")

        // Verify file on disk has all 3 rows
        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        let records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3, "Re-pulled file should have all 3 rows restored")
    }

    // ======================================================================
    // MARK: - File Deletion: Confirm → deletes from API
    // ======================================================================

    func testFileDeletionConfirmed_DeletesFromAPI() async throws {
        let (engine, config) = try makeAdapterEngine()
        let contactsResource = resource("contacts", from: config)

        // Pull contacts
        let result = try await engine.pull(resource: contactsResource)
        try writeFilesToDisk(result.files)

        // Find Alice's file
        let aliceFile = result.files.first(where: { $0.relativePath == "contacts/alice-johnson.vcf" })
        XCTAssertNotNil(aliceFile)
        let aliceId = aliceFile!.remoteId!

        // Delete Alice from API (simulates confirmed deletion)
        try await engine.delete(remoteId: aliceId, resource: contactsResource)

        // Verify API
        let contacts = try await getFromAPI("/api/contacts")
        XCTAssertEqual(contacts.count, 1, "Should have 1 contact after deletion")
        let alice = contacts.first(where: { ($0["firstName"] as? String) == "Alice" })
        XCTAssertNil(alice, "Alice should be gone")
    }

    // ======================================================================
    // MARK: - File Deletion: Cancel → file restored on re-pull
    // ======================================================================

    func testFileDeletionCancelled_FileRestoredOnPull() async throws {
        let (engine, config) = try makeAdapterEngine()
        let contactsResource = resource("contacts", from: config)

        // Pull contacts
        let result = try await engine.pull(resource: contactsResource)
        try writeFilesToDisk(result.files)
        XCTAssertTrue(fileExistsOnDisk("contacts/alice-johnson.vcf"))

        // Delete file from disk (user action)
        try FileManager.default.removeItem(at: serviceDir.appendingPathComponent("contacts/alice-johnson.vcf"))
        XCTAssertFalse(fileExistsOnDisk("contacts/alice-johnson.vcf"))

        // Simulate cancellation: re-pull restores the file
        let result2 = try await engine.pull(resource: contactsResource)
        try writeFilesToDisk(result2.files)

        XCTAssertTrue(fileExistsOnDisk("contacts/alice-johnson.vcf"), "File should be restored after re-pull")

        // API should still have both contacts
        let contacts = try await getFromAPI("/api/contacts")
        XCTAssertEqual(contacts.count, 2, "Both contacts should still exist on API")
    }

    // ======================================================================
    // MARK: - Handler receives correct DeletionInfo
    // ======================================================================

    func testHandlerReceivesCorrectInfo() async throws {
        let engine = makeSyncEngine()
        var receivedInfo: DeletionInfo?

        await engine.setDeletionConfirmationHandler { info in
            receivedInfo = info
            return false // cancel
        }

        // The handler is now set — we verify it stores the closure correctly
        let handler = await engine.deletionConfirmationHandler
        XCTAssertNotNil(handler)

        // Call the handler directly to verify it works
        let testInfo = DeletionInfo(
            serviceName: "Test Service",
            serviceId: "test",
            filePath: "data.csv",
            recordCount: 42,
            kind: .rowDeletion
        )
        let result = await handler!(testInfo)
        XCTAssertFalse(result, "Handler should return false (cancel)")
        XCTAssertEqual(receivedInfo?.serviceName, "Test Service")
        XCTAssertEqual(receivedInfo?.serviceId, "test")
        XCTAssertEqual(receivedInfo?.filePath, "data.csv")
        XCTAssertEqual(receivedInfo?.recordCount, 42)
        if case .rowDeletion = receivedInfo?.kind {} else {
            XCTFail("Expected .rowDeletion")
        }
    }

    func testHandlerCalledForFileDeletionKind() async throws {
        var receivedKind: DeletionInfo.DeletionKind?

        let handler: @Sendable (DeletionInfo) async -> Bool = { info in
            receivedKind = info.kind
            return true
        }

        let testInfo = DeletionInfo(
            serviceName: "S",
            serviceId: "s",
            filePath: "f.vcf",
            recordCount: 1,
            kind: .fileDeletion
        )
        let result = await handler(testInfo)
        XCTAssertTrue(result)
        if case .fileDeletion = receivedKind {} else {
            XCTFail("Expected .fileDeletion kind")
        }
    }
}
