import SwiftUI
import API2FileCore

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.services.isEmpty {
                Text("No services connected")
                    .foregroundStyle(.secondary)
                Divider()
            } else {
                ForEach(appState.services, id: \.serviceId) { service in
                    ServiceRow(service: service)
                }
                Divider()
            }

            Button("Add Service...") {
                // TODO: Open add service flow
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
}

struct ServiceRow: View {
    let service: ServiceInfo

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(service.displayName)
                .fontWeight(.medium)
            Spacer()
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
