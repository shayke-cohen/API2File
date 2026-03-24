import SwiftUI
import API2FileCore
#if DEBUG
import AppXray
#endif

@main
struct API2FileApp: App {
    @StateObject private var appState = AppState()

    init() {
        #if DEBUG
        AppXray.shared.start(config: AppXrayConfig(
            appName: "API2File",
            platform: AppXrayConfig.macos,
            port: 19420
        ))
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .onAppear {
                    #if DEBUG
                    AppXray.shared.registerObservableObject(appState, name: "appState", setters: [
                        "isPaused": { appState.isPaused = $0 as! Bool }
                    ])
                    #endif
                }
        } label: {
            Image(systemName: appState.menuBarIcon)
        }

        Settings {
            PreferencesView(appState: appState)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var services: [ServiceInfo] = []
    @Published var isPaused: Bool = false
    @Published var config: GlobalConfig = .init()
    @Published var recentActivity: [SyncHistoryEntry] = []

    private var syncEngine: SyncEngine?
    private var localServer: LocalServer?
    private var refreshTask: Task<Void, Never>?
    private var engineStarted = false
    private var addServiceWindow: NSWindow?

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

                // Refresh services list
                await refreshServices()
            } catch {
                print("[API2File] Failed to start: \(error)")
            }
        }

        // Periodic refresh of service statuses
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                await refreshServices()
            }
        }
    }

    func stopEngine() {
        refreshTask?.cancel()
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
