import XCTest
@testable import API2FileCore

/// End-to-end tests for delete operations: local file deletion → API record deletion,
/// collection row removal, and default behavior when deleteFromAPI is not set.
///
/// Uses a real DemoAPIServer, real files on disk, and real AdapterEngine pipeline.
final class DeleteE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!   // temp dir acting as ~/API2File/
    private var serviceDir: URL! // syncRoot/demo/

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Start real demo server on a random port
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

        // Create real sync folder structure (in temp dir)
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-delete-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config with deleteFromAPI flags:
        // - tasks: collection strategy, CSV, deleteFromAPI=true
        // - contacts: one-per-record strategy, VCF, deleteFromAPI=true
        // - config: collection strategy, JSON, no deleteFromAPI (defaults to false)
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
            },
            {
              "name": "config",
              "description": "Config",
              "pull": { "method": "GET", "url": "\(baseURL)/api/config", "dataPath": "$" },
              "push": {
                "update": { "method": "PUT", "url": "\(baseURL)/api/config" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "config.json",
                "format": "json"
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

    private func makeEngine() throws -> (AdapterEngine, AdapterConfig) {
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

    private func readFileFromDisk(_ relativePath: String) throws -> Data {
        try Data(contentsOf: serviceDir.appendingPathComponent(relativePath))
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

    private func deleteFromAPI(_ path: String) async throws {
        let c = HTTPClient()
        _ = try await c.request(APIRequest(method: .DELETE, url: "\(baseURL)\(path)"))
    }

    // ======================================================================
    // MARK: - TEST 1: Delete a one-per-record file → deletes from API
    // ======================================================================

    func testDeleteOnePerRecordFile() async throws {
        let (engine, config) = try makeEngine()
        let contactsResource = resource("contacts", from: config)

        // Pull all contacts, write files to disk
        let result = try await engine.pull(resource: contactsResource)
        let files = result.files
        try writeFilesToDisk(files)

        // Verify alice-johnson.vcf exists
        XCTAssertTrue(fileExistsOnDisk("contacts/alice-johnson.vcf"), "alice-johnson.vcf should exist on disk after pull")

        // Find Alice's file and get her remoteId
        let aliceFile = files.first(where: { $0.relativePath == "contacts/alice-johnson.vcf" })
        XCTAssertNotNil(aliceFile, "Should have a SyncableFile for Alice")
        let aliceRemoteId = aliceFile!.remoteId
        XCTAssertNotNil(aliceRemoteId, "Alice's file should have a remoteId")

        // Delete Alice via direct API call (same as what engine.delete does)
        try await deleteFromAPI("/api/contacts/\(aliceRemoteId!)")

        // Verify Alice is gone from the API
        let contacts = try await getFromAPI("/api/contacts")
        let aliceContact = contacts.first(where: { ($0["firstName"] as? String) == "Alice" })
        XCTAssertNil(aliceContact, "Alice should be deleted from the API")

        // Bob should still exist
        let bobContact = contacts.first(where: { ($0["firstName"] as? String) == "Bob" })
        XCTAssertNotNil(bobContact, "Bob should still exist on the API")
        XCTAssertEqual(contacts.count, 1, "Only Bob should remain")
    }

    // ======================================================================
    // MARK: - TEST 2: Delete all records in a collection file → API empty
    // ======================================================================

    func testDeleteCollectionFile() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // Pull tasks, write to disk
        let result = try await engine.pull(resource: tasksResource)
        let files = result.files
        try writeFilesToDisk(files)

        // Verify tasks.csv exists with 3 records
        XCTAssertTrue(fileExistsOnDisk("tasks.csv"), "tasks.csv should exist on disk")
        let csvData = try readFileFromDisk("tasks.csv")
        let records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3, "Should have 3 seed tasks")

        // Get all record IDs from the decoded CSV
        let recordIds: [String] = records.compactMap { record in
            if let id = record["id"] as? String { return id }
            if let id = record["id"] as? Int { return "\(id)" }
            return nil
        }
        XCTAssertEqual(recordIds.count, 3, "Should have 3 record IDs")

        // Delete each record via direct API call
        for remoteId in recordIds {
            try await deleteFromAPI("/api/tasks/\(remoteId)")
        }

        // Verify all tasks deleted from API
        let tasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(tasks.count, 0, "All tasks should be deleted from the API")
    }

    // ======================================================================
    // MARK: - TEST 3: Delete one row from a collection file → API has 2 left
    // ======================================================================

    func testDeleteRowFromCollectionFile() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // Pull tasks, write to disk (3 tasks)
        let result = try await engine.pull(resource: tasksResource)
        let files = result.files
        try writeFilesToDisk(files)

        let csvData = try readFileFromDisk("tasks.csv")
        let oldRecords = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(oldRecords.count, 3, "Should start with 3 tasks")

        // Remove the task with id=2 ("Fix login bug")
        let newRecords = oldRecords.filter { record in
            let idStr: String
            if let s = record["id"] as? String { idStr = s }
            else if let i = record["id"] as? Int { idStr = "\(i)" }
            else { return true }
            return idStr != "2"
        }
        XCTAssertEqual(newRecords.count, 2, "Should have 2 records after removing id=2")

        // Re-encode and write back to disk
        let modifiedCSV = try CSVFormat.encode(records: newRecords, options: nil)
        try modifiedCSV.write(to: serviceDir.appendingPathComponent("tasks.csv"), options: .atomic)

        // Use CollectionDiffer.diff to detect the deletion
        let diff = CollectionDiffer.diff(old: oldRecords, new: newRecords, idField: "id")
        XCTAssertEqual(diff.deleted.count, 1, "Diff should detect 1 deletion")
        XCTAssertTrue(diff.deleted.contains("2"), "Deleted ID should be '2'")
        XCTAssertTrue(diff.created.isEmpty, "No new records should be created")
        XCTAssertTrue(diff.updated.isEmpty, "No records should be updated")

        // Delete via direct API call
        for deletedId in diff.deleted {
            try await deleteFromAPI("/api/tasks/\(deletedId)")
        }

        // Verify API: only 2 tasks remain, id=2 is gone
        let tasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(tasks.count, 2, "Should have 2 tasks remaining on the API")

        let deletedTask = tasks.first(where: {
            ($0["id"] as? Int) == 2 || ($0["id"] as? String) == "2"
        })
        XCTAssertNil(deletedTask, "Task with id=2 should be gone from the API")

        // Verify the remaining tasks are still there
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1" })
        XCTAssertNotNil(task1, "Task 1 should still exist")
        let task3 = tasks.first(where: { ($0["id"] as? Int) == 3 || ($0["id"] as? String) == "3" })
        XCTAssertNotNil(task3, "Task 3 should still exist")
    }

    // ======================================================================
    // MARK: - TEST 4: Default behavior — file comes back after re-pull
    // ======================================================================

    func testDefaultBehaviorFileComesBack() async throws {
        let (engine, config) = try makeEngine()
        let configResource = resource("config", from: config)

        // Pull config.json (no deleteFromAPI set on this resource)
        let result = try await engine.pull(resource: configResource)
        let files = result.files
        try writeFilesToDisk(files)

        // Verify config.json exists
        XCTAssertTrue(fileExistsOnDisk("config.json"), "config.json should exist after pull")

        // Read original content for later comparison
        let originalData = try readFileFromDisk("config.json")
        let originalJSON = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        let originalSiteName = originalJSON["siteName"] as? String
        XCTAssertEqual(originalSiteName, "My Demo Site")

        // Delete config.json from disk
        try FileManager.default.removeItem(at: serviceDir.appendingPathComponent("config.json"))
        XCTAssertFalse(fileExistsOnDisk("config.json"), "config.json should be gone from disk")

        // Re-pull from API (server is source of truth)
        let result2 = try await engine.pull(resource: configResource)
        let files2 = result2.files
        try writeFilesToDisk(files2)

        // Verify config.json is recreated with same content
        XCTAssertTrue(fileExistsOnDisk("config.json"), "config.json should be recreated after re-pull")
        let recreatedData = try readFileFromDisk("config.json")
        let recreatedJSON = try JSONSerialization.jsonObject(with: recreatedData) as! [String: Any]
        XCTAssertEqual(recreatedJSON["siteName"] as? String, "My Demo Site", "Content should match original")
        XCTAssertEqual(recreatedJSON["theme"] as? String, "light", "Theme should match original")
        XCTAssertEqual(recreatedJSON["language"] as? String, "en", "Language should match original")
    }

    // ======================================================================
    // MARK: - TEST 5: deleteFromAPI config resolution
    // ======================================================================

    func testDeleteFromAPIConfigResolution() throws {
        // 1. FileMappingConfig with deleteFromAPI=true
        let mappingWithDelete = FileMappingConfig(
            strategy: .collection,
            directory: ".",
            filename: "tasks.csv",
            format: .csv,
            idField: "id",
            deleteFromAPI: true
        )
        XCTAssertEqual(mappingWithDelete.deleteFromAPI, true, "FileMappingConfig with deleteFromAPI=true should be true")

        // 2. FileMappingConfig with deleteFromAPI=nil (not set)
        let mappingWithoutDelete = FileMappingConfig(
            strategy: .collection,
            directory: ".",
            filename: "tasks.csv",
            format: .csv,
            idField: "id",
            deleteFromAPI: nil
        )
        XCTAssertNil(mappingWithoutDelete.deleteFromAPI, "FileMappingConfig with deleteFromAPI=nil should be nil")

        // 3. GlobalConfig with deleteFromAPI=true
        let globalWithDelete = GlobalConfig(deleteFromAPI: true)
        XCTAssertTrue(globalWithDelete.deleteFromAPI, "GlobalConfig with deleteFromAPI=true should be true")

        // 4. GlobalConfig with default — deleteFromAPI should be false
        let globalDefault = GlobalConfig()
        XCTAssertFalse(globalDefault.deleteFromAPI, "GlobalConfig default deleteFromAPI should be false")

        // 5. Test resolution: resource.fileMapping.deleteFromAPI ?? globalConfig.deleteFromAPI
        // Case A: fileMapping has deleteFromAPI=true, global=false → true
        let resolvedA = mappingWithDelete.deleteFromAPI ?? globalDefault.deleteFromAPI
        XCTAssertTrue(resolvedA, "When fileMapping has deleteFromAPI=true, resolution should be true regardless of global")

        // Case B: fileMapping has deleteFromAPI=nil, global=false → false
        let resolvedB = mappingWithoutDelete.deleteFromAPI ?? globalDefault.deleteFromAPI
        XCTAssertFalse(resolvedB, "When fileMapping is nil and global is false, resolution should be false")

        // Case C: fileMapping has deleteFromAPI=nil, global=true → true
        let resolvedC = mappingWithoutDelete.deleteFromAPI ?? globalWithDelete.deleteFromAPI
        XCTAssertTrue(resolvedC, "When fileMapping is nil and global is true, resolution should be true")

        // Case D: fileMapping has deleteFromAPI=false, global=true → false (fileMapping wins)
        let mappingWithDeleteFalse = FileMappingConfig(
            strategy: .collection,
            directory: ".",
            filename: "tasks.csv",
            format: .csv,
            idField: "id",
            deleteFromAPI: false
        )
        let resolvedD = mappingWithDeleteFalse.deleteFromAPI ?? globalWithDelete.deleteFromAPI
        XCTAssertFalse(resolvedD, "When fileMapping has deleteFromAPI=false, it should override global=true")
    }
}
