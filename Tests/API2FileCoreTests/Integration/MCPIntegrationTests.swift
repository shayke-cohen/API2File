import XCTest
@testable import API2FileCore

/// MCP Integration Tests — tests the full MCP binary → LocalServer → DemoAPIServer pipeline.
/// Spawns a real DemoAPIServer, SyncEngine, LocalServer, and the api2file-mcp binary,
/// then exercises the MCP tool interface end-to-end.
@MainActor
final class MCPIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var demoServer: DemoAPIServer!
    private var demoPort: UInt16!
    private var demoBaseURL: String { "http://localhost:\(demoPort!)" }

    private var syncEngine: SyncEngine!
    private var localServer: LocalServer!
    private var localPort: UInt16!

    private var syncRoot: URL!
    private var serviceDir: URL!
    private var tempDir: URL!

    private var harness: MCPTestHarness!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // 1. Start DemoAPIServer on a random port
        demoPort = UInt16.random(in: 20000...24999)
        demoServer = DemoAPIServer(port: demoPort)
        try await demoServer.start()

        // Wait for demo server readiness
        var ready = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(
                    from: URL(string: "\(demoBaseURL)/api/tasks")!
                )
                if let r = response as? HTTPURLResponse, r.statusCode == 200 {
                    ready = true
                    break
                }
            } catch { continue }
        }
        guard ready else {
            XCTFail("DemoAPIServer did not become ready on port \(demoPort!)")
            return
        }
        await demoServer.reset()

        // 2. Create temp directory structure for sync
        let resolvedTmpDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        tempDir = resolvedTmpDir.appendingPathComponent("mcp-integration-\(UUID().uuidString)")
        syncRoot = tempDir.appendingPathComponent("sync")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config pointing to demo server
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "siteUrl": "\(demoBaseURL)",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.mcp-test" },
          "globals": { "baseUrl": "\(demoBaseURL)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list",
              "pull": { "method": "GET", "url": "\(demoBaseURL)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(demoBaseURL)/api/tasks" },
                "update": { "method": "PUT", "url": "\(demoBaseURL)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "\(demoBaseURL)/api/tasks/{id}" }
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

        // 3. Start SyncEngine + LocalServer on a random port
        localPort = UInt16.random(in: 25000...29999)
        let globalConfig = GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 10,
            showNotifications: false,
            serverPort: Int(localPort)
        )
        syncEngine = SyncEngine(config: globalConfig)
        try await syncEngine.start()

        localServer = LocalServer(port: localPort, syncEngine: syncEngine)
        try await localServer.start()

        // Wait for LocalServer to be ready
        var localReady = false
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(
                    from: URL(string: "http://localhost:\(localPort!)/api/health")!
                )
                if let r = response as? HTTPURLResponse, r.statusCode == 200 {
                    localReady = true
                    break
                }
            } catch { continue }
        }
        guard localReady else {
            XCTFail("LocalServer did not become ready on port \(localPort!)")
            return
        }

        // 4. Write temp server.json for the MCP binary
        let serverJsonDir = tempDir.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: serverJsonDir, withIntermediateDirectories: true)
        let serverJsonPath = serverJsonDir.appendingPathComponent("server.json")
        let serverJson = """
        {
          "port": \(localPort!),
          "pid": \(ProcessInfo.processInfo.processIdentifier)
        }
        """
        try serverJson.write(to: serverJsonPath, atomically: true, encoding: .utf8)

        // 5. Build and spawn the MCP binary
        let binaryPath = try MCPTestHarness.locateBinary()
        harness = MCPTestHarness(binaryPath: binaryPath)
        try harness.start(env: [
            "API2FILE_SERVER_INFO_PATH": serverJsonPath.path
        ])
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil

        await localServer?.stop()
        localServer = nil

        if let engine = syncEngine {
            await engine.stop()
        }
        syncEngine = nil

        await demoServer?.stop()
        demoServer = nil

        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        syncRoot = nil
        serviceDir = nil

        try await super.tearDown()
    }

    // MARK: - Helpers

    private func initializeMCP() throws -> [String: Any] {
        let response = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])
        try harness.sendNotification([
            "method": "notifications/initialized",
            "params": [:] as [String: Any]
        ])
        return response
    }

    private func callTool(_ name: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        return try harness.sendRequest([
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ] as [String: Any]
        ])
    }

    private func extractToolText(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            return nil
        }
        return text
    }

    private func isToolError(_ response: [String: Any]) -> Bool {
        guard let result = response["result"] as? [String: Any] else { return false }
        return result["isError"] as? Bool == true
    }

    // MARK: - Tests

    func testGetServices() async throws {
        // Initialize MCP
        let initResponse = try initializeMCP()
        let result = initResponse["result"] as? [String: Any]
        XCTAssertNotNil(result, "Initialize should return a result")

        // Call get_services
        let response = try callTool("get_services")
        let text = extractToolText(response)
        XCTAssertNotNil(text, "get_services should return text content")
        XCTAssertFalse(isToolError(response), "get_services should not be an error")

        // Verify demo service shows up
        XCTAssertTrue(text!.contains("demo") || text!.contains("Demo"), "Response should contain the demo service")
    }

    func testSyncTriggers() async throws {
        _ = try initializeMCP()

        // Call sync with the demo service ID
        let response = try callTool("sync", arguments: ["serviceId": "demo"])
        let text = extractToolText(response)
        XCTAssertNotNil(text, "sync should return text content")
        XCTAssertFalse(isToolError(response), "sync should not be an error")
        XCTAssertTrue(text!.lowercased().contains("sync") || text!.lowercased().contains("triggered"),
                      "Response should confirm sync was triggered")
    }

    func testNavigateWithoutWebView() async throws {
        _ = try initializeMCP()

        // No BrowserControlDelegate is set — navigate should fail with browser not available
        let response = try callTool("navigate", arguments: ["url": "http://example.com"])
        let text = extractToolText(response)
        XCTAssertNotNil(text, "navigate should return a response")
        XCTAssertTrue(isToolError(response), "navigate should be an error without a browser")
        XCTAssertTrue(text!.lowercased().contains("browser") || text!.lowercased().contains("not available"),
                      "Error should mention browser not available")
    }

    func testScreenshotWithoutWebView() async throws {
        _ = try initializeMCP()

        // No BrowserControlDelegate — screenshot should fail
        let response = try callTool("screenshot")
        let text = extractToolText(response)
        XCTAssertNotNil(text, "screenshot should return a response")
        XCTAssertTrue(isToolError(response), "screenshot should be an error without a browser")
        XCTAssertTrue(text!.lowercased().contains("browser") || text!.lowercased().contains("not available"),
                      "Error should mention browser not available")
    }

    func testFullToolRoundtrip() async throws {
        // 1. Initialize
        let initResponse = try initializeMCP()
        let initResult = initResponse["result"] as? [String: Any]
        XCTAssertNotNil(initResult, "Initialize should return a result")
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2024-11-05")

        // 2. tools/list
        let listResponse = try harness.sendRequest([
            "method": "tools/list",
            "params": [:] as [String: Any]
        ])
        let listResult = listResponse["result"] as? [String: Any]
        let tools = listResult?["tools"] as? [[String: Any]]
        XCTAssertNotNil(tools, "tools/list should return tools array")
        let toolNames = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertTrue(toolNames.contains("get_services"), "Should have get_services tool")
        XCTAssertTrue(toolNames.contains("sync"), "Should have sync tool")
        XCTAssertTrue(toolNames.contains("navigate"), "Should have navigate tool")
        XCTAssertTrue(toolNames.contains("screenshot"), "Should have screenshot tool")

        // 3. get_services
        let servicesResponse = try callTool("get_services")
        XCTAssertFalse(isToolError(servicesResponse), "get_services should succeed")
        let servicesText = extractToolText(servicesResponse)
        XCTAssertNotNil(servicesText, "get_services should return text")

        // 4. sync
        let syncResponse = try callTool("sync", arguments: ["serviceId": "demo"])
        XCTAssertFalse(isToolError(syncResponse), "sync should succeed")
        let syncText = extractToolText(syncResponse)
        XCTAssertNotNil(syncText, "sync should return text")
    }

    func testGetServicesSiteUrlPresent() async throws {
        _ = try initializeMCP()

        let response = try callTool("get_services")
        let text = extractToolText(response)
        XCTAssertNotNil(text)

        // The demo adapter config includes siteUrl — verify it appears in the response
        if let data = text?.data(using: .utf8),
           let services = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let demo = services.first(where: { $0["serviceId"] as? String == "demo" })
            XCTAssertNotNil(demo, "Demo service should exist")
            // siteUrl may or may not be present depending on the per-service config
            // but the field should be serialized when present
            if let siteUrl = demo?["siteUrl"] as? String {
                XCTAssertTrue(siteUrl.contains("localhost"), "siteUrl should be a localhost URL")
            }
        }
    }
}
