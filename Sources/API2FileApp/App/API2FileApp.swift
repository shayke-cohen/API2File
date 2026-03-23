import SwiftUI
import API2FileCore

@main
struct API2FileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
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
        guard !engineStarted else { return }
        engineStarted = true
        print("[API2File] Starting sync engine...")
        let config = GlobalConfig.loadOrDefault(syncFolder: GlobalConfig().resolvedSyncFolder)
        self.config = config

        let engine = SyncEngine(config: config)
        self.syncEngine = engine

        Task {
            do {
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
        }
    }

    func syncService(serviceId: String) {
        Task {
            await syncEngine?.triggerSync(serviceId: serviceId)
            await refreshServices()
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
        // If window already exists, just bring it front
        if let window = addServiceWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let addServiceView = AddServiceView(onComplete: { [weak self] serviceId in
            guard let self else { return }
            Task { @MainActor in
                // Register the new service with the engine
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

    private func refreshServices() async {
        guard let engine = syncEngine else { return }
        let infos = await engine.getServices()
        await MainActor.run {
            self.services = infos
        }
    }
}
