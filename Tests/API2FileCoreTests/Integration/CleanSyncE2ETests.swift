import XCTest
@testable import API2FileCore

final class CleanSyncE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!
    private var engine: SyncEngine?
    private var keychainKey: String!

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 22000...28000)
        server = DemoAPIServer(port: port)
        try await server.start()

        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (response as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch {
                continue
            }
        }
        await server.reset()

        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-clean-sync-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        keychainKey = "api2file.demo.clean-sync.\(UUID().uuidString)"

        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "\(keychainKey!)" },
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

        _ = await KeychainManager.shared.save(key: keychainKey, value: "demo-token")
    }

    override func tearDown() async throws {
        if let engine {
            await engine.stop()
        }
        await server?.stop()
        if let keychainKey {
            _ = await KeychainManager.shared.delete(key: keychainKey)
        }
        if let dir = syncRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    func testCleanSyncDeletesLocalMirrorAndRepullsFromServer() async throws {
        let syncEngine = SyncEngine(config: GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            showNotifications: false,
            finderBadges: false,
            serverPort: 0,
            enableSnapshots: false
        ))
        engine = syncEngine

        try await syncEngine.start()
        try await waitForFile("tasks.csv")

        let tasksURL = serviceDir.appendingPathComponent("tasks.csv")
        let objectURL = serviceDir.appendingPathComponent(ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv"))
        let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        let junkURL = serviceDir.appendingPathComponent("scratch.txt")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tasksURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: objectURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        try "stale\ncontent\n".write(to: tasksURL, atomically: true, encoding: .utf8)
        try "delete me".write(to: junkURL, atomically: true, encoding: .utf8)

        try await syncEngine.cleanSync(serviceId: "demo")

        XCTAssertTrue(FileManager.default.fileExists(atPath: adapterURL.path), "adapter.json should be preserved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: junkURL.path), "clean sync should remove extra local files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tasksURL.path), "tasks.csv should be pulled back after clean sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: objectURL.path), "canonical object file should be regenerated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path), "state.json should be recreated")

        let tasksContent = try String(contentsOf: tasksURL, encoding: .utf8)
        XCTAssertFalse(tasksContent.contains("stale"))
        XCTAssertTrue(tasksContent.contains("Buy groceries"))

        let state = try SyncState.load(from: stateURL)
        XCTAssertNotNil(state.files["tasks.csv"])
    }

    private func waitForFile(_ relativePath: String, timeout: TimeInterval = 20) async throws {
        let fileURL = serviceDir.appendingPathComponent(relativePath)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        XCTFail("Timed out waiting for \(relativePath)")
    }
}
