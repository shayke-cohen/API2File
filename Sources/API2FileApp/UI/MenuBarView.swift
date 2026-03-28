import SwiftUI
import API2FileCore

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Services section
        if appState.services.isEmpty {
            Text("No services connected")
                .testId("menubar-empty-label")
            Button("Add Your First Service...") {
                appState.openAddServiceWindow()
            }
            .testId("menubar-add-first-service")
        } else {
            ForEach(enabledServices, id: \.serviceId) { service in
                serviceMenu(service)
            }
        }

        Divider()

        Button("Add Service...") {
            appState.openAddServiceWindow()
        }
        .testId("menubar-add-service")

        Button("Sync Now") {
            appState.syncNow()
        }
        .disabled(appState.isPaused || appState.services.isEmpty)
        .testId("menubar-sync-now")

        Menu("Recent Activity") {
            if appState.recentActivity.isEmpty {
                Text("No recent activity")
            } else {
                ForEach(appState.recentActivity.prefix(5)) { entry in
                    Text("\(entry.direction == .pull ? "↓" : "↑") \(entry.serviceName) — \(entry.summary) — \(entry.timestamp.formatted(.relative(presentation: .named)))")
                }
            }
        }
        .disabled(appState.services.isEmpty)
        .testId("menubar-recent-activity")

        Button(appState.isPaused ? "Resume Syncing" : "Pause Syncing") {
            appState.togglePause()
        }
        .disabled(appState.services.isEmpty)
        .testId("menubar-toggle-pause")

        Divider()

        Button("Open in Finder") {
            let url = appState.config.resolvedSyncFolder
            FinderSupport.openInFinder(url)
        }
        .testId("menubar-open-folder")

        Button("Open Lite Manager") {
            appState.openLiteManager()
        }
        .testId("menubar-open-lite-manager")

        Button("Open \(appState.codingAgentDisplayName)...") {
            appState.launchCodingAgent()
        }
        .testId("menubar-open-claude-code")

        Button("Open Logs") {
            appState.openLogs()
        }
        .testId("menubar-open-logs")

        Button("Dashboard...") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        .testId("menubar-dashboard")

        Divider()

        Button("Quit API2File") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .testId("menubar-quit")
    }

    private var enabledServices: [ServiceInfo] {
        appState.services.filter { $0.config.enabled != false }
    }

    @ViewBuilder
    private func serviceMenu(_ service: ServiceInfo) -> some View {
        Menu {
            Button("Sync Now") {
                appState.syncService(serviceId: service.serviceId)
            }
            .disabled(service.status == .syncing)
            .testId("menubar-service-sync-\(service.serviceId)")

            Button("Open Folder") {
                let url = appState.config.resolvedSyncFolder
                    .appendingPathComponent(service.serviceId)
                FinderSupport.openInFinder(url)
            }
            .testId("menubar-service-folder-\(service.serviceId)")

            Button("Open Lite Page") {
                appState.openLiteManager(serviceId: service.serviceId)
            }
            .testId("menubar-service-lite-page-\(service.serviceId)")

            if let time = service.lastSyncTime {
                Divider()
                Text("Last synced: \(time.formatted(.relative(presentation: .named)))")
            }

            Text("\(service.fileCount) files")
        } label: {
            let icon = statusIcon(service.status)
            Text("\(icon) \(service.displayName) — \(statusText(service))")
        }
        .testId("menubar-service-\(service.serviceId)")
    }

    private func statusIcon(_ status: ServiceStatus) -> String {
        switch status {
        case .connected: return "🟢"
        case .syncing: return "🔵"
        case .paused: return "⏸"
        case .error: return "🔴"
        case .disconnected: return "⚪"
        }
    }

    private func statusText(_ service: ServiceInfo) -> String {
        switch service.status {
        case .connected: return "Synced"
        case .syncing: return "Syncing..."
        case .paused: return "Paused"
        case .error: return service.errorMessage ?? "Error"
        case .disconnected: return "Disconnected"
        }
    }
}
