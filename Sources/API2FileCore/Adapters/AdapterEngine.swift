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
    /// ETag from the API response (for conditional requests on next pull).
    public let responseETag: String?
    /// True if the server returned 304 Not Modified (nothing changed).
    public let notModified: Bool

    public init(files: [SyncableFile], rawRecordsByFile: [String: [[String: Any]]] = [:], responseETag: String? = nil, notModified: Bool = false) {
        self.files = files
        self.rawRecordsByFile = rawRecordsByFile
        self.responseETag = responseETag
        self.notModified = notModified
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

    /// Pull all resources defined in the adapter config in parallel.
    /// - Parameters:
    ///   - concurrency: Max concurrent API requests (default 6)
    ///   - resourcesToSkip: Resource names to skip this cycle (e.g., empty backoff)
    /// - Returns: PullResult containing all synced files and raw records.
    public func pullAll(concurrency: Int = 6, resourcesToSkip: Set<String> = []) async throws -> PullResult {
        let resources = config.resources.filter { !resourcesToSkip.contains($0.name) }

        // Parallel pull with bounded concurrency
        let results = await withTaskGroup(of: (String, PullResult?).self, returning: [(String, PullResult)].self) { group in
            var active = 0
            var index = 0
            var collected: [(String, PullResult)] = []

            // Seed initial batch
            while active < concurrency && index < resources.count {
                let resource = resources[index]
                group.addTask { [self] in
                    do {
                        let result = try await self.pull(resource: resource)
                        return (resource.name, result)
                    } catch {
                        print("[AdapterEngine] Failed to pull resource '\(resource.name)': \(error)")
                        return (resource.name, nil)
                    }
                }
                active += 1
                index += 1
            }

            // As each completes, add the next
            for await (name, result) in group {
                if let result { collected.append((name, result)) }
                active -= 1
                if index < resources.count {
                    let resource = resources[index]
                    group.addTask { [self] in
                        do {
                            let result = try await self.pull(resource: resource)
                            return (resource.name, result)
                        } catch {
                            print("[AdapterEngine] Failed to pull resource '\(resource.name)': \(error)")
                            return (resource.name, nil)
                        }
                    }
                    active += 1
                    index += 1
                }
            }

            return collected
        }

        var allFiles: [SyncableFile] = []
        var allRawRecords: [String: [[String: Any]]] = [:]
        for (_, result) in results {
            allFiles.append(contentsOf: result.files)
            allRawRecords.merge(result.rawRecordsByFile) { _, new in new }
        }
        return PullResult(files: allFiles, rawRecordsByFile: allRawRecords)
    }

    // MARK: - Pull Single Resource

    /// Pull a single resource from the API and return PullResult with files and raw records.
    /// - Parameters:
    ///   - resource: The resource configuration
    ///   - updatedSince: If set, only fetch records updated after this date (incremental sync)
    ///   - eTag: If set, send If-None-Match header for conditional requests (requires supportsETag)
    /// - Returns: PullResult containing files and raw API records
    public func pull(resource: ResourceConfig, updatedSince: Date? = nil, eTag: String? = nil) async throws -> PullResult {
        guard var pullConfig = resource.pull else {
            throw AdapterError.noPullConfig(resource.name)
        }

        // Inject updatedSince into the pull config if supported
        if let since = updatedSince {
            pullConfig = injectUpdatedSince(since, into: pullConfig)
        }

        // Pass ETag for conditional request if the resource supports it
        let requestETag = (pullConfig.supportsETag == true) ? eTag : nil

        // Fetch all records (handles pagination)
        let fetchResult = try await fetchAllRecords(pullConfig: pullConfig, eTag: requestETag)

        // 304 Not Modified — nothing changed since last pull
        if fetchResult.notModified {
            return PullResult(files: [], responseETag: fetchResult.responseETag, notModified: true)
        }

        let records: [[String: Any]]
        if let detail = pullConfig.detail, resource.fileMapping.strategy == .onePerRecord {
            records = try await hydrateRecords(fetchResult.records, with: detail)
        } else {
            records = fetchResult.records
        }

        // Apply pull transforms
        let transforms = resource.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Media mode: apply transforms first so config can filter/select files before download.
        if pullConfig.type == .media, let mediaConfig = pullConfig.mediaConfig {
            let mediaFiles = try await pullMediaFiles(records: transformed, resource: resource, mediaConfig: mediaConfig)
            return PullResult(files: mediaFiles)
        }

        let fileRecords: [[String: Any]]
        if shouldUseRicosDocumentConversion(for: resource) {
            fileRecords = try await prepareMarkdownRecordsForPull(transformed, resource: resource)
        } else {
            fileRecords = transformed
        }

        // Convert to files based on mapping strategy
        let files = try mapToFiles(records: fileRecords, resource: resource)

        // Build raw records mapping keyed by file path.
        // Merge computed system fields (e.g. _url added by pull transforms) into raw records
        // so they appear in .objects files alongside the original API data.
        let rawWithComputed: [[String: Any]] = zip(records, transformed).map { (raw, xformed) in
            var r = raw
            for (k, v) in xformed where k.hasPrefix("_") { r[k] = v }
            return r
        }
        var rawRecordsByFile: [String: [[String: Any]]] = [:]
        // Exclude companion files from rawRecordsByFile — they have no object files
        let primaryFiles = files.filter { !$0.isCompanion }
        if resource.fileMapping.strategy == .collection {
            // Collection: all raw records map to the single file
            if let firstFile = primaryFiles.first {
                rawRecordsByFile[firstFile.relativePath] = rawWithComputed
            }
        } else {
            // One-per-record: each raw record maps to its corresponding file
            for (index, file) in primaryFiles.enumerated() where index < rawWithComputed.count {
                rawRecordsByFile[file.relativePath] = [rawWithComputed[index]]
            }
        }

        // Pull children recursively — child failures are non-fatal.
        // If a child endpoint is unavailable (e.g. feature not installed), skip it and keep the parent data.
        var allFiles = files
        if let children = resource.children {
            for child in children {
                for parentRecord in transformed {
                    do {
                        let childResult = try await pullChild(child, parentRecord: parentRecord)
                        allFiles.append(contentsOf: childResult.files)
                        rawRecordsByFile.merge(childResult.rawRecordsByFile) { _, new in new }
                    } catch {
                        await ActivityLogger.shared.warn(.sync, "\(resource.name) child '\(child.name)' pull skipped: \(error.localizedDescription)")
                    }
                }
            }
        }

        return PullResult(files: allFiles, rawRecordsByFile: rawRecordsByFile, responseETag: fetchResult.responseETag)
    }

    // MARK: - Push

    /// Push a local file change back to the API.
    /// - Parameters:
    ///   - file: The local file that changed
    ///   - resource: The resource configuration for this file
    @discardableResult
    public func push(file: SyncableFile, resource: ResourceConfig) async throws -> String? {
        guard !(file.readOnly) else {
            throw AdapterError.pushNotAllowed(file.relativePath)
        }
        guard let pushConfig = resource.push else {
            throw AdapterError.noPushConfig(resource.name)
        }

        // Decode the file back to records
        let records: [[String: Any]]
        if shouldUseRicosDocumentConversion(for: resource), file.format == .markdown {
            records = try await decodeMarkdownRecordsForPush(data: file.content, resource: resource)
        } else {
            records = try FormatConverterFactory.decode(
                data: file.content,
                format: file.format,
                options: resource.fileMapping.effectiveFormatOptions
            )
        }

        // Apply push transforms
        let transforms = resource.fileMapping.transforms?.push ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Push each record
        var createdId: String?
        for record in transformed {
            let hasRemoteId = file.remoteId != nil
            let resultId = try await pushRecord(record, pushConfig: pushConfig, remoteId: file.remoteId, isUpdate: hasRemoteId)
            if createdId == nil { createdId = resultId }
        }
        return createdId
    }

    private func shouldUseRicosDocumentConversion(for resource: ResourceConfig) -> Bool {
        guard resource.fileMapping.format == .markdown else { return false }
        guard resource.fileMapping.effectiveFormatOptions?.fieldMapping?["richContent"] != nil else { return false }
        return (config.globals?.baseUrl ?? "").contains("wixapis.com")
    }

    private func prepareMarkdownRecordsForPull(_ records: [[String: Any]], resource: ResourceConfig) async throws -> [[String: Any]] {
        guard let contentField = resource.fileMapping.effectiveFormatOptions?.fieldMapping?["content"],
              let richContentField = resource.fileMapping.effectiveFormatOptions?.fieldMapping?["richContent"] else {
            return records
        }

        var convertedRecords: [[String: Any]] = []
        convertedRecords.reserveCapacity(records.count)

        for var record in records {
            if let richDocument = record[richContentField] as? [String: Any] {
                do {
                    if let markdown = try await convertRicosDocumentToMarkdown(richDocument) {
                        record[contentField] = markdown
                    }
                } catch {
                    await ActivityLogger.shared.warn(.sync, "Wix Ricos → Markdown conversion failed for \(resource.name); falling back to local projection (\(error.localizedDescription))")
                }
            }
            convertedRecords.append(record)
        }

        return convertedRecords
    }

    private func decodeMarkdownRecordsForPush(data: Data, resource: ResourceConfig) async throws -> [[String: Any]] {
        guard let contentField = resource.fileMapping.effectiveFormatOptions?.fieldMapping?["content"],
              let richContentField = resource.fileMapping.effectiveFormatOptions?.fieldMapping?["richContent"] else {
            return try FormatConverterFactory.decode(
                data: data,
                format: resource.fileMapping.format,
                options: resource.fileMapping.effectiveFormatOptions
            )
        }

        let rawMarkdownOptions = FormatOptions(fieldMapping: ["content": contentField])
        let rawMarkdownRecords = try MarkdownFormat.decode(data: data, options: rawMarkdownOptions)
        let normalizedRecords = try MarkdownFormat.decode(data: data, options: resource.fileMapping.effectiveFormatOptions)
        guard rawMarkdownRecords.count == normalizedRecords.count else {
            return normalizedRecords
        }

        var converted: [[String: Any]] = []
        converted.reserveCapacity(normalizedRecords.count)

        for (rawRecord, normalizedRecord) in zip(rawMarkdownRecords, normalizedRecords) {
            var merged = normalizedRecord
            if let markdown = rawRecord[contentField] as? String {
                do {
                    if let document = try await convertMarkdownToRicosDocument(markdown) {
                        merged[richContentField] = document
                    }
                } catch {
                    await ActivityLogger.shared.warn(.sync, "Markdown → Wix Ricos conversion failed for \(resource.name); falling back to local projection (\(error.localizedDescription))")
                }
            }
            converted.append(merged)
        }

        return converted
    }

    private func convertRicosDocumentToMarkdown(_ document: [String: Any]) async throws -> String? {
        let body: [String: Any] = [
            "document": document,
            "targetFormat": "MARKDOWN",
        ]
        let response = try await requestJSON(
            method: .POST,
            url: "https://www.wixapis.com/ricos/v1/ricos-document/convert/from-ricos",
            body: body
        )
        return response["markdown"] as? String
    }

    private func convertMarkdownToRicosDocument(_ markdown: String) async throws -> [String: Any]? {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ["nodes": [], "metadata": ["version": 1]]
        }

        let response = try await requestJSON(
            method: .POST,
            url: "https://www.wixapis.com/ricos/v1/ricos-document/convert/to-ricos",
            body: ["markdown": markdown]
        )
        return response["document"] as? [String: Any]
    }

    private func requestJSON(method: HTTPMethod, url: String, body: [String: Any]) async throws -> [String: Any] {
        var headers = config.globals?.headers ?? [:]
        headers["Content-Type"] = "application/json"
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        let request = APIRequest(method: method, url: url, headers: headers, body: bodyData)
        let response = try await httpClient.request(request)
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw AdapterError.invalidResponseData
        }
        return json
    }

    // MARK: - Push Actions

    /// Action type for pushing a record
    public enum PushAction: Sendable {
        case create
        case update(id: String)
    }

    /// Push a single record with a specific action (create or update)
    @discardableResult
    public func pushRecord(_ record: [String: Any], resource: ResourceConfig, action: PushAction) async throws -> String? {
        guard let pushConfig = resource.push else {
            throw AdapterError.noPushConfig(resource.name)
        }

        // Apply push transforms
        let transforms = resource.fileMapping.transforms?.push ?? []
        let transformed = transforms.isEmpty ? [record] : TransformPipeline.apply(transforms, to: [record])
        guard let rec = transformed.first else { return nil }

        switch action {
        case .create:
            return try await pushRecord(rec, pushConfig: pushConfig, remoteId: nil, isUpdate: false)
        case .update(let id):
            return try await pushRecord(rec, pushConfig: pushConfig, remoteId: id, isUpdate: true)
        }
    }

    /// Delete a record from the API by its remote ID
    public func delete(remoteId: String, resource: ResourceConfig, extraTemplateVars: [String: Any] = [:]) async throws {
        guard let pushConfig = resource.push, let deleteConfig = pushConfig.delete else {
            print("[AdapterEngine] No delete config for \(resource.name)")
            return
        }

        var urlVars: [String: Any] = extraTemplateVars
        if let baseUrl = config.globals?.baseUrl { urlVars["baseUrl"] = baseUrl }
        urlVars["id"] = remoteId
        let url = TemplateEngine.render(deleteConfig.url, with: urlVars)

        var headers = config.globals?.headers ?? [:]

        // GraphQL delete: build mutation body and use POST
        var body: Data? = nil
        if deleteConfig.type == .graphql, let mutation = deleteConfig.mutation {
            let resolvedMutation = TemplateEngine.render(mutation, with: urlVars)
            body = try JSONSerialization.data(withJSONObject: ["query": resolvedMutation])
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        } else if let bodyType = deleteConfig.bodyType {
            // Handle bodyType for special delete semantics (e.g., GitHub close = PATCH with state:closed)
            headers["Content-Type"] = "application/json"
            switch bodyType {
            case "close":
                body = try JSONSerialization.data(withJSONObject: ["state": "closed"])
            default:
                break
            }
        }

        let defaultMethod = (deleteConfig.type == .graphql) ? "POST" : "DELETE"
        let method = HTTPMethod(rawValue: deleteConfig.method?.uppercased() ?? defaultMethod) ?? .POST

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

    private struct FetchResult {
        let records: [[String: Any]]
        let responseETag: String?
        let notModified: Bool
    }

    private func hydrateRecords(_ records: [[String: Any]], with detail: PullDetailConfig) async throws -> [[String: Any]] {
        var hydrated: [[String: Any]] = []
        hydrated.reserveCapacity(records.count)

        for record in records {
            let detailRecord = try await fetchDetailRecord(for: record, detail: detail)
            var merged = record
            if let detailRecord {
                for (key, value) in detailRecord {
                    merged[key] = value
                }
            }

            if merged["contentText"] == nil,
               let richContent = merged["richContent"] as? String,
               !richContent.isEmpty {
                merged["contentText"] = richContent
            }

            hydrated.append(merged)
        }

        return hydrated
    }

    private func fetchDetailRecord(for record: [String: Any], detail: PullDetailConfig) async throws -> [String: Any]? {
        var vars = record
        if let baseUrl = config.globals?.baseUrl {
            vars["baseUrl"] = baseUrl
        }
        let url = TemplateEngine.render(detail.url, with: vars)
        let method = HTTPMethod(rawValue: detail.method?.uppercased() ?? "GET") ?? .GET
        var headers = config.globals?.headers ?? [:]
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"

        let response = try await httpClient.request(
            APIRequest(method: method, url: url, headers: headers, body: nil)
        )
        let json = try JSONSerialization.jsonObject(with: response.body)

        if let dataPath = detail.dataPath,
           let extracted = JSONPath.extract(dataPath, from: json) as? [String: Any] {
            return extracted
        }

        return json as? [String: Any]
    }

    /// Fetch all records from an API endpoint, handling pagination.
    /// - Parameter eTag: Optional ETag for conditional request (If-None-Match). Only sent on first page.
    private func fetchAllRecords(pullConfig: PullConfig, eTag: String? = nil) async throws -> FetchResult {
        var allRecords: [[String: Any]] = []
        var cursor: String? = nil
        var offset: Int = 0
        var page: Int = 1
        let pageSize = pullConfig.pagination?.pageSize ?? 100
        let maxRecords = pullConfig.pagination?.maxRecords ?? 10000
        var responseETag: String? = nil
        var isFirstPage = true

        repeat {
            // Build the request URL with template variables and pagination params
            var url = resolveURL(pullConfig.url)
            let method = resolvedPullMethod(for: pullConfig)
            var headers = config.globals?.headers ?? [:]
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"

            // Send If-None-Match on the first page if we have a stored ETag
            if isFirstPage, let etag = eTag {
                headers["If-None-Match"] = etag
            }

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
                if let queryString = pullConfig.query {
                    // GraphQL: wrap query string in {"query": "..."} body
                    let queryBody: [String: Any] = ["query": queryString]
                    body = try JSONSerialization.data(withJSONObject: queryBody)
                } else if let bodyValue = pullConfig.body {
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

            // Capture ETag from the first page response
            if isFirstPage {
                responseETag = response.headers["ETag"] ?? response.headers["Etag"] ?? response.headers["etag"]
                isFirstPage = false
            }

            // 304 Not Modified — data hasn't changed since last pull
            if response.statusCode == 304 {
                return FetchResult(records: [], responseETag: responseETag ?? eTag, notModified: true)
            }

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
                    return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                }
            case .offset:
                if records.count < pageSize {
                    return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                }
                offset += records.count
            case .page:
                if records.count < pageSize {
                    return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                }
                page += 1
            case .body:
                // Body pagination: use cursor if cursorField is set, otherwise use offset
                if pagination.cursorField != nil {
                    if let next = nextCursor, !next.isEmpty {
                        cursor = next
                    } else {
                        return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                    }
                } else if pagination.offsetField != nil {
                    if records.count < pageSize {
                        return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                    }
                    offset += records.count
                } else {
                    return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
                }
            }
        } while true

        return FetchResult(records: allRecords, responseETag: responseETag, notModified: false)
    }

    private func resolvedPullMethod(for pullConfig: PullConfig) -> HTTPMethod {
        if let explicitMethod = pullConfig.method?.uppercased(),
           let method = HTTPMethod(rawValue: explicitMethod) {
            return method
        }
        if let globalMethod = config.globals?.method?.uppercased(),
           let method = HTTPMethod(rawValue: globalMethod) {
            return method
        }
        if pullConfig.type == .graphql || pullConfig.query != nil || pullConfig.pagination?.queryTemplate != nil {
            return .POST
        }
        return .GET
    }

    // MARK: - Private — Pushing

    /// Push a single record to the API via create or update endpoint.
    /// Returns the remote ID of the newly created record (nil for updates or if not extractable).
    @discardableResult
    private func pushRecord(
        _ record: [String: Any],
        pushConfig: PushConfig,
        remoteId: String?,
        isUpdate: Bool
    ) async throws -> String? {
        let endpoint: EndpointConfig?
        if isUpdate {
            endpoint = pushConfig.update
        } else {
            endpoint = pushConfig.create
        }

        guard let endpoint = endpoint else {
            // No endpoint for this action — skip silently (e.g., no create endpoint for a read-mostly resource)
            return nil
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
        if let bodyType = endpoint.bodyType,
           let customBody = buildCustomPushBody(
            bodyType: bodyType,
            record: record,
            remoteId: remoteId,
            isUpdate: isUpdate
           ) {
            bodyDict = customBody
        } else if endpoint.type == .graphql, let mutation = endpoint.mutation {
            // GraphQL mutation: render template vars inline, send as {"query": "mutation ..."}
            // Values are resolved directly into the mutation string via TemplateEngine,
            // so no separate "variables" object is needed.
            let resolvedMutation = TemplateEngine.render(mutation, with: templateVars)
            bodyDict = ["query": resolvedMutation]
        } else if let wrapper = endpoint.bodyWrapper {
            if let rootFields = endpoint.bodyRootFields, !rootFields.isEmpty {
                // Hoist specified fields to root level, wrap remainder
                var outerBody: [String: Any] = [:]
                var innerRecord = record
                for field in rootFields {
                    if let value = innerRecord.removeValue(forKey: field) {
                        outerBody[field] = value
                    }
                }
                outerBody[wrapper] = innerRecord
                bodyDict = outerBody
            } else {
                bodyDict = [wrapper: record]
            }
        }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)

        let request = APIRequest(
            method: method,
            url: url,
            headers: headers,
            body: body
        )

        let response = try await httpClient.request(request)

        // For create operations, extract the new record ID from the API response
        var createdId: String?
        if !isUpdate {
            if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] {
                createdId = extractCreatedId(from: json)
            }
        }

        // Execute follow-up request if configured (e.g. Wix Blog draft → publish)
        if let followup = endpoint.followup {
            // For create operations, use the newly created ID in the followup URL
            var followupVars = templateVars
            if let newId = createdId {
                followupVars["id"] = newId
            }
            let followupURL = TemplateEngine.render(followup.url, with: followupVars)
            let followupMethod = HTTPMethod(rawValue: followup.method?.uppercased() ?? "POST") ?? .POST
            let followupRequest = APIRequest(method: followupMethod, url: followupURL, headers: headers, body: nil)
            _ = try await httpClient.request(followupRequest)
        }

        return createdId
    }

    private func extractCreatedId(from json: [String: Any]) -> String? {
        if let id = json["id"] as? String {
            return id
        }
        if let id = json["id"] as? Int {
            return String(id)
        }

        for (_, value) in json {
            if let nested = value as? [String: Any],
               let id = extractCreatedId(from: nested) {
                return id
            }
            if let array = value as? [[String: Any]] {
                for nested in array {
                    if let id = extractCreatedId(from: nested) {
                        return id
                    }
                }
            }
        }
        return nil
    }

    private func buildCustomPushBody(
        bodyType: String,
        record: [String: Any],
        remoteId: String?,
        isUpdate: Bool
    ) -> Any? {
        switch bodyType {
        case "monday-item-create":
            return buildMondayItemCreateBody(record: record)
        case "monday-item-update":
            return buildMondayItemUpdateBody(record: record, remoteId: remoteId)
        case "wix-contact-create":
            return buildWixContactBody(record: record, isUpdate: false)
        case "wix-contact-update":
            return buildWixContactBody(record: record, isUpdate: true)
        case "wix-product-create":
            return buildWixProductCreateBody(record: record)
        case "wix-product-update":
            return buildWixProductUpdateBody(record: record)
        case "wix-cms-item-create":
            return buildWixCMSItemBody(record: record, remoteId: remoteId, isUpdate: false)
        case "wix-cms-item-update":
            return buildWixCMSItemBody(record: record, remoteId: remoteId, isUpdate: true)
        default:
            return nil
        }
    }

    private func buildMondayItemCreateBody(record: [String: Any]) -> [String: Any] {
        let boardId = stringifyValue(record["boardId"]) ?? ""
        let name = stringifyValue(record["name"]) ?? ""
        let itemName = name.isEmpty ? "Untitled Item" : name
        var variables: [String: Any] = [
            "boardId": boardId,
            "itemName": itemName
        ]

        if let columnValues = mondayColumnValuesJSONString(from: record["columns"]) {
            variables["columnValues"] = columnValues
        }

        return [
            "query": """
            mutation($boardId: ID!, $itemName: String!, $columnValues: JSON) {
              create_item(board_id: $boardId, item_name: $itemName, column_values: $columnValues) { id }
            }
            """,
            "variables": variables
        ]
    }

    private func buildMondayItemUpdateBody(record: [String: Any], remoteId: String?) -> [String: Any] {
        let boardId = stringifyValue(record["boardId"]) ?? ""
        let itemId = remoteId ?? stringifyValue(record["id"]) ?? ""
        let itemName = stringifyValue(record["name"]) ?? ""
        let columnPayload = mondayColumnMap(from: record["column_values"])
            ?? mondayColumnMap(from: record["columns"])

        var variables: [String: Any] = [
            "boardId": boardId,
            "itemId": itemId
        ]
        var variableDefinitions = [
            "$boardId: ID!",
            "$itemId: ID!"
        ]
        var mutationLines: [String] = []

        if !itemName.isEmpty {
            variableDefinitions.append("$itemName: String!")
            variables["itemName"] = itemName
            mutationLines.append(
                #"rename: change_simple_column_value(board_id: $boardId, item_id: $itemId, column_id: "name", value: $itemName) { id }"#
            )
        }

        if let columnPayload, !columnPayload.isEmpty {
            var simpleColumns: [(String, String)] = []
            var complexColumns: [String: Any] = [:]

            for key in columnPayload.keys.sorted() {
                guard let value = columnPayload[key] else { continue }
                if let simpleValue = mondaySimpleColumnValue(value) {
                    simpleColumns.append((key, simpleValue))
                } else {
                    complexColumns[key] = value
                }
            }

            for (index, column) in simpleColumns.enumerated() {
                let variableName = "columnValue\(index)"
                variableDefinitions.append("$\(variableName): String!")
                variables[variableName] = column.1
                let columnID = escapeGraphQLStringLiteral(column.0)
                mutationLines.append(
                    #"c\#(index): change_simple_column_value(board_id: $boardId, item_id: $itemId, column_id: "\#(columnID)", value: $\#(variableName)) { id }"#
                )
            }

            if let complexJSON = mondayColumnValuesJSONString(from: complexColumns) {
                variableDefinitions.append("$columnValues: JSON")
                variables["columnValues"] = complexJSON
                mutationLines.append(
                    "bulk: change_multiple_column_values(board_id: $boardId, item_id: $itemId, column_values: $columnValues) { id }"
                )
            }
        }

        if mutationLines.isEmpty {
            variableDefinitions.append("$itemName: String!")
            variables["itemName"] = itemName
            mutationLines.append(
                #"rename: change_simple_column_value(board_id: $boardId, item_id: $itemId, column_id: "name", value: $itemName) { id }"#
            )
        }

        let query = """
        mutation(\(variableDefinitions.joined(separator: ", "))) {
          \(mutationLines.joined(separator: "\n  "))
        }
        """

        return [
            "query": query,
            "variables": variables
        ]
    }

    private func mondayColumnMap(from value: Any?) -> [String: Any]? {
        switch value {
        case let array as [[String: Any]]:
            var result: [String: Any] = [:]
            for column in array {
                guard let id = column["id"] as? String, !id.isEmpty else { continue }
                if let text = column["text"] as? String {
                    result[id] = text
                } else if let nestedValue = column["value"] {
                    result[id] = nestedValue
                }
            }
            return result.isEmpty ? nil : result
        case let dict as [String: Any]:
            return dict.isEmpty ? nil : dict
        case let raw as NSDictionary:
            var swiftDict: [String: Any] = [:]
            for (key, value) in raw {
                guard let key = key as? String else { continue }
                swiftDict[key] = value
            }
            return swiftDict.isEmpty ? nil : swiftDict
        default:
            return nil
        }
    }

    private func mondaySimpleColumnValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func mondayColumnValuesJSONString(from value: Any?) -> String? {
        func serializeColumnArray(_ values: [[String: Any]]) -> String? {
            var byId: [String: Any] = [:]
            for value in values {
                guard let id = value["id"] as? String, !id.isEmpty else { continue }
                byId[id] = value["text"]
            }
            return serialize(byId)
        }

        func serialize(_ dict: [String: Any]) -> String? {
            guard !dict.isEmpty,
                  JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return string
        }

        switch value {
        case let array as [[String: Any]]:
            return serializeColumnArray(array)
        case let dict as [String: Any]:
            return serialize(dict)
        case let raw as NSDictionary:
            var swiftDict: [String: Any] = [:]
            for (key, value) in raw {
                guard let key = key as? String else { continue }
                swiftDict[key] = value
            }
            return serialize(swiftDict)
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "[:]", trimmed != "{}" else { return nil }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return serialize(json)
        default:
            return nil
        }
    }

    private func escapeGraphQLStringLiteral(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func buildWixProductCreateBody(record: [String: Any]) -> [String: Any] {
        let name = stringifyValue(record["name"]) ?? "Untitled Product"
        let productType = stringifyValue(record["productType"]) ?? "PHYSICAL"
        let visible = boolValue(record["visible"]) ?? true
        let slug = stringifyValue(record["slug"]) ?? TemplateEngine.render("{name|slugify}", with: ["name": name])

        var product: [String: Any] = [
            "name": name,
            "productType": productType,
            "visible": visible,
            "slug": slug,
            "variantsInfo": [
                "variants": [
                    [
                        "choices": [] as [[String: Any]],
                        "price": [
                            "actualPrice": [
                                "amount": amountString(record["priceAmount"])
                            ]
                        ]
                    ]
                ]
            ]
        ]

        if productType.uppercased() == "PHYSICAL" {
            product["physicalProperties"] = [:] as [String: Any]
        }

        if let ribbonDict = record["ribbon"] as? [String: Any], !ribbonDict.isEmpty {
            product["ribbon"] = ribbonDict
        } else if let ribbonStr = record["ribbon"] as? String, !ribbonStr.isEmpty,
                  let ribbonData = ribbonStr.data(using: .utf8),
                  let ribbonObj = try? JSONSerialization.jsonObject(with: ribbonData) as? [String: Any] {
            product["ribbon"] = ribbonObj
        }

        return ["product": product]
    }

    private func buildWixProductUpdateBody(record: [String: Any]) -> [String: Any] {
        var product: [String: Any] = [:]

        if let name = stringifyValue(record["name"]), !name.isEmpty {
            product["name"] = name
        }
        if let slug = stringifyValue(record["slug"]), !slug.isEmpty {
            product["slug"] = slug
        }
        if let ribbonDict = record["ribbon"] as? [String: Any], !ribbonDict.isEmpty {
            product["ribbon"] = ribbonDict
        } else if let ribbonStr = record["ribbon"] as? String, !ribbonStr.isEmpty,
                  let ribbonData = ribbonStr.data(using: .utf8),
                  let ribbonObj = try? JSONSerialization.jsonObject(with: ribbonData) as? [String: Any] {
            product["ribbon"] = ribbonObj
        }
        if let visible = boolValue(record["visible"]) {
            product["visible"] = visible
        }
        if let revision = stringifyValue(record["revision"]) ?? stringifyValue(record["_revision"]), !revision.isEmpty {
            product["revision"] = revision
        }

        return ["product": product]
    }

    private func buildWixContactBody(record: [String: Any], isUpdate: Bool) -> [String: Any]? {
        let existingInfo = (record["info"] as? [String: Any]) ?? [:]
        var info: [String: Any] = [:]
        var name = (existingInfo["name"] as? [String: Any]) ?? [:]
        let hadExplicitNestedName =
            nonEmptyString(name["first"]) != nil ||
            nonEmptyString(name["last"]) != nil
        let currentDisplayName = [nonEmptyString(name["first"]), nonEmptyString(name["last"])]
            .compactMap { $0 }
            .joined(separator: " ")

        if let first = nonEmptyString(record["first"]) {
            name["first"] = first
        }
        if let last = nonEmptyString(record["last"]) {
            name["last"] = last
        }
        if nonEmptyString(record["first"]) == nil,
           nonEmptyString(record["last"]) == nil,
           !hadExplicitNestedName,
           let displayName = nestedString(record, path: ["info", "extendedFields", "items", "contacts", "displayByFirstName"]),
           displayName != currentDisplayName,
           let parsedName = splitDisplayName(displayName) {
            name["first"] = parsedName.first
            name["last"] = parsedName.last
        }
        if !name.isEmpty {
            info["name"] = name
        }

        let currentEmail = firstEmailString(from: existingInfo["emails"])
        let editedEmail = firstEmailString(from: record["primaryEmail"]) ?? firstEmailString(from: record["emails"])
        let fallbackEmail: String?
        if record["primaryEmail"] == nil, record["emails"] == nil {
            fallbackEmail = currentEmail
        } else {
            fallbackEmail = nil
        }
        if let email = editedEmail ?? fallbackEmail,
           !isUpdate || currentEmail == nil || email != currentEmail || editedEmail == nil {
            info["emails"] = [
                "items": [
                    [
                        "email": email,
                        "primary": true
                    ]
                ]
            ]
        }

        let currentPhone = firstPhoneString(from: existingInfo["phones"])
        let editedPhone = firstPhoneString(from: record["primaryPhone"]) ?? firstPhoneString(from: record["phones"])
        let fallbackPhone: String?
        if record["primaryPhone"] == nil, record["phones"] == nil {
            fallbackPhone = currentPhone
        } else {
            fallbackPhone = nil
        }
        if let phone = editedPhone ?? fallbackPhone,
           !isUpdate || currentPhone == nil || phone != currentPhone || editedPhone == nil {
            info["phones"] = [
                "items": [
                    [
                        "phone": phone,
                        "primary": true
                    ]
                ]
            ]
        }

        guard !info.isEmpty else { return nil }

        if isUpdate {
            var body: [String: Any] = ["info": info]
            if let revision = numericJSONValue(record["revision"]) ?? numericJSONValue(record["_revision"]) {
                body["revision"] = revision
            } else if let revision = record["revision"] ?? record["_revision"] {
                body["revision"] = revision
            }
            return body
        }

        return ["info": info]
    }

    private func buildWixCMSItemBody(record: [String: Any], remoteId: String?, isUpdate: Bool) -> [String: Any]? {
        guard let dataCollectionId = nonEmptyString(record["dataCollectionId"]) else {
            return nil
        }

        var dataItem: [String: Any] = [:]

        if isUpdate, let id = remoteId ?? nonEmptyString(record["id"]) {
            dataItem["id"] = id
        }

        if let nestedData = record["data"] as? [String: Any] {
            dataItem["data"] = nestedData
        } else {
            var data = record
            data.removeValue(forKey: "id")
            data.removeValue(forKey: "dataCollectionId")
            dataItem["data"] = data
        }

        return [
            "dataCollectionId": dataCollectionId,
            "dataItem": dataItem
        ]
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = stringifyValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }

    private func firstEmailString(from value: Any?) -> String? {
        switch value {
        case let email as String:
            if let jsonData = email.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData),
               !(parsed is NSNull) {
                return firstEmailString(from: parsed)
            }
            return nonEmptyString(email)
        case let dict as [String: Any]:
            if let items = dict["items"] as? [[String: Any]] {
                for item in items {
                    if let email = nonEmptyString(item["email"]) {
                        return email
                    }
                }
            }
            return nonEmptyString(dict["email"])
        case let items as [[String: Any]]:
            for item in items {
                if let email = nonEmptyString(item["email"]) {
                    return email
                }
            }
            return nil
        case let values as [Any]:
            for item in values {
                if let dict = item as? [String: Any],
                   let email = nonEmptyString(dict["email"]) {
                    return email
                }
                if let email = item as? String,
                   let normalized = nonEmptyString(email) {
                    return normalized
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func firstPhoneString(from value: Any?) -> String? {
        switch value {
        case let phone as String:
            if let jsonData = phone.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData),
               !(parsed is NSNull) {
                return firstPhoneString(from: parsed)
            }
            return nonEmptyString(phone)
        case let dict as [String: Any]:
            if let items = dict["items"] as? [[String: Any]] {
                for item in items {
                    if let phone = nonEmptyString(item["phone"]) {
                        return phone
                    }
                }
            }
            return nonEmptyString(dict["phone"])
        case let items as [[String: Any]]:
            for item in items {
                if let phone = nonEmptyString(item["phone"]) {
                    return phone
                }
            }
            return nil
        case let values as [Any]:
            for item in values {
                if let dict = item as? [String: Any],
                   let phone = nonEmptyString(dict["phone"]) {
                    return phone
                }
                if let phone = item as? String,
                   let normalized = nonEmptyString(phone) {
                    return normalized
                }
            }
            return nil
        default:
            return nil
        }
    }

    private func numericJSONValue(_ value: Any?) -> Any? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) {
                return int
            }
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }

    private func nestedString(_ value: Any?, path: [String]) -> String? {
        guard !path.isEmpty else { return nonEmptyString(value) }
        guard let dict = value as? [String: Any] else { return nil }
        var current: Any? = dict
        for segment in path {
            guard let nextDict = current as? [String: Any] else { return nil }
            current = nextDict[segment]
        }
        return nonEmptyString(current)
    }

    private func splitDisplayName(_ displayName: String) -> (first: String, last: String)? {
        let parts = displayName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        let last = parts.dropFirst().joined(separator: " ")
        return (first: first, last: last)
    }

    private func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(number) {
                return number.boolValue
            }
            return nil
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" { return true }
            if normalized == "false" { return false }
            return nil
        default:
            return nil
        }
    }

    private func amountString(_ value: Any?) -> String {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "1.00" : trimmed
        case let int as Int:
            return "\(int)"
        case let double as Double:
            if double == double.rounded() {
                return "\(Int(double))"
            }
            return String(format: "%.2f", double)
        case let number as NSNumber:
            let double = number.doubleValue
            if double == double.rounded() {
                return "\(Int(double))"
            }
            return String(format: "%.2f", double)
        default:
            return "1.00"
        }
    }

    // MARK: - Private — File Mapping

    /// Convert API records to SyncableFile objects based on the mapping strategy.
    private func mapToFiles(records: [[String: Any]], resource: ResourceConfig) throws -> [SyncableFile] {
        let mapping = resource.fileMapping
        let format = mapping.format
        let options = mapping.effectiveFormatOptions
        let readOnly = mapping.readOnly ?? false
        let idField = mapping.idField ?? "id"

        var result: [SyncableFile]

        switch mapping.strategy {
        case .onePerRecord:
            // One file per record
            result = try records.map { record in
                let relativePath = FileMapper.filePath(for: record, config: mapping)
                let data: Data

                if format == .markdown {
                    data = try FormatConverterFactory.encode(records: [record], format: format, options: options)
                } else if let contentField = mapping.contentField,
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
            let remoteId = collectionContextRemoteId(for: resource)

            result = [SyncableFile(
                relativePath: relativePath,
                format: format,
                content: data,
                remoteId: remoteId,
                readOnly: readOnly
            )]

        case .mirror:
            // Mirror the remote structure — same as one-per-record but preserves remote paths
            result = try records.map { record in
                let relativePath = FileMapper.filePath(for: record, config: mapping)
                let data: Data

                if format == .markdown {
                    data = try FormatConverterFactory.encode(records: [record], format: format, options: options)
                } else if let contentField = mapping.contentField,
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

        // Append companion files — one per record per companion config
        if let companions = mapping.companionFiles, !companions.isEmpty {
            for companion in companions {
                for record in records {
                    let resolvedFilename = TemplateEngine.render(companion.filename, with: record)
                    let dir = companion.directory
                    let relPath = dir.isEmpty || dir == "." ? resolvedFilename : "\(dir)/\(resolvedFilename)"
                    let body = TemplateEngine.render(companion.template, with: record)
                    guard let data = body.data(using: .utf8) else { continue }
                    let remoteId = stringifyValue(record[idField])
                    result.append(SyncableFile(
                        relativePath: relPath,
                        format: .markdown,
                        content: data,
                        remoteId: remoteId,
                        readOnly: true,
                        isCompanion: true
                    ))
                }
            }
        }

        return result
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

        // Resolve query template variables from parent record (GraphQL queries with {id} etc.)
        let resolvedQuery = pullConfig.query.map { TemplateEngine.render($0, with: templateVars) }

        // Create a modified pull config with resolved URL, body, and query
        pullConfig = PullConfig(
            method: pullConfig.method,
            url: resolvedURL,
            type: pullConfig.type,
            query: resolvedQuery,
            body: resolvedBody,
            dataPath: pullConfig.dataPath,
            pagination: pullConfig.pagination,
            mediaConfig: pullConfig.mediaConfig,
            updatedSinceField: pullConfig.updatedSinceField,
            updatedSinceBodyPath: pullConfig.updatedSinceBodyPath,
            updatedSinceDateFormat: pullConfig.updatedSinceDateFormat,
            supportsETag: pullConfig.supportsETag
        )

        let fetchResult = try await fetchAllRecords(pullConfig: pullConfig)
        let records = fetchResult.records

        let transforms = child.fileMapping.transforms?.pull ?? []
        let transformed = transforms.isEmpty ? records : TransformPipeline.apply(transforms, to: records)

        // Resolve directory and filename templates from parent record for child files
        let resolvedDirectory = TemplateEngine.render(child.fileMapping.directory, with: templateVars)
        let resolvedFilename = child.fileMapping.filename.map { TemplateEngine.render($0, with: templateVars) }
        let resolvedChild = child.withResolvedFileMapping(directory: resolvedDirectory, filename: resolvedFilename)
        let files = try mapToFiles(records: transformed, resource: resolvedChild)

        // Build raw records mapping (include computed system fields from transforms)
        let rawWithComputed: [[String: Any]] = zip(records, transformed).map { (raw, xformed) in
            var r = raw
            for (k, v) in xformed where k.hasPrefix("_") { r[k] = v }
            return r
        }
        var rawRecordsByFile: [String: [[String: Any]]] = [:]
        let primaryFiles = files.filter { !$0.isCompanion }
        if child.fileMapping.strategy == .collection {
            if let firstFile = primaryFiles.first {
                rawRecordsByFile[firstFile.relativePath] = rawWithComputed
            }
        } else {
            for (index, file) in primaryFiles.enumerated() where index < rawWithComputed.count {
                rawRecordsByFile[file.relativePath] = [rawWithComputed[index]]
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
            detail: pullConfig.detail,
            pagination: pullConfig.pagination,
            mediaConfig: pullConfig.mediaConfig,
            updatedSinceField: pullConfig.updatedSinceField,
            updatedSinceBodyPath: pullConfig.updatedSinceBodyPath,
            updatedSinceDateFormat: pullConfig.updatedSinceDateFormat,
            supportsETag: pullConfig.supportsETag
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

    private func collectionContextRemoteId(for resource: ResourceConfig) -> String? {
        guard let body = resource.pull?.body else { return nil }
        return jsonString(body, path: ["dataCollectionId"])
    }

    private func jsonString(_ value: JSONValue, path: [String]) -> String? {
        if path.isEmpty {
            if case .string(let string) = value, !string.isEmpty {
                return string
            }
            return nil
        }

        guard case .object(let object) = value,
              let child = object[path[0]] else {
            return nil
        }

        return jsonString(child, path: Array(path.dropFirst()))
    }
}
