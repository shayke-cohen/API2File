import XCTest
@testable import API2FileCore

final class ManagedWorkspaceDemoAdapterBidirectionalTests: XCTestCase {
    private var demoServer: DemoAPIServer!
    private var syncEngine: SyncEngine!
    private var localServer: LocalServer!
    private var tempRoot: URL!
    private var syncRoot: URL!
    private var workspaceRoot: URL!
    private var keychain: KeychainManager!
    private let keychainKey = "api2file.demo.key"
    private var port: UInt16!
    private var localPort: UInt16!

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 22000...28000)
        demoServer = DemoAPIServer(port: port)
        try await demoServer.start()

        try await waitUntil("demo server ready") {
            do {
                let url = try XCTUnwrap(URL(string: "http://localhost:\(self.port!)/api/tasks"))
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-managed-demo-adapter-\(UUID().uuidString)", isDirectory: true)
        syncRoot = tempRoot.appendingPathComponent("sync", isDirectory: true)
        workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("support", isDirectory: true)
        let adapters = tempRoot.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)

        let serviceDir = syncRoot.appendingPathComponent("demo", isDirectory: true)
        let api2fileDir = serviceDir.appendingPathComponent(".api2file", isDirectory: true)
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        try makeManagedDemoAdapterConfig().write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )

        keychain = KeychainManager(keyPrefix: "com.api2file.tests.managed-demo-adapter.")
        _ = await keychain.save(key: keychainKey, value: "demo-token")

        let storage = StorageLocations(
            homeDirectory: tempRoot,
            syncRootDirectory: syncRoot,
            managedWorkspaceDirectory: workspaceRoot,
            adaptersDirectory: adapters,
            applicationSupportDirectory: appSupport
        )
        let platform = PlatformServices(
            storageLocations: storage,
            keychainManager: keychain,
            versionControlFactory: .embedded
        )
        let config = GlobalConfig(
            syncFolder: syncRoot.path,
            managedWorkspaceFolder: workspaceRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 10,
            showNotifications: false,
            serverPort: Int(UInt16.random(in: 28001...32000))
        )
        syncEngine = SyncEngine(config: config, platformServices: platform)
        try await syncEngine.start()

        try await waitUntil("managed demo tasks workspace materialized") {
            FileManager.default.fileExists(
                atPath: self.workspaceRoot.appendingPathComponent("demo/tasks/tasks.csv").path
            )
        }

        localPort = UInt16.random(in: 32001...36000)
        localServer = LocalServer(port: localPort, syncEngine: syncEngine)
        try await localServer.start()
        try await waitUntil("local server ready") {
            do {
                let (_, response) = try await self.localRequest(path: "/api/health")
                return response.statusCode == 200
            } catch {
                return false
            }
        }
    }

    override func tearDown() async throws {
        await localServer?.stop()
        localServer = nil
        if let syncEngine {
            await syncEngine.stop()
        }
        syncEngine = nil
        await demoServer?.stop()
        demoServer = nil
        if let keychain {
            _ = await keychain.delete(key: keychainKey)
        }
        keychain = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        syncRoot = nil
        workspaceRoot = nil
        localPort = nil
        try await super.tearDown()
    }

    func testDemoAdapterManagedWorkspacePushesCSVEditsToLiveServer() async throws {
        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks/tasks.csv")
        let original = try String(contentsOf: workspaceFile)
        let updatedName = "Buy groceries demo-adapter managed push"
        let updated = original.replacingOccurrences(of: "Buy groceries", with: updatedName)
        try updated.write(to: workspaceFile, atomically: true, encoding: .utf8)

        let result = try await syncEngine.submitManagedWorkspaceChange(
            serviceId: "demo",
            filePath: "tasks/tasks.csv",
            sourceApplication: "Tests"
        )
        XCTAssertEqual(result.kind, .accepted)

        try await waitUntil("demo server reflects managed CSV edit") {
            do {
                let tasks = try await self.fetchDemoTasks()
                return tasks.first?["name"] as? String == updatedName
            } catch {
                return false
            }
        }
    }

    func testDemoAdapterManagedWorkspacePullsLiveServerUpdatesIntoCSVFile() async throws {
        let remoteName = "Buy groceries demo-adapter remote pull"
        _ = try await putDemoTask(id: 1, body: [
            "name": remoteName,
            "status": "todo",
            "priority": "medium",
            "assignee": "Alice",
            "dueDate": "2026-03-25"
        ])

        let (syncData, syncResponse) = try await localRequest(
            method: "POST",
            path: "/api/services/demo/sync"
        )
        XCTAssertEqual(syncResponse.statusCode, 200)
        let syncJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: syncData) as? [String: String])
        XCTAssertEqual(syncJSON["triggered"], "true")

        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks/tasks.csv")
        try await waitUntil("managed workspace CSV reflects live server change") {
            (try? String(contentsOf: workspaceFile).contains(remoteName)) == true
        }
    }

    func testDemoAdapterManagedWorkspaceRejectsCSVSchemaDrift() async throws {
        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks/tasks.csv")
        let original = try String(contentsOf: workspaceFile)
        let invalid = """
        _id,assignee,dueDate,name,status
        1,Alice,2026-03-25,Buy groceries,todo
        2,Bob,2026-03-24,Fix login bug,in-progress
        3,Alice,2026-03-20,Write docs,done
        """
        try invalid.write(to: workspaceFile, atomically: true, encoding: .utf8)

        let result = try await syncEngine.submitManagedWorkspaceChange(
            serviceId: "demo",
            filePath: "tasks/tasks.csv",
            sourceApplication: "Tests"
        )
        XCTAssertEqual(result.kind, .rejectedValidation)
        XCTAssertTrue(result.message.contains("schema mismatch"))

        let restored = try String(contentsOf: workspaceFile)
        XCTAssertEqual(restored, original)

        let tasks = try await fetchDemoTasks()
        XCTAssertEqual(tasks.first?["name"] as? String, "Buy groceries")
    }

    func testDemoAdapterManagedWorkspaceRejectsEmptyNameField() async throws {
        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks/tasks.csv")
        let original = try String(contentsOf: workspaceFile)
        let invalid = original.replacingOccurrences(of: "Buy groceries", with: "")
        try invalid.write(to: workspaceFile, atomically: true, encoding: .utf8)

        let result = try await syncEngine.submitManagedWorkspaceChange(
            serviceId: "demo",
            filePath: "tasks/tasks.csv",
            sourceApplication: "Tests"
        )
        XCTAssertEqual(result.kind, .rejectedValidation)
        XCTAssertTrue(result.message.contains("cannot be empty"))

        let restored = try String(contentsOf: workspaceFile)
        XCTAssertEqual(restored, original)

        let tasks = try await fetchDemoTasks()
        XCTAssertEqual(tasks.first?["name"] as? String, "Buy groceries")
    }

    private func makeManagedDemoAdapterConfig() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/API2FileCore/Resources/Adapters/demo.adapter.json")
        let baseURL = "http://localhost:\(port!)"
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
            .replacingOccurrences(of: "http://localhost:8089", with: baseURL)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let resources = try XCTUnwrap(json["resources"] as? [[String: Any]])
        json["resources"] = resources.filter { ($0["name"] as? String) == "tasks" }
        json["storageMode"] = ServiceStorageMode.managedWorkspace.rawValue

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func localRequest(
        method: String = "GET",
        path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(URL(string: "http://localhost:\(localPort!)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func fetchDemoTasks() async throws -> [[String: Any]] {
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port!)/api/tasks"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func putDemoTask(id: Int, body: [String: Any]) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port!)/api/tasks/\(id)"))
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
