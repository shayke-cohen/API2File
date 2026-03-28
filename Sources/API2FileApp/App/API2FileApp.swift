import SwiftUI
import API2FileCore
#if DEBUG
#if canImport(AppXray)
import AppXray
#endif
#endif

@main
struct API2FileApp: App {
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)

        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        #if canImport(AppXray)
        let xrayMode: AppXrayConnectionMode =
            ProcessInfo.processInfo.environment["API2FILE_APPXRAY_MODE"] == "server"
            ? .server
            : .client
        AppXray.shared.start(config: AppXrayConfig(
            appName: "API2File",
            platform: AppXrayConfig.macos,
            mode: xrayMode
        ))
        AppXray.shared.registerObservableObject(state, name: "appState", setters: [
            "isPaused": { state.isPaused = $0 as! Bool }
        ])
        #endif
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
        }

        Window("Dashboard", id: "dashboard") {
            DashboardRootView(appState: appState)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
    }
}

struct SQLMirrorTableSummary: Decodable, Identifiable {
    let tableName: String
    let resourceName: String
    let rowCount: Int

    var id: String { tableName }

    private enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case resourceName = "resource_name"
        case rowCount = "row_count"
    }
}

struct SQLMirrorTableColumn: Decodable, Identifiable {
    let cid: Int
    let name: String
    let type: String
    let notNull: Int
    let defaultValue: String?
    let primaryKey: Int

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case cid
        case name
        case type
        case notNull = "notnull"
        case defaultValue = "dflt_value"
        case primaryKey = "pk"
    }
}

struct SQLMirrorTableDescription: Decodable {
    let databasePath: String
    let table: String
    let resourceName: String
    let rowCount: Int
    let columns: [SQLMirrorTableColumn]
}

struct SQLMirrorQueryRow: Identifiable {
    let id = UUID()
    let values: [String: String]
    let recordId: String?
}

struct SQLMirrorQueryResult {
    let databasePath: String?
    let query: String
    let rowCount: Int
    let columns: [String]
    let rows: [SQLMirrorQueryRow]
}

