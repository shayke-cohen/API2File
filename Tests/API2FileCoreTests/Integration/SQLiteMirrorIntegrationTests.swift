import XCTest
@testable import API2FileCore

@MainActor
final class SQLiteMirrorIntegrationTests: XCTestCase {
    private var demoServer: DemoAPIServer!
    private var demoPort: UInt16!
    private var syncEngine: SyncEngine!
    private var tempDir: URL!
    private var syncRoot: URL!
    private let keychain = KeychainManager.shared
    private let keychainKey = "api2file.demo.sqlite-integration"

    override func setUp() async throws {
        try await super.setUp()

        demoPort = UInt16.random(in: 20000...24999)
        demoServer = DemoAPIServer(port: demoPort)
        try await demoServer.start()
        try await waitUntil("demo server ready") {
            do {
                let (_, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:\(self.demoPort!)/api/tasks")!)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
        await demoServer.reset()

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-mirror-integration-\(UUID().uuidString)")
        syncRoot = tempDir.appendingPathComponent("sync")
        let serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "\(keychainKey)" },
          "globals": { "baseUrl": "http://localhost:\(demoPort!)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list",
              "pull": { "method": "GET", "url": "http://localhost:\(demoPort!)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "http://localhost:\(demoPort!)/api/tasks" },
                "update": { "method": "PUT", "url": "http://localhost:\(demoPort!)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "http://localhost:\(demoPort!)/api/tasks/{id}" }
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
        try adapterConfig.write(to: api2fileDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)
        _ = await keychain.save(key: keychainKey, value: "demo-token")

        let globalConfig = GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 10,
            showNotifications: false,
            serverPort: Int(UInt16.random(in: 25000...29999))
        )
        syncEngine = SyncEngine(config: globalConfig)
        try await syncEngine.start()

        try await waitUntil("initial task pull") { [self] in
            FileManager.default.fileExists(atPath: self.syncRoot.appendingPathComponent("demo/tasks.csv").path)
        }
        try await waitUntil("SQLite mirror created") { [self] in
            let dbURL = self.syncRoot
                .appendingPathComponent("demo/.api2file/cache/service.sqlite")
            return FileManager.default.fileExists(atPath: dbURL.path)
        }
    }

    override func tearDown() async throws {
        if let syncEngine {
            await syncEngine.stop()
        }
        syncEngine = nil

        await demoServer?.stop()
        demoServer = nil

        _ = await keychain.delete(key: keychainKey)

        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        syncRoot = nil
        try await super.tearDown()
    }

    func testInitialPullCreatesSQLiteMirror() async throws {
        let data = try await syncEngine.querySQL(serviceId: "demo", query: "SELECT name FROM tasks ORDER BY id")
        let result = try parseObject(data)
        XCTAssertEqual(result["rowCount"] as? Int, 3)
        let rows = result["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["name"] as? String, "Buy groceries")
    }

    func testFileEditRefreshesSQLiteMirrorAfterPush() async throws {
        let tasksURL = syncRoot.appendingPathComponent("demo/tasks.csv")
        let original = try String(contentsOf: tasksURL)
        let updated = original.replacingOccurrences(of: "Buy groceries", with: "Buy groceries updated")
        try updated.write(to: tasksURL, atomically: true, encoding: .utf8)

        await syncEngine.fileDidChange(serviceId: "demo", filePath: "tasks.csv")

        try await waitUntil("SQLite mirror reflects pushed edit", timeout: 10) {
            do {
                let data = try await self.syncEngine.querySQL(
                    serviceId: "demo",
                    query: "SELECT name FROM tasks WHERE id = 1"
                )
                let object = try self.parseObject(data)
                let rows = object["rows"] as? [[String: Any]]
                return rows?.first?["name"] as? String == "Buy groceries updated"
            } catch {
                return false
            }
        }
    }

    private func parseObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "SQLiteMirrorIntegrationTests", code: 1)
        }
        return dictionary
    }

    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 20,
        pollInterval: UInt64 = 250_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: pollInterval)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}
