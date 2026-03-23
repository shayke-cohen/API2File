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
    private var logos: [DemoLogo] = []
    private var photos: [DemoPhoto] = []
    private var documents: [DemoDocument] = []
    private var spreadsheets: [DemoSpreadsheet] = []
    private var reports: [DemoReport] = []
    private var presentations: [DemoPresentation] = []
    private var emails: [DemoEmail] = []
    private var bookmarks: [DemoBookmark] = []
    private var settings: DemoSettings = DemoSettings.seed
    private var snippets: [DemoSnippet] = []

    // Wix-like resource stores (string IDs, wrapped responses)
    private var wixContacts: [DemoWixContact] = []
    private var wixBlogPosts: [DemoWixBlogPost] = []
    private var wixProducts: [DemoWixProduct] = []
    private var wixBookings: [DemoWixBooking] = []
    private var wixCollections: [DemoWixCollection] = []

    // Auto-increment counters
    private var nextTaskId: Int = 1
    private var nextContactId: Int = 1
    private var nextEventId: Int = 1
    private var nextNoteId: Int = 1
    private var nextPageId: Int = 1
    private var nextServiceId: Int = 1
    private var nextIncidentId: Int = 1
    private var nextLogoId: Int = 1
    private var nextPhotoId: Int = 1
    private var nextDocumentId: Int = 1
    private var nextSpreadsheetId: Int = 1
    private var nextReportId: Int = 1
    private var nextPresentationId: Int = 1
    private var nextEmailId: Int = 1
    private var nextBookmarkId: Int = 1
    private var nextSnippetId: Int = 1

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
        self.logos = DemoLogo.seedData
        self.nextLogoId = 4
        self.photos = DemoPhoto.seedData
        self.nextPhotoId = 4
        self.documents = DemoDocument.seedData
        self.nextDocumentId = 3
        self.spreadsheets = DemoSpreadsheet.seedData
        self.nextSpreadsheetId = 4
        self.reports = DemoReport.seedData
        self.nextReportId = 3
        self.presentations = DemoPresentation.seedData
        self.nextPresentationId = 4
        self.emails = DemoEmail.seedData
        self.nextEmailId = 3
        self.bookmarks = DemoBookmark.seedData
        self.nextBookmarkId = 4
        self.settings = DemoSettings.seed
        self.snippets = DemoSnippet.seedData
        self.nextSnippetId = 3
        self.wixContacts = DemoWixContact.seedData
        self.wixBlogPosts = DemoWixBlogPost.seedData
        self.wixProducts = DemoWixProduct.seedData
        self.wixBookings = DemoWixBooking.seedData
        self.wixCollections = DemoWixCollection.seedData
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

        logos = DemoLogo.seedData
        nextLogoId = (logos.map(\.id).max() ?? 0) + 1

        photos = DemoPhoto.seedData
        nextPhotoId = (photos.map(\.id).max() ?? 0) + 1

        documents = DemoDocument.seedData
        nextDocumentId = (documents.map(\.id).max() ?? 0) + 1

        spreadsheets = DemoSpreadsheet.seedData
        nextSpreadsheetId = (spreadsheets.map(\.id).max() ?? 0) + 1

        reports = DemoReport.seedData
        nextReportId = (reports.map(\.id).max() ?? 0) + 1

        presentations = DemoPresentation.seedData
        nextPresentationId = (presentations.map(\.id).max() ?? 0) + 1

        emails = DemoEmail.seedData
        nextEmailId = (emails.map(\.id).max() ?? 0) + 1

        bookmarks = DemoBookmark.seedData
        nextBookmarkId = (bookmarks.map(\.id).max() ?? 0) + 1

        settings = DemoSettings.seed

        snippets = DemoSnippet.seedData
        nextSnippetId = (snippets.map(\.id).max() ?? 0) + 1

        wixContacts = DemoWixContact.seedData
        wixBlogPosts = DemoWixBlogPost.seedData
        wixProducts = DemoWixProduct.seedData
        wixBookings = DemoWixBooking.seedData
        wixCollections = DemoWixCollection.seedData
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
                print("[DemoAPI]   GET/POST       /api/logos         — SVG logos")
                print("[DemoAPI]   GET/PUT/DELETE  /api/logos/:id")
                print("[DemoAPI]   GET/POST       /api/photos        — PNG photos (base64)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/photos/:id")
                print("[DemoAPI]   GET/POST       /api/documents     — PDF documents (base64)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/documents/:id")
                print("[DemoAPI]   GET/POST       /api/spreadsheets  — spreadsheets (XLSX)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/spreadsheets/:id")
                print("[DemoAPI]   GET/POST       /api/reports       — reports (DOCX)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/reports/:id")
                print("[DemoAPI]   GET/POST       /api/presentations — presentations (PPTX)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/presentations/:id")
                print("[DemoAPI]   GET/POST       /api/emails        — emails (EML)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/emails/:id")
                print("[DemoAPI]   GET/POST       /api/bookmarks     — bookmarks (WEBLOC)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/bookmarks/:id")
                print("[DemoAPI]   GET/PUT         /api/settings      — settings (YAML)")
                print("[DemoAPI]   GET/POST       /api/snippets      — snippets (Text)")
                print("[DemoAPI]   GET/PUT/DELETE  /api/snippets/:id")
                print("[DemoAPI]   --- Wix-like endpoints (wrapped JSON) ---")
                print("[DemoAPI]   GET            /api/wix/contacts   — Wix CRM contacts")
                print("[DemoAPI]   GET            /api/wix/posts      — Wix blog posts")
                print("[DemoAPI]   GET            /api/wix/products   — Wix store products")
                print("[DemoAPI]   GET            /api/wix/services   — Wix bookings services")
                print("[DemoAPI]   GET            /api/wix/collections — Wix CMS collections")
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

    /// Get current logos (for testing assertions)
    public func getLogos() -> [DemoLogo] {
        logos
    }

    /// Get current photos (for testing assertions)
    public func getPhotos() -> [DemoPhoto] {
        photos
    }

    /// Get current documents (for testing assertions)
    public func getDocuments() -> [DemoDocument] {
        documents
    }

    /// Get current spreadsheets (for testing assertions)
    public func getSpreadsheets() -> [DemoSpreadsheet] {
        spreadsheets
    }

    /// Get current reports (for testing assertions)
    public func getReports() -> [DemoReport] {
        reports
    }

    /// Get current presentations (for testing assertions)
    public func getPresentations() -> [DemoPresentation] {
        presentations
    }

    /// Get current emails (for testing assertions)
    public func getEmails() -> [DemoEmail] {
        emails
    }

    /// Get current bookmarks (for testing assertions)
    public func getBookmarks() -> [DemoBookmark] {
        bookmarks
    }

    /// Get current settings (for testing assertions)
    public func getSettings() -> DemoSettings {
        settings
    }

    /// Get current snippets (for testing assertions)
    public func getSnippets() -> [DemoSnippet] {
        snippets
    }

    /// Get current Wix contacts (for testing assertions)
    public func getWixContacts() -> [DemoWixContact] {
        wixContacts
    }

    /// Get current Wix blog posts (for testing assertions)
    public func getWixBlogPosts() -> [DemoWixBlogPost] {
        wixBlogPosts
    }

    /// Get current Wix products (for testing assertions)
    public func getWixProducts() -> [DemoWixProduct] {
        wixProducts
    }

    /// Get current Wix bookings (for testing assertions)
    public func getWixBookings() -> [DemoWixBooking] {
        wixBookings
    }

    /// Get current Wix collections (for testing assertions)
    public func getWixCollections() -> [DemoWixCollection] {
        wixCollections
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
        } else if path == "/api/logos" || path.hasPrefix("/api/logos/") {
            routeLogos(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/photos" || path.hasPrefix("/api/photos/") {
            routePhotos(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/documents" || path.hasPrefix("/api/documents/") {
            routeDocuments(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/spreadsheets" || path.hasPrefix("/api/spreadsheets/") {
            routeSpreadsheets(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/reports" || path.hasPrefix("/api/reports/") {
            routeReports(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/presentations" || path.hasPrefix("/api/presentations/") {
            routePresentations(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/emails" || path.hasPrefix("/api/emails/") {
            routeEmails(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/bookmarks" || path.hasPrefix("/api/bookmarks/") {
            routeBookmarks(method: method, path: path, body: body, connection: connection)
        } else if path == "/api/settings" {
            routeSettings(method: method, body: body, connection: connection)
        } else if path == "/api/snippets" || path.hasPrefix("/api/snippets/") {
            routeSnippets(method: method, path: path, body: body, connection: connection)
        } else if path.hasPrefix("/api/wix/") {
            routeWix(method: method, path: path, body: body, connection: connection)
        } else if path == "/" || path == "/dashboard" {
            serveDashboard(connection: connection)
        } else {
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Web Dashboard

    private func serveDashboard(connection: NWConnection) {
        let html = Self.dashboardHTML
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(Data(html.utf8))
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static let dashboardHTML: String = {
        // Try SPM bundle first, then framework bundle
        let bundles: [Bundle] = {
            #if SWIFT_PACKAGE
            return [Bundle.module]
            #else
            return [Bundle(for: BundleToken.self), Bundle.main]
            #endif
        }()
        for bundle in bundles {
            if let url = bundle.url(forResource: "dashboard", withExtension: "html", subdirectory: "Web"),
               let html = try? String(contentsOf: url) {
                return html
            }
            if let url = bundle.url(forResource: "dashboard", withExtension: "html", subdirectory: "Resources/Web"),
               let html = try? String(contentsOf: url) {
                return html
            }
            // Flat lookup
            if let url = bundle.url(forResource: "dashboard", withExtension: "html"),
               let html = try? String(contentsOf: url) {
                return html
            }
        }
        // Fallback: minimal dashboard
        return """
        <!DOCTYPE html><html><head><title>API2File Demo</title></head>
        <body style="font-family:system-ui;background:#0d1117;color:#e6edf3;padding:40px">
        <h1>API2File Demo Server</h1>
        <p>Dashboard HTML not found in bundle. Try accessing the API directly:</p>
        <ul><li><a href="/api/tasks">/api/tasks</a></li>
        <li><a href="/api/contacts">/api/contacts</a></li>
        <li><a href="/api/events">/api/events</a></li>
        <li><a href="/api/notes">/api/notes</a></li>
        <li><a href="/api/pages">/api/pages</a></li>
        <li><a href="/api/config">/api/config</a></li>
        <li><a href="/api/services">/api/services</a></li>
        <li><a href="/api/incidents">/api/incidents</a></li>
        <li><a href="/api/logos">/api/logos</a></li>
        <li><a href="/api/photos">/api/photos</a></li>
        <li><a href="/api/documents">/api/documents</a></li>
        <li><a href="/api/spreadsheets">/api/spreadsheets</a></li>
        <li><a href="/api/reports">/api/reports</a></li>
        <li><a href="/api/presentations">/api/presentations</a></li>
        <li><a href="/api/emails">/api/emails</a></li>
        <li><a href="/api/bookmarks">/api/bookmarks</a></li>
        <li><a href="/api/settings">/api/settings</a></li>
        <li><a href="/api/snippets">/api/snippets</a></li></ul>
        <h2>Wix-like Endpoints (wrapped JSON)</h2>
        <ul><li><a href="/api/wix/contacts">/api/wix/contacts</a></li>
        <li><a href="/api/wix/posts">/api/wix/posts</a></li>
        <li><a href="/api/wix/products">/api/wix/products</a></li>
        <li><a href="/api/wix/services">/api/wix/services</a></li>
        <li><a href="/api/wix/collections">/api/wix/collections</a></li></ul>
        </body></html>
        """
    }()

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

    // MARK: - Logos Routes

    private func routeLogos(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/logos"):
            let items = logos.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/logos/".count))
            if let id = Int(idStr), let item = logos.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Logo not found"], connection: connection)
            }
        case ("POST", "/api/logos"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoLogo(id: nextLogoId, name: dict["name"] as? String ?? "untitled", content: dict["content"] as? String ?? "")
                nextLogoId += 1
                logos.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/logos/".count))
            if let id = Int(idStr), let idx = logos.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = logos[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["content"] as? String { item.content = v }
                logos[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Logo not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/logos/".count))
            if let id = Int(idStr), let idx = logos.firstIndex(where: { $0.id == id }) {
                logos.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Logo not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Photos Routes

    private func routePhotos(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/photos"):
            let items = photos.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/photos/".count))
            if let id = Int(idStr), let item = photos.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Photo not found"], connection: connection)
            }
        case ("POST", "/api/photos"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoPhoto(id: nextPhotoId, name: dict["name"] as? String ?? "untitled", width: dict["width"] as? Int ?? 0, height: dict["height"] as? Int ?? 0, data: dict["data"] as? String ?? "")
                nextPhotoId += 1
                photos.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/photos/".count))
            if let id = Int(idStr), let idx = photos.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = photos[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["width"] as? Int { item.width = v }
                if let v = dict["height"] as? Int { item.height = v }
                if let v = dict["data"] as? String { item.data = v }
                photos[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Photo not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/photos/".count))
            if let id = Int(idStr), let idx = photos.firstIndex(where: { $0.id == id }) {
                photos.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Photo not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Documents Routes

    private func routeDocuments(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/documents"):
            let items = documents.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/documents/".count))
            if let id = Int(idStr), let item = documents.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Document not found"], connection: connection)
            }
        case ("POST", "/api/documents"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoDocument(id: nextDocumentId, name: dict["name"] as? String ?? "untitled", data: dict["data"] as? String ?? "")
                nextDocumentId += 1
                documents.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/documents/".count))
            if let id = Int(idStr), let idx = documents.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = documents[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["data"] as? String { item.data = v }
                documents[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Document not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/documents/".count))
            if let id = Int(idStr), let idx = documents.firstIndex(where: { $0.id == id }) {
                documents.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Document not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }


    // MARK: - Spreadsheets Routes

    private func routeSpreadsheets(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/spreadsheets"):
            let items = spreadsheets.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/spreadsheets/".count))
            if let id = Int(idStr), let item = spreadsheets.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Spreadsheet not found"], connection: connection)
            }
        case ("POST", "/api/spreadsheets"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoSpreadsheet(
                    id: nextSpreadsheetId,
                    name: dict["name"] as? String ?? "Untitled",
                    category: dict["category"] as? String ?? "",
                    quantity: dict["quantity"] as? Int ?? 0,
                    price: dict["price"] as? Double ?? 0.0,
                    inStock: dict["inStock"] as? Bool ?? true
                )
                nextSpreadsheetId += 1
                spreadsheets.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/spreadsheets/".count))
            if let id = Int(idStr), let idx = spreadsheets.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = spreadsheets[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["category"] as? String { item.category = v }
                if let v = dict["quantity"] as? Int { item.quantity = v }
                if let v = dict["price"] as? Double { item.price = v }
                if let v = dict["inStock"] as? Bool { item.inStock = v }
                spreadsheets[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Spreadsheet not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/spreadsheets/".count))
            if let id = Int(idStr), let idx = spreadsheets.firstIndex(where: { $0.id == id }) {
                spreadsheets.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Spreadsheet not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Reports Routes

    private func routeReports(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/reports"):
            let items = reports.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/reports/".count))
            if let id = Int(idStr), let item = reports.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Report not found"], connection: connection)
            }
        case ("POST", "/api/reports"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoReport(
                    id: nextReportId,
                    title: dict["title"] as? String ?? "Untitled Report",
                    content: dict["content"] as? String ?? ""
                )
                nextReportId += 1
                reports.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/reports/".count))
            if let id = Int(idStr), let idx = reports.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = reports[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["content"] as? String { item.content = v }
                reports[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Report not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/reports/".count))
            if let id = Int(idStr), let idx = reports.firstIndex(where: { $0.id == id }) {
                reports.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Report not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Presentations Routes

    private func routePresentations(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/presentations"):
            let items = presentations.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/presentations/".count))
            if let id = Int(idStr), let item = presentations.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Presentation not found"], connection: connection)
            }
        case ("POST", "/api/presentations"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoPresentation(
                    id: nextPresentationId,
                    title: dict["title"] as? String ?? "Untitled Slide",
                    content: dict["content"] as? String ?? ""
                )
                nextPresentationId += 1
                presentations.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/presentations/".count))
            if let id = Int(idStr), let idx = presentations.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = presentations[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["content"] as? String { item.content = v }
                presentations[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Presentation not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/presentations/".count))
            if let id = Int(idStr), let idx = presentations.firstIndex(where: { $0.id == id }) {
                presentations.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Presentation not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Emails Routes

    private func routeEmails(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/emails"):
            let items = emails.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/emails/".count))
            if let id = Int(idStr), let item = emails.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Email not found"], connection: connection)
            }
        case ("POST", "/api/emails"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoEmail(
                    id: nextEmailId,
                    from: dict["from"] as? String ?? "",
                    to: dict["to"] as? String ?? "",
                    subject: dict["subject"] as? String ?? "No Subject",
                    date: dict["date"] as? String ?? "",
                    body: dict["body"] as? String ?? ""
                )
                nextEmailId += 1
                emails.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/emails/".count))
            if let id = Int(idStr), let idx = emails.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = emails[idx]
                if let v = dict["from"] as? String { item.from = v }
                if let v = dict["to"] as? String { item.to = v }
                if let v = dict["subject"] as? String { item.subject = v }
                if let v = dict["date"] as? String { item.date = v }
                if let v = dict["body"] as? String { item.body = v }
                emails[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Email not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/emails/".count))
            if let id = Int(idStr), let idx = emails.firstIndex(where: { $0.id == id }) {
                emails.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Email not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Bookmarks Routes

    private func routeBookmarks(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/bookmarks"):
            let items = bookmarks.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/bookmarks/".count))
            if let id = Int(idStr), let item = bookmarks.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Bookmark not found"], connection: connection)
            }
        case ("POST", "/api/bookmarks"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoBookmark(
                    id: nextBookmarkId,
                    name: dict["name"] as? String ?? "Untitled",
                    url: dict["url"] as? String ?? ""
                )
                nextBookmarkId += 1
                bookmarks.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/bookmarks/".count))
            if let id = Int(idStr), let idx = bookmarks.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = bookmarks[idx]
                if let v = dict["name"] as? String { item.name = v }
                if let v = dict["url"] as? String { item.url = v }
                bookmarks[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Bookmark not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/bookmarks/".count))
            if let id = Int(idStr), let idx = bookmarks.firstIndex(where: { $0.id == id }) {
                bookmarks.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Bookmark not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Settings Routes

    private func routeSettings(method: String, body: Data?, connection: NWConnection) {
        switch method {
        case "GET":
            sendJSONDict(statusCode: 200, body: settings.toDict(), connection: connection)

        case "PUT":
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let v = dict["appName"] as? String { settings.appName = v }
                if let v = dict["version"] as? String { settings.version = v }
                if let v = dict["debug"] as? Bool { settings.debug = v }
                if let v = dict["maxRetries"] as? Int { settings.maxRetries = v }
                if let v = dict["apiEndpoint"] as? String { settings.apiEndpoint = v }
                sendJSONDict(statusCode: 200, body: settings.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Snippets Routes

    private func routeSnippets(method: String, path: String, body: Data?, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/snippets"):
            let items = snippets.map { $0.toDict() }
            sendJSONArray(statusCode: 200, body: items, connection: connection)
        case ("GET", _):
            let idStr = String(path.dropFirst("/api/snippets/".count))
            if let id = Int(idStr), let item = snippets.first(where: { $0.id == id }) {
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Snippet not found"], connection: connection)
            }
        case ("POST", "/api/snippets"):
            if let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let item = DemoSnippet(
                    id: nextSnippetId,
                    title: dict["title"] as? String ?? "Untitled",
                    content: dict["content"] as? String ?? ""
                )
                nextSnippetId += 1
                snippets.append(item)
                sendJSONDict(statusCode: 201, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 400, body: ["error": "Invalid JSON body"], connection: connection)
            }
        case ("PUT", _):
            let idStr = String(path.dropFirst("/api/snippets/".count))
            if let id = Int(idStr), let idx = snippets.firstIndex(where: { $0.id == id }), let body, let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var item = snippets[idx]
                if let v = dict["title"] as? String { item.title = v }
                if let v = dict["content"] as? String { item.content = v }
                snippets[idx] = item
                sendJSONDict(statusCode: 200, body: item.toDict(), connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Snippet not found"], connection: connection)
            }
        case ("DELETE", _):
            let idStr = String(path.dropFirst("/api/snippets/".count))
            if let id = Int(idStr), let idx = snippets.firstIndex(where: { $0.id == id }) {
                snippets.remove(at: idx)
                sendJSON(statusCode: 200, body: ["deleted": "\(id)"], connection: connection)
            } else {
                sendJSON(statusCode: 404, body: ["error": "Snippet not found"], connection: connection)
            }
        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - Wix Routes (wrapped JSON responses)

    private func routeWix(method: String, path: String, body: Data?, connection: NWConnection) {
        // Extract sub-resource from /api/wix/{resource}
        let suffix = String(path.dropFirst("/api/wix/".count))
        let resource = suffix.split(separator: "/").first.map(String.init) ?? suffix

        switch (method, resource) {
        case ("GET", "contacts"):
            let items = wixContacts.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["contacts": items], connection: connection)

        case ("GET", "posts"):
            let items = wixBlogPosts.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["posts": items], connection: connection)

        case ("GET", "products"):
            let items = wixProducts.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["products": items], connection: connection)

        case ("GET", "services"):
            let items = wixBookings.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["services": items], connection: connection)

        case ("GET", "collections"):
            let items = wixCollections.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["collections": items], connection: connection)

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

// MARK: - Demo Logo Model (SVG)

public struct DemoLogo: Codable, Sendable {
    public var id: Int
    public var name: String
    public var content: String     // SVG markup

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "content": content]
    }

    static let seedData: [DemoLogo] = [
        DemoLogo(id: 1, name: "app-icon", content: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
              <rect width="100" height="100" rx="20" fill="#4A90D9"/>
              <text x="50" y="62" font-family="Helvetica" font-size="40" fill="white" text-anchor="middle" font-weight="bold">A2F</text>
            </svg>
            """),
        DemoLogo(id: 2, name: "badge", content: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120">
              <circle cx="60" cy="60" r="55" fill="none" stroke="#E74C3C" stroke-width="6"/>
              <polygon points="60,25 70,50 95,50 75,65 82,90 60,75 38,90 45,65 25,50 50,50" fill="#E74C3C"/>
            </svg>
            """),
        DemoLogo(id: 3, name: "chart-icon", content: """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
              <rect x="10" y="60" width="15" height="30" fill="#2ECC71"/>
              <rect x="30" y="40" width="15" height="50" fill="#3498DB"/>
              <rect x="50" y="20" width="15" height="70" fill="#E67E22"/>
              <rect x="70" y="10" width="15" height="80" fill="#9B59B6"/>
            </svg>
            """),
    ]
}

// MARK: - Demo Photo Model (PNG, base64)

public struct DemoPhoto: Codable, Sendable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    public var data: String        // base64-encoded PNG

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "width": width, "height": height, "data": data]
    }

    static let seedData: [DemoPhoto] = [
        DemoPhoto(id: 1, name: "red-swatch", width: 8, height: 8,
                  data: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2SEFTEMLQkAbRlQAcgCOpkAAAAASUVORK5CYII="),
        DemoPhoto(id: 2, name: "blue-swatch", width: 8, height: 8,
                  data: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMwSrmDFTEMLQkA+lVcgb/xykQAAAAASUVORK5CYII="),
        DemoPhoto(id: 3, name: "green-swatch", width: 8, height: 8,
                  data: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMw2hKAFTEMLQkAQQpNgcVQvJgAAAAASUVORK5CYII="),
    ]
}

// MARK: - Demo Document Model (PDF, base64)

public struct DemoDocument: Codable, Sendable {
    public var id: Int
    public var name: String
    public var data: String        // base64-encoded PDF

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "data": data]
    }

    static let seedData: [DemoDocument] = [
        DemoDocument(id: 1, name: "q1-report",
                     data: "JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBvYmo8PC9UeXBlL1BhZ2VzL0tpZHNbMyAwIFJdL0NvdW50IDE+PmVuZG9iagozIDAgb2JqPDwvVHlwZS9QYWdlL01lZGlhQm94WzAgMCA2MTIgNzkyXS9QYXJlbnQgMiAwIFIvUmVzb3VyY2VzPDwvRm9udDw8L0YxIDQgMCBSPj4+Pi9Db250ZW50cyA1IDAgUj4+ZW5kb2JqCjQgMCBvYmo8PC9UeXBlL0ZvbnQvU3VidHlwZS9UeXBlMS9CYXNlRm9udC9IZWx2ZXRpY2E+PmVuZG9iago1IDAgb2JqPDwvTGVuZ3RoIDExNj4+CnN0cmVhbQpCVCAvRjEgMTggVGYgNzIgNzAwIFRkIChRMSBSZXBvcnQpIFRqIDAgLTMwIFRkIC9GMSAxMiBUZiAoUmV2ZW51ZSB1cCAyMyBwZXJjZW50LiBBY3RpdmUgdXNlcnMgcmVhY2hlZCA1MCwwMDAuKSBUaiBFVAplbmRzdHJlYW0KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI2NiAwMDAwMCBuIAowMDAwMDAwMzQwIDAwMDAwIG4gCnRyYWlsZXI8PC9TaXplIDYvUm9vdCAxIDAgUj4+CnN0YXJ0eHJlZgo1MTYKJSVFT0Y="),
        DemoDocument(id: 2, name: "invoice-1042",
                     data: "JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBvYmo8PC9UeXBlL1BhZ2VzL0tpZHNbMyAwIFJdL0NvdW50IDE+PmVuZG9iagozIDAgb2JqPDwvVHlwZS9QYWdlL01lZGlhQm94WzAgMCA2MTIgNzkyXS9QYXJlbnQgMiAwIFIvUmVzb3VyY2VzPDwvRm9udDw8L0YxIDQgMCBSPj4+Pi9Db250ZW50cyA1IDAgUj4+ZW5kb2JqCjQgMCBvYmo8PC9UeXBlL0ZvbnQvU3VidHlwZS9UeXBlMS9CYXNlRm9udC9IZWx2ZXRpY2E+PmVuZG9iago1IDAgb2JqPDwvTGVuZ3RoIDExNj4+CnN0cmVhbQpCVCAvRjEgMTggVGYgNzIgNzAwIFRkIChJbnZvaWNlIDEwNDIpIFRqIDAgLTMwIFRkIC9GMSAxMiBUZiAoQW1vdW50IGR1ZTogVVNEIDIsNDUwLjAwIOKAlCBQYXltZW50IHRlcm1zOiBOZXQgMzApIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjY2IDAwMDAwIG4gCjAwMDAwMDAzNDAgMDAwMDAgbiAKdHJhaWxlcjw8L1NpemUgNi9Sb290IDEgMCBSPj4Kc3RhcnR4cmVmCjUxNgolJUVPRg=="),
    ]
}

// MARK: - Demo Spreadsheet Model (XLSX)

public struct DemoSpreadsheet: Codable, Sendable {
    public var id: Int
    public var name: String
    public var category: String
    public var quantity: Int
    public var price: Double
    public var inStock: Bool

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "category": category, "quantity": quantity, "price": price, "inStock": inStock]
    }

    static let seedData: [DemoSpreadsheet] = [
        DemoSpreadsheet(id: 1, name: "Wireless Mouse", category: "Electronics", quantity: 150, price: 29.99, inStock: true),
        DemoSpreadsheet(id: 2, name: "USB-C Cable", category: "Accessories", quantity: 500, price: 12.99, inStock: true),
        DemoSpreadsheet(id: 3, name: "Mechanical Keyboard", category: "Electronics", quantity: 0, price: 89.99, inStock: false),
    ]
}

// MARK: - Demo Report Model (DOCX)

public struct DemoReport: Codable, Sendable {
    public var id: Int
    public var title: String
    public var content: String  // Multi-paragraph text

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "content": content]
    }

    static let seedData: [DemoReport] = [
        DemoReport(id: 1, title: "Quarterly Review", content: "Q1 2026 Performance Summary\n\nRevenue increased by 23% compared to Q4 2025.\n\nKey highlights:\n- Active users reached 50,000\n- Customer satisfaction score: 4.7/5\n- Three new enterprise contracts signed\n\nLooking ahead, we plan to expand into two new markets."),
        DemoReport(id: 2, title: "Project Proposal", content: "API2File Integration Platform\n\nObjective: Build a bidirectional sync engine for cloud APIs.\n\nPhase 1: Core sync engine with config-driven adapters.\nPhase 2: Office format support (XLSX, DOCX, PPTX).\nPhase 3: Real-time webhooks and community adapters.\n\nEstimated timeline: 6 months."),
    ]
}

// MARK: - Demo Presentation Model (PPTX)

public struct DemoPresentation: Codable, Sendable {
    public var id: Int
    public var title: String
    public var content: String  // Slide body text

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "content": content]
    }

    static let seedData: [DemoPresentation] = [
        DemoPresentation(id: 1, title: "API2File Overview", content: "Sync cloud API data to local files\nConfig-driven — no code needed\nBidirectional — edit files, push to API"),
        DemoPresentation(id: 2, title: "Key Features", content: "15+ file formats (CSV, XLSX, DOCX, ICS, VCF...)\nGit auto-commit for version history\nNative macOS integration"),
        DemoPresentation(id: 3, title: "Roadmap", content: "Phase 1: Core sync engine (DONE)\nPhase 2: Office formats (IN PROGRESS)\nPhase 3: Webhooks and community adapters"),
    ]
}

// MARK: - Demo Email Model (EML)

public struct DemoEmail: Codable, Sendable {
    public var id: Int
    public var from: String
    public var to: String
    public var subject: String
    public var date: String
    public var body: String

    public func toDict() -> [String: Any] {
        ["id": id, "from": from, "to": to, "subject": subject, "date": date, "body": body]
    }

    static let seedData: [DemoEmail] = [
        DemoEmail(id: 1, from: "alice@example.com", to: "bob@example.com", subject: "Project Update", date: "Mon, 23 Mar 2026 10:00:00 +0000", body: "Hi Bob,\n\nThe project is on track for Q2 delivery.\n\nBest,\nAlice"),
        DemoEmail(id: 2, from: "bob@example.com", to: "alice@example.com", subject: "Re: Project Update", date: "Mon, 23 Mar 2026 11:30:00 +0000", body: "Thanks Alice!\n\nI'll prepare the demo for next week.\n\nBob"),
    ]
}

// MARK: - Demo Bookmark Model (WEBLOC)

public struct DemoBookmark: Codable, Sendable {
    public var id: Int
    public var name: String
    public var url: String

    public func toDict() -> [String: Any] {
        ["id": id, "name": name, "url": url]
    }

    static let seedData: [DemoBookmark] = [
        DemoBookmark(id: 1, name: "GitHub", url: "https://github.com"),
        DemoBookmark(id: 2, name: "Swift Documentation", url: "https://docs.swift.org"),
        DemoBookmark(id: 3, name: "API2File Docs", url: "https://api2file.dev/docs"),
    ]
}

// MARK: - Demo Settings Model (YAML)

public struct DemoSettings: Codable, Sendable {
    public var appName: String
    public var version: String
    public var debug: Bool
    public var maxRetries: Int
    public var apiEndpoint: String

    public func toDict() -> [String: Any] {
        ["appName": appName, "version": version, "debug": debug, "maxRetries": maxRetries, "apiEndpoint": apiEndpoint]
    }

    static let seed = DemoSettings(
        appName: "API2File",
        version: "2.0.0",
        debug: false,
        maxRetries: 3,
        apiEndpoint: "https://api.example.com/v2"
    )
}

// MARK: - Demo Snippet Model (Text)

public struct DemoSnippet: Codable, Sendable {
    public var id: Int
    public var title: String
    public var content: String

    public func toDict() -> [String: Any] {
        ["id": id, "title": title, "content": content]
    }

    static let seedData: [DemoSnippet] = [
        DemoSnippet(id: 1, title: "Hello World", content: "Hello, World!\nThis is a plain text snippet.\nIt demonstrates the text format."),
        DemoSnippet(id: 2, title: "Config Template", content: "# Configuration\nHOST=localhost\nPORT=8080\nDEBUG=true"),
    ]
}

// MARK: - Demo Wix Contact Model

public struct DemoWixContact: Codable, Sendable {
    public var id: String
    public var info: ContactInfo
    public var createdDate: String
    public var primaryEmail: String

    public struct ContactInfo: Codable, Sendable {
        public var name: NameInfo
        public var emails: [EmailInfo]
        public var phones: [PhoneInfo]

        public struct NameInfo: Codable, Sendable {
            public var first: String
            public var last: String

            public func toDict() -> [String: Any] {
                ["first": first, "last": last]
            }
        }

        public struct EmailInfo: Codable, Sendable {
            public var email: String
            public var tag: String

            public func toDict() -> [String: Any] {
                ["email": email, "tag": tag]
            }
        }

        public struct PhoneInfo: Codable, Sendable {
            public var phone: String
            public var tag: String

            public func toDict() -> [String: Any] {
                ["phone": phone, "tag": tag]
            }
        }

        public func toDict() -> [String: Any] {
            [
                "name": name.toDict(),
                "emails": emails.map { $0.toDict() },
                "phones": phones.map { $0.toDict() }
            ]
        }
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "info": info.toDict(),
            "createdDate": createdDate,
            "primaryEmail": primaryEmail
        ]
    }

    static let seedData: [DemoWixContact] = [
        DemoWixContact(
            id: "c1a2b3c4-d5e6-7890-abcd-ef1234567890",
            info: ContactInfo(
                name: ContactInfo.NameInfo(first: "Alice", last: "Johnson"),
                emails: [ContactInfo.EmailInfo(email: "alice@example.com", tag: "MAIN")],
                phones: [ContactInfo.PhoneInfo(phone: "+1-555-0101", tag: "MOBILE")]
            ),
            createdDate: "2026-01-15T10:30:00Z",
            primaryEmail: "alice@example.com"
        ),
        DemoWixContact(
            id: "d2b3c4d5-e6f7-8901-bcde-f12345678901",
            info: ContactInfo(
                name: ContactInfo.NameInfo(first: "Bob", last: "Smith"),
                emails: [ContactInfo.EmailInfo(email: "bob@example.com", tag: "MAIN"), ContactInfo.EmailInfo(email: "bob.work@globex.com", tag: "WORK")],
                phones: [ContactInfo.PhoneInfo(phone: "+1-555-0102", tag: "MOBILE")]
            ),
            createdDate: "2026-02-20T14:00:00Z",
            primaryEmail: "bob@example.com"
        ),
        DemoWixContact(
            id: "e3c4d5e6-f7a8-9012-cdef-123456789012",
            info: ContactInfo(
                name: ContactInfo.NameInfo(first: "Charlie", last: "Brown"),
                emails: [ContactInfo.EmailInfo(email: "charlie@example.com", tag: "MAIN")],
                phones: [ContactInfo.PhoneInfo(phone: "+1-555-0103", tag: "HOME")]
            ),
            createdDate: "2026-03-10T09:00:00Z",
            primaryEmail: "charlie@example.com"
        ),
    ]
}

// MARK: - Demo Wix Blog Post Model

public struct DemoWixBlogPost: Codable, Sendable {
    public var id: String
    public var title: String
    public var slug: String
    public var richContent: String
    public var published: Bool
    public var firstPublishedDate: String

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "slug": slug,
            "richContent": richContent,
            "published": published,
            "firstPublishedDate": firstPublishedDate
        ]
    }

    static let seedData: [DemoWixBlogPost] = [
        DemoWixBlogPost(
            id: "bp-001-aaaa-bbbb-cccc",
            title: "Getting Started with API2File",
            slug: "getting-started-with-api2file",
            richContent: "# Getting Started with API2File\n\nAPI2File syncs cloud API data to local files.\n\n## Quick Start\n\n1. Install the CLI\n2. Connect your service\n3. Run `api2file sync`\n\nYour data will appear as editable files in Finder.",
            published: true,
            firstPublishedDate: "2026-03-01T12:00:00Z"
        ),
        DemoWixBlogPost(
            id: "bp-002-dddd-eeee-ffff",
            title: "Advanced Sync Patterns",
            slug: "advanced-sync-patterns",
            richContent: "# Advanced Sync Patterns\n\nLearn how to configure bidirectional sync with transforms.\n\n## Flatten Nested Data\n\nUse the `flatten` transform to simplify nested API responses.\n\n## Omit Unnecessary Fields\n\nKeep your files clean by omitting metadata fields.",
            published: true,
            firstPublishedDate: "2026-03-15T09:00:00Z"
        ),
    ]
}

// MARK: - Demo Wix Product Model

public struct DemoWixProduct: Codable, Sendable {
    public var id: String
    public var name: String
    public var productType: String
    public var description: String
    public var priceData: PriceInfo
    public var stock: StockInfo
    public var visible: Bool

    public struct PriceInfo: Codable, Sendable {
        public var currency: String
        public var price: Double
        public var discountedPrice: Double

        public func toDict() -> [String: Any] {
            ["currency": currency, "price": price, "discountedPrice": discountedPrice]
        }
    }

    public struct StockInfo: Codable, Sendable {
        public var inventoryStatus: String
        public var quantity: Int

        public func toDict() -> [String: Any] {
            ["inventoryStatus": inventoryStatus, "quantity": quantity]
        }
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "productType": productType,
            "description": description,
            "priceData": priceData.toDict(),
            "stock": stock.toDict(),
            "visible": visible
        ]
    }

    static let seedData: [DemoWixProduct] = [
        DemoWixProduct(
            id: "prod-001-aaaa",
            name: "Wireless Mouse",
            productType: "physical",
            description: "Ergonomic wireless mouse with USB-C charging",
            priceData: PriceInfo(currency: "USD", price: 29.99, discountedPrice: 24.99),
            stock: StockInfo(inventoryStatus: "IN_STOCK", quantity: 150),
            visible: true
        ),
        DemoWixProduct(
            id: "prod-002-bbbb",
            name: "USB-C Hub",
            productType: "physical",
            description: "7-in-1 USB-C hub with HDMI, USB-A, and SD card reader",
            priceData: PriceInfo(currency: "USD", price: 49.99, discountedPrice: 49.99),
            stock: StockInfo(inventoryStatus: "IN_STOCK", quantity: 75),
            visible: true
        ),
        DemoWixProduct(
            id: "prod-003-cccc",
            name: "Developer Sticker Pack",
            productType: "physical",
            description: "Set of 20 developer-themed vinyl stickers",
            priceData: PriceInfo(currency: "USD", price: 9.99, discountedPrice: 7.99),
            stock: StockInfo(inventoryStatus: "OUT_OF_STOCK", quantity: 0),
            visible: false
        ),
    ]
}

// MARK: - Demo Wix Booking Model

public struct DemoWixBooking: Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var category: String
    public var duration: Int
    public var price: Double

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "description": description,
            "category": category,
            "duration": duration,
            "price": price
        ]
    }

    static let seedData: [DemoWixBooking] = [
        DemoWixBooking(
            id: "bk-001-aaaa",
            name: "One-on-One Consultation",
            description: "30-minute private consultation with an expert",
            category: "Consulting",
            duration: 30,
            price: 75.0
        ),
        DemoWixBooking(
            id: "bk-002-bbbb",
            name: "Group Workshop",
            description: "2-hour interactive group workshop for up to 10 people",
            category: "Training",
            duration: 120,
            price: 200.0
        ),
    ]
}

// MARK: - Demo Wix Collection Model

public struct DemoWixCollection: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var fields: Int
    public var items: Int

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "displayName": displayName,
            "fields": fields,
            "items": items
        ]
    }

    static let seedData: [DemoWixCollection] = [
        DemoWixCollection(id: "col-001", displayName: "Blog Posts", fields: 8, items: 24),
        DemoWixCollection(id: "col-002", displayName: "Products", fields: 12, items: 156),
        DemoWixCollection(id: "col-003", displayName: "Team Members", fields: 6, items: 8),
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

// Token class for Xcode bundle lookup (not needed for SPM)
#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
