import XCTest
@testable import API2FileCore

// MARK: - Mock Browser Delegate

@MainActor
final class MockBrowserDelegate: BrowserControlDelegate {

    // MARK: - Configurable return values

    var screenshotData: Data = Data()
    var domHTML: String = "<html></html>"
    var currentURL: String? = "https://example.com"
    var isOpen: Bool = true
    var evaluateResult: String = ""

    // MARK: - Error injection

    var errorToThrow: BrowserError?

    // MARK: - Call recording

    var openBrowserCalls: [Void] = []
    var navigateCalls: [String] = []
    var goBackCalls: [Void] = []
    var goForwardCalls: [Void] = []
    var reloadCalls: [Void] = []
    var screenshotCalls: [(width: Int?, height: Int?)] = []
    var getDOMCalls: [String?] = []
    var clickCalls: [String] = []
    var typeCalls: [(selector: String, text: String)] = []
    var evaluateJSCalls: [String] = []
    var getCurrentURLCalls: [Void] = []
    var waitForCalls: [(selector: String, timeout: TimeInterval)] = []
    var scrollCalls: [(direction: ScrollDirection, amount: Int?)] = []

    // MARK: - Protocol implementation

    func openBrowser() async throws {
        if let error = errorToThrow { throw error }
        openBrowserCalls.append(())
    }

    func isBrowserOpen() async -> Bool {
        return isOpen
    }

    func navigate(to url: String) async throws -> String {
        if let error = errorToThrow { throw error }
        navigateCalls.append(url)
        return url
    }

    func goBack() async throws {
        if let error = errorToThrow { throw error }
        goBackCalls.append(())
    }

    func goForward() async throws {
        if let error = errorToThrow { throw error }
        goForwardCalls.append(())
    }

    func reload() async throws {
        if let error = errorToThrow { throw error }
        reloadCalls.append(())
    }

    func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
        if let error = errorToThrow { throw error }
        screenshotCalls.append((width: width, height: height))
        return screenshotData
    }

    func getDOM(selector: String?) async throws -> String {
        if let error = errorToThrow { throw error }
        getDOMCalls.append(selector)
        return domHTML
    }

    func click(selector: String) async throws {
        if let error = errorToThrow { throw error }
        clickCalls.append(selector)
    }

    func type(selector: String, text: String) async throws {
        if let error = errorToThrow { throw error }
        typeCalls.append((selector: selector, text: text))
    }

    func evaluateJS(_ code: String) async throws -> String {
        if let error = errorToThrow { throw error }
        evaluateJSCalls.append(code)
        return evaluateResult
    }

    func getCurrentURL() async -> String? {
        getCurrentURLCalls.append(())
        return currentURL
    }

    func waitFor(selector: String, timeout: TimeInterval) async throws {
        if let error = errorToThrow { throw error }
        waitForCalls.append((selector: selector, timeout: timeout))
    }

    func scroll(direction: ScrollDirection, amount: Int?) async throws {
        if let error = errorToThrow { throw error }
        scrollCalls.append((direction: direction, amount: amount))
    }
}

// MARK: - Browser Route Tests

@MainActor
final class BrowserRouteTests: XCTestCase {

    // MARK: - Properties

    private var server: LocalServer!
    private var syncEngine: SyncEngine!
    private var mockDelegate: MockBrowserDelegate!
    private var port: UInt16!
    private var tempDir: URL!
    private var baseURL: String { "http://localhost:\(port!)" }

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Create temp directory for SyncEngine config
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserRouteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write a minimal GlobalConfig
        let config = GlobalConfig(syncFolder: tempDir.path, gitAutoCommit: false, defaultSyncInterval: 9999)

        // Create SyncEngine (won't start, just need it for LocalServer init)
        syncEngine = SyncEngine(config: config)

        // Start LocalServer on a random port
        let randomPort = UInt16.random(in: 19000...29999)
        server = LocalServer(port: randomPort, syncEngine: syncEngine)
        try await server.start()
        port = randomPort

        // Create and inject mock delegate
        mockDelegate = MockBrowserDelegate()
        await server.setBrowserDelegate(mockDelegate)