enum SQLExplorerError: LocalizedError {
    case unavailable
    case invalidResponse
    case missingFilePath(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The sync engine is not available yet."
        case .invalidResponse:
            return "API2File returned an unexpected SQLite response."
        case .missingFilePath(let path):
            return "The resolved file does not exist: \(path)"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = []
    @Published var isPaused: Bool = false
    @Published var config: GlobalConfig = .init() {
        didSet {
            publishFinderBadgeSnapshot()
        }
    }
    @Published var recentActivity: [SyncHistoryEntry] = []

    private(set) var syncEngine: SyncEngine?
    private(set) var localServer: LocalServer?
    private var refreshTask: Task<Void, Never>?
    private var engineStarted = false
    private var addServiceWindow: NSWindow?
    private var webViewBridge: WebViewBridge?
    /// Shared WebViewStore for the Browser pane — also serves as BrowserControlDelegate for MCP
    let sharedWebViewStore = WebViewStore()
    private var lastSyncTimes: [String: Date] = [:]

    init() {
        // Auto-start engine on creation
        Task { @MainActor [weak self] in
            self?.startEngine()
        }
    }

    var menuBarIcon: String {
        if isPaused { return "icloud.slash" }
        if services.contains(where: { $0.status == .error }) { return "exclamationmark.icloud" }
        if services.contains(where: { $0.status == .syncing }) { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    func startEngine() {
        NSLog("AppState startEngine called")
        guard !engineStarted else { return }
        engineStarted = true
        NSLog("AppState starting sync engine")
        let config = GlobalConfig.loadOrDefault(syncFolder: GlobalConfig().resolvedSyncFolder)
        self.config = config
        publishFinderBadgeSnapshot()

        let engine = SyncEngine(config: config)
        self.syncEngine = engine

        // Wire up deletion confirmation — shows a modal NSAlert before any remote delete
        Task {
            await engine.setDeletionConfirmationHandler { info in
                await MainActor.run {
                    AppState.showDeletionConfirmation(info)
                }
            }
        }

        Task {
            do {
                // Seed bundled adapters into ~/.api2file/adapters/ before starting
                try? await AdapterStore.shared.seedIfNeeded()

                NSLog("AppState starting SyncEngine")
                try await engine.start()
                NSLog("AppState SyncEngine started")

                // Start local REST server
                let server = LocalServer(port: UInt16(config.serverPort), syncEngine: engine)
                NSLog("AppState starting LocalServer on port %ld", config.serverPort)
                try await server.start()
                self.localServer = server
                NSLog("AppState LocalServer started on port %ld", config.serverPort)

                // Register shared WebViewStore as browser delegate for MCP
                await server.setBrowserDelegate(self.sharedWebViewStore)

                // Write port discovery file for MCP binary
                Self.writeServerInfo(port: config.serverPort)
                NSLog("AppState wrote server info for port %ld", config.serverPort)

                // Refresh services list
                await refreshServices()
            } catch {
                NSLog("AppState failed to start: %@", error.localizedDescription)
            }
        }

        // Periodic refresh of service statuses + live reload
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await refreshServices()
                await checkLiveReload()
            }
        }
    }

    func stopEngine() {
        refreshTask?.cancel()
        Self.removeServerInfo()
        NSLog("AppState stopEngine called")
        Task {
            await syncEngine?.stop()
            await localServer?.stop()
            NSLog("AppState stopEngine finished")
        }
    }

    func syncNow() {
        Task {
            for service in services {
                await syncEngine?.triggerSync(serviceId: service.serviceId)
            }
            await refreshServices()
            await refreshHistory()
        }
    }

    func syncService(serviceId: String) {
        Task {
            await syncEngine?.triggerSync(serviceId: serviceId)
            await refreshServices()
            await refreshHistory()
        }
    }

    func removeService(serviceId: String) {
        Task {
            await syncEngine?.removeService(serviceId: serviceId)
            await refreshServices()
        }
    }

    func togglePause() {
        isPaused.toggle()
        Task {
            await syncEngine?.setPaused(isPaused)
        }
    }

    func openAddServiceWindow() {
        // Defer window creation to next run loop iteration to avoid
        // reentrancy issues when called from within MenuBarExtra
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // If window already exists, just bring it front
            if let window = self.addServiceWindow, window.isVisible {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }

            let addServiceView = AddServiceView(onComplete: { [weak self] serviceId in
                guard let self else { return }
                Task { @MainActor in
                    if let serviceId {
                        try? await self.syncEngine?.registerNewService(serviceId)
                    }
                    await self.refreshServices()
                }
            })

            let hostingController = NSHostingController(rootView: addServiceView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Add Service"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 440, height: 360))
            window.center()
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.addServiceWindow = window
        }
    }

    func openLogs() {
        Task {
            if let logDir = await ActivityLogger.shared.logDirectoryURL() {
                NSWorkspace.shared.open(logDir)
            }
        }
    }

    func setServiceEnabled(serviceId: String, enabled: Bool) {
        Task {
            await syncEngine?.setServiceEnabled(serviceId: serviceId, enabled: enabled)
            await refreshServices()
        }
    }

    func updateAPIKey(serviceId: String, newKey: String) {
        Task {
            let keychainKey = "api2file.\(serviceId).key"
            let keychain = KeychainManager()
            await keychain.save(key: keychainKey, value: newKey)
            // Reload the service to pick up the new credential
            if let engine = syncEngine {
                await engine.removeService(serviceId: serviceId)
                try? await engine.registerNewService(serviceId)
            }
            await refreshServices()
        }
    }

    func refreshHistory(serviceId: String? = nil) async {
        guard let engine = syncEngine else { return }
        let entries: [SyncHistoryEntry]
        if let serviceId {
            entries = await engine.getHistory(serviceId: serviceId, limit: 50)
        } else {
            entries = await engine.getAllHistory(limit: 50)
        }
        await MainActor.run {
            self.recentActivity = entries
        }
    }

    func getServiceHistory(serviceId: String, limit: Int = 10) async -> [SyncHistoryEntry] {
        guard let engine = syncEngine else { return [] }
        return await engine.getHistory(serviceId: serviceId, limit: limit)
    }

    // MARK: - SQLite Explorer

    func listSQLTables(serviceId: String) async -> [SQLMirrorTableSummary] {
        guard let engine = syncEngine else { return [] }
        do {
            let data = try await engine.listSQLTables(serviceId: serviceId)
            let payload = try JSONDecoder().decode(SQLTablesPayload.self, from: data)
            return payload.tables
        } catch {
            print("[API2File] Failed to list SQL tables for \(serviceId): \(error)")
            return []
        }
    }

    func describeSQLTable(serviceId: String, table: String) async -> SQLMirrorTableDescription? {
        guard let engine = syncEngine else { return nil }
        do {
            let data = try await engine.describeSQLTable(serviceId: serviceId, table: table)
            return try JSONDecoder().decode(SQLMirrorTableDescription.self, from: data)
        } catch {
            print("[API2File] Failed to describe SQL table \(table) for \(serviceId): \(error)")
            return nil
        }
    }

    func runSQLQuery(serviceId: String, query: String) async throws -> SQLMirrorQueryResult {
        guard let engine = syncEngine else {
            throw SQLExplorerError.unavailable
        }

        let data = try await engine.querySQL(serviceId: serviceId, query: query)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLExplorerError.invalidResponse
        }

        let rawRows = object["rows"] as? [[String: Any]] ?? []
        let columns = resolvedColumns(from: object, rows: rawRows)
        let rows = rawRows.map { row in
            SQLMirrorQueryRow(
                values: Dictionary(uniqueKeysWithValues: columns.map { column in
                    (column, Self.sqlDisplayString(row[column]))
                }),
                recordId: Self.sqlRecordIdentifier(from: row)
            )
        }

        return SQLMirrorQueryResult(
            databasePath: object["databasePath"] as? String,
            query: object["query"] as? String ?? query,
            rowCount: object["rowCount"] as? Int ?? rows.count,
            columns: columns,
            rows: rows
        )
    }

