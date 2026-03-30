import XCTest
@testable import API2FileCore

final class ManagedWorkspaceIntegrationTests: XCTestCase {
    private var demoServer: DemoAPIServer!
    private var syncEngine: SyncEngine!
    private var localServer: LocalServer!
    private var tempRoot: URL!
    private var syncRoot: URL!
    private var workspaceRoot: URL!
    private var keychain: KeychainManager!
    private let keychainKey = "api2file.managed.demo.test"
    private var port: UInt16!
    private var localPort: UInt16!

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 22000...28000)
        demoServer = DemoAPIServer(port: port)
        try await demoServer.start()

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-managed-\(UUID().uuidString)", isDirectory: true)
        syncRoot = tempRoot.appendingPathComponent("sync", isDirectory: true)
        workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("support", isDirectory: true)
        let adapters = tempRoot.appendingPathComponent("adapters", isDirectory: true)
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)

        let serviceDir = syncRoot.appendingPathComponent("demo", isDirectory: true)
        let api2fileDir = serviceDir.appendingPathComponent(".api2file", isDirectory: true)
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "storageMode": "managed_workspace",
          "auth": { "type": "bearer", "keychainKey": "\(keychainKey)" },
          "globals": { "baseUrl": "http://localhost:\(port!)" },
          "resources": [
            {
              "name": "tasks",
              "commitPolicy": "push-then-commit",
              "pull": { "method": "GET", "url": "http://localhost:\(port!)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "http://localhost:\(port!)/api/tasks" },
                "update": { "method": "PUT", "url": "http://localhost:\(port!)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "http://localhost:\(port!)/api/tasks/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.json",
                "format": "json",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            }
          ]
        }
        """
        try adapterConfig.write(to: api2fileDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)

        keychain = KeychainManager(keyPrefix: "com.api2file.tests.managed.")
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

        try await waitUntil("managed workspace materialized") {
            FileManager.default.fileExists(
                atPath: self.workspaceRoot.appendingPathComponent("demo/tasks.json").path
            )
        }

        localPort = UInt16.random(in: 32001...36000)
        localServer = LocalServer(port: localPort, syncEngine: syncEngine)
        try await localServer.start()
        try await waitUntil("local server ready") {
            guard let url = URL(string: "http://localhost:\(self.localPort!)/api/health") else {
                return false
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            let semaphore = DispatchSemaphore(value: 0)
            var isReady = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                if let response = response as? HTTPURLResponse, response.statusCode == 200 {
                    isReady = true
                }
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 1.5)
            return isReady
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

    func testAcceptedManagedWorkspaceChangeUpdatesAcceptedState() async throws {
        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks.json")
        let originalData = try Data(contentsOf: workspaceFile)
        var tasks = try XCTUnwrap(try JSONSerialization.jsonObject(with: originalData) as? [[String: Any]])
        tasks[0]["name"] = "Buy groceries updated in managed workspace"
        let updatedData = try JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys])
        try updatedData.write(to: workspaceFile, options: .atomic)

        let result = try await syncEngine.submitManagedWorkspaceChange(serviceId: "demo", filePath: "tasks.json", sourceApplication: "Tests")
        XCTAssertEqual(result.kind, .accepted)

        let acceptedData = try Data(contentsOf: syncRoot.appendingPathComponent("demo/tasks.json"))
        let acceptedTasks = try XCTUnwrap(try JSONSerialization.jsonObject(with: acceptedData) as? [[String: Any]])
        XCTAssertEqual(acceptedTasks[0]["name"] as? String, "Buy groceries updated in managed workspace")
    }

    func testRejectedManagedWorkspaceChangeRestoresVisibleFileAndRecordsProposal() async throws {
        let workspaceFile = workspaceRoot.appendingPathComponent("demo/tasks.json")
        let original = try String(contentsOf: workspaceFile)
        try "{ invalid json".write(to: workspaceFile, atomically: true, encoding: .utf8)

        let result = try await syncEngine.submitManagedWorkspaceChange(serviceId: "demo", filePath: "tasks.json", sourceApplication: "Tests")
        XCTAssertEqual(result.kind, .rejectedValidation)

        let restored = try String(contentsOf: workspaceFile)
        XCTAssertEqual(restored, original)

        let proposals = await syncEngine.getManagedRejectedProposals(serviceId: "demo", limit: 10)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].filePath, "tasks.json")
    }

    func testManagedWorkspaceStatusAndRejectionsAreExposedOverLocalServerAPI() async throws {
        let (statusData, statusResponse) = try await localRequest(path: "/api/services/demo/workspace/status")
        XCTAssertEqual(statusResponse.statusCode, 200)
        let statusJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: statusData) as? [String: String])
        XCTAssertEqual(statusJSON["serviceId"], "demo")
        XCTAssertEqual(statusJSON["status"], "materialized")
        XCTAssertEqual(statusJSON["isAvailable"], "true")

        let (originalData, originalResponse) = try await localRequest(
            path: "/lite/api/file?service=demo&path=tasks.json"
        )
        XCTAssertEqual(originalResponse.statusCode, 200)

        let invalidData = Data("{ invalid json".utf8)
        let (rejectData, rejectResponse) = try await localRequest(
            method: "PUT",
            path: "/lite/api/file?service=demo&path=tasks.json",
            body: invalidData,
            contentType: "application/json"
        )
        XCTAssertEqual(rejectResponse.statusCode, 409)
        let rejectJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: rejectData) as? [String: String])
        XCTAssertNotNil(rejectJSON["error"])

        let (restoredData, restoredResponse) = try await localRequest(
            path: "/lite/api/file?service=demo&path=tasks.json"
        )
        XCTAssertEqual(restoredResponse.statusCode, 200)
        XCTAssertEqual(restoredData, originalData)

        let (rejectionsData, rejectionsResponse) = try await localRequest(
            path: "/api/services/demo/workspace/rejections?limit=10"
        )
        XCTAssertEqual(rejectionsResponse.statusCode, 200)
        let rejections = try XCTUnwrap(try JSONSerialization.jsonObject(with: rejectionsData) as? [[String: Any]])
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections[0]["filePath"] as? String, "tasks.json")
        XCTAssertEqual(rejections[0]["serviceId"] as? String, "demo")
        XCTAssertEqual(rejections[0]["sourceApplication"] as? String, "Lite Manager")
    }

    func testManagedWorkspaceLiteSavePushesAcceptedChangeToLiveServer() async throws {
        let (fileData, fileResponse) = try await localRequest(
            path: "/lite/api/file?service=demo&path=tasks.json"
        )
        XCTAssertEqual(fileResponse.statusCode, 200)

        var tasks = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [[String: Any]])
        tasks[0]["name"] = "Managed API push \(UUID().uuidString)"
        let updatedName = try XCTUnwrap(tasks[0]["name"] as? String)
        let updatedData = try JSONSerialization.data(withJSONObject: tasks, options: [.sortedKeys])

        let (saveData, saveResponse) = try await localRequest(
            method: "PUT",
            path: "/lite/api/file?service=demo&path=tasks.json",
            body: updatedData,
            contentType: "application/json"
        )
        XCTAssertEqual(saveResponse.statusCode, 200)
        let saveJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: saveData) as? [String: String])
        XCTAssertEqual(saveJSON["status"], "ok")

        try await waitUntil("managed update reaches demo server") {
            do {
                let tasks = try await self.fetchDemoTasks()
                return tasks.first?["name"] as? String == updatedName
            } catch {
                return false
            }
        }

        let (visibleData, visibleResponse) = try await localRequest(
            path: "/lite/api/file?service=demo&path=tasks.json"
        )
        XCTAssertEqual(visibleResponse.statusCode, 200)
        let visibleTasks = try XCTUnwrap(try JSONSerialization.jsonObject(with: visibleData) as? [[String: Any]])
        XCTAssertEqual(visibleTasks.first?["name"] as? String, updatedName)
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
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        pollInterval: TimeInterval = 0.2,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        XCTFail("Timed out waiting for \(description)")
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
