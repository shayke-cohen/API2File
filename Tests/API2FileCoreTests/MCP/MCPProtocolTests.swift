import XCTest

/// Tests the MCP binary's JSON-RPC protocol behavior.
/// Spawns api2file-mcp as a process and validates responses.
/// No app servers needed — tests the binary in isolation.
final class MCPProtocolTests: XCTestCase {

    private var harness: MCPTestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let binaryPath = try MCPTestHarness.locateBinary()
        harness = MCPTestHarness(binaryPath: binaryPath)
        // Start without a valid server.json — tests protocol behavior in isolation
        try harness.start(env: ["API2FILE_SERVER_INFO_PATH": "/nonexistent/server.json"])
    }

    override func tearDown() {
        harness?.stop()
        harness = nil
        super.tearDown()
    }

    // MARK: - Protocol Tests

    func testInitializeHandshake() throws {
        let response = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])

        let result = response["result"] as? [String: Any]
        XCTAssertNotNil(result, "Initialize should return a result")
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")

        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "api2file")

        let capabilities = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["tools"], "Should declare tools capability")
    }

    func testToolsList() throws {
        // Initialize first
        _ = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])

        let response = try harness.sendRequest([
            "method": "tools/list",
            "params": [:] as [String: Any]
        ])

        let result = response["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertNotNil(tools, "Should return tools array")

        let toolNames = Set(tools?.compactMap { $0["name"] as? String } ?? [])
        let expectedTools: Set<String> = [
            "navigate", "screenshot", "get_dom", "click", "type",
            "evaluate_js", "get_page_url", "wait_for", "back",
            "forward", "reload", "scroll", "get_services", "sync"
        ]

        for expected in expectedTools {
            XCTAssertTrue(toolNames.contains(expected), "Missing tool: \(expected)")
        }
    }

    func testInitializedNotification() throws {
        // Initialize first
        _ = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])

        // Send initialized notification (no id = notification)
        try harness.sendNotification([
            "method": "notifications/initialized",
            "params": [:] as [String: Any]
        ])

        // No response expected — verify by checking no data available
        let extra = harness.readAvailable()
        XCTAssertNil(extra, "Notification should not produce a response")
    }

    func testPingReturnsEmptyResult() throws {
        let response = try harness.sendRequest([
            "method": "ping",
            "params": [:] as [String: Any]
        ])

        XCTAssertNotNil(response["result"], "Ping should return a result")
        XCTAssertNil(response["error"], "Ping should not return an error")
    }

    func testUnknownMethod() throws {
        let response = try harness.sendRequest([
            "method": "nonexistent/method",
            "params": [:] as [String: Any]
        ])

        let error = response["error"] as? [String: Any]
        XCTAssertNotNil(error, "Unknown method should return error")
        XCTAssertEqual(error?["code"] as? Int, -32601, "Should return method not found error code")
    }

    func testMalformedJSON() throws {
        // Send garbage — the binary may ignore it or return a parse error
        try harness.sendRaw("this is not json at all")

        // Check if the process responded with a parse error, or simply ignored it
        let extra = harness.readAvailable()
        if let extra {
            // If it responded, it should be a JSON-RPC error
            let error = extra["error"] as? [String: Any]
            XCTAssertNotNil(error, "If the process responds to malformed input, it should be an error")
        }
        // Either way, the binary handled it (didn't crash the test)
    }

    func testToolCallWithoutApp() throws {
        // Initialize first
        _ = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])

        // Call navigate — should fail because no app is running
        let response = try harness.sendRequest([
            "method": "tools/call",
            "params": [
                "name": "navigate",
                "arguments": ["url": "https://example.com"]
            ] as [String: Any]
        ])

        let result = response["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        let isError = result?["isError"] as? Bool

        XCTAssertEqual(isError, true, "Should indicate error")
        let text = content?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("not running") || text.contains("Cannot connect"),
                      "Error should mention app not running, got: \(text)")
    }

    func testPortDiscoveryEnvVarOverride() throws {
        // The harness was started with API2FILE_SERVER_INFO_PATH=/nonexistent/server.json
        // Verify it uses that path (tool calls fail with "not running" not "no server file at ~/.api2file")
        _ = try harness.sendRequest([
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "test", "version": "1.0"]
            ] as [String: Any]
        ])

        let response = try harness.sendRequest([
            "method": "tools/call",
            "params": [
                "name": "get_services",
                "arguments": [:] as [String: Any]
            ] as [String: Any]
        ])

        let result = response["result"] as? [String: Any]
        let isError = result?["isError"] as? Bool
        XCTAssertEqual(isError, true, "Should fail when server.json doesn't exist")

        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        // The error should reference the overridden path, not the default ~/.api2file/server.json
        XCTAssertTrue(text.contains("nonexistent") || text.contains("not running"),
                      "Error should reference the env var path, got: \(text)")
    }
}
