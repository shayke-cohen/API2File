import SwiftUI
import API2FileCore

@main
struct API2FileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .onAppear {
                    appState.startEngine()
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

    private var syncEngine: SyncEngine?
    private var localServer: LocalServer?
    private var refreshTask: Task<Void, Never>?

    var menuBarIcon: String {
        if isPaused { return "icloud.slash" }
        if services.contains(where: { $0.status == .error }) { return "exclamationmark.icloud" }
        if services.contains(where: { $0.status == .syncing }) { return "arrow.triangle.2.circlepath.icloud" }
        return "checkmark.icloud"
    }

    func startEngine() {
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
                print("API2File: Failed to start sync engine: \(error)")
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

    func togglePause() {
        isPaused.toggle()
        Task {
            await syncEngine?.setPaused(isPaused)
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
