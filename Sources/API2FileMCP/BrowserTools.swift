import Foundation

/// MCP tool implementations for controlling the API2File embedded browser.
/// Each tool maps to an HTTP endpoint on the running API2File app.
enum BrowserTools {

    // MARK: - Tool Definitions

    static let allTools: [MCPToolDefinition] = [
        navigateDefinition,
        screenshotDefinition,
        getDomDefinition,
        clickDefinition,
        typeDefinition,
        evaluateJSDefinition,
        getPageURLDefinition,
        waitForDefinition,
        backDefinition,
        forwardDefinition,
        reloadDefinition,
        scrollDefinition,
    ]

    static let navigateDefinition = MCPToolDefinition(
        name: "navigate",
        description: "Opens the API2File browser window and loads the given URL. " +
            "Use get_services to discover service site URLs, or navigate to any web page for inspection. " +
            "The browser will fully load the page before returning.",
        inputSchema: .init(
            properties: [
                "url": .init(type: "string", description: "The URL to navigate to (e.g. https://example.com)")
            ],
            required: ["url"]
        )
    )

    static let screenshotDefinition = MCPToolDefinition(
        name: "screenshot",
        description: "Captures a screenshot of the current browser viewport and returns it as a PNG image. " +
            "Useful for visual inspection, debugging UI issues, or verifying page content. " +
            "Optionally specify width and height to resize the viewport before capturing.",
        inputSchema: .init(
            properties: [
                "width": .init(type: "integer", description: "Viewport width in pixels (default: current width)"),
                "height": .init(type: "integer", description: "Viewport height in pixels (default: current height)")
            ],
            required: []
        )
    )

    static let getDomDefinition = MCPToolDefinition(
        name: "get_dom",
        description: "Returns the DOM content of the current page as HTML. " +
            "Optionally pass a CSS selector to get only matching elements. " +
            "Without a selector, returns the full document body. " +
            "Useful for inspecting page structure, reading text content, or finding elements.",
        inputSchema: .init(
            properties: [
                "selector": .init(type: "string", description: "CSS selector to filter elements (e.g. 'div.main', '#content', 'table tr'). Omit for full page.")
            ],
            required: []
        )
    )

    static let clickDefinition = MCPToolDefinition(
        name: "click",
        description: "Clicks on a DOM element matching the given CSS selector. " +
            "Simulates a real mouse click event including mousedown, mouseup, and click. " +
            "Use get_dom first to find the right selector for the element you want to click.",
        inputSchema: .init(
            properties: [
                "selector": .init(type: "string", description: "CSS selector for the element to click (e.g. 'button.submit', '#login-btn', 'a[href=\"/next\"]')")
            ],
            required: ["selector"]
        )
    )

    static let typeDefinition = MCPToolDefinition(
        name: "type",
        description: "Types text into an input field or textarea matching the given CSS selector. " +
            "Focuses the element first, then simulates keyboard input. " +
            "Use get_dom to find input selectors. Works with input, textarea, and contenteditable elements.",
        inputSchema: .init(
            properties: [
                "selector": .init(type: "string", description: "CSS selector for the input element (e.g. 'input[name=\"email\"]', '#search-box', 'textarea.comment')"),
                "text": .init(type: "string", description: "The text to type into the element")
            ],
            required: ["selector", "text"]
        )
    )

    static let evaluateJSDefinition = MCPToolDefinition(
        name: "evaluate_js",
        description: "Executes arbitrary JavaScript code in the browser page context and returns the result. " +
            "The code runs in the page's global scope with full DOM access. " +
            "Return values are JSON-serialized. " +
            "Useful for complex interactions, reading JavaScript variables, or manipulating the page programmatically.",
        inputSchema: .init(
            properties: [
                "code": .init(type: "string", description: "JavaScript code to evaluate (e.g. 'document.title', 'JSON.stringify(window.appState)')")
            ],
            required: ["code"]
        )
    )

