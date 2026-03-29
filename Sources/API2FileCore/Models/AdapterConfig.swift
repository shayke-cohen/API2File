import Foundation

/// Root adapter configuration — parsed from .api2file/adapter.json
public struct AdapterConfig: Codable, Sendable {
    public let service: String
    public let displayName: String
    public let version: String
    public let auth: AuthConfig
    public let globals: GlobalsConfig?
    public let resources: [ResourceConfig]
    /// SF Symbol name shown in the Add Service wizard (e.g. "globe")
    public let icon: String?
    /// One-line description shown in the Add Service wizard picker
    public let wizardDescription: String?
    /// Extra input fields the wizard collects before writing the adapter config
    public let setupFields: [SetupField]?
    /// If true, this adapter is hidden from the Add Service wizard
    public let hidden: Bool?
    /// If false, syncing is disabled for this service (default: true when nil)
    public var enabled: Bool?
    /// URL for the service's public web UI (e.g., the Wix site, GitHub repo page)
    public var siteUrl: String?
    /// URL for the service's management dashboard (e.g., Wix Business Manager, Monday board)
    public var dashboardUrl: String?

    public init(service: String, displayName: String, version: String, auth: AuthConfig, globals: GlobalsConfig? = nil, resources: [ResourceConfig], icon: String? = nil, wizardDescription: String? = nil, setupFields: [SetupField]? = nil, hidden: Bool? = nil, enabled: Bool? = nil, siteUrl: String? = nil, dashboardUrl: String? = nil) {
        self.service = service
        self.displayName = displayName
        self.version = version
        self.auth = auth
        self.globals = globals
        self.resources = resources
        self.icon = icon
        self.wizardDescription = wizardDescription
        self.setupFields = setupFields
        self.hidden = hidden
        self.enabled = enabled
        self.siteUrl = siteUrl
        self.dashboardUrl = dashboardUrl
    }
}

// MARK: - Wizard Setup Fields

/// An extra input field shown in the Add Service wizard.
/// The collected value replaces `templateKey` in the raw adapter JSON before writing to disk.
public struct SetupField: Codable, Sendable {
    /// Unique key used to store the collected value (e.g. "wix-site-id")
    public let key: String
    /// Human-readable label shown in the wizard (e.g. "Site ID")
    public let label: String
    /// Placeholder text in the text field (e.g. "abc123-def456-...")
    public let placeholder: String?
    /// The literal string in the adapter JSON that gets replaced with the collected value
    public let templateKey: String
    /// Optional help text shown below the field
    public let helpText: String?
    /// If true, rendered as a SecureField
    public let isSecure: Bool?

    public init(key: String, label: String, placeholder: String? = nil, templateKey: String, helpText: String? = nil, isSecure: Bool? = nil) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.templateKey = templateKey
        self.helpText = helpText
        self.isSecure = isSecure
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
    public let capabilityClass: ResourceCapabilityClass?
    public let pull: PullConfig?
    public let push: PushConfig?
    public let fileMapping: FileMappingConfig
    public let children: [ResourceConfig]?
    public let sync: SyncConfig?
    /// Public-facing URL for this resource (e.g., blog page, product catalog)
    public var siteUrl: String?
    /// Management dashboard URL for this resource (e.g., Wix CRM, Monday board)
    public var dashboardUrl: String?
    /// If false, syncing is disabled for this resource (default: true when nil)
    public var enabled: Bool?

    public init(name: String, description: String? = nil, capabilityClass: ResourceCapabilityClass? = nil, pull: PullConfig? = nil, push: PushConfig? = nil, fileMapping: FileMappingConfig, children: [ResourceConfig]? = nil, sync: SyncConfig? = nil, siteUrl: String? = nil, dashboardUrl: String? = nil, enabled: Bool? = nil) {
        self.name = name
        self.description = description
        self.capabilityClass = capabilityClass
        self.pull = pull
        self.push = push
        self.fileMapping = fileMapping
        self.children = children
        self.sync = sync
        self.siteUrl = siteUrl
        self.dashboardUrl = dashboardUrl
        self.enabled = enabled
    }

    /// Create a copy with a resolved directory path (for child resources with template directories).
    public func withDirectory(_ directory: String) -> ResourceConfig {
        let newMapping = FileMappingConfig(
            strategy: fileMapping.strategy,
            directory: directory,
            filename: fileMapping.filename,
            format: fileMapping.format,
            formatOptions: fileMapping.formatOptions,
            idField: fileMapping.idField,
            contentField: fileMapping.contentField,
            readOnly: fileMapping.readOnly,
            preserveExtension: fileMapping.preserveExtension,
            transforms: fileMapping.transforms,
            pushMode: fileMapping.pushMode,
            deleteFromAPI: fileMapping.deleteFromAPI
        )
        return ResourceConfig(name: name, description: description, capabilityClass: capabilityClass, pull: pull, push: push, fileMapping: newMapping, children: children, sync: sync, siteUrl: siteUrl, dashboardUrl: dashboardUrl, enabled: enabled)
    }

