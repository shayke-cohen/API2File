import XCTest
@testable import API2FileCore

/// True end-to-end tests for the live auto-push and auto-pull pipeline.
///
/// These tests prove the full loop:
///   SyncEngine.start() -> FSEvents watches files -> user edits a file
///   -> debounce -> CollectionDiffer diffs -> push to API
///
/// And the reverse:
///   API change -> periodic poll pull -> file updated on disk
///
/// No mocks. Real DemoAPIServer, real filesystem, real FSEvents, real SyncEngine.
final class LiveAutoPushE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!     // temp dir acting as ~/API2File/
    private var serviceDir: URL!   // syncRoot/demo/
    private var engine: SyncEngine!
    private let keychain = KeychainManager()
    private let authKey = "api2file.demo.livetest"

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Pick a random port to avoid conflicts with parallel test runs
        port = UInt16.random(in: 29000...32000)
        server = DemoAPIServer(port: port)
        try await server.start()

        // Wait for server readiness (poll until it responds)
        var ready = false
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
            do {
                let (_, response) = try await URLSession.shared.data(
                    from: URL(string: "\(baseURL)/api/tasks")!
                )
                if let r = response as? HTTPURLResponse, r.statusCode == 200 {
                    ready = true
                    break
                }
            } catch {
                continue
            }
        }
        guard ready else {
            XCTFail("DemoAPIServer did not become ready on port \(port!)")
            return
        }

        // Reset server to seed data
        await server.reset()
        _ = await keychain.save(key: authKey, value: "demo-token")

        // Create temp sync folder structure
        // IMPORTANT: Resolve symlinks on the base temp directory so that FSEvents paths
        // match the watched paths. On macOS, /var -> /private/var and /tmp -> /private/tmp,
        // so FSEvents reports canonical paths while FileManager.temporaryDirectory uses
        // symlinked paths. Resolve the symlink on the existing base BEFORE appending
        // the unique subdirectory name.
        let resolvedTmpDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        syncRoot = resolvedTmpDir
            .appendingPathComponent("api2file-live-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter.json pointing to our local server
        // Sync interval = 5 seconds (fast enough for tests, not too aggressive)
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.livetest" },
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
                "idField": "id"
              },
              "sync": { "interval": 5 }
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
        // Stop engine first
        if let engine = engine {
            await engine.stop()
        }
        engine = nil

        // Stop server
        if let server = server {
            await server.stop()
        }
        server = nil

        // Clean up temp directory
        if let dir = syncRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        syncRoot = nil
        serviceDir = nil
        await keychain.delete(key: authKey)

        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Create a GlobalConfig pointing to our temp sync root.
    /// Uses the absolute path (no tilde) so resolvedSyncFolder works correctly.
    private func makeConfig() -> GlobalConfig {
        GlobalConfig(
            syncFolder: syncRoot.path,  // absolute path, no ~
            gitAutoCommit: false,
            defaultSyncInterval: 5,
            showNotifications: false,
            serverPort: Int(port)
        )
    }

    /// Start the SyncEngine and wait for initial pull to complete.
    /// Returns the engine (which is also stored in self.engine).
    @discardableResult
    private func startEngine() async throws -> SyncEngine {
        let config = makeConfig()
        let eng = SyncEngine(config: config)
        engine = eng
        try await eng.start()
        return eng
    }

    /// Query tasks from the API directly.
    private func getTasksFromAPI() async throws -> [[String: Any]] {
        let client = HTTPClient()
        let response = try await client.request(
            APIRequest(method: .GET, url: "\(baseURL)/api/tasks")
        )
        let json = try JSONSerialization.jsonObject(with: response.body)
        return json as? [[String: Any]] ?? []
    }

    /// Read the tasks.csv file from disk.
    private func readTasksCSV() throws -> String {
        let path = serviceDir.appendingPathComponent("tasks.csv")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Check if tasks.csv exists on disk.
    private func tasksCSVExists() -> Bool {
        FileManager.default.fileExists(
            atPath: serviceDir.appendingPathComponent("tasks.csv").path
        )
    }

    private func fileLinksURL() -> URL {
        serviceDir.appendingPathComponent(".api2file/file-links.json")
    }

    private func readFileLinks() throws -> FileLinkIndex {
        try FileLinkManager.load(from: serviceDir)
    }

    private func tasksObjectURL() -> URL {
        serviceDir.appendingPathComponent(".tasks.objects.json")
    }

    private func writeTasksObjectJSONTriggeringFSEvents(_ records: [[String: Any]]) throws {
        let targetPath = tasksObjectURL()
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        let handle = try FileHandle(forWritingTo: targetPath)
        handle.truncateFile(atOffset: 0)
        handle.write(data)
        handle.closeFile()
    }

    /// Write content to tasks.csv using a method that triggers FSEvents reliably.
    /// Uses in-place FileHandle write which consistently triggers kFSEventStreamEventFlagItemModified.
    private func writeTasksCSVTriggeringFSEvents(_ content: String) throws {
        let targetPath = serviceDir.appendingPathComponent("tasks.csv")
        let data = content.data(using: .utf8)!

        // Strategy: truncate and rewrite in place using FileHandle.
        // This avoids atomic-write / rename which may not trigger FSEvents reliably
        // in all environments.
        let handle = try FileHandle(forWritingTo: targetPath)
        handle.truncateFile(atOffset: 0)
        handle.write(data)
        handle.closeFile()
    }

    /// Post a new task to the API directly.
    private func postTaskToAPI(_ data: [String: Any]) async throws {
        let client = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await client.request(
            APIRequest(
                method: .POST,
                url: "\(baseURL)/api/tasks",
                headers: ["Content-Type": "application/json"],
                body: body
            )
        )
    }

    /// Update a task on the API directly.
    private func putTaskToAPI(id: Int, data: [String: Any]) async throws {
        let client = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await client.request(
            APIRequest(
                method: .PUT,
                url: "\(baseURL)/api/tasks/\(id)",
                headers: ["Content-Type": "application/json"],
                body: body
            )
        )
    }

    // ======================================================================
    // MARK: - TEST 1: Live Auto-Push — Edit CSV on Disk, Verify API Updated
    // ======================================================================

    func testLiveAutoPush_EditCSVOnDisk_PushesToAPI() async throws {
        // 1. Start the SyncEngine (performs initial pull)
        try await startEngine()

        // 2. Wait for initial pull to complete and tasks.csv to appear
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Verify tasks.csv was pulled
        XCTAssertTrue(tasksCSVExists(), "tasks.csv should exist after initial pull")
        let initialCSV = try readTasksCSV()
        XCTAssertTrue(initialCSV.contains("Buy groceries"), "CSV should contain seed data")

        // 3. Read current CSV, decode, modify, re-encode, write back
        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        var records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3, "Should have 3 seed tasks")

        // Change task 1's name
        if let idx = records.firstIndex(where: {
            ($0["id"] as? String) == "1" || ($0["id"] as? Int) == 1
        }) {
            records[idx]["name"] = "Buy organic groceries from live test"
        } else {
            XCTFail("Could not find task with id 1")
            return
        }

        // Re-encode to CSV
        let modifiedCSVData = try CSVFormat.encode(records: records, options: nil)
        let modifiedCSV = String(data: modifiedCSVData, encoding: .utf8)!

        // 4. Write the modified CSV to disk (triggering FSEvents)
        try writeTasksCSVTriggeringFSEvents(modifiedCSV)

        // 5. Wait for FSEvents debounce (500ms) + sync cycle (up to 5s) + processing
        // The flow: FSEvents fires -> debounce 500ms -> handleFileChanges -> queuePush
        // -> next sync cycle processes the push
        // Be generous: wait 8 seconds total
        try await Task.sleep(nanoseconds: 8_000_000_000)

        // 6. Verify the API reflects the change
        let apiTasks = try await getTasksFromAPI()
        let task1 = apiTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(task1, "Task 1 should still exist in API")
        XCTAssertEqual(
            task1?["name"] as? String,
            "Buy organic groceries from live test",
            "API should reflect the local file edit"
        )
    }

    func testLiveAutoPush_EditCSVDuringPull_IsQueuedAndPushedAfterPull() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(tasksCSVExists(), "tasks.csv should exist after initial pull")

        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        var records = try CSVFormat.decode(data: csvData, options: nil)
        guard let idx = records.firstIndex(where: {
            ($0["id"] as? String) == "1" || ($0["id"] as? Int) == 1
        }) else {
            XCTFail("Could not find task with id 1")
            return
        }
        records[idx]["name"] = "Buy groceries while pull is active"
        let modifiedCSV = String(
            data: try CSVFormat.encode(records: records, options: nil),
            encoding: .utf8
        )!

        await server.setArtificialDelay(pathPrefix: "/api/tasks", milliseconds: 7_000)

        // Polling is 5s in this suite, so this lands inside the next delayed pull.
        try await Task.sleep(nanoseconds: 5_600_000_000)
        try writeTasksCSVTriggeringFSEvents(modifiedCSV)

        // Give the delayed pull time to complete and the queued push time to flush.
        try await Task.sleep(nanoseconds: 12_000_000_000)

        let apiTasks = try await getTasksFromAPI()
        let task1 = apiTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(
            task1?["name"] as? String,
            "Buy groceries while pull is active",
            "Edits made during pull should be queued and pushed after the pull finishes"
        )
    }

    func testInitialPullBuildsFileLinksForInstalledService() async throws {
        try await startEngine()

        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fileLinksURL().path),
            "file-links.json should be created during startup sync"
        )

        let links = try readFileLinks()
        let tasksLink = try XCTUnwrap(links.links.first(where: { $0.userPath == "tasks.csv" }))
        XCTAssertEqual(tasksLink.resourceName, "tasks")
        XCTAssertEqual(tasksLink.canonicalPath, ".tasks.objects.json")
    }

    func testLiveObjectFileEdit_RegeneratesCSVAndPushesToAPI() async throws {
        try await startEngine()

        try await Task.sleep(nanoseconds: 2_000_000_000)

        XCTAssertTrue(tasksCSVExists(), "tasks.csv should exist after initial pull")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tasksObjectURL().path),
            ".tasks.objects.json should exist after initial pull"
        )

        var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: tasksObjectURL())
        guard let index = rawRecords.firstIndex(where: {
            ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1"
        }) else {
            XCTFail("Could not find task with id 1 in object file")
            return
        }
        rawRecords[index]["name"] = "Canonical edit from object watcher test"
        try writeTasksObjectJSONTriggeringFSEvents(rawRecords)

        try await Task.sleep(nanoseconds: 3_000_000_000)

        let csv = try readTasksCSV()
        XCTAssertTrue(
            csv.contains("Canonical edit from object watcher test"),
            "tasks.csv should be regenerated from the object file edit"
        )

        let apiTasks = try await getTasksFromAPI()
        let updatedTask = apiTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(updatedTask?["name"] as? String, "Canonical edit from object watcher test")
    }

    // ======================================================================
    // MARK: - TEST 1b: Immediate Push — Change Reaches API in Under 2.5 Seconds
    // ======================================================================
    // Without the flushPendingPushes call in handleFileChanges, the push waits for
    // the next polling interval (5 s in this test setup). This test would FAIL with
    // the old code because it only waits 2.5 s — proving immediacy.

    func testImmediatePush_FileChangeReachesAPIWithinTwoAndAHalfSeconds() async throws {
        try await startEngine()
        try await Task.sleep(nanoseconds: 2_000_000_000) // wait for initial pull

        XCTAssertTrue(tasksCSVExists(), "tasks.csv must exist after initial pull")

        // Read and modify task 1's name
        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        var records = try CSVFormat.decode(data: csvData, options: nil)
        guard let idx = records.firstIndex(where: {
            ($0["id"] as? String) == "1" || ($0["id"] as? Int) == 1
        }) else {
            XCTFail("Task with id 1 not found in CSV"); return
        }
        records[idx]["name"] = "Immediate push verified"

        let modified = try CSVFormat.encode(records: records, options: nil)
        try writeTasksCSVTriggeringFSEvents(String(data: modified, encoding: .utf8)!)

        // Wait 2.5 s — well below the 5 s polling interval.
        // Without immediate flush this would time out; with it the push fires within ~1 s.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let apiTasks = try await getTasksFromAPI()
        let task1 = apiTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(
            task1?["name"] as? String,
            "Immediate push verified",
            "API should reflect the local edit within 2.5 s (immediate push, not next poll cycle)"
        )
    }

    // ======================================================================
    // MARK: - TEST 2: Live Auto-Pull — Server Change Appears in File
    // ======================================================================

    func testLiveAutoPull_ServerChange_AppearsInFile() async throws {
        // 1. Start the SyncEngine (performs initial pull)
        try await startEngine()

        // 2. Wait for initial pull
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify initial state
        XCTAssertTrue(tasksCSVExists(), "tasks.csv should exist after initial pull")
        let initialCSV = try readTasksCSV()
        XCTAssertTrue(initialCSV.contains("Buy groceries"))
        XCTAssertFalse(initialCSV.contains("Server-added task"))

        // 3. Change data directly via API (simulating another user or system)
        try await postTaskToAPI([
            "name": "Server-added task",
            "status": "todo",
            "priority": "critical",
            "assignee": "ServerBot",
            "dueDate": "2026-12-25"
        ])

        // Verify the API has the new task
        let apiTasks = try await getTasksFromAPI()
        XCTAssertEqual(apiTasks.count, 4, "API should now have 4 tasks")

        // 4. Wait for the next poll cycle to pull the change
        // Sync interval is 5 seconds, plus processing time
        try await Task.sleep(nanoseconds: 8_000_000_000)

        // 5. Verify the file on disk now contains the new task
        let updatedCSV = try readTasksCSV()
        XCTAssertTrue(
            updatedCSV.contains("Server-added task"),
            "Local CSV should contain the server-added task after auto-pull"
        )
        XCTAssertTrue(
            updatedCSV.contains("critical"),
            "CSV should contain the priority of the new task"
        )

        // Decode to verify count
        let csvData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        let records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 4, "Should have 4 tasks on disk after pull")
    }

    // ======================================================================
    // MARK: - TEST 3: Live Round-Trip — Pull -> Edit -> Push -> API Change -> Pull -> Verify
    // ======================================================================

    func testLiveRoundTrip_PullEditPush() async throws {
        // 1. Start the SyncEngine
        try await startEngine()

        // 2. Wait for initial pull
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify initial state: 3 seed tasks on disk
        XCTAssertTrue(tasksCSVExists(), "tasks.csv should exist")
        let csvData1 = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        let records1 = try CSVFormat.decode(data: csvData1, options: nil)
        XCTAssertEqual(records1.count, 3, "Should start with 3 tasks")

        // --- PHASE 1: Local edit -> push to API ---

        // 3. Edit the CSV locally (change task 2's status)
        var editedRecords = records1
        if let idx = editedRecords.firstIndex(where: {
            ($0["id"] as? String) == "2" || ($0["id"] as? Int) == 2
        }) {
            editedRecords[idx]["status"] = "done"
            editedRecords[idx]["name"] = "Fix login bug (verified)"
        }

        let editedCSVData = try CSVFormat.encode(records: editedRecords, options: nil)
        let editedCSV = String(data: editedCSVData, encoding: .utf8)!
        try writeTasksCSVTriggeringFSEvents(editedCSV)

        // 4. Wait for push cycle
        try await Task.sleep(nanoseconds: 8_000_000_000)

        // 5. Verify API has the local edit
        let apiTasks1 = try await getTasksFromAPI()
        let task2 = apiTasks1.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(task2, "Task 2 should exist in API")
        XCTAssertEqual(
            task2?["name"] as? String,
            "Fix login bug (verified)",
            "API should reflect local name edit"
        )

        // --- PHASE 2: Remote change -> pull to disk ---

        // 6. Add a new task via the API
        try await postTaskToAPI([
            "name": "Round-trip remote task",
            "status": "in-progress",
            "priority": "high",
            "assignee": "RoundTripBot",
            "dueDate": "2026-06-01"
        ])

        // Also update task 1 remotely
        try await putTaskToAPI(id: 1, data: [
            "name": "Buy organic groceries (round-trip)"
        ])

        // 7. Wait for pull cycle
        try await Task.sleep(nanoseconds: 8_000_000_000)

        // 8. Verify the file reflects BOTH the remote changes
        let finalCSV = try readTasksCSV()
        XCTAssertTrue(
            finalCSV.contains("Round-trip remote task"),
            "CSV should contain the remotely-added task"
        )
        XCTAssertTrue(
            finalCSV.contains("Buy organic groceries (round-trip)"),
            "CSV should reflect the remote update to task 1"
        )

        // Verify total count: 3 original + 1 added = 4
        let finalData = try Data(contentsOf: serviceDir.appendingPathComponent("tasks.csv"))
        let finalRecords = try CSVFormat.decode(data: finalData, options: nil)
        XCTAssertEqual(finalRecords.count, 4, "Should have 4 tasks after round-trip")
    }
}
