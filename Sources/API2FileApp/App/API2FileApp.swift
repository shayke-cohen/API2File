import SwiftUI
import API2FileCore
#if DEBUG
import AppXray
#endif

@main
struct API2FileApp: App {
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)

        NSApplication.shared.setActivationPolicy(.regular)
        #if DEBUG
        AppXray.shared.start(config: AppXrayConfig(
            appName: "API2File",
            platform: AppXrayConfig.macos,
            mode: .client
        ))
        AppXray.shared.registerObservableObject(state, name: "appState", setters: [
            "isPaused": { state.isPaused = $0 as! Bool }
        ])
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
        }

        Window("Dashboard", id: "dashboard") {
            PreferencesView(appState: appState)
        }
        .defaultSize(width: 900, height: 600)
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = []
    @Published var isPaused: Bool = false
    @Published var config: GlobalConfig = .init()
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
        print("[AppState] startEngine called")
        guard !engineStarted else { return }
        engineStarted = true
        print("[API2File] Starting sync engine...")
        let config = GlobalConfig.loadOrDefault(syncFolder: GlobalConfig().resolvedSyncFolder)
        self.config = config

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

                try await engine.start()

                // Start local REST server
                let server = LocalServer(port: UInt16(config.serverPort), syncEngine: engine)
                try await server.start()
                self.localServer = server

                // Register shared WebViewStore as browser delegate for MCP
                await server.setBrowserDelegate(self.sharedWebViewStore)

                // Write port discovery file for MCP binary
                Self.writeServerInfo(port: config.serverPort)

                // Refresh services list
                await refreshServices()
            } catch {
                print("[API2File] Failed to start: \(error)")
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
        Task {
            await syncEngine?.stop()
            await localServer?.stop()
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
        }
    }
}
