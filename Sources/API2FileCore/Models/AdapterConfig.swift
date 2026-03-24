import Foundation

/// Root adapter configuration — parsed from .api2file/adapter.json
public struct AdapterConfig: Codable, Sendable {
    public let service: String
    public let displayName: String
    public let version: String
    public let auth: AuthConfig
    public let globals: GlobalsConfig?
    public let resources: [ResourceConfig]

    public init(service: String, displayName: String, version: String, auth: AuthConfig, globals: GlobalsConfig? = nil, resources: [ResourceConfig]) {
        self.service = service
        self.displayName = displayName
        self.version = version
        self.auth = auth
        self.globals = globals
        self.resources = resources
    }
}

// MARK: - Auth

public struct AuthConfig: Codable, Sendable {
    public let type: AuthType
    public let keychainKey: String
    public let setup: AuthSetup?
    // OAuth2 specific
    public let authorizeUrl: String?
    public let tokenUrl: String?
    public let refreshUrl: String?
    public let scopes: [String]?
    public let callbackPort: Int?

    public init(type: AuthType, keychainKey: String, setup: AuthSetup? = nil, authorizeUrl: String? = nil, tokenUrl: String? = nil, refreshUrl: String? = nil, scopes: [String]? = nil, callbackPort: Int? = nil) {
        self.type = type
        self.keychainKey = keychainKey
        self.setup = setup
        self.authorizeUrl = authorizeUrl
        self.tokenUrl = tokenUrl
        self.refreshUrl = refreshUrl
        self.scopes = scopes
        self.callbackPort = callbackPort
    }
}

public enum AuthType: String, Codable, Sendable {
    case bearer
    case oauth2
    case apiKey
    case basic
}

public struct AuthSetup: Codable, Sendable {
    public let instructions: String
    public let url: String?

    public init(instructions: String, url: String? = nil) {
        self.instructions = instructions
        self.url = url
    }
}

// MARK: - Globals

public struct GlobalsConfig: Codable, Sendable {
    public let baseUrl: String?
    public let headers: [String: String]?
    public let method: String?

    public init(baseUrl: String? = nil, headers: [String: String]? = nil, method: String? = nil) {
        self.baseUrl = baseUrl
        self.headers = headers
        self.method = method
    }
}

// MARK: - Resource

public struct ResourceConfig: Codable, Sendable {
    public let name: String
    public let description: String?
    public let pull: PullConfig?
    public let push: PushConfig?
    public let fileMapping: FileMappingConfig
    public let children: [ResourceConfig]?
    public let sync: SyncConfig?

    public init(name: String, description: String? = nil, pull: PullConfig? = nil, push: PushConfig? = nil, fileMapping: FileMappingConfig, children: [ResourceConfig]? = nil, sync: SyncConfig? = nil) {
        self.name = name
        self.description = description
        self.pull = pull
        self.push = push
        self.fileMapping = fileMapping
        self.children = children
        self.sync = sync
    }
}

// MARK: - Pull

public struct PullConfig: Codable, Sendable {
    public let method: String?
    public let url: String
    public let type: APIType?
    public let query: String?
    public let body: JSONValue?
    public let dataPath: String?
    public let pagination: PaginationConfig?
    public let mediaConfig: MediaConfig?
    public let updatedSinceField: String?      // URL param name (e.g. "since")
    public let updatedSinceBodyPath: String?   // body field path for date filter
    public let updatedSinceDateFormat: String? // "iso8601" (default) or "epoch"

    public init(method: String? = nil, url: String, type: APIType? = nil, query: String? = nil, body: JSONValue? = nil, dataPath: String? = nil, pagination: PaginationConfig? = nil, mediaConfig: MediaConfig? = nil, updatedSinceField: String? = nil, updatedSinceBodyPath: String? = nil, updatedSinceDateFormat: String? = nil) {
        self.method = method
        self.url = url
        self.type = type
        self.query = query
        self.body = body
        self.dataPath = dataPath
        self.pagination = pagination
        self.mediaConfig = mediaConfig
        self.updatedSinceField = updatedSinceField
        self.updatedSinceBodyPath = updatedSinceBodyPath
        self.updatedSinceDateFormat = updatedSinceDateFormat
    }
}

public enum APIType: String, Codable, Sendable {
    case rest
    case graphql
    case media
}