        // Wait for server to be ready
        var ready = false
        for attempt in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            do {
                let url = URL(string: "\(baseURL)/api/health")!
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    ready = true
                    break
                }
            } catch {
                if attempt == 9 {
                    XCTFail("Server not ready after 10 attempts on port \(randomPort): \(error)")
                }
            }
        }
        guard ready else { return }
    }

    override func tearDown() async throws {
        if let server {
            await server.stop()
        }
        server = nil
        syncEngine = nil
        mockDelegate = nil
        port = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - HTTP Helpers

    private func post(_ path: String, json: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "\(baseURL)\(path)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return (data, response as! HTTPURLResponse)
    }

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        return json as? [String: Any] ?? [:]
    }

    // MARK: - Tests

    // 1. testNavigateReturnsURL
    func testNavigateReturnsURL() async throws {
        let (data, response) = try await post("/api/browser/navigate", json: ["url": "https://example.com"])
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["url"] as? String, "https://example.com")
    }

    // 2. testNavigateAutoOpens
    func testNavigateAutoOpens() async throws {
        mockDelegate.isOpen = false
        let (_, response) = try await post("/api/browser/navigate", json: ["url": "https://example.com"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(mockDelegate.openBrowserCalls.count, 1, "openBrowser() should have been called")
    }

    // 3. testScreenshotReturnsBase64
    func testScreenshotReturnsBase64() async throws {
        let pngBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let pngData = Data(pngBytes)
        mockDelegate.screenshotData = pngData
        let (data, response) = try await post("/api/browser/screenshot")
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        let base64 = json["image"] as? String
        XCTAssertNotNil(base64)
        XCTAssertEqual(base64, pngData.base64EncodedString())
    }

    // 4. testDOMReturnsHTML
    func testDOMReturnsHTML() async throws {
        mockDelegate.domHTML = "<div>Hello World</div>"
        let (data, response) = try await post("/api/browser/dom")
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["html"] as? String, "<div>Hello World</div>")
    }

    // 5. testDOMWithSelector
    func testDOMWithSelector() async throws {
        mockDelegate.domHTML = "<div class=\"main\">Content</div>"
        let (_, response) = try await post("/api/browser/dom", json: ["selector": "div.main"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(mockDelegate.getDOMCalls.count, 1)
        XCTAssertEqual(mockDelegate.getDOMCalls.first as? String, "div.main")
    }

    // 6. testClickNotFound
    func testClickNotFound() async throws {
        mockDelegate.errorToThrow = .elementNotFound(selector: "#missing")
        let (_, response) = try await post("/api/browser/click", json: ["selector": "#missing"])
        XCTAssertEqual(response.statusCode, 404)
    }

    // 7. testWaitForTimeout
    func testWaitForTimeout() async throws {
        mockDelegate.errorToThrow = .timeout(selector: "#slow", seconds: 5)
        let (_, response) = try await post("/api/browser/wait", json: ["selector": "#slow"])
        XCTAssertEqual(response.statusCode, 408)
    }

    // 8. testNoDelegateReturns503
    func testNoDelegateReturns503() async throws {
        await server.setBrowserDelegate(nil)
        let (_, response) = try await post("/api/browser/navigate", json: ["url": "https://example.com"])
        XCTAssertEqual(response.statusCode, 503)
    }

    // 9. testScrollDirections
    func testScrollDirections() async throws {
        for direction in ["up", "down", "left", "right"] {
            let (_, response) = try await post("/api/browser/scroll", json: ["direction": direction])
            XCTAssertEqual(response.statusCode, 200, "Scroll \(direction) should return 200")
        }
        XCTAssertEqual(mockDelegate.scrollCalls.count, 4)
    }

    // 10. testBackForwardReload
    func testBackForwardReload() async throws {
        let (_, backResponse) = try await post("/api/browser/back")
        XCTAssertEqual(backResponse.statusCode, 200)
        XCTAssertEqual(mockDelegate.goBackCalls.count, 1)

        let (_, forwardResponse) = try await post("/api/browser/forward")
        XCTAssertEqual(forwardResponse.statusCode, 200)
        XCTAssertEqual(mockDelegate.goForwardCalls.count, 1)

        let (_, reloadResponse) = try await post("/api/browser/reload")
        XCTAssertEqual(reloadResponse.statusCode, 200)
        XCTAssertEqual(mockDelegate.reloadCalls.count, 1)
    }

    // 11. testBrowserStatus
    func testBrowserStatus() async throws {
        mockDelegate.isOpen = true
        mockDelegate.currentURL = "https://example.com/page"
        let (data, response) = try await get("/api/browser/status")
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["open"] as? String, "true")
        XCTAssertEqual(json["url"] as? String, "https://example.com/page")
    }

    // 12. testEvaluateJSReturnsResult
    func testEvaluateJSReturnsResult() async throws {
        mockDelegate.evaluateResult = "42"
        let (data, response) = try await post("/api/browser/evaluate", json: ["code": "1 + 1"])
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["result"] as? String, "42")
        XCTAssertEqual(mockDelegate.evaluateJSCalls.first, "1 + 1")
    }

    // 13. testTypeMissingParams
    func testTypeMissingParams() async throws {
        let (_, response) = try await post("/api/browser/type", json: ["text": "hello"])
        XCTAssertEqual(response.statusCode, 400)
    }

    // 14. testGetURL
    func testGetURL() async throws {
        mockDelegate.currentURL = "https://example.com/current"
        let (data, response) = try await get("/api/browser/url")
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["url"] as? String, "https://example.com/current")
    }

    // 15. testNavigateInvalidURL
    func testNavigateInvalidURL() async throws {
        mockDelegate.errorToThrow = .navigationFailed("Invalid URL")
        let (_, response) = try await post("/api/browser/navigate", json: ["url": "not-a-url"])
        XCTAssertEqual(response.statusCode, 400)
    }

    // 16. testEvaluateJSFails
    func testEvaluateJSFails() async throws {
        mockDelegate.errorToThrow = .evaluationFailed("SyntaxError")
        let (_, response) = try await post("/api/browser/evaluate", json: ["code": "???"])
        XCTAssertEqual(response.statusCode, 400)
    }

    // 17. testWindowNotOpen
    func testWindowNotOpen() async throws {
        mockDelegate.errorToThrow = .windowNotOpen
        let (_, response) = try await post("/api/browser/click", json: ["selector": "#btn"])
        XCTAssertEqual(response.statusCode, 503)
    }

    // 18. testBrowserOpenRoute
    func testBrowserOpenRoute() async throws {
        let (data, response) = try await post("/api/browser/open")
        XCTAssertEqual(response.statusCode, 200)
        let json = try parseJSON(data)
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(mockDelegate.openBrowserCalls.count, 1)
    }
}