    public func withResolvedFileMapping(directory: String, filename: String?) -> ResourceConfig {
        let newMapping = FileMappingConfig(
            strategy: fileMapping.strategy,
            directory: directory,
            filename: filename,
            format: fileMapping.format,
            formatOptions: fileMapping.formatOptions,
            idField: fileMapping.idField,
            contentField: fileMapping.contentField,
            readOnly: fileMapping.readOnly,
            preserveExtension: fileMapping.preserveExtension,
            transforms: fileMapping.transforms,
            pushMode: fileMapping.pushMode,
            deleteFromAPI: fileMapping.deleteFromAPI
        )
        return ResourceConfig(name: name, description: description, capabilityClass: capabilityClass, pull: pull, push: push, fileMapping: newMapping, children: children, sync: sync, siteUrl: siteUrl, dashboardUrl: dashboardUrl, enabled: enabled)
    }
}

public enum ResourceCapabilityClass: String, Codable, Sendable {
    case fullCRUD = "full_crud"
    case partialWritable = "partial_writable"
    case readOnly = "read_only"
}

// MARK: - Pull

public struct PullConfig: Codable, Sendable {
    public let method: String?
    public let url: String
    public let type: APIType?
    public let query: String?
    public let body: JSONValue?
    public let dataPath: String?
    public let detail: PullDetailConfig?
    public let pagination: PaginationConfig?
    public let mediaConfig: MediaConfig?
    public let updatedSinceField: String?      // URL param name (e.g. "since")
    public let updatedSinceBodyPath: String?   // body field path for date filter
    public let updatedSinceDateFormat: String? // "iso8601" (default) or "epoch"
    public let supportsETag: Bool?             // send If-None-Match for 304 optimization

    public init(method: String? = nil, url: String, type: APIType? = nil, query: String? = nil, body: JSONValue? = nil, dataPath: String? = nil, detail: PullDetailConfig? = nil, pagination: PaginationConfig? = nil, mediaConfig: MediaConfig? = nil, updatedSinceField: String? = nil, updatedSinceBodyPath: String? = nil, updatedSinceDateFormat: String? = nil, supportsETag: Bool? = nil) {
        self.method = method
        self.url = url
        self.type = type
        self.query = query
        self.body = body
        self.dataPath = dataPath
        self.detail = detail
        self.pagination = pagination
        self.mediaConfig = mediaConfig
        self.updatedSinceField = updatedSinceField
        self.updatedSinceBodyPath = updatedSinceBodyPath
        self.updatedSinceDateFormat = updatedSinceDateFormat
        self.supportsETag = supportsETag
    }
}

public struct PullDetailConfig: Codable, Sendable {
    public let method: String?
    public let url: String
    public let dataPath: String?

    public init(method: String? = nil, url: String, dataPath: String? = nil) {
        self.method = method
        self.url = url
        self.dataPath = dataPath
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
    /// Fields to hoist from the record to the root body level, outside of `bodyWrapper`.
    /// E.g. `["dataCollectionId"]` produces `{"dataCollectionId":"X","dataItem":{...}}`
    public let bodyRootFields: [String]?
    /// Optional follow-up request made after the main request succeeds.
    /// Used for two-step operations like Wix Blog's PATCH draft → POST publish.
    /// The follow-up URL is rendered with the same template vars as the main request (including `id`).
    public let followup: FollowupConfig?

    public init(method: String? = nil, url: String, type: APIType? = nil, query: String? = nil, mutation: String? = nil, bodyWrapper: String? = nil, bodyType: String? = nil, contentTypeFromExtension: Bool? = nil, bodyRootFields: [String]? = nil, followup: FollowupConfig? = nil) {
        self.method = method
        self.url = url
        self.type = type
        self.query = query
        self.mutation = mutation
        self.bodyWrapper = bodyWrapper
        self.bodyType = bodyType
        self.contentTypeFromExtension = contentTypeFromExtension
        self.bodyRootFields = bodyRootFields
        self.followup = followup
    }
}

/// A lightweight follow-up HTTP request made after the main push request succeeds.
public struct FollowupConfig: Codable, Sendable {
    public let method: String?
    public let url: String

    public init(method: String? = nil, url: String) {
        self.method = method
        self.url = url
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

    public var effectiveFormatOptions: FormatOptions? {
        guard format == .markdown, let contentField else {
            return formatOptions
        }

        var fieldMapping = formatOptions?.fieldMapping ?? [:]
        fieldMapping["content"] = contentField
        return FormatOptions(
            sheetMapping: formatOptions?.sheetMapping,
            columnTypes: formatOptions?.columnTypes,
            fieldMapping: fieldMapping
        )
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
