import SwiftUI
import API2FileCore

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.services.isEmpty {
                emptyState
                Divider()
            } else {
                ForEach(appState.services, id: \.serviceId) { service in
                    ServiceRow(service: service) {
                        appState.syncService(serviceId: service.serviceId)
                    }
                }
                Divider()
            }

            Button("Add Service...") {
                appState.openAddServiceWindow()
            }

            Button("Sync Now") {
                appState.syncNow()
            }
            .disabled(appState.isPaused || appState.services.isEmpty)

            Button(appState.isPaused ? "Resume Syncing" : "Pause Syncing") {
                appState.togglePause()
            }
            .disabled(appState.services.isEmpty)

            Divider()

            Button("Open ~/API2File") {
                let url = appState.config.resolvedSyncFolder
                NSWorkspace.shared.open(url)
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
        .padding(4)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "cloud.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No services connected")
                .fontWeight(.medium)
            Text("Sync cloud data to local files")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add Your First Service...") {
                appState.openAddServiceWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct ServiceRow: View {
    let service: ServiceInfo
    let onSync: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName)
                    .fontWeight(.medium)
                if let lastSync = service.lastSyncTime {
                    Text(lastSync, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(service.status == .syncing)
            .help("Sync \(service.displayName)")
            Text(statusText)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .connected: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch service.status {
        case .connected: return "Synced"
        case .syncing: return "Syncing..."
        case .paused: return "Paused"
        case .error: return service.errorMessage ?? "Error"
        case .disconnected: return "Disconnected"
        }
    }
}
