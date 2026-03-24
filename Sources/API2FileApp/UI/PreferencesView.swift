import SwiftUI
import API2FileCore

struct PreferencesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab(config: $appState.config)
                .tabItem { Label("General", systemImage: "gear") }
                .testId("prefs-tab-general")

            ServicesTab(appState: appState)
                .tabItem { Label("Services", systemImage: "cloud") }
                .testId("prefs-tab-services")

            ActivityTab(appState: appState)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .testId("prefs-tab-activity")
        }
        .frame(width: 600, height: 500)
        .testId("preferences-window")
    }
}

struct GeneralTab: View {
    @Binding var config: GlobalConfig
    @State private var hasPendingAdapterUpdates = false

    var body: some View {
        Form {
            TextField("Sync Folder:", text: $config.syncFolder)
                .testId("general-sync-folder")
            HStack {
                Text("Adapters Folder:")
                Spacer()
                Text("~/.api2file/adapters")
                    .foregroundStyle(.secondary)
                if hasPendingAdapterUpdates {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 8, height: 8)
                        .help("Adapter updates available — check for *.adapter_new.json files in ~/.api2file/adapters/")
                        .testId("general-adapters-update-badge")
                }
                Button("Reveal") {
                    NSWorkspace.shared.open(AdapterStore.userAdaptersURL)
                }
                .testId("general-adapters-reveal")
            }
            Toggle("Launch at login", isOn: $config.launchAtLogin)
                .testId("general-launch-at-login")
            Toggle("Auto-commit to git", isOn: $config.gitAutoCommit)
                .testId("general-git-auto-commit")
            TextField("Commit message format:", text: $config.commitMessageFormat)
                .testId("general-commit-format")
            Stepper("Default sync interval: \(config.defaultSyncInterval)s", value: $config.defaultSyncInterval, in: 10...600, step: 10)
                .testId("general-sync-interval")
            Toggle("Show notifications", isOn: $config.showNotifications)
                .testId("general-show-notifications")
            Toggle("Finder badges", isOn: $config.finderBadges)
                .testId("general-finder-badges")
            Stepper("Server port: \(config.serverPort)", value: $config.serverPort, in: 1024...65535)
                .testId("general-server-port")
        }
        .padding()
        .task {
            hasPendingAdapterUpdates = await AdapterStore.shared.hasPendingUpdates()
        }
    }
}

struct ServicesTab: View {
    @ObservedObject var appState: AppState
    @State private var selectedServiceId: String?

    var body: some View {
        VStack(spacing: 0) {
            if appState.services.isEmpty {
                emptyState
            } else {
                NavigationSplitView {
                    List(appState.services, id: \.serviceId, selection: $selectedServiceId) { service in
                        ServiceListRow(service: service)
                            .testId("services-row-\(service.serviceId)")
                            .contextMenu {
                                Button("Sync Now") {
                                    appState.syncService(serviceId: service.serviceId)
                                }
                                .testId("services-ctx-sync-\(service.serviceId)")
                                Button("Open Folder") {
                                    let url = appState.config.resolvedSyncFolder
                                        .appendingPathComponent(service.serviceId)
                                    NSWorkspace.shared.open(url)
                                }
                                .testId("services-ctx-folder-\(service.serviceId)")
                                Divider()
                                Button("Disconnect...", role: .destructive) {
                                    appState.removeService(serviceId: service.serviceId)
                                }
                                .testId("services-ctx-disconnect-\(service.serviceId)")
                            }
                    }
                    .listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
                    .testId("services-list")
                } detail: {
                    if let id = selectedServiceId,
                       let service = appState.services.first(where: { $0.serviceId == id }) {
                        ServiceDetailView(service: service, appState: appState)
                    } else {
                        Text("Select a service")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .testId("services-empty-detail")
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    appState.openAddServiceWindow()
                } label: {
                    Image(systemName: "plus")
                }
                .testId("services-add-service")
                .help("Add Service...")

                Button {
                    if let id = selectedServiceId {
                        appState.removeService(serviceId: id)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedServiceId == nil)
                .testId("services-remove-service")
                .help("Disconnect Service")

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No services connected")
                .font(.headline)
                .testId("services-empty-title")
            Text("Connect a cloud service to start syncing\ndata as files on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Service...") {
                appState.openAddServiceWindow()
            }
            .buttonStyle(.borderedProminent)
            .testId("services-empty-add")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .testId("services-empty-state")
    }
}

struct ServiceListRow: View {
    let service: ServiceInfo

    private var statusColor: Color {
        switch service.status {
        case .connected: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .testId("service-row-status-\(service.serviceId)")
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .lineLimit(1)
                    .testId("service-row-name-\(service.serviceId)")
                if let time = service.lastSyncTime {
                    Text(time, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("\(service.fileCount) files")
                .foregroundStyle(.secondary)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()
                .testId("service-row-count-\(service.serviceId)")
        }
    }
}