    static let getPageURLDefinition = MCPToolDefinition(
        name: "get_page_url",
        description: "Returns the current URL of the browser page. " +
            "Useful for verifying navigation, checking redirects, or getting the current location after interactions.",
        inputSchema: .init(
            properties: [:],
            required: []
        )
    )

    static let waitForDefinition = MCPToolDefinition(
        name: "wait_for",
        description: "Waits until a DOM element matching the CSS selector appears on the page. " +
            "Returns when the element is found or when the timeout expires. " +
            "Useful after navigation or dynamic content loading to ensure elements are available before interacting.",
        inputSchema: .init(
            properties: [
                "selector": .init(type: "string", description: "CSS selector to wait for (e.g. '#loaded-content', '.results-list')"),
                "timeout": .init(type: "integer", description: "Maximum wait time in milliseconds (default: 5000)")
            ],
            required: ["selector"]
        )
    )

    static let backDefinition = MCPToolDefinition(
        name: "back",
        description: "Navigates the browser back one step in history, like pressing the Back button. " +
            "Returns the URL of the page after navigating back.",
        inputSchema: .init(
            properties: [:],
            required: []
        )
    )

    static let forwardDefinition = MCPToolDefinition(
        name: "forward",
        description: "Navigates the browser forward one step in history, like pressing the Forward button. " +
            "Returns the URL of the page after navigating forward.",
        inputSchema: .init(
            properties: [:],
            required: []
        )
    )

    static let reloadDefinition = MCPToolDefinition(
        name: "reload",
        description: "Reloads the current browser page. " +
            "Useful when page content may have changed server-side or to reset page state.",
        inputSchema: .init(
            properties: [:],
            required: []
        )
    )

    static let scrollDefinition = MCPToolDefinition(
        name: "scroll",
        description: "Scrolls the browser viewport in the specified direction. " +
            "Useful for reaching content below the fold or navigating long pages. " +
            "Use get_dom or screenshot after scrolling to see the newly visible content.",
        inputSchema: .init(
            properties: [
                "direction": .init(
                    type: "string",
                    description: "Scroll direction",
                    enumValues: ["up", "down", "left", "right"]
                ),
                "amount": .init(type: "integer", description: "Scroll distance in pixels (default: 500)")
            ],
            required: ["direction"]
        )
    )

    // MARK: - Tool Execution

    static func execute(name: String, args: [String: Any], client: AppClient) -> MCPToolResult {
        do {
            switch name {
            case "navigate":
                return try executeNavigate(args: args, client: client)
            case "screenshot":
                return try executeScreenshot(args: args, client: client)
            case "get_dom":
                return try executeGetDom(args: args, client: client)
            case "click":
                return try executeClick(args: args, client: client)
            case "type":
                return try executeType(args: args, client: client)
            case "evaluate_js":
                return try executeEvaluateJS(args: args, client: client)
            case "get_page_url":
                return try executeGetPageURL(client: client)
            case "wait_for":
                return try executeWaitFor(args: args, client: client)
            case "back":
                return try executeBack(client: client)
            case "forward":
                return try executeForward(client: client)
            case "reload":
                return try executeReload(client: client)
            case "scroll":
                return try executeScroll(args: args, client: client)
            default:
                return MCPToolResult(error: "Unknown browser tool: \(name)")
            }
        } catch {
            return MCPToolResult(error: "Tool '\(name)' failed: \(error)")
        }
    }

    // MARK: - Individual Tool Implementations

