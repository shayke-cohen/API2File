import Foundation

/// MCP tool implementations for querying the read-only SQLite mirrors exposed by API2File.
enum SQLTools {

    static let allTools: [MCPToolDefinition] = [
        listSQLTablesDefinition,
        describeSQLTableDefinition,
        querySQLDefinition,
        searchRecordsDefinition,
        getRecordByIDDefinition,
        openRecordFileDefinition,
        queryAndOpenFirstDefinition,
    ]

    static let listSQLTablesDefinition = MCPToolDefinition(
        name: "list_sql_tables",
        description: "Lists the SQLite mirror tables available for a service. " +
            "Use this before querying so you know which resources are exposed as tables.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to inspect (from get_services)")
            ],
            required: ["serviceId"]
        )
    )

    static let describeSQLTableDefinition = MCPToolDefinition(
        name: "describe_sql_table",
        description: "Describes a SQLite mirror table for a service, including columns and row count. " +
            "Pass either the table name or the original resource name.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to inspect"),
                "table": .init(type: "string", description: "The table name or resource name to describe")
            ],
            required: ["serviceId", "table"]
        )
    )

    static let querySQLDefinition = MCPToolDefinition(
        name: "query_sql",
        description: "Runs a read-only SQL query against a service's local SQLite mirror. " +
            "Only SELECT-style queries are allowed.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to query"),
                "query": .init(type: "string", description: "A read-only SQL query, such as SELECT * FROM tasks LIMIT 10")
            ],
            required: ["serviceId", "query"]
        )
    )

    static let searchRecordsDefinition = MCPToolDefinition(
        name: "search_records",
        description: "Searches a service's SQLite mirror by scanning JSON payloads for matching text. " +
            "Optionally narrow the search to a comma-separated list of resource/table names.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to search"),
                "text": .init(type: "string", description: "Text to search for"),
                "resources": .init(type: "string", description: "Optional comma-separated resource or table names")
            ],
            required: ["serviceId", "text"]
        )
    )

    static let getRecordByIDDefinition = MCPToolDefinition(
        name: "get_record_by_id",
        description: "Looks up a specific record in a service's SQLite mirror and returns its canonical payload " +
            "plus the canonical/projection file paths for follow-up edits.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to inspect"),
                "resource": .init(type: "string", description: "The resource or SQLite table name"),
                "recordId": .init(type: "string", description: "The remote record ID to resolve")
            ],
            required: ["serviceId", "resource", "recordId"]
        )
    )

    static let openRecordFileDefinition = MCPToolDefinition(
        name: "open_record_file",
        description: "Opens the canonical or projection file for a specific record resolved through the SQLite mirror. " +
            "Use canonical for safe structured edits, or projection to inspect the user-facing file.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to inspect"),
                "resource": .init(type: "string", description: "The resource or SQLite table name"),
                "recordId": .init(type: "string", description: "The remote record ID to resolve"),
                "surface": .init(
                    type: "string",
                    description: "Which file surface to open",
                    enumValues: ["canonical", "projection"]
                )
            ],
            required: ["serviceId", "resource", "recordId"]
        )
    )

    static let queryAndOpenFirstDefinition = MCPToolDefinition(
        name: "query_and_open_first",
        description: "Runs a read-only SQL query, takes the first matching row, resolves its record ID, " +
            "and opens the canonical or projection file for that record. Prefer queries that return _remote_id.",
        inputSchema: .init(
            properties: [
                "serviceId": .init(type: "string", description: "The service ID to inspect"),
                "resource": .init(type: "string", description: "The resource or SQLite table name to resolve against"),
                "query": .init(type: "string", description: "A read-only SQL query that returns at least one row"),
                "surface": .init(
                    type: "string",
                    description: "Which file surface to open",
                    enumValues: ["canonical", "projection"]
                )
            ],
            required: ["serviceId", "resource", "query"]
        )
    )

    static func execute(name: String, args: [String: Any], client: AppClient) -> MCPToolResult {
        do {
            switch name {
            case "list_sql_tables":
                return try executeListTables(args: args, client: client)
            case "describe_sql_table":
                return try executeDescribeTable(args: args, client: client)
            case "query_sql":
                return try executeQuerySQL(args: args, client: client)
            case "search_records":
                return try executeSearchRecords(args: args, client: client)
            case "get_record_by_id":
                return try executeGetRecordByID(args: args, client: client)
            case "open_record_file":
                return try executeOpenRecordFile(args: args, client: client)
            case "query_and_open_first":
                return try executeQueryAndOpenFirst(args: args, client: client)
            default:
                return MCPToolResult(error: "Unknown SQL tool: \(name)")
            }
        } catch {
            return MCPToolResult(error: "Tool '\(name)' failed: \(error)")
        }
    }

    private static func executeListTables(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String else {
            return MCPToolResult(error: "Missing required argument 'serviceId' (string)")
        }
        return try performGET("/api/services/\(serviceId)/sql/tables", client: client)
    }

    private static func executeDescribeTable(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let table = args["table"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId' and 'table'")
        }
        return try performGET(
            "/api/services/\(serviceId)/sql/describe",
            queryItems: [URLQueryItem(name: "table", value: table)],
            client: client
        )
    }

    private static func executeQuerySQL(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let query = args["query"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId' and 'query'")
        }
        let (status, data) = try client.post("/api/services/\(serviceId)/sql/query", body: ["query": query])
        return prettyPrintedResult(status: status, data: data, failurePrefix: "query_sql failed")
    }

    private static func executeSearchRecords(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let text = args["text"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId' and 'text'")
        }

        var queryItems = [URLQueryItem(name: "text", value: text)]
        if let resources = args["resources"] as? String, !resources.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "resources", value: resources))
        }

        return try performGET("/api/services/\(serviceId)/sql/search", queryItems: queryItems, client: client)
    }

    private static func executeGetRecordByID(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let resource = args["resource"] as? String,
              let recordId = args["recordId"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId', 'resource', and 'recordId'")
        }

        return try performGET(
            "/api/services/\(serviceId)/sql/record",
            queryItems: [
                URLQueryItem(name: "resource", value: resource),
                URLQueryItem(name: "recordId", value: recordId)
            ],
            client: client
        )
    }

    private static func executeOpenRecordFile(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let resource = args["resource"] as? String,
              let recordId = args["recordId"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId', 'resource', and 'recordId'")
        }

        var queryItems = [
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "recordId", value: recordId)
        ]
        if let surface = args["surface"] as? String, !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "surface", value: surface))
        }

        return try performGET("/api/services/\(serviceId)/sql/open", queryItems: queryItems, client: client)
    }

    private static func executeQueryAndOpenFirst(args: [String: Any], client: AppClient) throws -> MCPToolResult {
        guard let serviceId = args["serviceId"] as? String,
              let resource = args["resource"] as? String,
              let query = args["query"] as? String else {
            return MCPToolResult(error: "Missing required arguments 'serviceId', 'resource', and 'query'")
        }

        let (queryStatus, queryData) = try client.post("/api/services/\(serviceId)/sql/query", body: ["query": query])
        guard queryStatus >= 200 && queryStatus < 300 else {
            let message = String(data: queryData, encoding: .utf8) ?? "HTTP \(queryStatus)"
            return MCPToolResult(error: "query_and_open_first failed during query: \(message)")
        }

        guard let queryObject = try JSONSerialization.jsonObject(with: queryData) as? [String: Any],
              let rows = queryObject["rows"] as? [[String: Any]] else {
            return MCPToolResult(error: "query_and_open_first failed: query_sql returned an unexpected payload")
        }
        guard let firstRow = rows.first else {
            return MCPToolResult(error: "query_and_open_first failed: query returned no rows")
        }
        guard let recordId = recordIdentifier(from: firstRow) else {
            return MCPToolResult(
                error: "query_and_open_first failed: first row must include '_remote_id' (preferred) or 'id'"
            )
        }

        var queryItems = [
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "recordId", value: recordId)
        ]
        if let surface = args["surface"] as? String, !surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "surface", value: surface))
        }

        let (openStatus, openData) = try client.get("/api/services/\(serviceId)/sql/open", queryItems: queryItems)
        guard openStatus >= 200 && openStatus < 300 else {
            let message = String(data: openData, encoding: .utf8) ?? "HTTP \(openStatus)"
            return MCPToolResult(error: "query_and_open_first failed while opening the record file: \(message)")
        }

        if var openObject = try JSONSerialization.jsonObject(with: openData) as? [String: Any] {
            openObject["query"] = query
            openObject["selectedRow"] = firstRow
            openObject["resolvedRecordId"] = recordId
            if let pretty = try? JSONSerialization.data(withJSONObject: openObject, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return MCPToolResult(text: text)
            }
        }

        return MCPToolResult(text: String(data: openData, encoding: .utf8) ?? "")
    }

    private static func performGET(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        client: AppClient
    ) throws -> MCPToolResult {
        let (status, data) = try client.get(path, queryItems: queryItems)
        return prettyPrintedResult(status: status, data: data, failurePrefix: "SQL request failed")
    }

    private static func prettyPrintedResult(status: Int, data: Data, failurePrefix: String) -> MCPToolResult {
        if status >= 200 && status < 300 {
            if let json = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8) {
                return MCPToolResult(text: text)
            }
            return MCPToolResult(text: String(data: data, encoding: .utf8) ?? "")
        }

        let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        return MCPToolResult(error: "\(failurePrefix): \(message)")
    }

    private static func recordIdentifier(from row: [String: Any]) -> String? {
        if let value = normalizedIdentifier(row["_remote_id"]) {
            return value
        }
        if let value = normalizedIdentifier(row["id"]) {
            return value
        }
        if let value = normalizedIdentifier(row["_id"]) {
            return value
        }
        return nil
    }

    private static func normalizedIdentifier(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let int as Int:
            return String(int)
        case let double as Double:
            if double.rounded() == double {
                return String(Int(double))
            }
            return String(double)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
