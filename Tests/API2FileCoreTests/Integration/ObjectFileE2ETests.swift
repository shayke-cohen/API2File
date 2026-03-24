import XCTest
@testable import API2FileCore

/// End-to-end tests for object file and inverse transform pipeline.
/// Uses a real DemoAPIServer, real files on disk, and real AdapterEngine.
///
/// Validates that:
/// - Pull creates object files alongside user-facing files
/// - Object files contain raw (untransformed) API records
/// - Inverse transforms restore omitted fields from object files on push
/// - Agents can edit object files and regenerate user files
/// - New and deleted records work correctly with object files
final class ObjectFileE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Start real demo server on random port
        port = UInt16.random(in: 22000...28000)
        server = DemoAPIServer(port: port)
        try await server.start()

        // Wait for readiness with 10x retry
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch { continue }
        }
        await server.reset()

        // Create temp sync folder structure
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-objfile-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config with pull transforms (omit priority) on tasks
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
                "transforms": {
                  "pull": [
                    { "op": "omit", "fields": ["priority"] }
                  ]
                }
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
                "idField": "id"
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
        try adapterConfig.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )
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
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func writeObjectFiles(_ rawRecordsByFile: [String: [[String: Any]]]) throws {
        for (relativePath, records) in rawRecordsByFile {
            // Determine strategy from the file path
            let isOnePerRecord = relativePath.contains("/") && !relativePath.hasPrefix(".")
            if isOnePerRecord {
                // One-per-record: write to .objects/ subdirectory
                let objectPath = ObjectFileManager.objectFilePath(
                    forRecordFile: relativePath
                )
                let objectURL = serviceDir.appendingPathComponent(objectPath)
                if let record = records.first {
                    try ObjectFileManager.writeRecordObjectFile(record: record, to: objectURL)
                }
            } else {
                // Collection: write .{stem}.objects.json
                let objectPath = ObjectFileManager.objectFilePath(
                    forCollectionFile: relativePath
                )
                let objectURL = serviceDir.appendingPathComponent(objectPath)
                try ObjectFileManager.writeCollectionObjectFile(records: records, to: objectURL)
            }
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

    private func putToAPI(_ path: String, _ data: [String: Any]) async throws {
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await c.request(APIRequest(
            method: .PUT, url: "\(baseURL)\(path)",
            headers: ["Content-Type": "application/json"], body: body
        ))
    }

    private func postToAPI(_ path: String, _ data: [String: Any]) async throws {
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await c.request(APIRequest(
            method: .POST, url: "\(baseURL)\(path)",
            headers: ["Content-Type": "application/json"], body: body
        ))
    }

    private func deleteFromAPI(_ path: String) async throws {
        let c = HTTPClient()
        _ = try await c.request(APIRequest(method: .DELETE, url: "\(baseURL)\(path)"))
    }

    // ======================================================================
    // MARK: - TEST 1: Pull creates object files alongside user files
    // ======================================================================

    func testPullCreatesObjectFiles() async throws {
        let (engine, _) = try makeEngine()

        // Pull all resources
        let result = try await engine.pullAll()
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // --- Tasks: collection strategy ---
        // User file should exist
        XCTAssertTrue(fileExistsOnDisk("tasks.csv"), "tasks.csv should exist on disk")

        // Object file should exist: .tasks.objects.json
        let tasksObjectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        XCTAssertTrue(
            fileExistsOnDisk(tasksObjectPath),
            ".tasks.objects.json should exist alongside tasks.csv"
        )

        // Object file should contain raw records WITH "priority" field
        let rawRecords = try ObjectFileManager.readCollectionObjectFile(
            from: serviceDir.appendingPathComponent(tasksObjectPath)
        )
        XCTAssertEqual(rawRecords.count, 3, "Object file should have 3 raw records")
        for record in rawRecords {
            XCTAssertNotNil(
                record["priority"],
                "Raw record should contain 'priority' field (omitted from CSV)"
            )
        }

        // CSV should NOT contain "priority" column
        let csvString = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertFalse(
            csvString.contains("priority"),
            "tasks.csv should NOT contain 'priority' (it was omitted by pull transform)"
        )

        // --- Contacts: one-per-record strategy ---
        let contactFiles = result.files.filter { $0.relativePath.hasSuffix(".vcf") }
        XCTAssertEqual(contactFiles.count, 2, "Should have 2 VCF contact files")

        // Verify .objects/ directory exists for contacts
        let contactsObjectsDir = serviceDir.appendingPathComponent("contacts/.objects")
        var isDir: ObjCBool = false
        let objectsDirExists = FileManager.default.fileExists(
            atPath: contactsObjectsDir.path,
            isDirectory: &isDir
        )
        XCTAssertTrue(objectsDirExists && isDir.boolValue, "contacts/.objects/ directory should exist")
    }

    // ======================================================================
    // MARK: - TEST 2: Object file contains raw (untransformed) records
    // ======================================================================

    func testObjectFileContainsRawRecords() async throws {
        let (engine, config) = try makeEngine()

        // Pull tasks
        let result = try await engine.pull(resource: resource("tasks", from: config))
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // Read object file
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let rawRecords = try ObjectFileManager.readCollectionObjectFile(
            from: serviceDir.appendingPathComponent(objectPath)
        )

        // Verify each raw record has all expected fields including "priority"
        XCTAssertEqual(rawRecords.count, 3, "Should have 3 raw task records")
        for record in rawRecords {
            XCTAssertNotNil(record["id"], "Raw record should have 'id'")
            XCTAssertNotNil(record["name"], "Raw record should have 'name'")
            XCTAssertNotNil(record["status"], "Raw record should have 'status'")
            XCTAssertNotNil(record["priority"], "Raw record should have 'priority' (omitted from CSV)")
            XCTAssertNotNil(record["assignee"], "Raw record should have 'assignee'")
            XCTAssertNotNil(record["dueDate"], "Raw record should have 'dueDate'")
        }

        // Count should match what the API returns
        let apiTasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(rawRecords.count, apiTasks.count, "Object file record count should match API")
    }

    // ======================================================================
    // MARK: - TEST 3: Reverse push restores omitted fields via inverse transforms
    // ======================================================================

    func testReversePushRestoresOmittedFields() async throws {
        let (engine, config) = try makeEngine()

        // Pull tasks (creates files + object files)
        let result = try await engine.pull(resource: resource("tasks", from: config))
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // Decode the CSV
        let csvData = try readFileFromDisk("tasks.csv")
        var editedRecords = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(editedRecords.count, 3)

        // Edit task 1: change name
        if let idx = editedRecords.firstIndex(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        }) {
            editedRecords[idx]["name"] = "Buy organic groceries"
        }

        // Read raw records from object file
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let rawRecords = try ObjectFileManager.readCollectionObjectFile(
            from: serviceDir.appendingPathComponent(objectPath)
        )

        // Compute inverse transforms
        let pullTransforms = resource("tasks", from: config).fileMapping.transforms?.pull ?? []
        let inverseOps = InverseTransformPipeline.computeInverse(of: pullTransforms)
        XCTAssertFalse(inverseOps.isEmpty, "Should have inverse ops for the omit transform")

        // Apply inverse to the edited record, using the matching raw record
        let editedTask1 = editedRecords.first(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        })!
        let rawTask1 = rawRecords.first(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        })!

        let merged = InverseTransformPipeline.apply(
            inverseOps: inverseOps,
            editedRecord: editedTask1,
            rawRecord: rawTask1
        )

        // Verify: "priority" field is restored from object file
        XCTAssertNotNil(merged["priority"], "Merged record should have 'priority' restored")
        XCTAssertEqual(merged["priority"] as? String, "medium", "Priority should be 'medium' from raw record")

        // Verify: edited "name" field is updated
        XCTAssertEqual(merged["name"] as? String, "Buy organic groceries", "Edited name should be preserved")
    }

    // ======================================================================
    // MARK: - TEST 4: Full round-trip: pull, edit CSV, inverse transform, push, re-pull
    // ======================================================================

    func testReversePushFullRoundTrip() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Pull tasks
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // 2. Decode CSV, change task 1 name
        let csvData = try readFileFromDisk("tasks.csv")
        var editedRecords = try CSVFormat.decode(data: csvData, options: nil)
        if let idx = editedRecords.firstIndex(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        }) {
            editedRecords[idx]["name"] = "Buy organic groceries"
        }

        // 3. Read raw records from object file
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let rawRecords = try ObjectFileManager.readCollectionObjectFile(
            from: serviceDir.appendingPathComponent(objectPath)
        )

        // 4. Apply inverse transforms to merge edit + raw
        let pullTransforms = tasksResource.fileMapping.transforms?.pull ?? []
        let inverseOps = InverseTransformPipeline.computeInverse(of: pullTransforms)

        let editedTask1 = editedRecords.first(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        })!
        let rawTask1 = rawRecords.first(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        })!

        let merged = InverseTransformPipeline.apply(
            inverseOps: inverseOps,
            editedRecord: editedTask1,
            rawRecord: rawTask1
        )

        // 5. PUT merged record to API
        try await putToAPI("/api/tasks/1", merged)

        // 6. GET from API — verify name changed AND priority preserved
        let apiTasks = try await getFromAPI("/api/tasks")
        let task1 = apiTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(task1, "Task 1 should still exist on server")
        XCTAssertEqual(task1?["name"] as? String, "Buy organic groceries", "Name should be updated")
        XCTAssertEqual(task1?["priority"] as? String, "medium", "Priority should be preserved on server")

        // 7. Re-pull and verify CSV reflects the change
        let result2 = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result2.files)
        let csv2 = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(csv2.contains("Buy organic groceries"), "Re-pulled CSV should contain edited name")
        XCTAssertFalse(csv2.contains("priority"), "Re-pulled CSV should still omit 'priority'")
    }

    // ======================================================================
    // MARK: - TEST 5: Agent edits object file, regenerates user file
    // ======================================================================

    func testAgentEditsObjectFile() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Pull tasks (creates object files)
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // 2. Read object file, modify a field in a record
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)

        // Edit task 2: change name in the raw record
        if let idx = rawRecords.firstIndex(where: {
            ($0["id"] as? Int) == 2 || ($0["id"] as? String) == "2"
        }) {
            rawRecords[idx]["name"] = "Fix critical login bug"
        }

        // 3. Write modified object file back
        try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)

        // 4. Apply pull transforms to the edited raw records
        let pullTransforms = tasksResource.fileMapping.transforms?.pull ?? []
        let transformed = pullTransforms.isEmpty
            ? rawRecords
            : TransformPipeline.apply(pullTransforms, to: rawRecords)

        // 5. Encode as CSV
        let regeneratedCSV = try CSVFormat.encode(records: transformed, options: nil)
        let csvString = String(data: regeneratedCSV, encoding: .utf8)!

        // 6. Verify the regenerated CSV reflects the change
        XCTAssertTrue(
            csvString.contains("Fix critical login bug"),
            "Regenerated CSV should contain the agent's edit"
        )
        XCTAssertFalse(
            csvString.contains("Fix login bug"),
            "Regenerated CSV should NOT contain the old name"
        )
        // Priority should still be omitted in the CSV
        XCTAssertFalse(
            csvString.contains("priority"),
            "Regenerated CSV should not contain 'priority' column"
        )
    }

    // ======================================================================
    // MARK: - TEST 6: New record without object file entry
    // ======================================================================

    func testNewRecordWithoutObjectFile() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Pull tasks (creates object files with 3 records)
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // Verify initial state
        let initialTasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(initialTasks.count, 3, "Should start with 3 tasks")

        // 2. Create a new task record (no object file entry for it)
        let newRecord: [String: Any] = [
            "name": "Deploy to staging",
            "status": "todo",
            "assignee": "Charlie",
            "dueDate": "2026-04-01"
        ]

        // 3. Apply mechanical inverse transforms (no raw record to merge with)
        let pullTransforms = tasksResource.fileMapping.transforms?.pull ?? []
        let inverseOps = InverseTransformPipeline.computeInverse(of: pullTransforms)
        let mechanicalResult = InverseTransformPipeline.applyMechanical(
            inverseOps: inverseOps,
            editedRecord: newRecord
        )

        // 4. POST to API
        try await postToAPI("/api/tasks", mechanicalResult)

        // 5. Verify new task exists on server
        let finalTasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(finalTasks.count, 4, "Should now have 4 tasks")
        let newTask = finalTasks.first(where: { ($0["name"] as? String) == "Deploy to staging" })
        XCTAssertNotNil(newTask, "New task should exist on server")
        XCTAssertEqual(newTask?["status"] as? String, "todo")
        XCTAssertEqual(newTask?["assignee"] as? String, "Charlie")
    }

    // ======================================================================
    // MARK: - TEST 7: Deleted record removed from object file
    // ======================================================================

    func testDeletedRecordRemovedFromObjectFile() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Pull tasks (3 records in object file)
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // Read object file to confirm 3 records
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        let rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
        XCTAssertEqual(rawRecords.count, 3, "Object file should have 3 records initially")

        // 2. Identify the record to delete (task 3: "Write docs")
        let csvData = try readFileFromDisk("tasks.csv")
        let oldRecords = try CSVFormat.decode(data: csvData, options: nil)
        let newRecords = oldRecords.filter {
            !(($0["id"] as? Int) == 3 || ($0["id"] as? String) == "3")
        }

        // 3. Diff to detect deletion
        let deletedIds = oldRecords.compactMap { record -> String? in
            let id = record["id"]
            let idStr: String
            if let intId = id as? Int { idStr = "\(intId)" }
            else if let strId = id as? String { idStr = strId }
            else { return nil }

            let stillExists = newRecords.contains {
                ($0["id"] as? Int).map(String.init) == idStr ||
                ($0["id"] as? String) == idStr
            }
            return stillExists ? nil : idStr
        }

        XCTAssertEqual(deletedIds, ["3"], "Should detect task 3 as deleted")

        // 4. DELETE from API
        for id in deletedIds {
            try await deleteFromAPI("/api/tasks/\(id)")
        }

        // 5. Verify record is gone from API
        let finalTasks = try await getFromAPI("/api/tasks")
        XCTAssertEqual(finalTasks.count, 2, "Should now have 2 tasks after deletion")
        let deletedTask = finalTasks.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNil(deletedTask, "Task 3 should be gone from server")
    }

    // ======================================================================
    // MARK: - TEST 8: Object file round-trip preserves all fields (JSON fidelity)
    // ======================================================================

    func testObjectFileRoundTripPreservesAllFields() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Pull tasks
        let result = try await engine.pull(resource: tasksResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // 2. Read object file
        let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv")
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        let firstRead = try ObjectFileManager.readCollectionObjectFile(from: objectURL)

        // 3. Write it back unchanged
        try ObjectFileManager.writeCollectionObjectFile(records: firstRead, to: objectURL)

        // 4. Read again
        let secondRead = try ObjectFileManager.readCollectionObjectFile(from: objectURL)

        // 5. Verify all fields match exactly
        XCTAssertEqual(firstRead.count, secondRead.count, "Record count should be identical")

        for (i, original) in firstRead.enumerated() {
            let roundTripped = secondRead[i]

            // Compare all keys
            XCTAssertEqual(
                Set(original.keys), Set(roundTripped.keys),
                "Keys at index \(i) should match after round-trip"
            )

            // Compare each field value
            for key in original.keys {
                let origVal = "\(original[key] ?? "nil")"
                let rtVal = "\(roundTripped[key] ?? "nil")"
                XCTAssertEqual(
                    origVal, rtVal,
                    "Field '\(key)' at index \(i) should match after round-trip"
                )
            }
        }
    }

    // ======================================================================
    // MARK: - TEST 9: One-per-record object files for contacts
    // ======================================================================

    func testOnePerRecordObjectFiles() async throws {
        let (engine, config) = try makeEngine()
        let contactsResource = resource("contacts", from: config)

        // 1. Pull contacts (one-per-record, VCF)
        let result = try await engine.pull(resource: contactsResource)
        try writeFilesToDisk(result.files)
        try writeObjectFiles(result.rawRecordsByFile)

        // 2. Verify contacts/.objects/ directory exists
        let objectsDir = serviceDir.appendingPathComponent("contacts/.objects")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: objectsDir.path, isDirectory: &isDir) && isDir.boolValue,
            "contacts/.objects/ directory should exist"
        )

        // 3. Verify one .json file per contact
        let objectFiles = try FileManager.default.contentsOfDirectory(
            at: objectsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(objectFiles.count, 2, "Should have one .json object file per contact")

        // 4. Read a contact object file and verify it has full API fields
        let firstObjectFile = objectFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first!
        let contactRecord = try ObjectFileManager.readRecordObjectFile(from: firstObjectFile)
        XCTAssertNotNil(contactRecord["id"], "Contact object should have 'id'")
        XCTAssertNotNil(contactRecord["firstName"], "Contact object should have 'firstName'")
        XCTAssertNotNil(contactRecord["lastName"], "Contact object should have 'lastName'")
        XCTAssertNotNil(contactRecord["email"], "Contact object should have 'email'")
        XCTAssertNotNil(contactRecord["phone"], "Contact object should have 'phone'")
        XCTAssertNotNil(contactRecord["company"], "Contact object should have 'company'")

        // 5. Verify VCF files exist alongside
        let vcfFiles = result.files.filter { $0.relativePath.hasSuffix(".vcf") }
        XCTAssertEqual(vcfFiles.count, 2, "Should have 2 VCF files")
        for vcf in vcfFiles {
            XCTAssertTrue(fileExistsOnDisk(vcf.relativePath), "\(vcf.relativePath) should exist on disk")
        }
    }

    // ======================================================================
    // MARK: - TEST 10: PullResult contains raw records with untransformed data
    // ======================================================================

    func testPullResultContainsRawRecords() async throws {
        let (engine, config) = try makeEngine()
        let tasksResource = resource("tasks", from: config)

        // 1. Use AdapterEngine.pull() directly
        let result = try await engine.pull(resource: tasksResource)

        // 2. Verify rawRecordsByFile is populated
        XCTAssertFalse(
            result.rawRecordsByFile.isEmpty,
            "PullResult.rawRecordsByFile should be populated"
        )

        // 3. Verify raw records contain untransformed data (e.g., "priority" field)
        let tasksRaw = result.rawRecordsByFile["tasks.csv"]
        XCTAssertNotNil(tasksRaw, "Raw records should be keyed by file path 'tasks.csv'")
        XCTAssertEqual(tasksRaw?.count, 3, "Should have 3 raw records")

        for record in tasksRaw ?? [] {
            XCTAssertNotNil(
                record["priority"],
                "Raw record should contain 'priority' (untransformed)"
            )
        }

        // 4. Verify files contain transformed data (no "priority")
        let csvFile = result.files.first(where: { $0.relativePath == "tasks.csv" })
        XCTAssertNotNil(csvFile, "Should have tasks.csv in files")

        let csvString = String(data: csvFile!.content, encoding: .utf8)!
        XCTAssertFalse(
            csvString.contains("priority"),
            "CSV file content should NOT contain 'priority' (transformed/omitted)"
        )

        // Decoded CSV records should also lack priority
        let csvRecords = try CSVFormat.decode(data: csvFile!.content, options: nil)
        for record in csvRecords {
            XCTAssertNil(
                record["priority"],
                "Decoded CSV record should NOT have 'priority'"
            )
        }
    }
}