/// Configuration for media/binary file sync — maps API response fields to download URLs and filenames
public struct MediaConfig: Codable, Sendable {
    /// JSON field containing the download URL (e.g., "url", "webContentLink", "presignedUrl")
    public let urlField: String
    /// JSON field containing the filename (e.g., "displayName", "name", "fileName")
    public let filenameField: String
    /// JSON field for the file's unique ID
    public let idField: String?
    /// JSON field for file size in bytes (for progress reporting)
    public let sizeField: String?
    /// JSON field for file hash/ETag (for skip-if-unchanged optimization)
    public let hashField: String?

    public init(urlField: String = "url", filenameField: String = "displayName", idField: String? = "id", sizeField: String? = nil, hashField: String? = nil) {
        self.urlField = urlField
        self.filenameField = filenameField
        self.idField = idField
        self.sizeField = sizeField
        self.hashField = hashField
    }
}

public struct PaginationConfig: Codable, Sendable {
    public let type: PaginationType
    public let nextCursorPath: String?
    public let pageSize: Int?
    public let maxRecords: Int?          // safety cap, default 10000
    public let cursorField: String?      // body path for cursor (type: body)
    public let offsetField: String?      // body path for offset (type: body)
    public let limitField: String?       // body path for limit (type: body)
    public let queryTemplate: String?    // GraphQL template with {cursor}/{limit} placeholders
    public let paramNames: PaginationParamNames?  // custom URL param names

    public init(type: PaginationType, nextCursorPath: String? = nil, pageSize: Int? = nil, maxRecords: Int? = nil, cursorField: String? = nil, offsetField: String? = nil, limitField: String? = nil, queryTemplate: String? = nil, paramNames: PaginationParamNames? = nil) {
        self.type = type
        self.nextCursorPath = nextCursorPath
        self.pageSize = pageSize
        self.maxRecords = maxRecords
        self.cursorField = cursorField
        self.offsetField = offsetField
        self.limitField = limitField
        self.queryTemplate = queryTemplate
        self.paramNames = paramNames
    }
}

public struct PaginationParamNames: Codable, Sendable {
    public let limit: String?
    public let offset: String?
    public let page: String?
    public let cursor: String?

    public init(limit: String? = nil, offset: String? = nil, page: String? = nil, cursor: String? = nil) {
        self.limit = limit
        self.offset = offset
        self.page = page
        self.cursor = cursor
    }
}

public enum PaginationType: String, Codable, Sendable {
    case cursor
    case offset
    case page
    case body  // pagination params go in JSON request body
}

// MARK: - Push

public struct PushConfig: Codable, Sendable {
    public let create: EndpointConfig?
    public let update: EndpointConfig?
    public let delete: EndpointConfig?
    public let type: String?
    public let steps: [EndpointConfig]?

    public init(create: EndpointConfig? = nil, update: EndpointConfig? = nil, delete: EndpointConfig? = nil, type: String? = nil, steps: [EndpointConfig]? = nil) {
        self.create = create
        self.update = update
        self.delete = delete
        self.type = type
        self.steps = steps
    }
}

public struct EndpointConfig: Codable, Sendable {
    public let method: String?
    public let url: String
    public let type: APIType?
    public let query: String?
    public let mutation: String?
    public let bodyWrapper: String?
    public let bodyType: String?
    public let contentTypeFromExtension: Bool?

    public init(method: String? = nil, url: String, type: APIType? = nil, query: String? = nil, mutation: String? = nil, bodyWrapper: String? = nil, bodyType: String? = nil, contentTypeFromExtension: Bool? = nil) {
        self.method = method
        self.url = url
        self.type = type
        self.query = query
        self.mutation = mutation
        self.bodyWrapper = bodyWrapper
        self.bodyType = bodyType
        self.contentTypeFromExtension = contentTypeFromExtension
    }
}

// MARK: - File Mapping

public struct FileMappingConfig: Codable, Sendable {
    public let strategy: MappingStrategy
    public let directory: String
    public let filename: String?
    public let format: FileFormat
    public let formatOptions: FormatOptions?
    public let idField: String?
    public let contentField: String?
    public let readOnly: Bool?
    public let preserveExtension: Bool?
    public let transforms: TransformConfig?
    public let pushMode: PushMode?
    public let deleteFromAPI: Bool?

