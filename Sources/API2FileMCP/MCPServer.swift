import Foundation

/// Main MCP server that handles JSON-RPC dispatch and tool routing.
final class MCPServer {
    private let transport = MCPTransport()
    private var client: AppClient?

    /// All registered tool definitions from both browser and service tools.
    private var allToolDefinitions: [MCPToolDefinition] {
        BrowserTools.allTools + ServiceTools.allTools + SQLTools.allTools
    }

    /// All browser tool names for dispatch routing.
    private let browserToolNames: Set<String> = Set(BrowserTools.allTools.map { $0.name })

    /// All service tool names for dispatch routing.
    private let serviceToolNames: Set<String> = Set(ServiceTools.allTools.map { $0.name })

    /// All SQL tool names for dispatch routing.
    private let sqlToolNames: Set<String> = Set(SQLTools.allTools.map { $0.name })

    /// Start the MCP server. Blocks on stdin until EOF.
    func run() {
        // Log to stderr so it doesn't interfere with the JSON-RPC protocol on stdout
        log("api2file-mcp server starting...")

        transport.run { [weak self] request in
            guard let self = self else { return nil }
            return self.handleRequest(request)
        }

        log("api2file-mcp server shutting down.")
    }

    // MARK: - Request Dispatch

    private func handleRequest(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        switch request.method {

        case "initialize":
            return handleInitialize(request)

        case "initialized":
            // Notification — no response
            log("Client sent 'initialized' notification.")
            return nil

        case "notifications/initialized":
            // Alternative notification path — no response
            log("Client sent 'notifications/initialized'.")
            return nil

        case "tools/list":
            return handleToolsList(request)

        case "tools/call":
            return handleToolCall(request)

        case "ping":
            return JSONRPCResponse(id: request.id, result: AnyCodable([:] as [String: String]))

        default:
            log("Unknown method: \(request.method)")
            if request.id != nil {
                return JSONRPCResponse(id: request.id, error: .methodNotFound)
            }
            // No id means notification — don't respond
            return nil
        }
    }

    // MARK: - initialize

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:] as [String: Any]
            ] as [String: Any],
            "serverInfo": [
                "name": "api2file",
                "version": "1.0.0"
            ] as [String: Any]
        ]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result))
    }

    // MARK: - tools/list

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let tools = allToolDefinitions.map { tool -> [String: Any] in
            // Serialize tool definition to dictionary
            var props: [String: Any] = [:]
            for (key, prop) in tool.inputSchema.properties {
                var propDict: [String: Any] = [
                    "type": prop.type,
                    "description": prop.description
                ]
                if let enumVals = prop.enumValues {
                    propDict["enum"] = enumVals
                }
                props[key] = propDict
            }

            let schema: [String: Any] = [
                "type": tool.inputSchema.type,
                "properties": props,
                "required": tool.inputSchema.required
            ]

            return [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": schema
            ]
        }

        let result: [String: Any] = ["tools": tools]
        return JSONRPCResponse(id: request.id, result: AnyCodable(result))
    }

    // MARK: - tools/call

    private func handleToolCall(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard let params = request.params,
              let toolName = params["name"]?.value as? String else {
            return JSONRPCResponse(id: request.id, error: .invalidParams)
        }

        // Extract arguments
        let args: [String: Any]
        if let argsValue = params["arguments"]?.value as? [String: Any] {
            args = argsValue
        } else {
            args = [:]
        }

        // Ensure we have a client connection
        let appClient: AppClient
        if let existing = client {
            appClient = existing
        } else {
            do {
                appClient = try PortDiscovery.discover()
                client = appClient
            } catch {
                let errorResult = MCPToolResult(error: "Cannot connect to API2File: \(error)")
                return toolResultResponse(id: request.id, result: errorResult)
            }
        }

        // Dispatch to the right tool set
        let toolResult: MCPToolResult
        if browserToolNames.contains(toolName) {
            toolResult = BrowserTools.execute(name: toolName, args: args, client: appClient)
        } else if serviceToolNames.contains(toolName) {
            toolResult = ServiceTools.execute(name: toolName, args: args, client: appClient)
        } else if sqlToolNames.contains(toolName) {
            toolResult = SQLTools.execute(name: toolName, args: args, client: appClient)
        } else {
            toolResult = MCPToolResult(error: "Unknown tool: '\(toolName)'. Use tools/list to see available tools.")
        }

        return toolResultResponse(id: request.id, result: toolResult)
    }

    // MARK: - Helpers

    private func toolResultResponse(id: JSONRPCRequest.RequestID?, result: MCPToolResult) -> JSONRPCResponse {
        // Encode MCPToolResult to dictionary
        var resultDict: [String: Any] = [:]

        let content: [[String: Any]] = result.content.map { block in
            var dict: [String: Any] = ["type": block.type]
            if let text = block.text { dict["text"] = text }
            if let data = block.data { dict["data"] = data }
            if let mimeType = block.mimeType { dict["mimeType"] = mimeType }
            return dict
        }
        resultDict["content"] = content

        if let isError = result.isError {
            resultDict["isError"] = isError
        }

        return JSONRPCResponse(id: id, result: AnyCodable(resultDict))
    }

    private func log(_ message: String) {
        // Write to stderr so it doesn't interfere with the JSON-RPC protocol on stdout
        FileHandle.standardError.write(Data("[api2file-mcp] \(message)\n".utf8))
    }
}
