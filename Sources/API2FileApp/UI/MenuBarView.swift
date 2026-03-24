import SwiftUI
import API2FileCore

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // Services section
        if appState.services.isEmpty {
            Text("No services connected")
            Button("Add Your First Service...") {
                appState.openAddServiceWindow()
            }
        } else {
            ForEach(appState.services, id: \.serviceId) { service in
                serviceMenu(service)
            }
        }

        Divider()

        Button("Add Service...") {
            appState.openAddServiceWindow()
        }

        Button("Sync Now") {
            appState.syncNow()
        }
        .disabled(appState.isPaused || appState.services.isEmpty)

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

        Button(appState.isPaused ? "Resume Syncing" : "Pause Syncing") {
            appState.togglePause()
        }
        .disabled(appState.services.isEmpty)

        Divider()

        Button("Open ~/API2File") {
            let url = appState.config.resolvedSyncFolder
            NSWorkspace.shared.open(url)
        }

        Button("Open Logs") {
            appState.openLogs()
        }

        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Preferences...")
            }
        } else {
            Button("Preferences...") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }

        Divider()

        Button("Quit API2File") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func serviceMenu(_ service: ServiceInfo) -> some View {
        Menu {
            Button("Sync Now") {
                appState.syncService(serviceId: service.serviceId)
            }
            .disabled(service.status == .syncing)

            Button("Open Folder") {
                let url = appState.config.resolvedSyncFolder
                    .appendingPathComponent(service.serviceId)
                NSWorkspace.shared.open(url)
            }

            if let time = service.lastSyncTime {
                Divider()
                Text("Last synced: \(time.formatted(.relative(presentation: .named)))")
            }

            Text("\(service.fileCount) files")
        } label: {
            let icon = statusIcon(service.status)
            Text("\(icon) \(service.displayName) — \(statusText(service))")
        }
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
