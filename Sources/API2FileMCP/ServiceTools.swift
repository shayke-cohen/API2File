import Foundation

/// MCP tool implementations for managing API2File cloud services.
/// These tools allow listing connected services and triggering sync operations.
enum ServiceTools {

    // MARK: - Tool Definitions

    static let allTools: [MCPToolDefinition] = [
        getServicesDefinition,
        syncDefinition,
    ]

    static let getServicesDefinition = MCPToolDefinition(
        name: "get_services",
        description: "Lists all connected cloud services in API2File and their current sync status. " +
            "Returns service IDs, names, types (e.g. Wix, GitHub, Monday.com), sync state, " +
            "file counts, and last sync timestamps. " +
            "Use this to discover available services before performing sync operations.",
        inputSchema: .init(
            properties: [:],
            required: []
        )
    )

    static let syncDefinition = MCPToolDefinition(
        name: "sync",
        description: "Triggers an immediate sync for a specific cloud service. " +
            "Downloads remote changes and uploads local file modifications. " +
            "Use get_services first to find the service ID. " +
            "Returns the sync result including files updated, conflicts detected, and any errors.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to sync (from get_services)")
            ],
            required: ["serviceId"]
        )
    )

    // MARK: - Tool Execution

    static func execute(name: String, args: [String: Any], client: AppClient) -> MCPToolResult {
        do {
            switch name {
            case "get_services":
                return try executeGetServices(client: client)
            case "sync":
                return try executeSync(args: args, client: client)
            default:
                return MCPToolResult(error: "Unknown service tool: \(name)")
            }
        } catch {
            return MCPToolResult(error: "Tool '\(name)' failed: \(error)")
        }
    }

    // MARK: - Individual Tool Implementations

    private static func executeGetServices(client: AppClient) throws -> MCPToolResult {
        let (status, data) = try client.get("/api/services")
        if status >= 200 && status < 300 {
            // Pretty-print the JSON if possible
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return MCPToolResult(text: text)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: text)
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "get_services failed: \(msg)")
        }
    }

    private static func executeSync(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String else {
            return MCPToolResult(error: "Missing required argument 'serviceId' (string)")
        }
        let path = "/api/services/\(serviceId)/sync"
        let (status, data) = try client.post(path)
        if status >= 200 && status < 300 {
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return MCPToolResult(text: "Sync triggered for service '\(serviceId)'.\n\(text)")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return MCPToolResult(text: "Sync triggered for service '\(serviceId)'. \(text)")
        } else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            return MCPToolResult(error: "Sync failed for '\(serviceId)': \(msg)")
        }
    }
}