    public init(strategy: MappingStrategy, directory: String, filename: String? = nil, format: FileFormat = .json, formatOptions: FormatOptions? = nil, idField: String? = nil, contentField: String? = nil, readOnly: Bool? = nil, preserveExtension: Bool? = nil, transforms: TransformConfig? = nil, pushMode: PushMode? = nil, deleteFromAPI: Bool? = nil) {
        self.strategy = strategy
        self.directory = directory
        self.filename = filename
        self.format = format
        self.formatOptions = formatOptions
        self.idField = idField
        self.contentField = contentField
        self.readOnly = readOnly
        self.preserveExtension = preserveExtension
        self.transforms = transforms
        self.pushMode = pushMode
        self.deleteFromAPI = deleteFromAPI
    }

    /// Resolve the effective push mode based on config and transforms.
    public var effectivePushMode: PushMode {
        // Explicit pushMode takes priority
        if let mode = pushMode { return mode }
        // readOnly flag
        if readOnly == true { return .readOnly }
        // Auto-detect based on transforms and idField
        let hasPullTransforms = !(transforms?.pull?.isEmpty ?? true)
        if hasPullTransforms {
            return idField != nil ? .autoReverse : .readOnly
        }
        // No pull transforms — push works as-is
        return .passthrough
    }
}

/// Push mode for a resource — determines how file edits are transformed before pushing to API.
public enum PushMode: String, Codable, Sendable {
    /// System auto-computes inverse of pull transforms
    case autoReverse = "auto-reverse"
    /// No push allowed
    case readOnly = "read-only"
    /// Use explicit push transforms defined in config
    case custom
    /// No transforms needed — push file data as-is
    case passthrough
}

public enum MappingStrategy: String, Codable, Sendable {
    case onePerRecord = "one-per-record"
    case collection
    case mirror
}

public enum FileFormat: String, Codable, Sendable {
    case json
    case csv
    case html
    case markdown = "md"
    case yaml
    case text = "txt"
    case raw
    // Phase 2
    case ics
    case vcf
    case eml
    case svg
    case webloc
    case xlsx
    case docx
    case pptx
}

public struct FormatOptions: Codable, Sendable {
    public let sheetMapping: String?
    public let columnTypes: [String: String]?
    public let fieldMapping: [String: String]?

    public init(sheetMapping: String? = nil, columnTypes: [String: String]? = nil, fieldMapping: [String: String]? = nil) {
        self.sheetMapping = sheetMapping
        self.columnTypes = columnTypes
        self.fieldMapping = fieldMapping
    }
}

// MARK: - Transforms

public struct TransformConfig: Codable, Sendable {
    public let pull: [TransformOp]?
    public let push: [TransformOp]?

    public init(pull: [TransformOp]? = nil, push: [TransformOp]? = nil) {
        self.pull = pull
        self.push = push
    }
}

public struct TransformOp: Codable, Sendable {
    public let op: String
    public let fields: [String]?
    public let from: String?
    public let to: String?
    public let path: String?
    public let select: String?
    public let key: String?
    public let value: String?
    public let wrap: [String: String]?
    public let field: String?
    public let template: String?

    public init(op: String, fields: [String]? = nil, from: String? = nil, to: String? = nil, path: String? = nil, select: String? = nil, key: String? = nil, value: String? = nil, wrap: [String: String]? = nil, field: String? = nil, template: String? = nil) {
        self.op = op
        self.fields = fields
        self.from = from
        self.to = to
        self.path = path
        self.select = select
        self.key = key
        self.value = value
        self.wrap = wrap
        self.field = field
        self.template = template
    }
}

// MARK: - Sync

public struct SyncConfig: Codable, Sendable {
    public let interval: Int?
    public let debounceMs: Int?
    public let fullSyncEvery: Int?  // do full re-sync every N intervals (default 10)

    public init(interval: Int? = nil, debounceMs: Int? = nil, fullSyncEvery: Int? = nil) {
        self.interval = interval
        self.debounceMs = debounceMs
        self.fullSyncEvery = fullSyncEvery
    }

    public var intervalSeconds: TimeInterval {
        TimeInterval(interval ?? 60)
    }

    public var debounceSeconds: TimeInterval {
        TimeInterval(debounceMs ?? 500) / 1000.0
    }
}

// MARK: - JSON Value (for arbitrary JSON in configs)

public enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
