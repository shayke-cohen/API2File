import Foundation
import Network

/// A standalone demo REST API server for testing API2File end-to-end.
/// Provides a simple "tasks" API with CRUD operations, backed by in-memory storage.
/// This is the first "cloud service" you can sync with — no account needed.
public actor DemoAPIServer {
    private let port: UInt16
    private var listener: NWListener?
    private var tasks: [DemoTask] = []
    private var nextId: Int = 1

    public init(port: UInt16 = 8089) {
        self.port = port
        // Seed with sample data
        self.tasks = [
            DemoTask(id: 1, name: "Buy groceries", status: "todo", priority: "medium", assignee: "Alice", dueDate: "2026-03-25"),
            DemoTask(id: 2, name: "Fix login bug", status: "in-progress", priority: "high", assignee: "Bob", dueDate: "2026-03-24"),
            DemoTask(id: 3, name: "Write docs", status: "done", priority: "low", assignee: "Alice", dueDate: "2026-03-20"),
        ]
        self.nextId = 4
    }

    // MARK: - Lifecycle

    public func start() throws {
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let nwListener = try NWListener(using: params, on: nwPort)

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleConnection(connection) }
        }

        nwListener.stateUpdateHandler = { state in
            if case .ready = state {
                print("[DemoAPI] Server running on http://localhost:\(self.port)")
                print("[DemoAPI] Endpoints:")
                print("[DemoAPI]   GET    /api/tasks       — list all tasks")
                print("[DemoAPI]   GET    /api/tasks/:id   — get one task")
                print("[DemoAPI]   POST   /api/tasks       — create task")
                print("[DemoAPI]   PUT    /api/tasks/:id   — update task")
                print("[DemoAPI]   DELETE /api/tasks/:id   — delete task")
            }
        }

        nwListener.start(queue: .global(qos: .userInitiated))
        self.listener = nwListener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// Get current tasks (for testing assertions)
    public func getTasks() -> [DemoTask] {
        tasks
    }

    /// Reset to seed data (for testing)
    public func reset() {
        tasks = [
            DemoTask(id: 1, name: "Buy groceries", status: "todo", priority: "medium", assignee: "Alice", dueDate: "2026-03-25"),
            DemoTask(id: 2, name: "Fix login bug", status: "in-progress", priority: "high", assignee: "Bob", dueDate: "2026-03-24"),
            DemoTask(id: 3, name: "Write docs", status: "done", priority: "low", assignee: "Alice", dueDate: "2026-03-20"),
        ]
        nextId = 4
    }

    // MARK: - Connection

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection: connection, accumulated: Data())
    }

    private func receiveRequest(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            var data = accumulated
            if let content { data.append(content) }

            if let headerEnd = data.findDemoHeaderEnd() {
                let headerString = String(data: data[data.startIndex..<headerEnd], encoding: .utf8) ?? ""
                let contentLength = Self.parseContentLength(from: headerString)
                let bodyStart = headerEnd + 4
                let bodyReceived = data.count - bodyStart

                if bodyReceived >= contentLength {
                    Task { await self.processRequest(data: data, connection: connection) }
                    return
                }
            }

            if isComplete || error != nil {
                if !data.isEmpty {
                    Task { await self.processRequest(data: data, connection: connection) }
                } else {
                    connection.cancel()
                }
                return
            }

            Task { await self.receiveRequest(connection: connection, accumulated: data) }
        }
    }

    // MARK: - Request Processing

    private func processRequest(data: Data, connection: NWConnection) {
        guard let (method, path, body) = parseHTTPRequest(data) else {
            sendJSON(statusCode: 400, body: ["error": "Bad Request"], connection: connection)
            return
        }

        // Route
        switch (method, path) {
        // GET /api/tasks
        case ("GET", "/api/tasks"):
            let tasksJSON = tasks.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: tasksJSON, connection: connection)

        // GET /api/tasks/:id
        case ("GET", _) where path.hasPrefix("/api/tasks/"):
            let idStr = String(path.dropFirst("/api/tasks/".count))
            if let id = Int(idStr), let task = tasks.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: task.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Task not found"], connection: connection)
            }

        // POST /api/tasks
        case ("POST", "/api/tasks"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let task = DemoTask(
                    id: nextId,
                    name: dict["name"] as? String ?? "Untitled",
                    status: dict["status"] as? String ?? "todo",
                    priority: dict["priority"] as? String ?? "medium",
                    assignee: dict["assignee"] as? String ?? "",
                    dueDate: dict["dueDate"] as? String ?? ""
                )
                nextId += 1
                tasks.append(task)
                sendJSONDict(statusCode: 201, body: task.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        // PUT /api/tasks/:id
        case ("PUT", _) where path.hasPrefix("/api/tasks/"):
            let idStr = String(path.dropFirst("/api/tasks/".count))
            if let id = Int(idStr),
               let idx = tasks.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var task = tasks[idx]
                if let name = dict["name"] as? String { task.name = name }
                if let status = dict["status"] as? String { task.status = status }
                if let priority = dict["priority"] as? String { task.priority = priority }
                if let assignee = dict["assignee"] as? String { task.assignee = assignee }
                if let dueDate = dict["dueDate"] as? String { task.dueDate = dueDate }
                tasks[idx] = task
                sendJSONDict(statusCode: 200, body: task.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Task not found"], connection: connection)
            }

        // DELETE /api/tasks/:id
        case ("DELETE", _) where path.hasPrefix("/api/tasks/"):
            let idStr = String(path.dropFirst("/api/tasks/".count))
            if let id = Int(idStr), let idx = tasks.firstIndex(where: { $0.id == id }) {
                tasks.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Task not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - HTTP Helpers

    private func parseHTTPRequest(_ data: Data) -> (method: String, path: String, body: Data?)? {
        guard let headerEnd = data.findDemoHeaderEnd() else { return nil }
        let headerData = data[data.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.split(separator: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        let bodyStart = headerEnd + 4
        let body: Data? = bodyStart < data.count ? Data(data[bodyStart...]) : nil

        return (method, path, body)
    }

    private func sendJSON(statusCode: Int, body: [String: String], connection: NWConnection) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        sendRawResponse(statusCode: statusCode, body: jsonData, connection: connection)
    }

    private func sendJSONDict(statusCode: Int, body: [String: Any], connection: NWConnection) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        sendRawResponse(statusCode: statusCode, body: jsonData, connection: connection)
    }

    private func sendJSONArray(statusCode: Int, body: [[String: Any]], connection: NWConnection) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        sendRawResponse(statusCode: statusCode, body: jsonData, connection: connection)
    }

    private func sendRawResponse(statusCode: Int, body: Data, connection: NWConnection) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Unknown"
        }

        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseContentLength(from headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }
}

// MARK: - Demo Task Model

public struct DemoTask: Codable, Sendable {
    public var id: Int
    public var name: String
    public var status: String
    public var priority: String
    public var assignee: String
    public var dueDate: String

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "status": status, "priority": priority, "assignee": assignee, "dueDate": dueDate]
    }
}

// MARK: - Data Extension

private extension Data {
    func findDemoHeaderEnd() -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
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
