import Foundation
import Network
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Lightweight HTTP server using NWListener for local control API.
/// Designed for AI agents and scripts to query and control the sync engine.
public actor LocalServer {
    private let port: UInt16
    private let syncEngine: SyncEngine
    private var listener: NWListener?
    private nonisolated(unsafe) var browserDelegate: BrowserControlDelegate?
    private nonisolated(unsafe) var openAppCallback: ((String, String?) -> Void)?

    public init(port: UInt16 = 21567, syncEngine: SyncEngine) {
        self.port = port
        self.syncEngine = syncEngine
    }

    public func setBrowserDelegate(_ delegate: BrowserControlDelegate?) {
        self.browserDelegate = delegate
    }

    public func setOpenAppCallback(_ callback: @escaping (String, String?) -> Void) {
        self.openAppCallback = callback
    }

    // MARK: - Lifecycle

    public func start() throws {
        NSLog("LocalServer start requested on port %hu", port)
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: params, on: nwPort)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("LocalServer listener ready on port %hu", self.port)
                break
            case .failed(let error):
                NSLog("LocalServer listener failed on port %hu: %@", self.port, error.localizedDescription)
            case .cancelled:
                NSLog("LocalServer listener cancelled on port %hu", self.port)
            default:
                NSLog("LocalServer listener state on port %hu: %@", self.port, String(describing: state))
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
        NSLog("LocalServer stop requested on port %hu", port)
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveHTTPRequest(connection: connection, accumulated: Data())
    }

    private func receiveHTTPRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var data = accumulated
            if let content {
                data.append(content)
            }

            // Check if we have a complete HTTP request (headers end with \r\n\r\n)
            if let headerEnd = data.findHeaderEnd() {
                // Parse Content-Length to see if we need to read body
                let headerData = data[data.startIndex..<headerEnd]
                let headerString = String(data: headerData, encoding: .utf8) ?? ""
                let contentLength = Self.parseContentLength(from: headerString)

                let bodyStart = headerEnd + 4 // skip \r\n\r\n
                let bodyReceived = data.count - bodyStart

                if bodyReceived >= contentLength {
                    // Full request received
                    Task {
                        await self.processRequest(data: data, connection: connection)
                    }
                    return
                }
            }

            if isComplete || error != nil {
                // Connection closed or errored — try to process what we have
                if !data.isEmpty {
                    Task {
                        await self.processRequest(data: data, connection: connection)
                    }
                } else {
                    connection.cancel()
                }
                return
            }

            // Need more data
            Task {
                await self.receiveHTTPRequest(connection: connection, accumulated: data)
            }
        }
    }

    // MARK: - Request Processing

    private func processRequest(data: Data, connection: NWConnection) async {
        guard let request = HTTPRequest.parse(from: data) else {
            let response = HTTPResponse(statusCode: 400, body: ["error": "Bad Request"])
            sendResponse(response, on: connection)
            return
        }

        let response = await routeRequest(request)
        sendResponse(response, on: connection)
    }

    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path
        let method = request.method

        if method == "OPTIONS" && path.hasPrefix("/lite/api/") {
            return HTTPResponse(statusCode: 204, bodyRaw: Data(), headers: liteCORSHeaders())
        }

        if method == "GET" && (path == "/lite" || path == "/lite/") {
            return handleLiteManagerPage()
        }

        if method == "GET" && path.hasPrefix("/website/") {
            return handleLiteStaticAsset(path: path)
        }

        if method == "GET" && path == "/lite/api/services" {
            return await handleLiteServices()
        }

        if method == "GET" && path == "/lite/api/files" {
            let includeHidden = request.queryItems["includeHidden"] == "true"
            return await handleLiteFiles(serviceId: request.queryItems["service"], includeHidden: includeHidden)
        }

        if method == "GET" && path == "/lite/api/file" {
            return await handleLiteFile(queryItems: request.queryItems)
        }

        if method == "PUT" && path == "/lite/api/file" {
            return await handleLiteFileSave(queryItems: request.queryItems, body: request.body)
        }

        if method == "POST" && path == "/lite/api/file" {
            return await handleLiteFileCreate(queryItems: request.queryItems, body: request.body)
        }

        if method == "DELETE" && path == "/lite/api/file" {
            return await handleLiteFileDelete(queryItems: request.queryItems)
        }

        if method == "POST" && path == "/lite/api/folder" {
            return await handleLiteFolderCreate(queryItems: request.queryItems)
        }

        if method == "POST" && path == "/lite/api/rename" {
            return await handleLiteRename(queryItems: request.queryItems)
        }

        // GET /api/health
        if method == "GET" && path == "/api/health" {
            return handleHealth()
        }

        // GET /api/services
        if method == "GET" && path == "/api/services" {
            return await handleGetServices()
        }

        // GET /api/services/:id/status
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/status") {
            return await handleGetServiceStatus(serviceId: serviceId)
        }

        // GET /api/services/:id/history
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/history") {
            let limit = min(Int(request.queryItems["limit"] ?? "") ?? 50, 500)
            return await handleGetHistory(serviceId: serviceId, limit: limit)
        }

        // GET /api/services/:id/sql/tables
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/tables") {
            return await handleListSQLTables(serviceId: serviceId)
        }

        // GET /api/services/:id/sql/describe?table=...
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/describe") {
            return await handleDescribeSQLTable(serviceId: serviceId, queryItems: request.queryItems)
        }

        // POST /api/services/:id/sql/query
        if method == "POST", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/query") {
            return await handleQuerySQL(serviceId: serviceId, body: request.body)
        }

        // GET /api/services/:id/sql/search?text=...&resources=a,b
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/search") {
            return await handleSearchSQL(serviceId: serviceId, queryItems: request.queryItems)
        }

        // GET /api/services/:id/sql/record?resource=...&recordId=...
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/record") {
            return await handleGetSQLRecord(serviceId: serviceId, queryItems: request.queryItems)
        }

        // GET /api/services/:id/sql/open?resource=...&recordId=...&surface=canonical|projection
        if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sql/open") {
            return await handleOpenSQLRecordFile(serviceId: serviceId, queryItems: request.queryItems)
        }

        // POST /api/services/:id/sync
        if method == "POST", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sync") {
            return await handleTriggerSync(serviceId: serviceId)
        }

        // PATCH /api/services/:id/resources/:name  {"enabled": bool}
        if method == "PATCH", path.hasPrefix("/api/services/"), path.contains("/resources/") {
            let parts = path.components(separatedBy: "/")
            if parts.count == 6, parts[4] == "resources" {
                return await handleSetResourceEnabled(serviceId: parts[3], resourceName: parts[5], body: request.body)
            }
        }

        // PATCH /api/services/:id/files  {"path": "...", "excluded": bool}
        if method == "PATCH", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/files") {
            return await handleSetFileExcluded(serviceId: serviceId, body: request.body)
        }

        // POST /api/adapters/validate
        if method == "POST" && path == "/api/adapters/validate" {
            return handleValidateAdapter(body: request.body)
        }

        // POST /api/open-url
        if method == "POST" && path == "/api/open-url" {
            return handleOpenURL(body: request.body)
        }

        // POST /api/app/open?service=xxx&path=yyy  — "Open in API2File" from Finder extension
        if method == "POST" && path == "/api/app/open" {
            return handleOpenApp(queryItems: request.queryItems)
        }

        // --- Browser control routes ---

        if method == "POST" && path == "/api/browser/open" {
            return await handleBrowserOpen()
        }
        if method == "POST" && path == "/api/browser/navigate" {
            return await handleBrowserNavigate(body: request.body)
        }
        if method == "POST" && path == "/api/browser/screenshot" {
            return await handleBrowserScreenshot(body: request.body)
        }
        if method == "POST" && path == "/api/browser/dom" {
            return await handleBrowserDOM(body: request.body)
        }
        if method == "POST" && path == "/api/browser/click" {
            return await handleBrowserClick(body: request.body)
        }
        if method == "POST" && path == "/api/browser/type" {
            return await handleBrowserType(body: request.body)
        }
        if method == "POST" && path == "/api/browser/evaluate" {
            return await handleBrowserEvaluate(body: request.body)
        }
        if method == "GET" && path == "/api/browser/url" {
            return await handleBrowserGetURL()
        }
        if method == "POST" && path == "/api/browser/wait" {
            return await handleBrowserWait(body: request.body)
        }
        if method == "GET" && path == "/api/browser/status" {
            return await handleBrowserStatus()
        }
        if method == "POST" && path == "/api/browser/back" {
            return await handleBrowserBack()
        }
        if method == "POST" && path == "/api/browser/forward" {
            return await handleBrowserForward()
        }
        if method == "POST" && path == "/api/browser/reload" {
            return await handleBrowserReload()
        }
        if method == "POST" && path == "/api/browser/scroll" {
            return await handleBrowserScroll(body: request.body)
        }

        return HTTPResponse(statusCode: 404, body: ["error": "Not Found"])
    }

    // MARK: - Route Handlers

    private func handleHealth() -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: [
            "status": "ok",
            "version": "1.0"
        ])
    }

    private func handleLiteManagerPage() -> HTTPResponse {
        guard let htmlURL = liteManagerHTMLURL(),
              let html = try? Data(contentsOf: htmlURL) else {
            return HTTPResponse(
                statusCode: 404,
                bodyRaw: Data("Lite Manager HTML not found".utf8),
                contentType: "text/plain; charset=utf-8"
            )
        }

        return HTTPResponse(statusCode: 200, bodyRaw: html, contentType: "text/html; charset=utf-8")
    }

    private func handleLiteStaticAsset(path: String) -> HTTPResponse {
        guard let websiteRoot = liteManagerRootURL() else {
            return HTTPResponse(statusCode: 404, bodyRaw: Data("Lite Manager assets not found".utf8), contentType: "text/plain; charset=utf-8")
        }

        let relativePath = String(path.dropFirst("/website/".count))
        let segments = relativePath.split(separator: "/").map(String.init)
        guard !segments.isEmpty,
              !segments.contains(".."),
              !segments.contains(where: { $0.isEmpty }) else {
            return HTTPResponse(statusCode: 400, bodyRaw: Data("Invalid asset path".utf8), contentType: "text/plain; charset=utf-8")
        }

        let assetURL = websiteRoot.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard assetURL.path.hasPrefix(websiteRoot.path + "/") else {
            return HTTPResponse(statusCode: 400, bodyRaw: Data("Invalid asset path".utf8), contentType: "text/plain; charset=utf-8")
        }
        guard let data = try? Data(contentsOf: assetURL) else {
            return HTTPResponse(statusCode: 404, bodyRaw: Data("Asset not found".utf8), contentType: "text/plain; charset=utf-8")
        }

        return HTTPResponse(statusCode: 200, bodyRaw: data, contentType: contentType(for: assetURL))
    }

    private func handleLiteServices() async -> HTTPResponse {
        let services = await syncEngine.getServices()
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        let items: [[String: Any]] = services.map { info in
            var item: [String: Any] = [
                "serviceId": info.serviceId,
                "displayName": info.displayName,
                "status": info.status.rawValue,
                "fileCount": info.fileCount
            ]
            if let lastSync = info.lastSyncTime {
                item["lastSyncTime"] = ISO8601DateFormatter().string(from: lastSync)
            }
            return item
        }

        return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(items), headers: liteCORSHeaders())
    }

    private func handleLiteFiles(serviceId: String?, includeHidden: Bool) async -> HTTPResponse {
        let services = await syncEngine.getServices()
        let allowedServices = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceId, $0) })

        let targetServiceIds: [String]
        if let serviceId, !serviceId.isEmpty {
            guard allowedServices[serviceId] != nil else {
                return HTTPResponse(statusCode: 404, bodyRaw: encodeJSON(["error": "Service not found", "serviceId": serviceId]), headers: liteCORSHeaders())
            }
            targetServiceIds = [serviceId]
        } else {
            targetServiceIds = allowedServices.keys.sorted()
        }

        let rootURL = await syncEngine.getSyncRootURL()
        var files: [[String: Any]] = []

        for serviceId in targetServiceIds {
            guard let service = allowedServices[serviceId] else { continue }
            let serviceRoot = rootURL.appendingPathComponent(serviceId, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: serviceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }

                let relativePath = fileURL.path.replacingOccurrences(of: serviceRoot.path + "/", with: "")
                if shouldHideLitePath(relativePath, includeHidden: includeHidden) {
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                let item: [String: Any] = [
                    "serviceId": serviceId,
                    "displayName": service.displayName,
                    "path": relativePath,
                    "name": fileURL.lastPathComponent,
                    "extension": ext,
                    "size": values?.fileSize ?? 0,
                    "modifiedAt": values?.contentModificationDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                    "editable": isLiteEditable(relativePath: relativePath, fileExtension: ext)
                ]
                files.append(item)
            }
        }

        files.sort {
            let lhsService = ($0["serviceId"] as? String) ?? ""
            let rhsService = ($1["serviceId"] as? String) ?? ""
            if lhsService == rhsService {
                return (($0["path"] as? String) ?? "").localizedStandardCompare(($1["path"] as? String) ?? "") == .orderedAscending
            }
            return lhsService.localizedStandardCompare(rhsService) == .orderedAscending
        }

        return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(files), headers: liteCORSHeaders())
    }

    private func handleLiteFile(queryItems: [String: String]) async -> HTTPResponse {
        guard let fileURL = await validatedLiteFileURL(queryItems: queryItems) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid service/path"]), headers: liteCORSHeaders())
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: 404, bodyRaw: encodeJSON(["error": "File not found"]), headers: liteCORSHeaders())
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": "Failed to read file"]), headers: liteCORSHeaders())
        }
        return HTTPResponse(statusCode: 200, bodyRaw: data, contentType: contentType(for: fileURL), headers: liteCORSHeaders())
    }

    private func handleLiteFileSave(queryItems: [String: String], body: Data?) async -> HTTPResponse {
        guard let fileURL = await validatedLiteFileURL(queryItems: queryItems) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid service/path"]), headers: liteCORSHeaders())
        }
        guard let body else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Request body is required"]), headers: liteCORSHeaders())
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: 404, bodyRaw: encodeJSON(["error": "File not found"]), headers: liteCORSHeaders())
        }

        let relativePath = queryItems["path"] ?? ""
        if !isLiteEditable(relativePath: relativePath, fileExtension: fileURL.pathExtension.lowercased()) {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "This file type is not editable from Lite Manager"]), headers: liteCORSHeaders())
        }

        do {
            try body.write(to: fileURL, options: .atomic)
            return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(["status": "ok"]), headers: liteCORSHeaders())
        } catch {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": error.localizedDescription]), headers: liteCORSHeaders())
        }
    }

    private func handleLiteFileCreate(queryItems: [String: String], body: Data?) async -> HTTPResponse {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty,
              let path = queryItems["path"], !path.isEmpty,
              let fileURL = await validatedLiteServicePathURL(serviceId: serviceId, path: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid service/path"]), headers: liteCORSHeaders())
        }
        guard let body else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Request body is required"]), headers: liteCORSHeaders())
        }
        guard isLiteMutable(relativePath: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "This path cannot be modified from Lite Manager"]), headers: liteCORSHeaders())
        }

        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try body.write(to: fileURL, options: .atomic)
            return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(["status": "ok"]), headers: liteCORSHeaders())
        } catch {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": error.localizedDescription]), headers: liteCORSHeaders())
        }
    }

    private func handleLiteFileDelete(queryItems: [String: String]) async -> HTTPResponse {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty,
              let path = queryItems["path"], !path.isEmpty,
              let fileURL = await validatedLiteServicePathURL(serviceId: serviceId, path: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid service/path"]), headers: liteCORSHeaders())
        }
        guard isLiteMutable(relativePath: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "This path cannot be modified from Lite Manager"]), headers: liteCORSHeaders())
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return HTTPResponse(statusCode: 404, bodyRaw: encodeJSON(["error": "File not found"]), headers: liteCORSHeaders())
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(["status": "ok"]), headers: liteCORSHeaders())
        } catch {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": error.localizedDescription]), headers: liteCORSHeaders())
        }
    }

    private func handleLiteFolderCreate(queryItems: [String: String]) async -> HTTPResponse {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty,
              let path = queryItems["path"], !path.isEmpty,
              let folderURL = await validatedLiteServicePathURL(serviceId: serviceId, path: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid service/path"]), headers: liteCORSHeaders())
        }
        guard isLiteMutable(relativePath: path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "This path cannot be modified from Lite Manager"]), headers: liteCORSHeaders())
        }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(["status": "ok"]), headers: liteCORSHeaders())
        } catch {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": error.localizedDescription]), headers: liteCORSHeaders())
        }
    }

    private func handleLiteRename(queryItems: [String: String]) async -> HTTPResponse {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty,
              let path = queryItems["path"], !path.isEmpty,
              let nextPath = queryItems["nextPath"], !nextPath.isEmpty,
              let sourceURL = await validatedLiteServicePathURL(serviceId: serviceId, path: path),
              let destinationURL = await validatedLiteServicePathURL(serviceId: serviceId, path: nextPath) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Missing or invalid rename path"]), headers: liteCORSHeaders())
        }
        guard isLiteMutable(relativePath: path), isLiteMutable(relativePath: nextPath) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "This path cannot be modified from Lite Manager"]), headers: liteCORSHeaders())
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return HTTPResponse(statusCode: 404, bodyRaw: encodeJSON(["error": "Source file not found"]), headers: liteCORSHeaders())
        }
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return HTTPResponse(statusCode: 400, bodyRaw: encodeJSON(["error": "Destination already exists"]), headers: liteCORSHeaders())
        }

        do {
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return HTTPResponse(statusCode: 200, bodyRaw: encodeJSON(["status": "ok"]), headers: liteCORSHeaders())
        } catch {
            return HTTPResponse(statusCode: 500, bodyRaw: encodeJSON(["error": error.localizedDescription]), headers: liteCORSHeaders())
        }
    }

    private func handleGetServices() async -> HTTPResponse {
        let services = await syncEngine.getServices()
        let serviceList = services.map { encodeServiceInfo($0) }
        return HTTPResponse(statusCode: 200, bodyRaw: encodeJSONArray(serviceList))
    }

    private func handleGetServiceStatus(serviceId: String) async -> HTTPResponse {
        guard let info = await syncEngine.getServiceStatus(serviceId) else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        return HTTPResponse(statusCode: 200, bodyRaw: encodeServiceInfo(info))
    }

    private func handleTriggerSync(serviceId: String) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            NSLog("LocalServer triggerSync missing service %@", serviceId)
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        NSLog("LocalServer triggerSync requested for %@", serviceId)
        await syncEngine.triggerSync(serviceId: serviceId)
        NSLog("LocalServer triggerSync dispatched for %@", serviceId)
        return HTTPResponse(statusCode: 200, body: ["triggered": "true"])
    }

    private func handleSetResourceEnabled(serviceId: String, resourceName: String, body: Data?) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: ["error": "Service not found", "serviceId": serviceId])
        }
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let enabled = json["enabled"] as? Bool else {
            return HTTPResponse(statusCode: 400, body: ["error": "Body must be {\"enabled\": bool}"])
        }
        await syncEngine.setResourceEnabled(serviceId: serviceId, resourceName: resourceName, enabled: enabled)
        return HTTPResponse(statusCode: 200, body: ["serviceId": serviceId, "resource": resourceName, "enabled": enabled ? "true" : "false"])
    }

    private func handleSetFileExcluded(serviceId: String, body: Data?) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: ["error": "Service not found", "serviceId": serviceId])
        }
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let relativePath = json["path"] as? String,
              let excluded = json["excluded"] as? Bool else {
            return HTTPResponse(statusCode: 400, body: ["error": "Body must be {\"path\": \"...\", \"excluded\": bool}"])
        }
        await syncEngine.setFileExcluded(serviceId: serviceId, relativePath: relativePath, excluded: excluded)
        return HTTPResponse(statusCode: 200, body: ["serviceId": serviceId, "path": relativePath, "excluded": excluded ? "true" : "false"])
    }

    private func handleGetHistory(serviceId: String, limit: Int) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        let entries = await syncEngine.getHistory(serviceId: serviceId, limit: limit)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            return HTTPResponse(statusCode: 500, body: ["error": "Failed to encode history"])
        }
        return HTTPResponse(statusCode: 200, bodyRaw: data)
    }

    private func handleListSQLTables(serviceId: String) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }

        do {
            let data = try await syncEngine.listSQLTables(serviceId: serviceId)
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleDescribeSQLTable(serviceId: String, queryItems: [String: String]) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        guard let table = queryItems["table"], !table.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'table' query parameter"])
        }

        do {
            let data = try await syncEngine.describeSQLTable(serviceId: serviceId, table: table)
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleQuerySQL(serviceId: String, body: Data?) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        guard let query = parseJSONString(body, key: "query"), !query.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'query' in request body"])
        }

        do {
            let data = try await syncEngine.querySQL(serviceId: serviceId, query: query)
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleSearchSQL(serviceId: String, queryItems: [String: String]) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        guard let text = queryItems["text"], !text.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'text' query parameter"])
        }
        let resources = queryItems["resources"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        do {
            let data = try await syncEngine.searchSQL(
                serviceId: serviceId,
                text: text,
                resources: resources?.isEmpty == false ? resources : nil
            )
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleGetSQLRecord(serviceId: String, queryItems: [String: String]) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        guard let resource = queryItems["resource"], !resource.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'resource' query parameter"])
        }
        guard let recordId = queryItems["recordId"], !recordId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'recordId' query parameter"])
        }

        do {
            let data = try await syncEngine.getRecordByID(
                serviceId: serviceId,
                resource: resource,
                recordId: recordId
            )
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleOpenSQLRecordFile(serviceId: String, queryItems: [String: String]) async -> HTTPResponse {
        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        guard let resource = queryItems["resource"], !resource.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'resource' query parameter"])
        }
        guard let recordId = queryItems["recordId"], !recordId.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'recordId' query parameter"])
        }

        let surfaceValue = queryItems["surface"] ?? SQLiteMirror.FileSurface.canonical.rawValue
        guard let surface = SQLiteMirror.FileSurface(rawValue: surfaceValue) else {
            return HTTPResponse(statusCode: 400, body: ["error": "Invalid 'surface' query parameter"])
        }

        do {
            let data = try await syncEngine.openRecordFile(
                serviceId: serviceId,
                resource: resource,
                recordId: recordId,
                surface: surface
            )
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return sqlErrorResponse(error)
        }
    }

    private func handleValidateAdapter(body: Data?) -> HTTPResponse {
        guard let body, !body.isEmpty else {
            return HTTPResponse(statusCode: 400, body: ["error": "Request body is required"])
        }

        do {
            _ = try JSONDecoder().decode(AdapterConfig.self, from: body)
            return HTTPResponse(statusCode: 200, body: ["valid": "true"])
        } catch {
            return HTTPResponse(statusCode: 400, body: [
                "valid": "false",
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Browser Route Handlers

    private func handleBrowserOpen() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        do {
            try await delegate.openBrowser()
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserNavigate(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let url = parseJSONString(body, key: "url") else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'url' in request body"])
        }
        do {
            // Auto-open browser if not open
            if !(await delegate.isBrowserOpen()) {
                try await delegate.openBrowser()
            }
            let finalURL = try await delegate.navigate(to: url)
            return HTTPResponse(statusCode: 200, body: ["status": "ok", "url": finalURL])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserScreenshot(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        let width = parseJSONInt(body, key: "width")
        let height = parseJSONInt(body, key: "height")
        do {
            let pngData = try await delegate.captureScreenshot(width: width, height: height)
            let base64 = pngData.base64EncodedString()
            let json: [String: Any] = [
                "image": base64,
                "size": pngData.count
            ]
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserDOM(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        let selector = parseJSONString(body, key: "selector")
        do {
            let html = try await delegate.getDOM(selector: selector)
            let json: [String: Any] = ["html": html]
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
            return HTTPResponse(statusCode: 200, bodyRaw: data)
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserClick(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let selector = parseJSONString(body, key: "selector") else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'selector' in request body"])
        }
        do {
            try await delegate.click(selector: selector)
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserType(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let selector = parseJSONString(body, key: "selector"),
              let text = parseJSONString(body, key: "text") else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'selector' or 'text' in request body"])
        }
        do {
            try await delegate.type(selector: selector, text: text)
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserEvaluate(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let code = parseJSONString(body, key: "code") else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'code' in request body"])
        }
        do {
            let result = try await delegate.evaluateJS(code)
            return HTTPResponse(statusCode: 200, body: ["result": result])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserGetURL() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        let url = await delegate.getCurrentURL()
        return HTTPResponse(statusCode: 200, body: ["url": url ?? ""])
    }

    private func handleBrowserWait(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let selector = parseJSONString(body, key: "selector") else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing 'selector' in request body"])
        }
        let timeout = TimeInterval(parseJSONInt(body, key: "timeout") ?? 5000) / 1000.0
        do {
            try await delegate.waitFor(selector: selector, timeout: timeout)
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserStatus() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 200, body: ["open": "false"])
        }
        let isOpen = await delegate.isBrowserOpen()
        let url = await delegate.getCurrentURL()
        var result: [String: String] = ["open": isOpen ? "true" : "false"]
        if let url { result["url"] = url }
        return HTTPResponse(statusCode: 200, body: result)
    }

    private func handleBrowserBack() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        do {
            try await delegate.goBack()
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserForward() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        do {
            try await delegate.goForward()
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserReload() async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        do {
            try await delegate.reload()
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func handleBrowserScroll(body: Data?) async -> HTTPResponse {
        guard let delegate = browserDelegate else {
            return HTTPResponse(statusCode: 503, body: ["error": "Browser not available"])
        }
        guard let dirStr = parseJSONString(body, key: "direction"),
              let direction = ScrollDirection(rawValue: dirStr) else {
            return HTTPResponse(statusCode: 400, body: ["error": "Missing or invalid 'direction' (up/down/left/right)"])
        }
        let amount = parseJSONInt(body, key: "amount")
        do {
            try await delegate.scroll(direction: direction, amount: amount)
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        } catch {
            return browserErrorResponse(error)
        }
    }

    private func browserErrorResponse(_ error: Error) -> HTTPResponse {
        if let browserError = error as? BrowserError {
            switch browserError {
            case .windowNotOpen:
                return HTTPResponse(statusCode: 503, body: ["error": browserError.localizedDescription])
            case .elementNotFound:
                return HTTPResponse(statusCode: 404, body: ["error": browserError.localizedDescription])
            case .timeout:
                return HTTPResponse(statusCode: 408, body: ["error": browserError.localizedDescription])
            case .evaluationFailed, .navigationFailed:
                return HTTPResponse(statusCode: 400, body: ["error": browserError.localizedDescription])
            }
        }
        return HTTPResponse(statusCode: 500, body: ["error": error.localizedDescription])
    }

    private func sqlErrorResponse(_ error: Error) -> HTTPResponse {
        if let mirrorError = error as? SQLiteMirror.MirrorError {
            switch mirrorError {
            case .missingDatabase, .notFound:
                return HTTPResponse(statusCode: 404, body: ["error": mirrorError.localizedDescription])
            case .invalidQuery:
                return HTTPResponse(statusCode: 400, body: ["error": mirrorError.localizedDescription])
            case .openDatabase, .sqlite:
                return HTTPResponse(statusCode: 500, body: ["error": mirrorError.localizedDescription])
            }
        }
        return HTTPResponse(statusCode: 500, body: ["error": error.localizedDescription])
    }

    // MARK: - JSON Body Parsing Helpers

    private func parseJSONString(_ body: Data?, key: String) -> String? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json[key] as? String
    }

    private func parseJSONInt(_ body: Data?, key: String) -> Int? {
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return json[key] as? Int
    }

    private func handleOpenURL(body: Data?) -> HTTPResponse {
        guard let rawURL = parseJSONString(body, key: "url"),
              let url = URL(string: rawURL) else {
            NSLog("LocalServer openURL missing or invalid url payload")
            return HTTPResponse(statusCode: 400, body: ["error": "Missing or invalid url"])
        }

        let preferredBrowser = parseJSONString(body, key: "preferredBrowser")
        NSLog("LocalServer openURL requested url=%@ preferredBrowser=%@", url.absoluteString, preferredBrowser ?? "<default>")

        #if os(macOS)
        let workspace = NSWorkspace.shared
        if preferredBrowser == "chrome",
           let chromeURL = workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: chromeURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("LocalServer failed opening Chrome for %@: %@", url.absoluteString, error.localizedDescription)
                    workspace.open(url)
                } else {
                    NSLog("LocalServer opened Chrome for %@", url.absoluteString)
                }
            }
            return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        }

        workspace.open(url)
        NSLog("LocalServer opened default browser for %@", url.absoluteString)
        return HTTPResponse(statusCode: 200, body: ["status": "ok"])
        #else
        return HTTPResponse(statusCode: 503, body: ["error": "Opening external URLs is not supported on this platform"])
        #endif
    }

    private func handleOpenApp(queryItems: [String: String]) -> HTTPResponse {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty else {
            NSLog("LocalServer handleOpenApp missing service parameter")
            return HTTPResponse(statusCode: 400, body: ["error": "Missing service parameter"])
        }
        let relativePath: String? = queryItems["path"].flatMap { $0.isEmpty ? nil : $0 }
        NSLog("LocalServer handleOpenApp serviceId=%@ path=%@", serviceId, relativePath ?? "")
        openAppCallback?(serviceId, relativePath)
        return HTTPResponse(statusCode: 200, body: ["status": "ok"])
    }

    // MARK: - Route Matching

    /// Match routes like /api/services/:id/status where pattern="/api/services/" and suffix="/status"
    private func matchRoute(path: String, pattern: String, suffix: String) -> String? {
        guard path.hasPrefix(pattern) && path.hasSuffix(suffix) else { return nil }
        let idPart = String(path.dropFirst(pattern.count).dropLast(suffix.count))
        guard !idPart.isEmpty, !idPart.contains("/") else { return nil }
        return idPart
    }

    // MARK: - Response Sending

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON Encoding Helpers

    private func encodeServiceInfo(_ info: ServiceInfo) -> Data {
        var dict: [String: Any] = [
            "serviceId": info.serviceId,
            "displayName": info.displayName,
            "status": info.status.rawValue,
            "fileCount": info.fileCount
        ]
        if let lastSync = info.lastSyncTime {
            dict["lastSyncTime"] = ISO8601DateFormatter().string(from: lastSync)
        }
        if let error = info.errorMessage {
            dict["errorMessage"] = error
        }
        if let siteUrl = info.config.siteUrl {
            dict["siteUrl"] = siteUrl
        }
        if let dashboardUrl = info.config.dashboardUrl {
            dict["dashboardUrl"] = dashboardUrl
        }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    private func encodeJSONArray(_ items: [Data]) -> Data {
        // Build a JSON array from individually serialized objects
        var result = Data("[".utf8)
        for (index, item) in items.enumerated() {
            if index > 0 { result.append(Data(",".utf8)) }
            result.append(item)
        }
        result.append(Data("]".utf8))
        return result
    }

    private func encodeJSON(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private func liteManagerHTMLURL() -> URL? {
        liteManagerRootURL()?.appendingPathComponent("index.html", isDirectory: false)
    }

    private func liteManagerRootURL() -> URL? {
        let bundleCandidates = [
            Bundle.main.url(forResource: "website", withExtension: nil),
            Bundle.main.url(forResource: "LiteManager", withExtension: nil)
        ]
        if let match = bundleCandidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }) {
            return match
        }

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRootURL = sourceFileURL
            .deletingLastPathComponent() // LocalServer.swift
            .deletingLastPathComponent() // Server
            .deletingLastPathComponent() // API2FileCore
            .deletingLastPathComponent() // Sources
        let developmentURL = repoRootURL.appendingPathComponent("website", isDirectory: true)
        return FileManager.default.fileExists(atPath: developmentURL.appendingPathComponent("index.html").path) ? developmentURL : nil
    }

    private func shouldHideLitePath(_ relativePath: String, includeHidden: Bool) -> Bool {
        let segments = relativePath.split(separator: "/").map(String.init)
        let hasHiddenSegment = segments.contains { $0.hasPrefix(".") }
        if relativePath.hasPrefix(".git/") || relativePath == ".git" {
            return true
        }
        return hasHiddenSegment && !includeHidden
    }

    private func isLiteEditable(relativePath: String, fileExtension: String) -> Bool {
        if relativePath.hasPrefix(".api2file/") || relativePath.hasPrefix(".git/") {
            return false
        }
        let editableExtensions: Set<String> = [
            "txt", "md", "markdown", "json", "yaml", "yml", "html", "htm", "svg",
            "csv", "ics", "vcf", "eml", "xml", "js", "css", "log"
        ]
        return editableExtensions.contains(fileExtension)
    }

    private func isLiteMutable(relativePath: String) -> Bool {
        !(relativePath.hasPrefix(".api2file/") || relativePath == ".api2file" || relativePath.hasPrefix(".git/") || relativePath == ".git")
    }

    private func validatedLiteFileURL(queryItems: [String: String]) async -> URL? {
        guard let serviceId = queryItems["service"], !serviceId.isEmpty,
              let path = queryItems["path"], !path.isEmpty else {
            return nil
        }
        return await validatedLiteServicePathURL(serviceId: serviceId, path: path)
    }

    private func validatedLiteServicePathURL(serviceId: String, path: String) async -> URL? {
        guard !path.hasPrefix("/") else {
            return nil
        }

        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty,
              !segments.contains(".."),
              !segments.contains(where: { $0.isEmpty }) else {
            return nil
        }

        guard await syncEngine.getServiceStatus(serviceId) != nil else {
            return nil
        }

        let rootURL = await syncEngine.getSyncRootURL()
        let serviceRoot = rootURL.appendingPathComponent(serviceId, isDirectory: true).standardizedFileURL
        let itemURL = serviceRoot.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard itemURL.path.hasPrefix(serviceRoot.path + "/") else {
            return nil
        }
        return itemURL
    }

    private func contentType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }

        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt", "log", "csv", "yaml", "yml", "json", "js", "css", "xml", "ics", "vcf", "eml":
            return "text/plain; charset=utf-8"
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        default:
            return "application/octet-stream"
        }
    }

    private func liteCORSHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Methods", "GET, PUT, POST, DELETE, OPTIONS"),
            ("Access-Control-Allow-Headers", "Content-Type")
        ]
    }

    // MARK: - Header Parsing

    private static func parseContentLength(from headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }
}

// MARK: - HTTP Request

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [(String, String)]
    let body: Data?

    static func parse(from data: Data) -> HTTPRequest? {
        guard let headerEnd = data.findHeaderEnd() else { return nil }

        let headerData = data[data.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let rawPath = String(parts[1])

        // Parse query string before stripping
        let pathParts = rawPath.split(separator: "?", maxSplits: 1)
        let path = pathParts.first.map(String.init) ?? rawPath
        var queryItems: [String: String] = [:]
        if pathParts.count == 2 {
            let queryString = String(pathParts[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])
                    queryItems[key] = value
                }
            }
        }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let bodyStart = headerEnd + 4
        let body: Data? = bodyStart < data.count ? data[bodyStart...] as Data : nil

        return HTTPRequest(method: method, path: path, queryItems: queryItems, headers: headers, body: body)
    }
}

// MARK: - HTTP Response

private struct HTTPResponse {
    let statusCode: Int
    let bodyData: Data
    let contentType: String
    let headers: [(String, String)]

    init(statusCode: Int, body: [String: String]) {
        self.statusCode = statusCode
        self.bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        self.contentType = "application/json"
        self.headers = []
    }

    init(statusCode: Int, bodyRaw: Data, contentType: String = "application/json", headers: [(String, String)] = []) {
        self.statusCode = statusCode
        self.bodyData = bodyRaw
        self.contentType = contentType
        self.headers = headers
    }

    var statusText: String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    func serialize() -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(bodyData.count)\r\n"
        for (name, value) in headers {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(bodyData)
        return data
    }
}

// MARK: - Data Extension for Header Parsing

private extension Data {
    /// Find the index of the \r\n\r\n sequence that separates HTTP headers from body
    func findHeaderEnd() -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard count >= 4 else { return nil }
        for i in 0...(count - 4) {
            if self[startIndex + i] == separator[0]
                && self[startIndex + i + 1] == separator[1]
                && self[startIndex + i + 2] == separator[2]
                && self[startIndex + i + 3] == separator[3] {
                return startIndex + i
            }
        }
        return nil
    }
}
