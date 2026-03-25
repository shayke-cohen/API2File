import XCTest
@testable import API2FileCore

// MARK: - BrowserSimulator

/// A test double implementing BrowserControlDelegate that performs real HTTP requests
/// instead of using a WebView. Used for E2E testing the MCP → LocalServer → browser pipeline.
@MainActor
final class BrowserSimulator: BrowserControlDelegate {
    private(set) var isOpen = false
    private(set) var currentURL: String?
    private var storedHTML: String = ""
    private(set) var recordedCalls: [(method: String, args: [String])] = []

    /// Minimal valid 1x1 transparent PNG
    private static let pngBytes: Data = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    )!

    func openBrowser() async throws {
        isOpen = true
    }

    func isBrowserOpen() async -> Bool {
        return isOpen
    }

    func navigate(to url: String) async throws -> String {
        // Auto-open if needed
        if !isOpen { isOpen = true }

        // Perform a real HTTP GET to the URL
        guard let requestURL = URL(string: url) else {
            throw BrowserError.navigationFailed("Invalid URL: \(url)")
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: requestURL)
            storedHTML = String(data: data, encoding: .utf8) ?? ""
        } catch {
            throw BrowserError.navigationFailed("HTTP request failed: \(error.localizedDescription)")
        }
        currentURL = url
        return url
    }

    func goBack() async throws {
        recordedCalls.append((method: "goBack", args: []))
    }

    func goForward() async throws {
        recordedCalls.append((method: "goForward", args: []))
    }

    func reload() async throws {
        recordedCalls.append((method: "reload", args: []))
    }

    func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
        return BrowserSimulator.pngBytes
    }

    func getDOM(selector: String?) async throws -> String {
        // Return stored HTML regardless of selector (simplification for testing)
        return storedHTML
    }

    func click(selector: String) async throws {
        recordedCalls.append((method: "click", args: [selector]))
    }

    func type(selector: String, text: String) async throws {
        recordedCalls.append((method: "type", args: [selector, text]))
    }

    func evaluateJS(_ code: String) async throws -> String {
        recordedCalls.append((method: "evaluateJS", args: [code]))
        return "OK"
    }

    func getCurrentURL() async -> String? {
        return currentURL
    }

    func waitFor(selector: String, timeout: TimeInterval) async throws {
        recordedCalls.append((method: "waitFor", args: [selector]))
    }

    func scroll(direction: ScrollDirection, amount: Int?) async throws {
        recordedCalls.append((method: "scroll", args: [direction.rawValue, "\(amount ?? 500)"]))
    }
}

// MARK: - MCPBrowserE2ETests

/// E2E Tests with BrowserSimulator — full MCP binary → LocalServer → BrowserSimulator pipeline.
/// Same setup as MCPIntegrationTests but with a BrowserSimulator injected into LocalServer.
/// NOTE: NOT @MainActor — the harness blocks its thread waiting for responses, which would
/// deadlock BrowserSimulator's @MainActor methods if the test ran on the main actor.
final class MCPBrowserE2ETests: XCTestCase {

    // MARK: - Properties

    private var demoServer: DemoAPIServer!
    private var demoPort: UInt16!
    private var demoBaseURL: String { "http://localhost:\(demoPort!)" }

    private var syncEngine: SyncEngine!
    private var localServer: LocalServer!
    private var localPort: UInt16!
    private var browserSim: BrowserSimulator!

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
        tempDir = resolvedTmpDir.appendingPathComponent("mcp-browser-e2e-\(UUID().uuidString)")
        syncRoot = tempDir.appendingPathComponent("sync")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config pointing to demo server (include siteUrl)
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "siteUrl": "\(demoBaseURL)",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.browser-e2e" },
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

        // 4. Create and inject BrowserSimulator (must be on MainActor)
        browserSim = await MainActor.run { BrowserSimulator() }
        await localServer.setBrowserDelegate(browserSim)

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

        // 5. Write temp server.json for the MCP binary
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

        // 6. Build and spawn the MCP binary
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
        browserSim = nil

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

    @discardableResult
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

    /// Extract image data from a screenshot response.
    private func extractToolImage(_ response: [String: Any]) -> String? {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        // Look for an image content block
        for block in content {
            if let data = block["data"] as? String {
                return data
            }
        }
        // Fall back to text that might contain base64
        return content.first?["text"] as? String
    }

