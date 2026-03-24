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

/// Result of a pull operation, containing both transformed files and raw API records.
public struct PullResult: @unchecked Sendable {
    /// The transformed files to write to disk for users.
    public let files: [SyncableFile]
    /// Raw API records keyed by relative file path (pre-transform).
    /// Used to write object files and support inverse transforms on push.
    public let rawRecordsByFile: [String: [[String: Any]]]

    public init(files: [SyncableFile], rawRecordsByFile: [String: [[String: Any]]] = [:]) {
        self.files = files
        self.rawRecordsByFile = rawRecordsByFile
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
    /// - Returns: PullResult containing all synced files and raw records.
    public func pullAll() async throws -> PullResult {
        var allFiles: [SyncableFile] = []
        var allRawRecords: [String: [[String: Any]]] = [:]
        for resource in config.resources {
            do {
                let result = try await pull(resource: resource)
                allFiles.append(contentsOf: result.files)
                allRawRecords.merge(result.rawRecordsByFile) { _, new in new }
            } catch {
                print("[AdapterEngine] Failed to pull resource '\(resource.name)': \(error)")
                // Continue with other resources instead of aborting
            }
        }
        return PullResult(files: allFiles, rawRecordsByFile: allRawRecords)
    }

    // MARK: - Pull Single Resource

    /// Pull a single resource from the API and return PullResult with files and raw records.
    /// - Parameters:
    ///   - resource: The resource configuration
    ///   - updatedSince: If set, only fetch records updated after this date (incremental sync)
    /// - Returns: PullResult containing files and raw API records
    public func pull(resource: ResourceConfig, updatedSince: Date? = nil) async throws -> PullResult {
        guard var pullConfig = resource.pull else {
            throw AdapterError.noPullConfig(resource.name)
        }

        // Inject updatedSince into the pull config if supported
        if let since = updatedSince {
            pullConfig = injectUpdatedSince(since, into: pullConfig)
        }

        // Fetch all records (handles pagination)
        let records = try await fetchAllRecords(pullConfig: pullConfig)

        // Media mode: download binary files from URLs instead of converting to formats
        if pullConfig.type == .media, let mediaConfig = pullConfig.mediaConfig {
            let mediaFiles = try await pullMediaFiles(records: records, resource: resource, mediaConfig: mediaConfig)
            return PullResult(files: mediaFiles)
        }

        // Apply pull transforms
        let transforms = resource.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Convert to files based on mapping strategy
        let files = try mapToFiles(records: transformed, resource: resource)

        // Build raw records mapping keyed by file path
        var rawRecordsByFile: [String: [[String: Any]]] = [:]
        if resource.fileMapping.strategy == .collection {
            // Collection: all raw records map to the single file
            if let firstFile = files.first {
                rawRecordsByFile[firstFile.relativePath] = records
            }
        } else {
            // One-per-record: each raw record maps to its corresponding file
            for (index, file) in files.enumerated() where index < records.count {
                rawRecordsByFile[file.relativePath] = [records[index]]
            }
        }

        // Pull children recursively
        var allFiles = files
        if let children = resource.children {
            for child in children {
                for parentRecord in transformed {
                    let childResult = try await pullChild(child, parentRecord: parentRecord)
                    allFiles.append(contentsOf: childResult.files)
                    rawRecordsByFile.merge(childResult.rawRecordsByFile) { _, new in new }
                }
            }
        }

        return PullResult(files: allFiles, rawRecordsByFile: rawRecordsByFile)
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

    // MARK: - Push Actions

    /// Action type for pushing a record
    public enum PushAction: Sendable {
        case create
        case update(id: String)
    }

    /// Push a single record with a specific action (create or update)
    public func pushRecord(_ record: [String: Any], resource: ResourceConfig, action: PushAction) async throws {
        guard let pushConfig = resource.push else {
            throw AdapterError.noPushConfig(resource.name)
        }

        // Apply push transforms
        let transforms = resource.fileMapping.transforms?.push ?? []
        let transformed = transforms.isEmpty ? [record] : TransformPipeline.apply(transforms, to: [record])
        guard let rec = transformed.first else { return }

        switch action {
        case .create:
            try await pushRecord(rec, pushConfig: pushConfig, remoteId: nil, isUpdate: false)
        case .update(let id):
            try await pushRecord(rec, pushConfig: pushConfig, remoteId: id, isUpdate: true)
        }
    }

    /// Delete a record from the API by its remote ID
    public func delete(remoteId: String, resource: ResourceConfig) async throws {
        guard let pushConfig = resource.push, let deleteConfig = pushConfig.delete else {
            print("[AdapterEngine] No delete config for \(resource.name)")
            return
        }

        let url = resolveURL(deleteConfig.url)
            .replacingOccurrences(of: "{id}", with: remoteId)

        let method = HTTPMethod(rawValue: deleteConfig.method?.uppercased() ?? "DELETE") ?? .DELETE
        var headers = config.globals?.headers ?? [:]

        // Handle bodyType for special delete semantics (e.g., GitHub close = PATCH with state:closed)
        var body: Data? = nil
        if let bodyType = deleteConfig.bodyType {
            headers["Content-Type"] = "application/json"
            switch bodyType {
            case "close":
                body = try JSONSerialization.data(withJSONObject: ["state": "closed"])
            default:
                break
            }
        }

        let request = APIRequest(
            method: method,
            url: url,
            headers: headers,
            body: body
        )

        _ = try await httpClient.request(request)
        print("[AdapterEngine] Deleted record \(remoteId) from \(resource.name)")
    }

    // MARK: - Config Loading

    // MARK: - Media File Sync

    /// Download binary files from URLs in the API response.
    /// Used when pull type is `.media` — downloads actual files (images, PDFs, etc.)
    private func pullMediaFiles(
        records: [[String: Any]],
        resource: ResourceConfig,
        mediaConfig: MediaConfig
    ) async throws -> [SyncableFile] {
        var files: [SyncableFile] = []
        let dir = resource.fileMapping.directory

        for record in records {
            guard let urlString = record[mediaConfig.urlField] as? String,
                  let filename = record[mediaConfig.filenameField] as? String,
                  let downloadURL = URL(string: urlString) else { continue }

            let remoteId = record[mediaConfig.idField ?? "id"] as? String

            // Download binary content directly (CDN URLs typically don't need auth)
            let (data, response) = try await URLSession.shared.data(from: downloadURL)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[AdapterEngine] Failed to download media: \(filename) from \(urlString)")
                continue
            }

            let relativePath = dir == "." ? filename : "\(dir)/\(filename)"
            let file = SyncableFile(
                relativePath: relativePath,
                format: .raw,
                content: data,
                remoteId: remoteId
            )
            files.append(file)

            let sizeKB = data.count / 1024
            print("[AdapterEngine] Downloaded: \(filename) (\(sizeKB)KB)")
        }

        return files
    }

    /// Upload a local binary file to the cloud via a two-step upload process:
    /// 1. Generate a signed upload URL from the API
    /// 2. PUT the binary data to that URL
    public func pushMediaFile(
        fileData: Data,
        filename: String,
        mimeType: String,
        resource: ResourceConfig
    ) async throws {
        guard let pushConfig = resource.push else {
            throw AdapterError.noPushConfig(resource.name)
        }

        // Step 1: Generate upload URL
        guard let genConfig = pushConfig.create else {
            throw AdapterError.noPushConfig(resource.name)
        }

        let genURL = resolveURL(genConfig.url)
        var headers = config.globals?.headers ?? [:]
        headers["Content-Type"] = "application/json"

        let body = try JSONSerialization.data(withJSONObject: [
            "mimeType": mimeType,
            "fileName": filename
        ])

        let genRequest = APIRequest(method: .POST, url: genURL, headers: headers, body: body)
        let genResponse = try await httpClient.request(genRequest)

        guard let json = try JSONSerialization.jsonObject(with: genResponse.body) as? [String: Any],
              let uploadUrl = json["uploadUrl"] as? String else {
            throw AdapterError.invalidResponseData
        }

        // Step 2: PUT binary data to the upload URL
        var uploadRequest = URLRequest(url: URL(string: uploadUrl)!)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.httpBody = fileData
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (_, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)

        if let httpResponse = uploadResponse as? HTTPURLResponse, httpResponse.statusCode < 300 {
            print("[AdapterEngine] Uploaded: \(filename) (\(fileData.count / 1024)KB)")
        } else {
            print("[AdapterEngine] Upload may have failed for: \(filename)")
        }
    }

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
        let maxRecords = pullConfig.pagination?.maxRecords ?? 10000

        repeat {
            // Build the request URL with template variables and pagination params
            var url = resolveURL(pullConfig.url)
            let method = HTTPMethod(rawValue: pullConfig.method?.uppercased() ?? "GET") ?? .GET
            var headers = config.globals?.headers ?? [:]
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            var body: Data? = nil

            if let pagination = pullConfig.pagination {
                switch pagination.type {
                case .body:
                    // Inject pagination into request body
                    body = injectBodyPagination(
                        bodyValue: pullConfig.body,
                        pagination: pagination,
                        cursor: cursor,
                        offset: offset,
                        pageSize: pageSize
                    )
                case .cursor where pagination.queryTemplate != nil:
                    // GraphQL: render query from template
                    var template = pagination.queryTemplate!
                    template = template.replacingOccurrences(of: "{limit}", with: "\(pageSize)")
                    if let c = cursor {
                        template = template.replacingOccurrences(of: "{cursor}", with: c)
                    } else {
                        // First page: remove cursor argument
                        template = template.replacingOccurrences(of: ", after: \"{cursor}\"", with: "")
                    }
                    let queryBody: [String: Any] = ["query": template]
                    body = try JSONSerialization.data(withJSONObject: queryBody)
                default:
                    // URL query param pagination (existing behavior)
                    url = appendPaginationParams(to: url, pagination: pagination, cursor: cursor, offset: offset, page: page, pageSize: pageSize)
                    if let bodyValue = pullConfig.body {
                        body = try JSONSerialization.data(withJSONObject: jsonValueToAny(bodyValue))
                    }
                }
            } else {
                if let bodyValue = pullConfig.body {
                    body = try JSONSerialization.data(withJSONObject: jsonValueToAny(bodyValue))
                }
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

            // Max records safety cap
            if allRecords.count >= maxRecords {
                print("[AdapterEngine] Max records limit (\(maxRecords)) reached, stopping pagination")
                break
            }

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
            case .body:
                // Body pagination: use cursor if cursorField is set, otherwise use offset
                if pagination.cursorField != nil {
                    if let next = nextCursor, !next.isEmpty {
                        cursor = next
                    } else {
                        return allRecords
                    }
                } else if pagination.offsetField != nil {
                    if records.count < pageSize {
                        return allRecords
                    }
                    offset += records.count
                } else {
                    return allRecords
                }
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
            // No endpoint for this action — skip silently (e.g., no create endpoint for a read-mostly resource)
            return
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
    private func pullChild(_ child: ResourceConfig, parentRecord: [String: Any]) async throws -> PullResult {
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

        // Resolve body template variables from parent record
        let resolvedBody: JSONValue?
        if let body = pullConfig.body {
            let bodyAny = jsonValueToAny(body)
            let resolvedAny = resolveTemplatesInJSON(bodyAny, with: templateVars)
            resolvedBody = anyToJSONValue(resolvedAny)
        } else {
            resolvedBody = pullConfig.body
        }

        // Create a modified pull config with resolved URL and body
        pullConfig = PullConfig(
            method: pullConfig.method,
            url: resolvedURL,
            type: pullConfig.type,
            query: pullConfig.query,
            body: resolvedBody,
            dataPath: pullConfig.dataPath,
            pagination: pullConfig.pagination,
            mediaConfig: pullConfig.mediaConfig,
            updatedSinceField: pullConfig.updatedSinceField,
            updatedSinceBodyPath: pullConfig.updatedSinceBodyPath,
            updatedSinceDateFormat: pullConfig.updatedSinceDateFormat
        )

        let records = try await fetchAllRecords(pullConfig: pullConfig)

        let transforms = child.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Resolve directory template from parent record for child files
        let resolvedDirectory = TemplateEngine.render(child.fileMapping.directory, with: templateVars)
        let resolvedChild = child.withDirectory(resolvedDirectory)
        let files = try mapToFiles(records: transformed, resource: resolvedChild)

        // Build raw records mapping
        var rawRecordsByFile: [String: [[String: Any]]] = [:]
        if child.fileMapping.strategy == .collection {
            if let firstFile = files.first {
                rawRecordsByFile[firstFile.relativePath] = records
            }
        } else {
            for (index, file) in files.enumerated() where index < records.count {
                rawRecordsByFile[file.relativePath] = [records[index]]
            }
        }

        return PullResult(files: files, rawRecordsByFile: rawRecordsByFile)
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
            let limitName = pagination.paramNames?.limit ?? "limit"
            let cursorName = pagination.paramNames?.cursor ?? "cursor"
            queryItems.append(URLQueryItem(name: limitName, value: "\(pageSize)"))
            if let cursor = cursor {
                queryItems.append(URLQueryItem(name: cursorName, value: cursor))
            }
        case .offset:
            let limitName = pagination.paramNames?.limit ?? "limit"
            let offsetName = pagination.paramNames?.offset ?? "offset"
            queryItems.append(URLQueryItem(name: limitName, value: "\(pageSize)"))
            queryItems.append(URLQueryItem(name: offsetName, value: "\(offset)"))
        case .page:
            let limitName = pagination.paramNames?.limit ?? "per_page"
            let pageName = pagination.paramNames?.page ?? "page"
            queryItems.append(URLQueryItem(name: limitName, value: "\(pageSize)"))
            queryItems.append(URLQueryItem(name: pageName, value: "\(page)"))
        case .body:
            break  // handled in body injection, not URL
        }

        components.queryItems = queryItems
        return components.string ?? url
    }

    // MARK: - Private — Body Pagination

    /// Inject pagination parameters into the request body using dot-path resolution.
    private func injectBodyPagination(
        bodyValue: JSONValue?,
        pagination: PaginationConfig,
        cursor: String?,
        offset: Int,
        pageSize: Int
    ) -> Data? {
        // Convert JSONValue to mutable dict
        var bodyDict: [String: Any] = [:]
        if let bodyValue {
            bodyDict = jsonValueToAny(bodyValue) as? [String: Any] ?? [:]
        }

        // Inject limit
        if let limitPath = pagination.limitField {
            setNestedValue(pageSize, atPath: limitPath, in: &bodyDict)
        }

        // Inject cursor or offset
        if let cursorPath = pagination.cursorField, let cursor {
            setNestedValue(cursor, atPath: cursorPath, in: &bodyDict)
        } else if let offsetPath = pagination.offsetField {
            setNestedValue(offset, atPath: offsetPath, in: &bodyDict)
        }

        return try? JSONSerialization.data(withJSONObject: bodyDict)
    }

    /// Set a value at a dot-separated path in a nested dictionary.
    private func setNestedValue(_ value: Any, atPath path: String, in dict: inout [String: Any]) {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return }
        if components.count == 1 {
            dict[components[0]] = value
            return
        }
        let topKey = components[0]
        var nested = dict[topKey] as? [String: Any] ?? [:]
        let remaining = components.dropFirst().joined(separator: ".")
        setNestedValue(value, atPath: remaining, in: &nested)
        dict[topKey] = nested
    }

    // MARK: - Private — Incremental Sync

    /// Inject an updatedSince date into a PullConfig by modifying the URL or body.
    /// Returns a new PullConfig with the date filter applied.
    private func injectUpdatedSince(_ date: Date, into pullConfig: PullConfig) -> PullConfig {
        let dateString = formatUpdatedSinceDate(date, format: pullConfig.updatedSinceDateFormat)

        var newURL = pullConfig.url
        var newBody = pullConfig.body

        // URL param injection (e.g., ?since=2024-01-01T00:00:00Z)
        if let field = pullConfig.updatedSinceField {
            if var components = URLComponents(string: newURL) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: field, value: dateString))
                components.queryItems = items
                newURL = components.string ?? newURL
            } else {
                // Fallback: simple string append
                let separator = newURL.contains("?") ? "&" : "?"
                newURL = "\(newURL)\(separator)\(field)=\(dateString)"
            }
        }

        // Body path injection (e.g., set "filter.updatedAfter" in request body)
        if let bodyPath = pullConfig.updatedSinceBodyPath {
            newBody = injectDateIntoBody(dateString, atPath: bodyPath, body: newBody)
        }

        return PullConfig(
            method: pullConfig.method,
            url: newURL,
            type: pullConfig.type,
            query: pullConfig.query,
            body: newBody,
            dataPath: pullConfig.dataPath,
            pagination: pullConfig.pagination,
            mediaConfig: pullConfig.mediaConfig,
            updatedSinceField: pullConfig.updatedSinceField,
            updatedSinceBodyPath: pullConfig.updatedSinceBodyPath,
            updatedSinceDateFormat: pullConfig.updatedSinceDateFormat
        )
    }

    /// Format a date for the updatedSince parameter based on the configured format.
    private func formatUpdatedSinceDate(_ date: Date, format: String?) -> String {
        switch format {
        case "epoch":
            return "\(Int(date.timeIntervalSince1970))"
        case "epoch_ms":
            return "\(Int(date.timeIntervalSince1970 * 1000))"
        default:
            // ISO 8601 (default)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }

    /// Inject a date string at a dot-path location in a JSONValue body.
    private func injectDateIntoBody(_ dateString: String, atPath path: String, body: JSONValue?) -> JSONValue {
        var bodyDict: [String: Any] = [:]
        if let body {
            bodyDict = jsonValueToAny(body) as? [String: Any] ?? [:]
        }
        setNestedValue(dateString, atPath: path, in: &bodyDict)
        return anyToJSONValue(bodyDict)
    }

    /// Convert a Foundation value back to JSONValue.
    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let s as String: return .string(s)
        case let n as Int: return .number(Double(n))
        case let n as Double: return .number(n)
        case let b as Bool: return .bool(b)
        case is NSNull: return .null
        case let arr as [Any]: return .array(arr.map { anyToJSONValue($0) })
        case let dict as [String: Any]:
            var obj: [String: JSONValue] = [:]
            for (k, v) in dict { obj[k] = anyToJSONValue(v) }
            return .object(obj)
        default: return .string("\(value)")
        }
    }

    // MARK: - Private — Template Resolution

    /// Recursively resolve {template} placeholders in a JSON structure.
    private func resolveTemplatesInJSON(_ value: Any, with vars: [String: Any]) -> Any {
        if let str = value as? String {
            return TemplateEngine.render(str, with: vars)
        }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                result[k] = resolveTemplatesInJSON(v, with: vars)
            }
            return result
        }
        if let arr = value as? [Any] {
            return arr.map { resolveTemplatesInJSON($0, with: vars) }
        }
        return value
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