    private static func executeNavigate(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let url = args["url"] as? String else {
            return MCPToolResult(error: "Missing required argument 'url' (string)")
        }
        let (status, data) = try client.post("/api/browser/navigate", body: ["url": url])
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Navigated to \(url). \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Navigate failed: \(msg)")
        }
    }

    private static func executeScreenshot(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        var body: [String: Any] = [:]
        if let width = args["width"] as? Int { body["width"] = width }
        if let height = args["height"] as? Int { body["height"] = height }

        let (status, data) = try client.post("/api/browser/screenshot", body: body.isEmpty ? nil : body)
        if status >= 200 && status < 300 {
            // Save screenshot to a temp file and return the path.
            // Claude Code can read image files natively with its Read tool.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let base64 = json["image"] as? String,
               let imageData = Data(base64Encoded: base64) {
                let filename = "api2file-screenshot-\(Int(Date().timeIntervalSince1970)).png"
                let path = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try imageData.write(to: path)
                return MCPToolResult(text: "Screenshot saved to \(path.path)\nUse the Read tool to view the image.")
            } else {
                return MCPToolResult(error: "Screenshot failed: could not decode image data")
            }
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Screenshot failed: \(msg)")
        }
    }

    private static func executeGetDom(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        var body: [String: Any] = [:]
        if let selector = args["selector"] as? String { body["selector"] = selector }

        let (status, data) = try client.post("/api/browser/dom", body: body.isEmpty ? nil : body)
        if status >= 200 && status < 300 {
            let html = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: html)
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "get_dom failed: \(msg)")
        }
    }

    private static func executeClick(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let selector = args["selector"] as? String else {
            return MCPToolResult(error: "Missing required argument 'selector' (string)")
        }
        let (status, data) = try client.post("/api/browser/click", body: ["selector": selector])
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Clicked element '\(selector)'. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Click failed on '\(selector)': \(msg)")
        }
    }

    private static func executeType(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let selector = args["selector"] as? String else {
            return MCPToolResult(error: "Missing required argument 'selector' (string)")
        }
        guard let text = args["text"] as? String else {
            return MCPToolResult(error: "Missing required argument 'text' (string)")
        }
        let (status, data) = try client.post("/api/browser/type", body: ["selector": selector, "text": text])
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Typed into '\(selector)'. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Type failed on '\(selector)': \(msg)")
        }
    }

    private static func executeEvaluateJS(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let code = args["code"] as? String else {
            return MCPToolResult(error: "Missing required argument 'code' (string)")
        }
        let (status, data) = try client.post("/api/browser/evaluate", body: ["code": code])
        if status >= 200 && status < 300 {
            let result = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: result)
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "JavaScript evaluation failed: \(msg)")
        }
    }

    private static func executeGetPageURL(client: AppClient) throws -> MCPToolResult {
        let (status, data) = try client.get("/api/browser/url")
        if status >= 200 && status < 300 {
            let url = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: url)
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "get_page_url failed: \(msg)")
        }
    }

    private static func executeWaitFor(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let selector = args["selector"] as? String else {
            return MCPToolResult(error: "Missing required argument 'selector' (string)")
        }
        var body: [String: Any] = ["selector": selector]
        if let timeout = args["timeout"] as? Int { body["timeout"] = timeout }

        let (status, data) = try client.post("/api/browser/wait", body: body)
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Element '\(selector)' found. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "wait_for '\(selector)' failed: \(msg)")
        }
    }

    private static func executeBack(client: AppClient) throws -> MCPToolResult {
        let (status, data) = try client.post("/api/browser/back")
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Navigated back. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Back navigation failed: \(msg)")
        }
    }

    private static func executeForward(client: AppClient) throws -> MCPToolResult {
        let (status, data) = try client.post("/api/browser/forward")
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Navigated forward. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Forward navigation failed: \(msg)")
        }
    }

    private static func executeReload(client: AppClient) throws -> MCPToolResult {
        let (status, data) = try client.post("/api/browser/reload")
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Page reloaded. \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Reload failed: \(msg)")
        }
    }

    private static func executeScroll(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let direction = args["direction"] as? String else {
            return MCPToolResult(error: "Missing required argument 'direction' (string: up/down/left/right)")
        }
        var body: [String: Any] = ["direction": direction]
        if let amount = args["amount"] as? Int { body["amount"] = amount }

        let (status, data) = try client.post("/api/browser/scroll", body: body)
        if status >= 200 && status < 300 {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Scrolled \(direction). \(responseText)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Scroll failed: \(msg)")
        }
    }
}
