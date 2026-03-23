import Foundation
import Network

/// Lightweight HTTP server using NWListener for local control API.
/// Designed for AI agents and scripts to query and control the sync engine.
public actor LocalServer {
    private let port: UInt16
    private let syncEngine: SyncEngine
    private var listener: NWListener?

    public init(port: UInt16 = 21567, syncEngine: SyncEngine) {
        self.port = port
        self.syncEngine = syncEngine
    }

    // MARK: - Lifecycle

    public func start() throws {
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
                break
            case .failed(let error):
                print("[LocalServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    public func stop() {
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

        // POST /api/services/:id/sync
        if method == "POST", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/sync") {
            return await handleTriggerSync(serviceId: serviceId)
        }

        // POST /api/adapters/validate
        if method == "POST" && path == "/api/adapters/validate" {
            return handleValidateAdapter(body: request.body)
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
            return HTTPResponse(statusCode: 404, body: [
                "error": "Service not found",
                "serviceId": serviceId
            ])
        }
        await syncEngine.triggerSync(serviceId: serviceId)
        return HTTPResponse(statusCode: 200, body: ["triggered": "true"])
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
                    queryItems[String(kv[0])] = String(kv[1])
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

    init(statusCode: Int, body: [String: String]) {
        self.statusCode = statusCode
        self.bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    init(statusCode: Int, bodyRaw: Data) {
        self.statusCode = statusCode
        self.bodyData = bodyRaw
    }

    var statusText: String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    func serialize() -> Data {
        let header = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
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
