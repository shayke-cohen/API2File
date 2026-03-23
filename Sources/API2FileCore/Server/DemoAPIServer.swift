import Foundation
import Network

/// A standalone demo REST API server for testing API2File end-to-end.
/// Provides multiple resource APIs with CRUD operations, backed by in-memory storage.
/// Each resource showcases a different file format.
/// This is the first "cloud service" you can sync with — no account needed.
public actor DemoAPIServer {
    private let port: UInt16
    private var listener: NWListener?

    // Resource stores
    private var tasks: [DemoTask] = []
    private var contacts: [DemoContact] = []
    private var events: [DemoEvent] = []
    private var notes: [DemoNote] = []
    private var pages: [DemoPage] = []
    private var config: DemoConfig = DemoConfig.seed
    private var services: [DemoService] = []
    private var incidents: [DemoIncident] = []

    // Auto-increment counters
    private var nextTaskId: Int = 1
    private var nextContactId: Int = 1
    private var nextEventId: Int = 1
    private var nextNoteId: Int = 1
    private var nextPageId: Int = 1
    private var nextServiceId: Int = 1
    private var nextIncidentId: Int = 1

    public init(port: UInt16 = 8089) {
        self.port = port
        // Inline seed to avoid actor-isolation issues in init
        self.tasks = DemoTask.seedData
        self.nextTaskId = 4
        self.contacts = DemoContact.seedData
        self.nextContactId = 3
        self.events = DemoEvent.seedData
        self.nextEventId = 4
        self.notes = DemoNote.seedData
        self.nextNoteId = 3
        self.pages = DemoPage.seedData
        self.nextPageId = 3
        self.config = DemoConfig.seed
        self.services = DemoService.seedData
        self.nextServiceId = 4
        self.incidents = DemoIncident.seedData
        self.nextIncidentId = 5
    }

    private func seedAll() {
        tasks = DemoTask.seedData
        nextTaskId = (tasks.map(\.id).max() ?? 0) + 1

        contacts = DemoContact.seedData
        nextContactId = (contacts.map(\.id).max() ?? 0) + 1

        events = DemoEvent.seedData
        nextEventId = (events.map(\.id).max() ?? 0) + 1

        notes = DemoNote.seedData
        nextNoteId = (notes.map(\.id).max() ?? 0) + 1

        pages = DemoPage.seedData
        nextPageId = (pages.map(\.id).max() ?? 0) + 1

        config = DemoConfig.seed

        services = DemoService.seedData
        nextServiceId = (services.map(\.id).max() ?? 0) + 1

        incidents = DemoIncident.seedData
        nextIncidentId = (incidents.map(\.id).max() ?? 0) + 1
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
                print("[DemoAPI]   GET/POST       /api/tasks         — task list (CSV)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/tasks/:id")
                print("[DemoAPI]   GET/POST       /api/contacts      — contacts (VCF)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/contacts/:id")
                print("[DemoAPI]   GET/POST       /api/events        — events (ICS)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/events/:id")
                print("[DemoAPI]   GET/POST       /api/notes         — notes (Markdown)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/notes/:id")
                print("[DemoAPI]   GET/POST       /api/pages         — pages (HTML)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/pages/:id")
                print("[DemoAPI]   GET/PUT         /api/config        — settings (JSON)")
                print("[DemoAPI]   GET/POST       /api/services      — services (JSON)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/services/:id")
                print("[DemoAPI]   GET/POST       /api/incidents     — incidents (CSV)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/incidents/:id")
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

    /// Get current contacts (for testing assertions)
    public func getContacts() -> [DemoContact] {
        contacts
    }

    /// Get current events (for testing assertions)
    public func getEvents() -> [DemoEvent] {
        events
    }

    /// Get current notes (for testing assertions)
    public func getNotes() -> [DemoNote] {
        notes
    }

    /// Get current pages (for testing assertions)
    public func getPages() -> [DemoPage] {
        pages
    }

    /// Get current config (for testing assertions)
    public func getConfig() -> DemoConfig {
        config
    }

    /// Get current services (for testing assertions)
    public func getServices() -> [DemoService] {
        services
    }

    /// Get current incidents (for testing assertions)
    public func getIncidents() -> [DemoIncident] {
        incidents
    }

    /// Reset to seed data (for testing)
    public func reset() {
        seedAll()
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

        // Route to resource handlers
        if path == "/api/tasks" || path.hasPrefix("/api/tasks/") {
            routeTasks(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/contacts" || path.hasPrefix("/api/contacts/") {
            routeContacts(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/events" || path.hasPrefix("/api/events/") {
            routeEvents(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/notes" || path.hasPrefix("/api/notes/") {
            routeNotes(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/pages" || path.hasPrefix("/api/pages/") {
            routePages(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/config" {
            routeConfig(method: method, body: body, connection: connection)
        } else if path == "/api/services" || path.hasPrefix("/api/services/") {
            routeServices(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/incidents" || path.hasPrefix("/api/incidents/") {
            routeIncidents(method: method, path: path, body: body, connection: connection)
        } else {
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Tasks Routes

    private func routeTasks(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/tasks"):
            let tasksJSON = tasks.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: tasksJSON, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/tasks/".count))
            if let id = Int(idStr), let task = tasks.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: task.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Task not found"], connection: connection)
            }

        case ("POST", "/api/tasks"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let task = DemoTask(
                    id: nextTaskId,
                    name: dict["name"] as? String ?? "Untitled",
                    status: dict["status"] as? String ?? "todo",
                    priority: dict["priority"] as? String ?? "medium",
                    assignee: dict["assignee"] as? String ?? "",
                    dueDate: dict["dueDate"] as? String ?? ""
                )
                nextTaskId += 1
                tasks.append(task)
                sendJSONDict(statusCode: 201, body: task.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
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

        case ("DELETE", _):
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

    // MARK: - Contacts Routes

    private func routeContacts(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/contacts"):
            let items = contacts.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/contacts/".count))
            if let id = Int(idStr), let item = contacts.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Contact not found"], connection: connection)
            }

        case ("POST", "/api/contacts"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoContact(
                    id: nextContactId,
                    firstName: dict["firstName"] as? String ?? "",
                    lastName: dict["lastName"] as? String ?? "",
                    email: dict["email"] as? String ?? "",
                    phone: dict["phone"] as? String ?? "",
                    company: dict["company"] as? String ?? ""
                )
                nextContactId += 1
                contacts.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/contacts/".count))
            if let id = Int(idStr),
               let idx = contacts.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = contacts[idx]
                if let v = dict["firstName"] as? String { item.firstName = v }
                if let v = dict["lastName"] as? String { item.lastName = v }
                if let v = dict["email"] as? String { item.email = v }
                if let v = dict["phone"] as? String { item.phone = v }
                if let v = dict["company"] as? String { item.company = v }
                contacts[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Contact not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/contacts/".count))
            if let id = Int(idStr), let idx = contacts.firstIndex(where: { $0.id == id }) {
                contacts.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Contact not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Events Routes

    private func routeEvents(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/events"):
            let items = events.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/events/".count))
            if let id = Int(idStr), let item = events.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Event not found"], connection: connection)
            }

        case ("POST", "/api/events"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoEvent(
                    id: nextEventId,
                    title: dict["title"] as? String ?? "Untitled Event",
                    startDate: dict["startDate"] as? String ?? "",
                    endDate: dict["endDate"] as? String ?? "",
                    location: dict["location"] as? String ?? "",
                    description: dict["description"] as? String ?? "",
                    status: dict["status"] as? String ?? "confirmed"
                )
                nextEventId += 1
                events.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/events/".count))
            if let id = Int(idStr),
               let idx = events.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = events[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["startDate"] as? String { item.startDate = v }
                if let v = dict["endDate"] as? String { item.endDate = v }
                if let v = dict["location"] as? String { item.location = v }
                if let v = dict["description"] as? String { item.description = v }
                if let v = dict["status"] as? String { item.status = v }
                events[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Event not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/events/".count))
            if let id = Int(idStr), let idx = events.firstIndex(where: { $0.id == id }) {
                events.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Event not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Notes Routes

    private func routeNotes(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/notes"):
            let items = notes.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/notes/".count))
            if let id = Int(idStr), let item = notes.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Note not found"], connection: connection)
            }

        case ("POST", "/api/notes"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoNote(
                    id: nextNoteId,
                    title: dict["title"] as? String ?? "Untitled Note",
                    content: dict["content"] as? String ?? ""
                )
                nextNoteId += 1
                notes.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/notes/".count))
            if let id = Int(idStr),
               let idx = notes.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = notes[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["content"] as? String { item.content = v }
                notes[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Note not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/notes/".count))
            if let id = Int(idStr), let idx = notes.firstIndex(where: { $0.id == id }) {
                notes.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Note not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Pages Routes

    private func routePages(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/pages"):
            let items = pages.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/pages/".count))
            if let id = Int(idStr), let item = pages.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Page not found"], connection: connection)
            }

        case ("POST", "/api/pages"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoPage(
                    id: nextPageId,
                    title: dict["title"] as? String ?? "Untitled Page",
                    slug: dict["slug"] as? String ?? "untitled",
                    content: dict["content"] as? String ?? ""
                )
                nextPageId += 1
                pages.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/pages/".count))
            if let id = Int(idStr),
               let idx = pages.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = pages[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["slug"] as? String { item.slug = v }
                if let v = dict["content"] as? String { item.content = v }
                pages[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Page not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/pages/".count))
            if let id = Int(idStr), let idx = pages.firstIndex(where: { $0.id == id }) {
                pages.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Page not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Config Routes

    private func routeConfig(method: String, body: Data?, connection: NWConnection) {
        switch method {
        case "GET":
            sendJSONDict(statusCode: 200, body: config.toDict(), connection: connection)

        case "PUT":
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let v = dict["siteName"] as? String { config.siteName = v }
                if let v = dict["theme"] as? String { config.theme = v }
                if let v = dict["language"] as? String { config.language = v }
                if let v = dict["timezone"] as? String { config.timezone = v }
                if let v = dict["notifications"] as? Bool { config.notifications = v }
                sendJSONDict(statusCode: 200, body: config.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Services Routes

    private func routeServices(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/services"):
            let items = services.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/services/".count))
            if let id = Int(idStr), let item = services.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Service not found"], connection: connection)
            }

        case ("POST", "/api/services"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoService(
                    id: nextServiceId,
                    name: dict["name"] as? String ?? "unnamed-service",
                    status: dict["status"] as? String ?? "healthy",
                    uptime: dict["uptime"] as? Double ?? 100.0,
                    lastChecked: dict["lastChecked"] as? String ?? "",
                    responseTimeMs: dict["responseTimeMs"] as? Int ?? 0,
                    version: dict["version"] as? String ?? "0.0.1"
                )
                nextServiceId += 1
                services.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/services/".count))
            if let id = Int(idStr),
               let idx = services.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = services[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["status"] as? String { item.status = v }
                if let v = dict["uptime"] as? Double { item.uptime = v }
                if let v = dict["lastChecked"] as? String { item.lastChecked = v }
                if let v = dict["responseTimeMs"] as? Int { item.responseTimeMs = v }
                if let v = dict["version"] as? String { item.version = v }
                services[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Service not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/services/".count))
            if let id = Int(idStr), let idx = services.firstIndex(where: { $0.id == id }) {
                services.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Service not found"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Incidents Routes

    private func routeIncidents(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/incidents"):
            let items = incidents.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)

        case ("GET", _):
            let idStr = String(path.dropFirst("/api/incidents/".count))
            if let id = Int(idStr), let item = incidents.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Incident not found"], connection: connection)
            }

        case ("POST", "/api/incidents"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoIncident(
                    id: nextIncidentId,
                    timestamp: dict["timestamp"] as? String ?? "",
                    severity: dict["severity"] as? String ?? "info",
                    service: dict["service"] as? String ?? "",
                    message: dict["message"] as? String ?? "",
                    resolved: dict["resolved"] as? Bool ?? false
                )
                nextIncidentId += 1
                incidents.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/incidents/".count))
            if let id = Int(idStr),
               let idx = incidents.firstIndex(where: { $0.id == id }),
               let body,
               let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = incidents[idx]
                if let v = dict["timestamp"] as? String { item.timestamp = v }
                if let v = dict["severity"] as? String { item.severity = v }
                if let v = dict["service"] as? String { item.service = v }
                if let v = dict["message"] as? String { item.message = v }
                if let v = dict["resolved"] as? Bool { item.resolved = v }
                incidents[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Incident not found"], connection: connection)
            }

        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/incidents/".count))
            if let id = Int(idStr), let idx = incidents.firstIndex(where: { $0.id == id }) {
                incidents.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Incident not found"], connection: connection)
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

    static let seedData: [DemoTask] = [
        DemoTask(id: 1, name: "Buy groceries", status: "todo", priority: "medium", assignee: "Alice", dueDate: "2026-03-25"),
        DemoTask(id: 2, name: "Fix login bug", status: "in-progress", priority: "high", assignee: "Bob", dueDate: "2026-03-24"),
        DemoTask(id: 3, name: "Write docs", status: "done", priority: "low", assignee: "Alice", dueDate: "2026-03-20"),
    ]
}

// MARK: - Demo Contact Model

public struct DemoContact: Codable, Sendable {
    public var id: Int
    public var firstName: String
    public var lastName: String
    public var email: String
    public var phone: String
    public var company: String

    public func toDict() -> [String: Any] {
        ["id": id, "firstName": firstName, "lastName": lastName, "email": email, "phone": phone, "company": company]
    }

    static let seedData: [DemoContact] = [
        DemoContact(id: 1, firstName: "Alice", lastName: "Johnson", email: "alice@example.com", phone: "+1-555-0101", company: "Acme Corp"),
        DemoContact(id: 2, firstName: "Bob", lastName: "Smith", email: "bob@example.com", phone: "+1-555-0102", company: "Globex Inc"),
    ]
}

// MARK: - Demo Event Model

public struct DemoEvent: Codable, Sendable {
    public var id: Int
    public var title: String
    public var startDate: String   // ISO 8601
    public var endDate: String
    public var location: String
    public var description: String
    public var status: String      // confirmed, tentative, cancelled

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "startDate": startDate, "endDate": endDate, "location": location, "description": description, "status": status]
    }

    static let seedData: [DemoEvent] = [
        DemoEvent(id: 1, title: "Team Standup", startDate: "2026-03-24T09:00:00Z", endDate: "2026-03-24T09:15:00Z", location: "Zoom", description: "Daily sync with the engineering team", status: "confirmed"),
        DemoEvent(id: 2, title: "Product Launch", startDate: "2026-04-15T14:00:00Z", endDate: "2026-04-15T16:00:00Z", location: "Main Conference Room", description: "Q2 product launch event and demo", status: "tentative"),
        DemoEvent(id: 3, title: "Design Review", startDate: "2026-03-26T11:00:00Z", endDate: "2026-03-26T12:00:00Z", location: "Room 42", description: "Review new landing page mockups", status: "confirmed"),
    ]
}

// MARK: - Demo Note Model

public struct DemoNote: Codable, Sendable {
    public var id: Int
    public var title: String
    public var content: String     // Markdown text

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "content": content]
    }

    static let seedData: [DemoNote] = [
        DemoNote(id: 1, title: "Meeting Notes", content: "# Meeting Notes\n\n## Attendees\n- Alice\n- Bob\n- Charlie\n\n## Action Items\n1. Update the roadmap\n2. Review pull requests\n3. Schedule follow-up\n\n## Decisions\n- Ship v2.0 by end of Q2\n- Hire two more engineers"),
        DemoNote(id: 2, title: "Ideas", content: "Some ideas for the next sprint:\n\n- Improve onboarding flow\n- Add dark mode support\n- Refactor the auth module"),
    ]
}

// MARK: - Demo Page Model

public struct DemoPage: Codable, Sendable {
    public var id: Int
    public var title: String
    public var slug: String
    public var content: String     // HTML

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "slug": slug, "content": content]
    }

    static let seedData: [DemoPage] = [
        DemoPage(id: 1, title: "Home", slug: "home", content: "<h1>Welcome</h1>\n<p>This is the home page of our demo site.</p>\n<ul>\n  <li><a href=\"/about\">About Us</a></li>\n  <li><a href=\"/contact\">Contact</a></li>\n</ul>"),
        DemoPage(id: 2, title: "About", slug: "about", content: "<h1>About Us</h1>\n<p>We are a <strong>small team</strong> building great tools.</p>\n<h2>Our Mission</h2>\n<p>To make file-based API syncing <em>effortless</em>.</p>"),
    ]
}

// MARK: - Demo Config Model

public struct DemoConfig: Codable, Sendable {
    public var siteName: String
    public var theme: String
    public var language: String
    public var timezone: String
    public var notifications: Bool

    public func toDict() -> [String: Any] {
        ["siteName": siteName, "theme": theme, "language": language, "timezone": timezone, "notifications": notifications]
    }

    static let seed = DemoConfig(
        siteName: "My Demo Site",
        theme: "light",
        language: "en",
        timezone: "America/New_York",
        notifications: true
    )
}

// MARK: - Demo Service Model

public struct DemoService: Codable, Sendable {
    public var id: Int
    public var name: String
    public var status: String      // healthy, degraded, down
    public var uptime: Double      // percentage, e.g. 99.95
    public var lastChecked: String // ISO 8601
    public var responseTimeMs: Int
    public var version: String

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "status": status, "uptime": uptime, "lastChecked": lastChecked, "responseTimeMs": responseTimeMs, "version": version]
    }

    static let seedData: [DemoService] = [
        DemoService(id: 1, name: "auth-service", status: "healthy", uptime: 99.99, lastChecked: "2026-03-23T10:30:00Z", responseTimeMs: 45, version: "3.2.1"),
        DemoService(id: 2, name: "payment-api", status: "degraded", uptime: 98.50, lastChecked: "2026-03-23T10:30:00Z", responseTimeMs: 320, version: "2.0.4"),
        DemoService(id: 3, name: "search-index", status: "healthy", uptime: 99.95, lastChecked: "2026-03-23T10:30:00Z", responseTimeMs: 12, version: "1.8.0"),
    ]
}

// MARK: - Demo Incident Model

public struct DemoIncident: Codable, Sendable {
    public var id: Int
    public var timestamp: String   // ISO 8601
    public var severity: String    // info, warning, critical
    public var service: String
    public var message: String
    public var resolved: Bool

    public func toDict() -> [String: Any] {
        ["id": id, "timestamp": timestamp, "severity": severity, "service": service, "message": message, "resolved": resolved]
    }

    static let seedData: [DemoIncident] = [
        DemoIncident(id: 1, timestamp: "2026-03-23T08:00:00Z", severity: "info", service: "auth-service", message: "Routine key rotation completed", resolved: true),
        DemoIncident(id: 2, timestamp: "2026-03-23T09:15:00Z", severity: "warning", service: "payment-api", message: "Response time exceeding 300ms threshold", resolved: false),
        DemoIncident(id: 3, timestamp: "2026-03-23T09:45:00Z", severity: "critical", service: "payment-api", message: "Database connection pool exhausted", resolved: false),
        DemoIncident(id: 4, timestamp: "2026-03-23T10:00:00Z", severity: "info", service: "search-index", message: "Index rebuild completed successfully", resolved: true),
    ]
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
