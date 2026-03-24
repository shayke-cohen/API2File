import SwiftUI
import API2FileCore

struct PreferencesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab(config: $appState.config)
                .tabItem { Label("General", systemImage: "gear") }

            ServicesTab(appState: appState)
                .tabItem { Label("Services", systemImage: "cloud") }

            ActivityTab(appState: appState)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 600, height: 500)
    }
}

struct GeneralTab: View {
    @Binding var config: GlobalConfig
    @State private var hasPendingAdapterUpdates = false

    var body: some View {
        Form {
            TextField("Sync Folder:", text: $config.syncFolder)
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
                }
                Button("Reveal") {
                    NSWorkspace.shared.open(AdapterStore.userAdaptersURL)
                }
            }
            Toggle("Launch at login", isOn: $config.launchAtLogin)
            Toggle("Auto-commit to git", isOn: $config.gitAutoCommit)
            TextField("Commit message format:", text: $config.commitMessageFormat)
            Stepper("Default sync interval: \(config.defaultSyncInterval)s", value: $config.defaultSyncInterval, in: 10...600, step: 10)
            Toggle("Show notifications", isOn: $config.showNotifications)
            Toggle("Finder badges", isOn: $config.finderBadges)
            Stepper("Server port: \(config.serverPort)", value: $config.serverPort, in: 1024...65535)
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
                            .contextMenu {
                                Button("Sync Now") {
                                    appState.syncService(serviceId: service.serviceId)
                                }
                                Button("Open Folder") {
                                    let url = appState.config.resolvedSyncFolder
                                        .appendingPathComponent(service.serviceId)
                                    NSWorkspace.shared.open(url)
                                }
                                Divider()
                                Button("Disconnect...", role: .destructive) {
                                    appState.removeService(serviceId: service.serviceId)
                                }
                            }
                    }
                    .listStyle(.sidebar)
                } detail: {
                    if let id = selectedServiceId,
                       let service = appState.services.first(where: { $0.serviceId == id }) {
                        ServiceDetailView(service: service, appState: appState)
                    } else {
                        Text("Select a service")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Add Service...") {
                    appState.openAddServiceWindow()
                }
            }
            .padding(10)
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
            Text("Connect a cloud service to start syncing\ndata as files on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Add Service...") {
                appState.openAddServiceWindow()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServiceListRow: View {
    let service: ServiceInfo

    var body: some View {
        HStack {
            Circle()
                .fill(service.status == .error ? Color.red : Color.green)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                if let time = service.lastSyncTime {
                    Text(time, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("\(service.fileCount) files")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
