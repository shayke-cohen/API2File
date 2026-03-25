import Foundation

// MARK: - AnyCodable wrapper for dynamic JSON values

struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        case let data as Data:
            try container.encode(data.base64EncodedString())
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simple equality for basic types
        switch (lhs.value, rhs.value) {
        case (is NSNull, is NSNull): return true
        case (let l as Bool, let r as Bool): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as String, let r as String): return l == r
        default: return false
        }
    }
}

// MARK: - JSON-RPC 2.0 Request

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: [String: AnyCodable]?

    enum RequestID: Decodable, Encodable {
        case int(Int)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intVal = try? container.decode(Int.self) {
                self = .int(intVal)
            } else if let strVal = try? container.decode(String.self) {
                self = .string(strVal)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "ID must be int or string")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let v): try container.encode(v)
            case .string(let v): try container.encode(v)
            }
        }
    }
}

// MARK: - JSON-RPC 2.0 Response

struct JSONRPCResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: JSONRPCRequest.RequestID?
    let result: AnyCodable?
    let error: MCPError?

    init(id: JSONRPCRequest.RequestID?, result: AnyCodable) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCRequest.RequestID?, error: MCPError) {
        self.id = id
        self.result = nil
        self.error = error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        // Always encode id, even if nil (JSON-RPC spec)
        if let id = id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        if let error = error {
            try container.encode(error, forKey: .error)
        } else if let result = result {
            try container.encode(result, forKey: .result)
        } else {
            try container.encodeNil(forKey: .result)
        }
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }
}

// MARK: - MCP Error

struct MCPError: Encodable {
    let code: Int
    let message: String

    static let parseError = MCPError(code: -32700, message: "Parse error")
    static let invalidRequest = MCPError(code: -32600, message: "Invalid Request")
    static let methodNotFound = MCPError(code: -32601, message: "Method not found")
    static let invalidParams = MCPError(code: -32602, message: "Invalid params")
    static let internalError = MCPError(code: -32603, message: "Internal error")

    static func custom(code: Int = -32000, message: String) -> MCPError {
        MCPError(code: code, message: message)
    }
}

// MARK: - MCP Tool Definition

struct MCPToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: InputSchema

    struct InputSchema: Encodable {
        let type: String
        let properties: [String: PropertySchema]
        let required: [String]

        init(properties: [String: PropertySchema] = [:], required: [String] = []) {
            self.type = "object"
            self.properties = properties
            self.required = required
        }
    }

    struct PropertySchema: Encodable {
        let type: String
        let description: String
        let enumValues: [String]?

        init(type: String, description: String, enumValues: [String]? = nil) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }

        enum CodingKeys: String, CodingKey {
            case type, description
            case enumValues = "enum"
        }
    }
}

// MARK: - MCP Tool Result

struct MCPToolResult: Encodable {
    let content: [ContentBlock]
    let isError: Bool?

    init(text: String) {
        self.content = [ContentBlock(type: "text", text: text, data: nil, mimeType: nil)]
        self.isError = nil
    }

    init(image data: String, mimeType: String = "image/png") {
        self.content = [ContentBlock(type: "image", text: nil, data: data, mimeType: mimeType)]
        self.isError = nil
    }

    init(error message: String) {
        self.content = [ContentBlock(type: "text", text: message, data: nil, mimeType: nil)]
        self.isError = true
    }

    struct ContentBlock: Encodable {
        let type: String
        let text: String?
        let data: String?
        let mimeType: String?
    }
}