    private func isToolError(_ response: [String: Any]) -> Bool {
        guard let result = response["result"] as? [String: Any] else { return false }
        return result["isError"] as? Bool == true
    }

    // MARK: - Tests

    func testEditTaskAndVerifyInHTML() async throws {
        try initializeMCP()

        // Write a tasks.csv with modified data to the service directory
        let tasksCSV = """
        id,name,status,priority
        1,Buy groceries,done,high
        2,Walk the dog,todo,medium
        3,Test MCP integration,in-progress,high
        """
        let tasksPath = serviceDir.appendingPathComponent("tasks.csv")
        try tasksCSV.write(to: tasksPath, atomically: true, encoding: .utf8)

        // Trigger sync via MCP
        let syncResponse = try callTool("sync", arguments: ["serviceId": "demo"])
        XCTAssertFalse(isToolError(syncResponse), "sync should succeed")

        // Wait a moment for sync to process
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Navigate to the tasks API endpoint (Accept: text/html header is handled by BrowserSimulator's HTTP GET)
        let navResponse = try callTool("navigate", arguments: [
            "url": "\(demoBaseURL)/api/tasks"
        ])
        XCTAssertFalse(isToolError(navResponse), "navigate should succeed with BrowserSimulator")

        // Get DOM content
        let domResponse = try callTool("get_dom")
        XCTAssertFalse(isToolError(domResponse), "get_dom should succeed")
        let html = extractToolText(domResponse)
        XCTAssertNotNil(html, "get_dom should return HTML content")

        // The HTML should contain task data (the demo server returns JSON for the API endpoint,
        // which our BrowserSimulator stores as-is)
        XCTAssertTrue(html!.contains("groceries") || html!.contains("Buy") || html!.contains("tasks"),
                      "DOM content should contain task data from the demo server")
    }

    func testGetServicesReturnsSiteUrl() async throws {
        try initializeMCP()

        let response = try callTool("get_services")
        XCTAssertFalse(isToolError(response), "get_services should succeed")

        let text = extractToolText(response)
        XCTAssertNotNil(text, "get_services should return text")

        // Verify siteUrl is present in the response
        XCTAssertTrue(text!.contains("siteUrl") || text!.contains("localhost"),
                      "get_services response should contain siteUrl field")
    }

    func testNavigateToSiteUrl() async throws {
        try initializeMCP()

        // Get services to extract siteUrl
        let servicesResponse = try callTool("get_services")
        XCTAssertFalse(isToolError(servicesResponse), "get_services should succeed")

        // Navigate to the demo server base URL (the siteUrl)
        let navResponse = try callTool("navigate", arguments: [
            "url": demoBaseURL
        ])
        XCTAssertFalse(isToolError(navResponse), "navigate should succeed")

        // Take a screenshot
        let screenshotResponse = try callTool("screenshot")
        XCTAssertFalse(isToolError(screenshotResponse), "screenshot should succeed")

        // Verify we got image data back (either base64 in data field or text)
        let result = screenshotResponse["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertNotNil(content, "screenshot should return content")
        XCTAssertFalse(content!.isEmpty, "screenshot content should not be empty")

        // The response should contain some image data
        let firstBlock = content!.first!
        let hasImageData = firstBlock["data"] != nil || firstBlock["text"] != nil
        XCTAssertTrue(hasImageData, "screenshot should return image data")
    }

    func testScrollReturnsOK() async throws {
        try initializeMCP()

        // Navigate first
        let navResponse = try callTool("navigate", arguments: [
            "url": "\(demoBaseURL)/api/tasks"
        ])
        XCTAssertFalse(isToolError(navResponse), "navigate should succeed")

        // Scroll down
        let scrollResponse = try callTool("scroll", arguments: [
            "direction": "down",
            "amount": 300
        ])
        XCTAssertFalse(isToolError(scrollResponse), "scroll should succeed")

        let text = extractToolText(scrollResponse)
        XCTAssertNotNil(text, "scroll should return a response")
        XCTAssertTrue(text!.lowercased().contains("scroll") || text!.lowercased().contains("ok") || text!.lowercased().contains("down"),
                      "Response should confirm scroll action")
    }

    func testEvaluateJSReturnsResult() async throws {
        try initializeMCP()

        // Navigate first
        let navResponse = try callTool("navigate", arguments: [
            "url": "\(demoBaseURL)/api/tasks"
        ])
        XCTAssertFalse(isToolError(navResponse), "navigate should succeed")

        // Evaluate JavaScript
        let evalResponse = try callTool("evaluate_js", arguments: [
            "code": "document.title"
        ])
        XCTAssertFalse(isToolError(evalResponse), "evaluate_js should succeed")

        let text = extractToolText(evalResponse)
        XCTAssertNotNil(text, "evaluate_js should return a result")
        // BrowserSimulator returns "OK" for evaluateJS, and the MCP wraps it in a response
        XCTAssertFalse(text!.isEmpty, "evaluate_js result should not be empty")
    }

    func testMultipleToolSequence() async throws {
        // 1. Initialize
        let initResponse = try initializeMCP()
        let initResult = initResponse["result"] as? [String: Any]
        XCTAssertNotNil(initResult, "Initialize should return a result")

        // 2. get_services
        let servicesResponse = try callTool("get_services")
        XCTAssertFalse(isToolError(servicesResponse), "get_services should succeed")
        let servicesText = extractToolText(servicesResponse)
        XCTAssertNotNil(servicesText, "get_services should return text")

        // 3. navigate
        let navResponse = try callTool("navigate", arguments: [
            "url": "\(demoBaseURL)/api/tasks"
        ])
        XCTAssertFalse(isToolError(navResponse), "navigate should succeed")

        // 4. get_dom
        let domResponse = try callTool("get_dom")
        XCTAssertFalse(isToolError(domResponse), "get_dom should succeed")
        let domText = extractToolText(domResponse)
        XCTAssertNotNil(domText, "get_dom should return HTML content")

        // 5. screenshot
        let screenshotResponse = try callTool("screenshot")
        XCTAssertFalse(isToolError(screenshotResponse), "screenshot should succeed")
        let result = screenshotResponse["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertNotNil(content, "screenshot should return content blocks")
        XCTAssertFalse(content!.isEmpty, "screenshot content should not be empty")

        // All five steps succeeded — the full tool sequence works end-to-end
    }

    // MARK: - Screenshot File Tests

    func testScreenshotSavesToFile() async throws {
        try initializeMCP()

        // Navigate first
        try callTool("navigate", arguments: ["url": demoBaseURL])

        // Take screenshot
        let response = try callTool("screenshot")
        XCTAssertFalse(isToolError(response), "screenshot should succeed")

        let text = extractToolText(response)
        XCTAssertNotNil(text, "screenshot should return text")
        XCTAssertTrue(text!.contains("Screenshot saved to"), "should mention file path")
        XCTAssertTrue(text!.contains(".png"), "should be a PNG file")
        XCTAssertTrue(text!.contains("Read tool"), "should mention Read tool")

        // Extract the file path and verify the file exists
        if let pathRange = text!.range(of: "/var/") ?? text!.range(of: "/tmp/") {
            let pathEnd = text![pathRange.lowerBound...].firstIndex(of: "\n") ?? text!.endIndex
            let filePath = String(text![pathRange.lowerBound..<pathEnd])
            XCTAssertTrue(FileManager.default.fileExists(atPath: filePath),
                          "Screenshot file should exist at \(filePath)")

            // Verify it's a valid PNG
            let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
            XCTAssertGreaterThan(data.count, 50, "PNG should have meaningful size")
            XCTAssertEqual(data[0], 0x89, "Should start with PNG magic byte")
            XCTAssertEqual(data[1], 0x50, "Second byte should be 'P'")
            XCTAssertEqual(data[2], 0x4E, "Third byte should be 'N'")
            XCTAssertEqual(data[3], 0x47, "Fourth byte should be 'G'")

            // Clean up
            try? FileManager.default.removeItem(atPath: filePath)
        }
    }

    func testGetServicesIncludesSiteUrl() async throws {
        try initializeMCP()

        let response = try callTool("get_services")
        let text = extractToolText(response)
        XCTAssertNotNil(text)

        // Parse the JSON array from the response text
        if let data = text?.data(using: .utf8),
           let services = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let demoService = services.first(where: { $0["serviceId"] as? String == "demo" })
            XCTAssertNotNil(demoService, "Demo service should be in the list")
            let siteUrl = demoService?["siteUrl"] as? String
            XCTAssertNotNil(siteUrl, "Demo service should have siteUrl")
            XCTAssertTrue(siteUrl!.contains("localhost"), "siteUrl should be a localhost URL")
        }
    }
}
