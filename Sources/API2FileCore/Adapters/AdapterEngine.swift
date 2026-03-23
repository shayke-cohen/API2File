import Foundation

/// Errors specific to the adapter engine.
public enum AdapterError: Error, LocalizedError {
    case noPullConfig(String)
    case noPushConfig(String)
    case configNotFound(URL)
    case invalidResponseData
    case pushNotAllowed(String)

    public var errorDescription: String? {
        switch self {
        case .noPullConfig(let name):
            return "Resource '\(name)' has no pull configuration."
        case .noPushConfig(let name):
            return "Resource '\(name)' has no push configuration."
        case .configNotFound(let url):
            return "Adapter config not found at \(url.path)."
        case .invalidResponseData:
            return "Invalid or missing data in API response."
        case .pushNotAllowed(let path):
            return "File '\(path)' is read-only and cannot be pushed."
        }
    }
}

/// Orchestrates API-to-file sync for a single service.
///
/// Each AdapterEngine instance is bound to one `AdapterConfig` (e.g., Monday, Notion)
/// and a corresponding service directory on disk (e.g., `~/API2File/monday/`).
public actor AdapterEngine {
    public let config: AdapterConfig
    public let serviceDir: URL
    public let httpClient: HTTPClient

    public init(config: AdapterConfig, serviceDir: URL, httpClient: HTTPClient) {
        self.config = config
        self.serviceDir = serviceDir
        self.httpClient = httpClient
    }

    // MARK: - Pull All

    /// Pull all resources defined in the adapter config and write them to files.
    /// - Returns: All synced files across all resources.
    public func pullAll() async throws -> [SyncableFile] {
        var allFiles: [SyncableFile] = []
        for resource in config.resources {
            do {
                let files = try await pull(resource: resource)
                allFiles.append(contentsOf: files)
            } catch {
                print("[AdapterEngine] Failed to pull resource '\(resource.name)': \(error)")
                // Continue with other resources instead of aborting
            }
        }
        return allFiles
    }

    // MARK: - Pull Single Resource

    /// Pull a single resource from the API and return SyncableFile objects.
    /// - Parameter resource: The resource configuration
    /// - Returns: Array of SyncableFile representing the pulled data
    public func pull(resource: ResourceConfig) async throws -> [SyncableFile] {
        guard let pullConfig = resource.pull else {
            throw AdapterError.noPullConfig(resource.name)
        }

        // Fetch all records (handles pagination)
        let records = try await fetchAllRecords(pullConfig: pullConfig)

        // Apply pull transforms
        let transforms = resource.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Convert to files based on mapping strategy
        let files = try mapToFiles(records: transformed, resource: resource)

        // Pull children recursively
        var allFiles = files
        if let children = resource.children {
            for child in children {
                for parentRecord in transformed {
                    let childFiles = try await pullChild(child, parentRecord: parentRecord)
                    allFiles.append(contentsOf: childFiles)
                }
            }
        }

        return allFiles
    }

    // MARK: - Push

    /// Push a local file change back to the API.
    /// - Parameters:
    ///   - file: The local file that changed
    ///   - resource: The resource configuration for this file
    public func push(file: SyncableFile, resource: ResourceConfig) async throws {
        guard !(file.readOnly) else {
            throw AdapterError.pushNotAllowed(file.relativePath)
        }
        guard let pushConfig = resource.push else {
            throw AdapterError.noPushConfig(resource.name)
        }

        // Decode the file back to records
        let records = try FormatConverterFactory.decode(
            data: file.content,
            format: file.format,
            options: resource.fileMapping.formatOptions
        )

        // Apply push transforms
        let transforms = resource.fileMapping.transforms?.push ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Push each record
        for record in transformed {
            let hasRemoteId = file.remoteId != nil
            try await pushRecord(record, pushConfig: pushConfig, remoteId: file.remoteId, isUpdate: hasRemoteId)
        }
    }

    // MARK: - Config Loading

    /// Load an AdapterConfig from `.api2file/adapter.json` inside a service directory.
    /// - Parameter serviceDir: The service directory (e.g. `~/API2File/monday/`)
    /// - Returns: The decoded AdapterConfig
    public static func loadConfig(from serviceDir: URL) throws -> AdapterConfig {
        let configURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw AdapterError.configNotFound(configURL)
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(AdapterConfig.self, from: data)
    }

    // MARK: - Private — Fetching

    /// Fetch all records from an API endpoint, handling pagination.
    private func fetchAllRecords(pullConfig: PullConfig) async throws -> [[String: Any]] {
        var allRecords: [[String: Any]] = []
        var cursor: String? = nil
        var offset: Int = 0
        var page: Int = 1
        let pageSize = pullConfig.pagination?.pageSize ?? 100

        repeat {
            // Build the request URL with template variables and pagination params
            var url = resolveURL(pullConfig.url)

            // Inject pagination into URL query parameters
            if let pagination = pullConfig.pagination {
                url = appendPaginationParams(to: url, pagination: pagination, cursor: cursor, offset: offset, page: page, pageSize: pageSize)
            }

            let method = HTTPMethod(rawValue: pullConfig.method?.uppercased() ?? "GET") ?? .GET
            var headers = config.globals?.headers ?? [:]
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"

            var body: Data? = nil
            if let bodyValue = pullConfig.body {
                body = try JSONSerialization.data(withJSONObject: jsonValueToAny(bodyValue))
            }

            let request = APIRequest(
                method: method,
                url: url,
                headers: headers,
                body: body
            )

            let response = try await httpClient.request(request)

            // Parse response JSON — handle both objects and arrays
            let rawJSON = try JSONSerialization.jsonObject(with: response.body)
            let json: [String: Any]
            if let dict = rawJSON as? [String: Any] {
                json = dict
            } else if let array = rawJSON as? [[String: Any]] {
                // Wrap array in a dict so JSONPath can extract it with "$"
                json = ["$root": array]
            } else {
                throw AdapterError.invalidResponseData
            }

            // Extract records using dataPath
            let extracted: Any?
            if let dataPath = pullConfig.dataPath {
                // If we wrapped an array, "$" should return the array
                if json["$root"] != nil && dataPath == "$" {
                    extracted = json["$root"]
                } else {
                    extracted = JSONPath.extract(dataPath, from: json)
                }
            } else {
                extracted = json
            }

            // Normalize to array of dictionaries
            let records = normalizeRecords(extracted)
            allRecords.append(contentsOf: records)

            // Check for next page
            guard let pagination = pullConfig.pagination else { break }

            let nextCursor: String?
            if let cursorPath = pagination.nextCursorPath {
                nextCursor = JSONPath.extract(cursorPath, from: json) as? String
            } else {
                nextCursor = nil
            }

            switch pagination.type {
            case .cursor:
                if let next = nextCursor, !next.isEmpty {
                    cursor = next
                } else {
                    cursor = nil
                    return allRecords
                }
            case .offset:
                if records.count < pageSize {
                    return allRecords
                }
                offset += records.count
            case .page:
                if records.count < pageSize {
                    return allRecords
                }
                page += 1
            }
        } while true

        return allRecords
    }

    // MARK: - Private — Pushing

    /// Push a single record to the API via create or update endpoint.
    private func pushRecord(
        _ record: [String: Any],
        pushConfig: PushConfig,
        remoteId: String?,
        isUpdate: Bool
    ) async throws {
        let endpoint: EndpointConfig?
        if isUpdate {
            endpoint = pushConfig.update
        } else {
            endpoint = pushConfig.create
        }

        guard let endpoint = endpoint else {
            throw AdapterError.noPushConfig("missing \(isUpdate ? "update" : "create") endpoint")
        }

        // Resolve URL templates
        var templateVars: [String: Any] = record
        if let baseUrl = config.globals?.baseUrl {
            templateVars["baseUrl"] = baseUrl
        }
        if let id = remoteId {
            templateVars["id"] = id
        }
        let url = TemplateEngine.render(endpoint.url, with: templateVars)

        let method = HTTPMethod(rawValue: endpoint.method?.uppercased() ?? "POST") ?? .POST
        var headers = config.globals?.headers ?? [:]
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"

        // Build request body
        var bodyDict: Any = record
        if let wrapper = endpoint.bodyWrapper {
            bodyDict = [wrapper: record]
        }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)

        let request = APIRequest(
            method: method,
            url: url,
            headers: headers,
            body: body
        )

        _ = try await httpClient.request(request)
    }

    // MARK: - Private — File Mapping

    /// Convert API records to SyncableFile objects based on the mapping strategy.
    private func mapToFiles(records: [[String: Any]], resource: ResourceConfig) throws -> [SyncableFile] {
        let mapping = resource.fileMapping
        let format = mapping.format
        let options = mapping.formatOptions
        let readOnly = mapping.readOnly ?? false
        let idField = mapping.idField ?? "id"

        switch mapping.strategy {
        case .onePerRecord:
            // One file per record
            return try records.map { record in
                let relativePath = FileMapper.filePath(for: record, config: mapping)
                let data: Data

                // If contentField is set, write just that field's content directly
                if let contentField = mapping.contentField,
                   let content = record[contentField] {
                    if let stringContent = content as? String {
                        data = Data(stringContent.utf8)
                    } else {
                        data = try JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted])
                    }
                } else {
                    data = try FormatConverterFactory.encode(records: [record], format: format, options: options)
                }

                let remoteId = stringifyValue(record[idField])

                return SyncableFile(
                    relativePath: relativePath,
                    format: format,
                    content: data,
                    remoteId: remoteId,
                    readOnly: readOnly
                )
            }

        case .collection:
            // All records in a single file
            let filename = mapping.filename ?? "\(resource.name).\(format.rawValue)"
            let directory = mapping.directory
            let relativePath = directory.isEmpty || directory == "." ? filename : "\(directory)/\(filename)"
            let data = try FormatConverterFactory.encode(records: records, format: format, options: options)

            return [SyncableFile(
                relativePath: relativePath,
                format: format,
                content: data,
                remoteId: nil,
                readOnly: readOnly
            )]

        case .mirror:
            // Mirror the remote structure — same as one-per-record but preserves remote paths
            return try records.map { record in
                let relativePath = FileMapper.filePath(for: record, config: mapping)
                let data: Data

                if let contentField = mapping.contentField,
                   let content = record[contentField] {
                    if let stringContent = content as? String {
                        data = Data(stringContent.utf8)
                    } else {
                        data = try JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted])
                    }
                } else {
                    data = try FormatConverterFactory.encode(records: [record], format: format, options: options)
                }

                let remoteId = stringifyValue(record[idField])

                return SyncableFile(
                    relativePath: relativePath,
                    format: format,
                    content: data,
                    remoteId: remoteId,
                    readOnly: readOnly
                )
            }
        }
    }

    // MARK: - Private — Children

    /// Pull a child resource using a parent record's data for template resolution.
    private func pullChild(_ child: ResourceConfig, parentRecord: [String: Any]) async throws -> [SyncableFile] {
        guard var pullConfig = child.pull else {
            throw AdapterError.noPullConfig(child.name)
        }

        // Resolve parent template variables in the child's URL
        var templateVars = parentRecord
        if let baseUrl = config.globals?.baseUrl {
            templateVars["baseUrl"] = baseUrl
        }
        let idField = child.fileMapping.idField ?? "id"
        if let parentId = stringifyValue(parentRecord[idField]) {
            templateVars["parentId"] = parentId
        }
        let resolvedURL = TemplateEngine.render(pullConfig.url, with: templateVars)

        // Create a modified pull config with the resolved URL
        pullConfig = PullConfig(
            method: pullConfig.method,
            url: resolvedURL,
            type: pullConfig.type,
            query: pullConfig.query,
            body: pullConfig.body,
            dataPath: pullConfig.dataPath,
            pagination: pullConfig.pagination
        )

        let records = try await fetchAllRecords(pullConfig: pullConfig)

        let transforms = child.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        return try mapToFiles(records: transformed, resource: child)
    }

    // MARK: - Private — URL Resolution

    /// Resolve template variables in a URL string (`{baseUrl}`, etc.)
    private func resolveURL(_ urlTemplate: String) -> String {
        var vars: [String: Any] = [:]
        if let baseUrl = config.globals?.baseUrl {
            vars["baseUrl"] = baseUrl
        }
        return TemplateEngine.render(urlTemplate, with: vars)
    }

    /// Append pagination query parameters to a URL string.
    private func appendPaginationParams(
        to url: String,
        pagination: PaginationConfig,
        cursor: String?,
        offset: Int,
        page: Int,
        pageSize: Int
    ) -> String {
        var components = URLComponents(string: url) ?? URLComponents()
        var queryItems = components.queryItems ?? []

        switch pagination.type {
        case .cursor:
            queryItems.append(URLQueryItem(name: "limit", value: "\(pageSize)"))
            if let cursor = cursor {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
        case .offset:
            queryItems.append(URLQueryItem(name: "limit", value: "\(pageSize)"))
            queryItems.append(URLQueryItem(name: "offset", value: "\(offset)"))
        case .page:
            queryItems.append(URLQueryItem(name: "per_page", value: "\(pageSize)"))
            queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        }

        components.queryItems = queryItems
        return components.string ?? url
    }

    // MARK: - Private — Helpers

    /// Normalize extracted data into an array of dictionaries.
    private func normalizeRecords(_ data: Any?) -> [[String: Any]] {
        guard let data = data else { return [] }

        if let array = data as? [[String: Any]] {
            return array
        }
        if let dict = data as? [String: Any] {
            return [dict]
        }
        // If it's an array of non-dict values, wrap each in a dict
        if let array = data as? [Any] {
            return array.compactMap { item in
                if let dict = item as? [String: Any] { return dict }
                return nil
            }
        }
        return []
    }

    /// Convert a JSONValue enum to a Foundation Any for JSONSerialization.
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        case .object(let obj):
            var dict: [String: Any] = [:]
            for (k, v) in obj {
                dict[k] = jsonValueToAny(v)
            }
            return dict
        }
    }

    /// Safely convert any value to a String.
    private func stringifyValue(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case let s as String: return s
        case let n as Int: return "\(n)"
        case let n as Double:
            if n == n.rounded() && n < 1e15 { return "\(Int(n))" }
            return "\(n)"
        default: return "\(value)"
        }
    }
}