    func openSQLRecordInEditor(
        serviceId: String,
        resource: String,
        recordId: String,
        surface: String
    ) async throws {
        guard let engine = syncEngine else {
            throw SQLExplorerError.unavailable
        }

        let data = try await engine.getRecordByID(serviceId: serviceId, resource: resource, recordId: recordId)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLExplorerError.invalidResponse
        }

        let key = surface == "canonical" ? "canonicalFile" : "projectionFile"
        guard let path = object[key] as? String else {
            throw SQLExplorerError.invalidResponse
        }
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SQLExplorerError.missingFilePath(path)
        }

        openFileInEditor(fileURL)
    }

    // MARK: - Browser Window

    func openBrowserWindow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.webViewBridge == nil {
                self.webViewBridge = WebViewBridge()
            }
            self.webViewBridge?.openWindow()
            // Inject into LocalServer so HTTP routes can reach the WebView
            Task {
                await self.localServer?.setBrowserDelegate(self.webViewBridge)
            }
        }
    }

    func openLiteManager() {
        openLiteManager(serviceId: nil)
    }

    func openLiteManager(serviceId: String?) {
        if var components = URLComponents(string: "http://localhost:\(config.serverPort)/lite") {
            if let serviceId {
                components.fragment = "service=\(serviceId)"
            }
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        }

        if let url = liteManagerURL(serviceId: serviceId) {
            NSWorkspace.shared.open(url)
            return
        }

        var fallbackURL = config.resolvedSyncFolder
        if let serviceId {
            fallbackURL.appendPathComponent(serviceId)
        }
        NSWorkspace.shared.open(fallbackURL)
    }

    // MARK: - Live Reload

    private func checkLiveReload() async {
        guard let bridge = webViewBridge, await bridge.isBrowserOpen() else { return }
        var anyChanged = false
        for service in services {
            if let syncTime = service.lastSyncTime {
                if let prev = lastSyncTimes[service.serviceId], prev != syncTime {
                    anyChanged = true
                }
                lastSyncTimes[service.serviceId] = syncTime
            }
        }
        if anyChanged {
            try? await bridge.reload()
        }
    }

    private func liteManagerURL(serviceId: String?) -> URL? {
        let candidates = [
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "LiteManager"),
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "website"),
            Self.developmentLiteManagerURL()
        ]

        guard var url = candidates.compactMap({ $0 }).first else {
            return nil
        }

        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "serverPort", value: String(config.serverPort))
            ]
            if let serviceId {
                components.fragment = "service=\(serviceId)"
            }
            if let deepLinkedURL = components.url {
                url = deepLinkedURL
            }
        }

        return url
    }

    private static func developmentLiteManagerURL() -> URL? {
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRootURL = sourceFileURL
            .deletingLastPathComponent() // API2FileApp.swift
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // API2FileApp
            .deletingLastPathComponent() // Sources
        let websiteURL = repoRootURL
            .appendingPathComponent("website", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)

        guard FileManager.default.fileExists(atPath: websiteURL.path) else {
            return nil
        }
        return websiteURL
    }

    // MARK: - Claude Code Launcher

    func launchClaudeCode(serviceId: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Check if claude CLI is installed
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["claude"]
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            whichProcess.standardError = pipe
            try? whichProcess.run()
            whichProcess.waitUntilExit()

            guard whichProcess.terminationStatus == 0 else {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Claude Code not found"
                alert.informativeText = "Install Claude Code CLI first:\n\nnpm install -g @anthropic-ai/claude-code\n\nOr visit https://claude.ai/download"
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }

            // Generate MCP config
            let home = FileManager.default.homeDirectoryForCurrentUser
            let api2fileDir = home.appendingPathComponent(".api2file")
            try? FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

            // Find the MCP binary — check build output first, then ~/.api2file/bin/
            var mcpBinaryPath = api2fileDir.appendingPathComponent("bin/api2file-mcp").path
            // In development, use the build output
            let devBinary = home.appendingPathComponent("API2File/.build/debug/api2file-mcp").path
            if FileManager.default.fileExists(atPath: devBinary) {
                mcpBinaryPath = devBinary
            }

            let mcpConfig: [String: Any] = [
                "mcpServers": [
                    "api2file": [
                        "command": mcpBinaryPath,
                        "args": [] as [String]
                    ]
                ]
            ]
            let mcpConfigURL = api2fileDir.appendingPathComponent("mcp.json")
            if let data = try? JSONSerialization.data(withJSONObject: mcpConfig, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: mcpConfigURL, options: .atomic)
            }

            // Auto-navigate the shared browser to the service's siteUrl
            if let serviceId,
               let service = self.services.first(where: { $0.serviceId == serviceId }),
               let siteUrl = service.config.siteUrl {
                self.sharedWebViewStore.navigate(to: siteUrl)
            }

            // Detect terminal and launch — cd into service subfolder if provided
            var targetFolder = self.config.resolvedSyncFolder
            if let serviceId {
                targetFolder = targetFolder.appendingPathComponent(serviceId)
            }
            let command = "cd \(Self.shellEscape(targetFolder.path)) && claude --mcp-config \(Self.shellEscape(mcpConfigURL.path))"
            Self.openInTerminal(command: command)
        }
    }

    private static func openInTerminal(command: String) {
        // Write a .command file — macOS opens these in Terminal.app automatically
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".api2file/launch-claude.command")
        let scriptContent = "#!/bin/zsh\n\(command)\n"
        try? scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path
        )
        NSWorkspace.shared.open(scriptPath)
    }

    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Port Discovery File

    private static func writeServerInfo(port: Int) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".api2file")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "port": port,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "startedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("server.json"), options: .atomic)
        }
    }

    private static func removeServerInfo() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".api2file/server.json")
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Deletion Confirmation

    @MainActor
    static func showDeletionConfirmation(_ info: DeletionInfo) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning

        let kindLabel: String
        switch info.kind {
        case .fileDeletion:
            kindLabel = "File deleted"
        case .rowDeletion:
            kindLabel = "Rows removed"
        }

        alert.messageText = "\(kindLabel) — \(info.serviceName)"

        let countText: String
        if let count = info.recordCount {
            countText = "\(count) record\(count == 1 ? "" : "s")"
        } else {
            countText = "records"
        }
        alert.informativeText = "You deleted \"\(info.filePath)\" which maps to \(countText) on \(info.serviceName).\n\nDelete from server or restore the file?"

        alert.addButton(withTitle: "Delete from Server")
        alert.addButton(withTitle: "Cancel & Restore")

        // Bring the app to front so the alert is visible
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        return response == .alertFirstButtonReturn // true = proceed with delete
    }

    private func refreshServices() async {
        guard let engine = syncEngine else { return }
        let infos = await engine.getServices()
        await MainActor.run {
            self.services = infos
            self.publishFinderBadgeSnapshot()
        }
    }

    private func publishFinderBadgeSnapshot() {
        guard shouldUseFinderBadgeSharedContainer else {
            return
        }

        guard let defaults = FinderBadgeSupport.sharedDefaults() else { return }

        FinderBadgeSupport.setSyncRootURL(config.resolvedSyncFolder, in: defaults)
        if let bookmarkData = try? config.resolvedSyncFolder.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            FinderBadgeSupport.setSyncRootBookmarkData(bookmarkData, in: defaults)
        } else {
            FinderBadgeSupport.setSyncRootBookmarkData(nil, in: defaults)
        }
        FinderBadgeSupport.setBadgesEnabled(config.finderBadges, in: defaults)

        FinderBadgeSupport.clearBadgeStates(in: defaults)
        FinderBadgeSupport.clearServiceConfigs(in: defaults)

        for service in services {
            FinderBadgeSupport.setServiceConfig(service.config, forServiceId: service.serviceId, in: defaults)
        }

        guard config.finderBadges else {
            postFinderBadgeRefresh()
            return
        }

        for service in services {
            let serviceStatus = finderBadgeStatus(for: service.status)
            if !serviceStatus.isEmpty {
                FinderBadgeSupport.setBadgeState(serviceStatus, forRelativePath: service.serviceId, in: defaults)
            }

            publishFileBadgeStates(for: service, defaults: defaults)
        }

        postFinderBadgeRefresh()
    }

    private func publishFileBadgeStates(for service: ServiceInfo, defaults: UserDefaults) {
        let stateURL = config.resolvedSyncFolder
            .appendingPathComponent(service.serviceId, isDirectory: true)
            .appendingPathComponent(".api2file/state.json", isDirectory: false)

        guard let state = try? SyncState.load(from: stateURL) else { return }

        for (relativePath, fileState) in state.files {
            let normalizedStatus = FinderBadgeSupport.normalizeStatus(fileState.status.rawValue)
            guard !normalizedStatus.isEmpty else { continue }
            let badgePath = "\(service.serviceId)/\(FinderBadgeSupport.normalizeRelativePath(relativePath))"
            FinderBadgeSupport.setBadgeState(normalizedStatus, forRelativePath: badgePath, in: defaults)
        }
    }

    private func finderBadgeStatus(for serviceStatus: ServiceStatus) -> String {
        switch serviceStatus {
        case .connected:
            return "synced"
        case .syncing:
            return "syncing"
        case .error:
            return "error"
        case .paused, .disconnected:
            return ""
        }
    }

    private func postFinderBadgeRefresh() {
        DistributedNotificationCenter.default().post(
            name: FinderBadgeSupport.refreshNotificationName,
            object: nil
        )
    }

    private var shouldUseFinderBadgeSharedContainer: Bool {
        if ProcessInfo.processInfo.environment["API2FILE_ALLOW_APP_GROUP_ACCESS"] == "1" {
            return true
        }

        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let bundlePath = bundleURL.path

        let blockedPathFragments = [
            "/DerivedData/",
            "/.build/",
            "/build/Debug/",
            "/build/Release/"
        ]
        if blockedPathFragments.contains(where: { bundlePath.contains($0) }) {
            return false
        }

        if bundleURL.lastPathComponent == "API2File-sandboxed.app" {
            return false
        }

        let homeApplicationsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .resolvingSymlinksInPath()
            .path

        return bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(homeApplicationsPath + "/")
    }

    private struct SQLTablesPayload: Decodable {
        let tables: [SQLMirrorTableSummary]
    }

    private func resolvedColumns(from object: [String: Any], rows: [[String: Any]]) -> [String] {
        if let columns = object["columns"] as? [String], !columns.isEmpty {
            return columns
        }
        return rows.first.map { $0.keys.sorted() } ?? []
    }

    private static func sqlDisplayString(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return double.rounded() == double ? String(Int(double)) : String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\(array)"
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\(dictionary)"
        default:
            return String(describing: value ?? "")
        }
    }

    private static func sqlRecordIdentifier(from row: [String: Any]) -> String? {
        for key in ["_remote_id", "id", "_id"] {
            if let string = row[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let int = row[key] as? Int {
                return String(int)
            }
            if let double = row[key] as? Double {
                return double.rounded() == double ? String(Int(double)) : String(double)
            }
            if let number = row[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}
