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
    private var wixMediaFiles: [DemoWixMediaFile] = []
    private var wixBookings: [DemoWixBooking] = []
    private var wixAppointments: [DemoWixAppointment] = []
    private var wixGroups: [DemoWixGroup] = []
    private var wixComments: [DemoWixComment] = []
    private var wixCollections: [DemoWixCollection] = []
    private var wixCollectionItems: [String: [DemoWixCollectionItem]] = [:]

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
        self.wixMediaFiles = DemoWixMediaFile.seedData
        self.wixBookings = DemoWixBooking.seedData
        self.wixAppointments = DemoWixAppointment.seedData
        self.wixGroups = DemoWixGroup.seedData
        self.wixComments = DemoWixComment.seedData
        self.wixCollections = DemoWixCollection.seedData
        self.wixCollectionItems = DemoWixCollectionItem.seedData
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
        wixMediaFiles = DemoWixMediaFile.seedData
        wixBookings = DemoWixBooking.seedData
        wixAppointments = DemoWixAppointment.seedData
        wixGroups = DemoWixGroup.seedData
        wixComments = DemoWixComment.seedData
        wixCollections = DemoWixCollection.seedData
        wixCollectionItems = DemoWixCollectionItem.seedData
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
                print("[DemoAPI]   GET            /api/wix/media      — Wix media manager files")
                print("[DemoAPI]   GET            /api/wix/assets/:id — Raw asset download")
                print("[DemoAPI]   GET            /api/wix/services   — Wix bookings services")
                print("[DemoAPI]   GET            /api/wix/appointments — Wix booking appointments")
                print("[DemoAPI]   GET            /api/wix/groups     — Wix groups")
                print("[DemoAPI]   GET            /api/wix/comments   — Wix comments")
                print("[DemoAPI]   GET            /api/wix/collections — Wix CMS collections")
                print("[DemoAPI]   GET            /api/wix/collections/:id/items — Wix CMS collection items")
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
        guard let (method, path, queryString, body, headers) = parseHTTPRequest(data) else {
            sendJSON(statusCode: 400, body: ["error": "Bad Request"], connection: connection)
            return
        }

        let acceptsHTML = Self.requestAcceptsHTML(headers: headers)

        // Route to resource handlers
        if path == "/api/tasks" || path.hasPrefix("/api/tasks/") {
            routeTasks(method: method, path: path, queryString: queryString, body: body, acceptsHTML: acceptsHTML, connection: connection)
        } else if path == "/api/contacts" || path.hasPrefix("/api/contacts/") {
            routeContacts(method: method, path: path, body: body, acceptsHTML: acceptsHTML, connection: connection)
        } else if path == "/api/events" || path.hasPrefix("/api/events/") {
            routeEvents(method: method, path: path, body: body, acceptsHTML: acceptsHTML, connection: connection)
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
            serveDynamicDashboard(connection: connection)
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
        <li><a href="/api/wix/media">/api/wix/media</a></li>
        <li><a href="/api/wix/services">/api/wix/services</a></li>
        <li><a href="/api/wix/appointments">/api/wix/appointments</a></li>
        <li><a href="/api/wix/groups">/api/wix/groups</a></li>
        <li><a href="/api/wix/comments">/api/wix/comments</a></li>
        <li><a href="/api/wix/collections">/api/wix/collections</a></li></ul>
        </body></html>
        """
    }()

    // MARK: - HTML Visualization Pages

    /// Check if the request Accept header indicates the client wants HTML
    private static func requestAcceptsHTML(headers: String) -> Bool {
        for line in headers.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("accept:") {
                let value = String(lower.dropFirst("accept:".count))
                return value.contains("text/html")
            }
        }
        return false
    }

    /// Send an HTML response
    private func sendHTML(_ html: String, statusCode: Int = 200, connection: NWConnection) {
        let utf8 = Data(html.utf8)
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        default: statusText = "OK"
        }
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(utf8.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(utf8)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // Shared CSS variables and base styles for all HTML visualization pages
    private static let cssBase = """
    :root {
      --bg: #0d1117; --surface: #161b22; --border: #30363d;
      --text: #e6edf3; --text2: #8b949e; --accent: #58a6ff;
      --green: #3fb950; --yellow: #d29922; --red: #f85149;
      --purple: #bc8cff; --radius: 12px;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', system-ui, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }

    /* Nav bar */
    nav { background: var(--surface); border-bottom: 1px solid var(--border); padding: 0 24px; display: flex; align-items: center; gap: 24px; height: 56px; position: sticky; top: 0; z-index: 10; }
    nav .logo { font-size: 18px; font-weight: 700; letter-spacing: -0.5px; display: flex; align-items: center; gap: 8px; color: var(--text); }
    nav .logo span { color: var(--accent); }
    nav .nav-links { display: flex; gap: 4px; }
    nav .nav-links a { padding: 8px 14px; border-radius: 8px; font-size: 14px; font-weight: 500; color: var(--text2); transition: background 0.15s, color 0.15s; }
    nav .nav-links a:hover { background: rgba(88,166,255,0.08); color: var(--text); text-decoration: none; }
    nav .nav-links a.active { background: rgba(88,166,255,0.15); color: var(--accent); }
    .container { max-width: 1100px; margin: 0 auto; padding: 32px 24px; }
    h1.page-title { font-size: 28px; font-weight: 700; margin-bottom: 8px; }
    .page-subtitle { color: var(--text2); font-size: 15px; margin-bottom: 28px; }
    """

    private static func htmlShell(title: String, activePage: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\(Self.escapeHTML(title)) - API2File Demo</title>
        <style>
        \(cssBase)
        </style>
        </head>
        <body>
        <nav>
          <div class="logo"><span>API2File</span> Demo</div>
          <div class="nav-links">
            <a href="/" class="\(activePage == "dashboard" ? "active" : "")">Dashboard</a>
            <a href="/api/tasks" class="\(activePage == "tasks" ? "active" : "")">Tasks</a>
            <a href="/api/contacts" class="\(activePage == "contacts" ? "active" : "")">Contacts</a>
            <a href="/api/events" class="\(activePage == "events" ? "active" : "")">Events</a>
          </div>
        </nav>
        <div class="container">
        \(body)
        </div>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Dynamic Dashboard

    private func serveDynamicDashboard(connection: NWConnection) {
        let resources: [(name: String, path: String, count: Int, format: String, icon: String)] = [
            ("Tasks", "/api/tasks", tasks.count, "CSV", "checkmark.circle"),
            ("Contacts", "/api/contacts", contacts.count, "VCF", "person.2"),
            ("Events", "/api/events", events.count, "ICS", "calendar"),
            ("Notes", "/api/notes", notes.count, "MD", "note.text"),
            ("Pages", "/api/pages", pages.count, "HTML", "doc.richtext"),
            ("Config", "/api/config", 1, "JSON", "gearshape"),
            ("Services", "/api/services", services.count, "JSON", "server.rack"),
            ("Incidents", "/api/incidents", incidents.count, "CSV", "exclamationmark.triangle"),
            ("Logos", "/api/logos", logos.count, "SVG", "paintbrush"),
            ("Photos", "/api/photos", photos.count, "PNG", "photo"),
            ("Documents", "/api/documents", documents.count, "PDF", "doc"),
            ("Spreadsheets", "/api/spreadsheets", spreadsheets.count, "XLSX", "tablecells"),
            ("Reports", "/api/reports", reports.count, "DOCX", "chart.bar"),
            ("Presentations", "/api/presentations", presentations.count, "PPTX", "rectangle.on.rectangle"),
            ("Emails", "/api/emails", emails.count, "EML", "envelope"),
            ("Bookmarks", "/api/bookmarks", bookmarks.count, "WEBLOC", "bookmark"),
            ("Settings", "/api/settings", 1, "YAML", "slider.horizontal.3"),
            ("Snippets", "/api/snippets", snippets.count, "TXT", "curlybraces"),
        ]

        let totalItems = resources.reduce(0) { $0 + $1.count }

        let formatColorMap: [String: String] = [
            "CSV": "var(--accent)", "VCF": "var(--purple)", "ICS": "var(--green)",
            "MD": "var(--yellow)", "HTML": "var(--red)", "JSON": "var(--accent)",
            "SVG": "var(--purple)", "PNG": "var(--green)", "PDF": "var(--red)",
            "XLSX": "var(--green)", "DOCX": "var(--accent)", "PPTX": "#e67e22",
            "EML": "var(--purple)", "WEBLOC": "var(--yellow)", "YAML": "var(--yellow)",
            "TXT": "var(--text2)",
        ]

        var cardsHTML = ""
        for r in resources {
            let color = formatColorMap[r.format] ?? "var(--accent)"
            cardsHTML += """
            <a href="\(r.path)" class="resource-card">
              <div class="rc-header">
                <span class="rc-name">\(Self.escapeHTML(r.name))</span>
                <span class="rc-format" style="color: \(color); background: color-mix(in srgb, \(color) 15%, transparent)">\(r.format)</span>
              </div>
              <div class="rc-count">\(r.count)</div>
              <div class="rc-label">\(r.count == 1 ? "item" : "items")</div>
            </a>
            """
        }

        let body = """
        <style>
          .stats-bar { display: flex; gap: 24px; margin-bottom: 32px; }
          .stat-box { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 20px 24px; flex: 1; }
          .stat-box .stat-value { font-size: 36px; font-weight: 700; color: var(--accent); }
          .stat-box .stat-label { font-size: 13px; color: var(--text2); margin-top: 4px; }
          .resource-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 12px; }
          .resource-card { display: block; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 20px; transition: border-color 0.2s, transform 0.15s, box-shadow 0.2s; text-decoration: none !important; }
          .resource-card:hover { border-color: var(--accent); transform: translateY(-2px); box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
          .rc-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
          .rc-name { font-weight: 600; font-size: 15px; color: var(--text); }
          .rc-format { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; padding: 2px 8px; border-radius: 6px; }
          .rc-count { font-size: 32px; font-weight: 700; color: var(--text); }
          .rc-label { font-size: 12px; color: var(--text2); }
          .section-title { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; color: var(--text2); margin-bottom: 16px; margin-top: 32px; }
          .section-title:first-of-type { margin-top: 0; }
          .wix-links { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
          .wix-link { padding: 6px 14px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; font-size: 13px; color: var(--text2); transition: border-color 0.2s, color 0.15s; }
          .wix-link:hover { border-color: var(--accent); color: var(--accent); text-decoration: none; }
        </style>
        <h1 class="page-title">Dashboard</h1>
        <p class="page-subtitle">API2File Demo Server — local REST API for testing</p>
        <div class="stats-bar">
          <div class="stat-box">
            <div class="stat-value">\(resources.count)</div>
            <div class="stat-label">Resource Types</div>
          </div>
          <div class="stat-box">
            <div class="stat-value">\(totalItems)</div>
            <div class="stat-label">Total Items</div>
          </div>
          <div class="stat-box">
            <div class="stat-value">8089</div>
            <div class="stat-label">Port</div>
          </div>
        </div>
        <div class="section-title">Resources</div>
        <div class="resource-grid">
        \(cardsHTML)
        </div>
        <div class="section-title" style="margin-top:32px">Wix-like Endpoints</div>
        <div class="wix-links">
          <a href="/api/wix/contacts" class="wix-link">Contacts (\(wixContacts.count))</a>
          <a href="/api/wix/posts" class="wix-link">Blog Posts (\(wixBlogPosts.count))</a>
          <a href="/api/wix/products" class="wix-link">Products (\(wixProducts.count))</a>
          <a href="/api/wix/media" class="wix-link">Media (\(wixMediaFiles.count))</a>
          <a href="/api/wix/services" class="wix-link">Services (\(wixBookings.count))</a>
          <a href="/api/wix/appointments" class="wix-link">Appointments (\(wixAppointments.count))</a>
          <a href="/api/wix/groups" class="wix-link">Groups (\(wixGroups.count))</a>
          <a href="/api/wix/comments" class="wix-link">Comments (\(wixComments.count))</a>
          <a href="/api/wix/collections" class="wix-link">Collections (\(wixCollections.count))</a>
          <a href="/api/wix/collections/col-002/items" class="wix-link">CMS Items (\(wixCollectionItems.values.reduce(0) { $0 + $1.count }))</a>
        </div>
        """

        let html = Self.htmlShell(title: "Dashboard", activePage: "dashboard", body: body)
        sendHTML(html, connection: connection)
    }

    // MARK: Tasks HTML

    private func renderTasksHTML() -> String {
        var rows = ""
        for task in tasks {
            let statusColor: String
            switch task.status {
            case "done": statusColor = "var(--green)"
            case "in-progress": statusColor = "var(--yellow)"
            default: statusColor = "var(--text2)"
            }
            let priorityColor: String
            switch task.priority {
            case "high": priorityColor = "var(--red)"
            case "medium": priorityColor = "var(--yellow)"
            default: priorityColor = "var(--text2)"
            }
            rows += """
            <tr>
              <td class="id-cell">\(task.id)</td>
              <td class="name-cell">\(Self.escapeHTML(task.name))</td>
              <td><span class="pill" style="color:\(statusColor);background:color-mix(in srgb,\(statusColor) 15%,transparent)">\(Self.escapeHTML(task.status))</span></td>
              <td><span class="pill" style="color:\(priorityColor);background:color-mix(in srgb,\(priorityColor) 15%,transparent)">\(Self.escapeHTML(task.priority))</span></td>
              <td>\(Self.escapeHTML(task.assignee))</td>
              <td class="date-cell">\(Self.escapeHTML(task.dueDate))</td>
            </tr>
            """
        }

        let body = """
        <style>
          table { width: 100%; border-collapse: collapse; font-size: 14px; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); overflow: hidden; }
          thead { background: rgba(0,0,0,0.25); }
          th { text-align: left; padding: 12px 16px; color: var(--text2); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
          td { padding: 12px 16px; border-top: 1px solid var(--border); }
          tr:hover td { background: rgba(88,166,255,0.05); }
          .pill { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 12px; font-weight: 600; }
          .id-cell { color: var(--text2); font-size: 12px; }
          .name-cell { font-weight: 500; }
          .date-cell { color: var(--text2); font-size: 13px; font-variant-numeric: tabular-nums; }
          .empty-state { text-align: center; padding: 48px; color: var(--text2); }
          .count-badge { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 13px; font-weight: 500; background: rgba(88,166,255,0.12); color: var(--accent); margin-left: 8px; vertical-align: middle; }
          .api-link { font-size: 13px; color: var(--text2); margin-bottom: 28px; display: block; }
          .api-link code { background: var(--surface); border: 1px solid var(--border); padding: 2px 8px; border-radius: 6px; font-size: 12px; }
        </style>
        <h1 class="page-title">Tasks <span class="count-badge">\(tasks.count)</span></h1>
        <span class="api-link">JSON API: <code>GET /api/tasks</code></span>
        \(tasks.isEmpty ? "<div class=\"empty-state\">No tasks yet.</div>" : """
        <table>
          <thead>
            <tr><th>ID</th><th>Name</th><th>Status</th><th>Priority</th><th>Assignee</th><th>Due Date</th></tr>
          </thead>
          <tbody>
            \(rows)
          </tbody>
        </table>
        """)
        """

        return Self.htmlShell(title: "Tasks", activePage: "tasks", body: body)
    }

    // MARK: Contacts HTML

    private func renderContactsHTML() -> String {
        var cards = ""
        for contact in contacts {
            let initials = "\(contact.firstName.prefix(1))\(contact.lastName.prefix(1))"
            cards += """
            <div class="contact-card">
              <div class="contact-avatar">\(Self.escapeHTML(initials))</div>
              <div class="contact-info">
                <div class="contact-name">\(Self.escapeHTML(contact.firstName)) \(Self.escapeHTML(contact.lastName))</div>
                <div class="contact-company">\(Self.escapeHTML(contact.company))</div>
              </div>
              <div class="contact-details">
                <div class="contact-detail"><span class="detail-label">Email</span><span class="detail-value">\(Self.escapeHTML(contact.email))</span></div>
                <div class="contact-detail"><span class="detail-label">Phone</span><span class="detail-value">\(Self.escapeHTML(contact.phone))</span></div>
              </div>
            </div>
            """
        }

        let body = """
        <style>
          .contact-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
          .contact-card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 24px; transition: border-color 0.2s, transform 0.15s, box-shadow 0.2s; }
          .contact-card:hover { border-color: var(--accent); transform: translateY(-2px); box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
          .contact-avatar { width: 48px; height: 48px; border-radius: 50%; background: linear-gradient(135deg, var(--accent), var(--purple)); display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 18px; color: #fff; margin-bottom: 16px; }
          .contact-name { font-size: 17px; font-weight: 600; }
          .contact-company { font-size: 13px; color: var(--text2); margin-top: 2px; }
          .contact-info { margin-bottom: 16px; }
          .contact-details { border-top: 1px solid var(--border); padding-top: 12px; }
          .contact-detail { display: flex; justify-content: space-between; padding: 4px 0; font-size: 13px; }
          .detail-label { color: var(--text2); }
          .detail-value { font-weight: 500; }
          .empty-state { text-align: center; padding: 48px; color: var(--text2); }
          .count-badge { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 13px; font-weight: 500; background: rgba(188,140,255,0.12); color: var(--purple); margin-left: 8px; vertical-align: middle; }
          .api-link { font-size: 13px; color: var(--text2); margin-bottom: 28px; display: block; }
          .api-link code { background: var(--surface); border: 1px solid var(--border); padding: 2px 8px; border-radius: 6px; font-size: 12px; }
        </style>
        <h1 class="page-title">Contacts <span class="count-badge">\(contacts.count)</span></h1>
        <span class="api-link">JSON API: <code>GET /api/contacts</code></span>
        \(contacts.isEmpty ? "<div class=\"empty-state\">No contacts yet.</div>" : """
        <div class="contact-grid">
          \(cards)
        </div>
        """)
        """

        return Self.htmlShell(title: "Contacts", activePage: "contacts", body: body)
    }

    // MARK: Events HTML

    private func renderEventsHTML() -> String {
        var items = ""
        for event in events {
            let statusColor: String
            switch event.status {
            case "confirmed": statusColor = "var(--green)"
            case "tentative": statusColor = "var(--yellow)"
            case "cancelled": statusColor = "var(--red)"
            default: statusColor = "var(--text2)"
            }
            // Format dates for display
            let startDisplay = event.startDate.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")
            let endDisplay = event.endDate.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: " UTC")

            items += """
            <div class="event-item">
              <div class="event-timeline-dot" style="background:\(statusColor)"></div>
              <div class="event-content">
                <div class="event-header">
                  <span class="event-title">\(Self.escapeHTML(event.title))</span>
                  <span class="event-status" style="color:\(statusColor);background:color-mix(in srgb,\(statusColor) 15%,transparent)">\(Self.escapeHTML(event.status))</span>
                </div>
                <div class="event-description">\(Self.escapeHTML(event.description))</div>
                <div class="event-meta">
                  <span class="event-time">\(Self.escapeHTML(startDisplay)) &mdash; \(Self.escapeHTML(endDisplay))</span>
                  <span class="event-location">\(Self.escapeHTML(event.location))</span>
                </div>
              </div>
            </div>
            """
        }

        let body = """
        <style>
          .events-list { position: relative; padding-left: 28px; }
          .events-list::before { content: ''; position: absolute; left: 7px; top: 8px; bottom: 8px; width: 2px; background: var(--border); border-radius: 1px; }
          .event-item { position: relative; margin-bottom: 20px; }
          .event-timeline-dot { position: absolute; left: -24px; top: 8px; width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--bg); }
          .event-content { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 20px; transition: border-color 0.2s, box-shadow 0.2s; }
          .event-content:hover { border-color: var(--accent); box-shadow: 0 4px 20px rgba(0,0,0,0.2); }
          .event-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
          .event-title { font-size: 16px; font-weight: 600; }
          .event-status { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 12px; font-weight: 600; }
          .event-description { font-size: 14px; color: var(--text2); margin-bottom: 12px; line-height: 1.5; }
          .event-meta { display: flex; gap: 20px; font-size: 13px; color: var(--text2); flex-wrap: wrap; }
          .event-time::before { content: ''; display: inline-block; width: 12px; height: 12px; background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='%238b949e'%3E%3Cpath d='M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM1.5 8a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Zm7-3.25v2.992l2.028.812a.75.75 0 0 1-.557 1.392l-2.5-1A.751.751 0 0 1 7 8.25v-3.5a.75.75 0 0 1 1.5 0Z'/%3E%3C/svg%3E") no-repeat center/contain; margin-right: 4px; vertical-align: -1px; }
          .event-location::before { content: ''; display: inline-block; width: 12px; height: 12px; background: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16' fill='%238b949e'%3E%3Cpath d='m12.596 11.596-3.535 3.535a1.5 1.5 0 0 1-2.122 0l-3.535-3.535a6.5 6.5 0 1 1 9.192 0ZM8 11.184l3.535-3.535a4.5 4.5 0 1 0-7.07 0L8 11.184Z'/%3E%3Ccircle cx='8' cy='6' r='1.5'/%3E%3C/svg%3E") no-repeat center/contain; margin-right: 4px; vertical-align: -1px; }
          .empty-state { text-align: center; padding: 48px; color: var(--text2); }
          .count-badge { display: inline-block; padding: 2px 10px; border-radius: 20px; font-size: 13px; font-weight: 500; background: rgba(63,185,80,0.12); color: var(--green); margin-left: 8px; vertical-align: middle; }
          .api-link { font-size: 13px; color: var(--text2); margin-bottom: 28px; display: block; }
          .api-link code { background: var(--surface); border: 1px solid var(--border); padding: 2px 8px; border-radius: 6px; font-size: 12px; }
        </style>
        <h1 class="page-title">Events <span class="count-badge">\(events.count)</span></h1>
        <span class="api-link">JSON API: <code>GET /api/events</code></span>
        \(events.isEmpty ? "<div class=\"empty-state\">No events yet.</div>" : """
        <div class="events-list">
          \(items)
        </div>
        """)
        """

        return Self.htmlShell(title: "Events", activePage: "events", body: body)
    }

    // MARK: - Tasks Routes

    private func routeTasks(method: String, path: String, queryString: String?, body: Data?, acceptsHTML: Bool = false, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/tasks"):
            if acceptsHTML {
                sendHTML(renderTasksHTML(), connection: connection)
                return
            }
            var tasksJSON = tasks.map { $0.toDict() }

            // Support pagination via limit/offset query params
            let params = parseQueryParams(queryString)
            if let limitStr = params["limit"], let limit = Int(limitStr) {
                let offset = Int(params["offset"] ?? "0") ?? 0
                let start = min(offset, tasksJSON.count)
                let end = min(start + limit, tasksJSON.count)
                tasksJSON = Array(tasksJSON[start..<end])
            }

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

    private func routeContacts(method: String, path: String, body: Data?, acceptsHTML: Bool = false, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/contacts"):
            if acceptsHTML {
                sendHTML(renderContactsHTML(), connection: connection)
                return
            }
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

    private func routeEvents(method: String, path: String, body: Data?, acceptsHTML: Bool = false, connection: NWConnection) {
        switch (method, path) {
        case ("GET", "/api/events"):
            if acceptsHTML {
                sendHTML(renderEventsHTML(), connection: connection)
                return
            }
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
        let suffix = String(path.dropFirst("/api/wix/".count))
        let parts = suffix.split(separator: "/").map(String.init)
        let resource = parts.first ?? suffix
        let baseURL = "http://localhost:\(port)"

        switch (method, resource) {
        case ("GET", "contacts"):
            let items = wixContacts.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["contacts": items], connection: connection)

        case ("GET", "posts"):
            if parts.count >= 2, let post = wixBlogPosts.first(where: { $0.id == parts[1] }) {
                sendJSONDict(statusCode: 200, body: ["post": post.toDetailDict()], connection: connection)
            } else {
                let items = wixBlogPosts.map { $0.toSummaryDict() }
                sendJSONDict(statusCode: 200, body: ["posts": items], connection: connection)
            }

        case ("GET", "products"):
            let items = wixProducts.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["products": items], connection: connection)

        case ("GET", "media"):
            let items = wixMediaFiles.map { $0.toDict(baseURL: baseURL) }
            sendJSONDict(statusCode: 200, body: ["files": items], connection: connection)

        case ("GET", "assets"):
            guard parts.count >= 2,
                  let asset = wixMediaFiles.first(where: { $0.id == parts[1] }) else {
                sendJSON(statusCode: 404, body: ["error": "Asset not found"], connection: connection)
                return
            }
            sendBinaryResponse(statusCode: 200, body: asset.binaryData, contentType: asset.mimeType, connection: connection)

        case ("GET", "services"):
            let items = wixBookings.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["services": items], connection: connection)

        case ("GET", "appointments"):
            let items = wixAppointments.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["bookings": items], connection: connection)

        case ("GET", "groups"):
            let items = wixGroups.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["groups": items], connection: connection)

        case ("GET", "comments"):
            let items = wixComments.map { $0.toDict() }
            sendJSONDict(statusCode: 200, body: ["comments": items], connection: connection)

        case ("GET", "collections"):
            if parts.count >= 3, parts[2] == "items" {
                let items = (wixCollectionItems[parts[1]] ?? []).map { $0.toDict() }
                sendJSONDict(statusCode: 200, body: ["dataItems": items], connection: connection)
            } else {
                let items = wixCollections.map { $0.toDict() }
                sendJSONDict(statusCode: 200, body: ["collections": items], connection: connection)
            }

        default:
            sendJSON(statusCode: 404, body: ["error": "Not Found"], connection: connection)
        }
    }

    // MARK: - HTTP Helpers

    private func parseQueryParams(_ queryString: String?) -> [String: String] {
        guard let qs = queryString, !qs.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1])
            }
        }
        return params
    }

    private func parseHTTPRequest(_ data: Data) -> (method: String, path: String, queryString: String?, body: Data?, headers: String)? {
        guard let headerEnd = data.findDemoHeaderEnd() else { return nil }
        let headerData = data[data.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.split(separator: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let rawPath = String(parts[1])
        let pathParts = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        let queryString = pathParts.count > 1 ? String(pathParts[1]) : nil

        let bodyStart = headerEnd + 4
        let body: Data? = bodyStart < data.count ? Data(data[bodyStart...]) : nil

        return (method, path, queryString, body, headerString)
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

    private func sendBinaryResponse(statusCode: Int, body: Data, contentType: String, connection: NWConnection) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Unknown"
        }

        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
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

    public var contentText: String {
        richContent
    }

    public func toSummaryDict() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "slug": slug,
            "published": published,
            "firstPublishedDate": firstPublishedDate
        ]
    }

    public func toDetailDict() -> [String: Any] {
        var dict = toSummaryDict()
        dict["richContent"] = richContent
        dict["contentText"] = contentText
        return dict
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

// MARK: - Demo Wix Media File Model

public struct DemoWixMediaFile: Codable, Sendable {
    public var id: String
    public var displayName: String
    public var mediaType: String
    public var mimeType: String
    public var hash: String
    public var data: String

    public var sizeInBytes: Int {
        Data(base64Encoded: data)?.count ?? 0
    }

    public var binaryData: Data {
        Data(base64Encoded: data) ?? Data()
    }

    public func toDict(baseURL: String) -> [String: Any] {
        [
            "id": id,
            "displayName": displayName,
            "mediaType": mediaType,
            "mimeType": mimeType,
            "hash": hash,
            "sizeInBytes": sizeInBytes,
            "url": "\(baseURL)/api/wix/assets/\(id)"
        ]
    }

    static let seedData: [DemoWixMediaFile] = [
        DemoWixMediaFile(
            id: "media-001-image",
            displayName: "homepage-hero.png",
            mediaType: "IMAGE",
            mimeType: "image/png",
            hash: "hash-homepage-hero",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2SEFTEMLQkAbRlQAcgCOpkAAAAASUVORK5CYII="
        ),
        DemoWixMediaFile(
            id: "media-002-image",
            displayName: "gallery-shot.png",
            mediaType: "IMAGE",
            mimeType: "image/png",
            hash: "hash-gallery-shot",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMwSrmDFTEMLQkA+lVcgb/xykQAAAAASUVORK5CYII="
        ),
        DemoWixMediaFile(
            id: "media-003-pdf",
            displayName: "pricing-guide.pdf",
            mediaType: "DOCUMENT",
            mimeType: "application/pdf",
            hash: "hash-pricing-guide",
            data: "JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBvYmo8PC9UeXBlL1BhZ2VzL0tpZHNbMyAwIFJdL0NvdW50IDE+PmVuZG9iagozIDAgb2JqPDwvVHlwZS9QYWdlL01lZGlhQm94WzAgMCA2MTIgNzkyXS9QYXJlbnQgMiAwIFIvUmVzb3VyY2VzPDwvRm9udDw8L0YxIDQgMCBSPj4+Pi9Db250ZW50cyA1IDAgUj4+ZW5kb2JqCjQgMCBvYmo8PC9UeXBlL0ZvbnQvU3VidHlwZS9UeXBlMS9CYXNlRm9udC9IZWx2ZXRpY2E+PmVuZG9iago1IDAgb2JqPDwvTGVuZ3RoIDExNj4+CnN0cmVhbQpCVCAvRjEgMTggVGYgNzIgNzAwIFRkIChRMSBSZXBvcnQpIFRqIDAgLTMwIFRkIC9GMSAxMiBUZiAoUmV2ZW51ZSB1cCAyMyBwZXJjZW50LiBBY3RpdmUgdXNlcnMgcmVhY2hlZCA1MCwwMDAuKSBUaiBFVAplbmRzdHJlYW0KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI2NiAwMDAwMCBuIAowMDAwMDAwMzQwIDAwMDAwIG4gCnRyYWlsZXI8PC9TaXplIDYvUm9vdCAxIDAgUj4+CnN0YXJ0eHJlZgo1MTYKJSVFT0Y="
        ),
        DemoWixMediaFile(
            id: "media-004-video",
            displayName: "launch-teaser.mp4",
            mediaType: "VIDEO",
            mimeType: "video/mp4",
            hash: "hash-launch-teaser",
            data: "RkFLRS1NUDQtREFUQS1GT1ItREVNTw=="
        ),
        DemoWixMediaFile(
            id: "media-005-audio",
            displayName: "podcast-intro.mp3",
            mediaType: "AUDIO",
            mimeType: "audio/mpeg",
            hash: "hash-podcast-intro",
            data: "RkFLRS1NUDMtREFUQS1GT1ItREVNTw=="
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

// MARK: - Demo Wix Appointment Model

public struct DemoWixAppointment: Codable, Sendable {
    public var id: String
    public var startDate: String
    public var endDate: String
    public var status: String
    public var bookedEntity: BookedEntity
    public var contactDetails: ContactDetails

    public struct BookedEntity: Codable, Sendable {
        public var title: String

        public func toDict() -> [String: Any] {
            ["title": title]
        }
    }

    public struct ContactDetails: Codable, Sendable {
        public var firstName: String
        public var lastName: String
        public var email: String

        public func toDict() -> [String: Any] {
            ["firstName": firstName, "lastName": lastName, "email": email]
        }
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "startDate": startDate,
            "endDate": endDate,
            "status": status,
            "bookedEntity": bookedEntity.toDict(),
            "contactDetails": contactDetails.toDict()
        ]
    }

    static let seedData: [DemoWixAppointment] = [
        DemoWixAppointment(
            id: "appt-001",
            startDate: "2026-03-24T09:00:00Z",
            endDate: "2026-03-24T09:30:00Z",
            status: "CONFIRMED",
            bookedEntity: BookedEntity(title: "One-on-One Consultation"),
            contactDetails: ContactDetails(firstName: "Alice", lastName: "Johnson", email: "alice@example.com")
        ),
        DemoWixAppointment(
            id: "appt-002",
            startDate: "2026-03-25T14:00:00Z",
            endDate: "2026-03-25T16:00:00Z",
            status: "PENDING",
            bookedEntity: BookedEntity(title: "Group Workshop"),
            contactDetails: ContactDetails(firstName: "Bob", lastName: "Smith", email: "bob@example.com")
        ),
    ]
}

// MARK: - Demo Wix Group Model

public struct DemoWixGroup: Codable, Sendable {
    public var id: String
    public var name: String
    public var slug: String
    public var description: String
    public var memberCount: Int
    public var ownerId: String
    public var settings: Settings

    public struct Settings: Codable, Sendable {
        public var memberWelcomeMessage: String

        public func toDict() -> [String: Any] {
            ["memberWelcomeMessage": memberWelcomeMessage]
        }
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "slug": slug,
            "description": description,
            "memberCount": memberCount,
            "ownerId": ownerId,
            "settings": settings.toDict()
        ]
    }

    static let seedData: [DemoWixGroup] = [
        DemoWixGroup(
            id: "group-001",
            name: "Founders Circle",
            slug: "founders-circle",
            description: "A private group for launch partners and early members.",
            memberCount: 42,
            ownerId: "member-001",
            settings: Settings(memberWelcomeMessage: "Welcome to the founders circle.")
        ),
        DemoWixGroup(
            id: "group-002",
            name: "Workshop Alumni",
            slug: "workshop-alumni",
            description: "Past workshop attendees sharing templates and follow-ups.",
            memberCount: 118,
            ownerId: "member-002",
            settings: Settings(memberWelcomeMessage: "Introduce yourself and share what you build.")
        ),
    ]
}

// MARK: - Demo Wix Comment Model

public struct DemoWixComment: Codable, Sendable {
    public var id: String
    public var entityId: String
    public var status: String
    public var createdDate: String
    public var author: Author
    public var content: Content

    public struct Author: Codable, Sendable {
        public var memberId: String

        public func toDict() -> [String: Any] {
            ["memberId": memberId]
        }
    }

    public struct Content: Codable, Sendable {
        public var plainText: String

        public func toDict() -> [String: Any] {
            ["plainText": plainText]
        }
    }

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "entityId": entityId,
            "status": status,
            "createdDate": createdDate,
            "author": author.toDict(),
            "content": content.toDict()
        ]
    }

    static let seedData: [DemoWixComment] = [
        DemoWixComment(
            id: "comment-001",
            entityId: "bp-001-aaaa-bbbb-cccc",
            status: "VISIBLE",
            createdDate: "2026-03-18T09:30:00Z",
            author: Author(memberId: "member-100"),
            content: Content(plainText: "This walkthrough made the first sync flow much clearer.")
        ),
        DemoWixComment(
            id: "comment-002",
            entityId: "bp-002-dddd-eeee-ffff",
            status: "VISIBLE",
            createdDate: "2026-03-19T11:00:00Z",
            author: Author(memberId: "member-101"),
            content: Content(plainText: "Would love an example for media-heavy collections too.")
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

// MARK: - Demo Wix Collection Item Model

public struct DemoWixCollectionItem: Codable, Sendable {
    public var id: String
    public var title: String
    public var slug: String
    public var status: String
    public var collectionId: String

    public func toDict() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "slug": slug,
            "status": status,
            "collectionId": collectionId
        ]
    }

    static let seedData: [String: [DemoWixCollectionItem]] = [
        "col-001": [
            DemoWixCollectionItem(id: "item-blog-001", title: "Getting Started with API2File", slug: "getting-started-with-api2file", status: "PUBLISHED", collectionId: "col-001"),
            DemoWixCollectionItem(id: "item-blog-002", title: "Advanced Sync Patterns", slug: "advanced-sync-patterns", status: "PUBLISHED", collectionId: "col-001"),
        ],
        "col-002": [
            DemoWixCollectionItem(id: "item-product-001", title: "Wireless Mouse", slug: "wireless-mouse", status: "VISIBLE", collectionId: "col-002"),
            DemoWixCollectionItem(id: "item-product-002", title: "USB-C Hub", slug: "usb-c-hub", status: "VISIBLE", collectionId: "col-002"),
            DemoWixCollectionItem(id: "item-product-003", title: "Developer Sticker Pack", slug: "developer-sticker-pack", status: "HIDDEN", collectionId: "col-002"),
        ],
        "col-003": [
            DemoWixCollectionItem(id: "item-team-001", title: "Alice Johnson", slug: "alice-johnson", status: "ACTIVE", collectionId: "col-003"),
            DemoWixCollectionItem(id: "item-team-002", title: "Bob Smith", slug: "bob-smith", status: "ACTIVE", collectionId: "col-003"),
        ],
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
