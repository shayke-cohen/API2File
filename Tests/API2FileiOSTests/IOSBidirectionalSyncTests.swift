import XCTest
@testable import API2FileCore

final class IOSBidirectionalSyncTests: XCTestCase {
    private let authKey = "api2file.demo.ios-bidirectional-test"

    override func tearDown() async throws {
        await KeychainManager.shared.delete(key: authKey)
        try await super.tearDown()
    }

    func testIOSPlatformSyncPullsAndPushesBothWays() async throws {
        let port = randomPort
        let server = DemoAPIServer(port: port)
        try await server.start()
        defer { Task { await server.stop() } }

        try await waitForServerReady(baseURL: baseURL(for: port))
        await server.reset()
        let savedToken = await KeychainManager.shared.save(key: authKey, value: "demo-token")
        XCTAssertTrue(savedToken)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-sync-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let serviceDir = tempRoot.appendingPathComponent("demo", isDirectory: true)
        let api2fileDir = serviceDir.appendingPathComponent(".api2file", isDirectory: true)
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let baseURL = baseURL(for: port)
        try demoAdapterJSON(baseURL: baseURL).write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )

        let storage = StorageLocations(
            homeDirectory: tempRoot,
            syncRootDirectory: tempRoot,
            adaptersDirectory: tempRoot.appendingPathComponent("Adapters", isDirectory: true),
            applicationSupportDirectory: tempRoot.appendingPathComponent("Application Support", isDirectory: true)
        )
        let services = PlatformServices(
            storageLocations: storage,
            adapterStore: AdapterStore(storageLocations: storage),
            versionControlFactory: .embedded
        )
        let engine = SyncEngine(
            config: GlobalConfig(
                syncFolder: tempRoot.path,
                gitAutoCommit: false,
                defaultSyncInterval: 5,
                showNotifications: false,
                serverPort: Int(port)
            ),
            platformServices: services
        )
        defer { Task { await engine.stop() } }

        try await engine.start()

        let tasksURL = serviceDir.appendingPathComponent("tasks.csv")
        try await waitUntil("initial iOS pull writes tasks.csv") {
            FileManager.default.fileExists(atPath: tasksURL.path)
        }

        var localRecords = try CSVFormat.decode(data: Data(contentsOf: tasksURL), options: nil)
        XCTAssertFalse(localRecords.isEmpty, "Expected iOS sync to pull at least one task from the demo server")

        let updatedName = "iOS local push \(UUID().uuidString.prefix(8))"
        localRecords[0]["name"] = updatedName
        let updatedCSV = try CSVFormat.encode(records: localRecords, options: nil)
        try updatedCSV.write(to: tasksURL, options: .atomic)
        await engine.fileDidChange(serviceId: "demo", filePath: "tasks.csv")
        await engine.triggerSync(serviceId: "demo")

        try await waitUntil("local edit is pushed back to the API") {
            let tasks = try await self.fetchTasks(baseURL: baseURL)
            return tasks.contains { ($0["name"] as? String) == updatedName }
        }

        let serverCreatedName = "iOS remote pull \(UUID().uuidString.prefix(8))"
        try await postTask(
            baseURL: baseURL,
            payload: [
                "name": serverCreatedName,
                "status": "todo",
                "completed": false
            ]
        )

        await engine.triggerSync(serviceId: "demo")
        try await waitUntil("remote API change is pulled down to iOS storage") {
            let records = try CSVFormat.decode(data: Data(contentsOf: tasksURL), options: nil)
            return records.contains { ($0["name"] as? String) == serverCreatedName }
        }
    }

    private var randomPort: UInt16 {
        UInt16.random(in: 29000...32000)
    }

    private func baseURL(for port: UInt16) -> String {
        "http://localhost:\(port)"
    }

    private func waitForServerReady(baseURL: String) async throws {
        try await waitUntil("demo server becomes ready") {
            let url = URL(string: "\(baseURL)/api/tasks")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    private func fetchTasks(baseURL: String) async throws -> [[String: Any]] {
        let response = try await HTTPClient().request(
            APIRequest(method: .GET, url: "\(baseURL)/api/tasks")
        )
        return try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] ?? []
    }

    private func postTask(baseURL: String, payload: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await HTTPClient().request(
            APIRequest(
                method: .POST,
                url: "\(baseURL)/api/tasks",
                headers: ["Content-Type": "application/json"],
                body: body
            )
        )
    }

    private func demoAdapterJSON(baseURL: String) -> String {
        """
        {
          "service": "demo",
          "displayName": "Demo API",
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
    }

    private func waitUntil(
        _ description: String,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        pollNanoseconds: UInt64 = 300_000_000,
        _ condition: @escaping () async throws -> Bool
    ) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < Double(timeoutNanoseconds) / 1_000_000_000 {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
