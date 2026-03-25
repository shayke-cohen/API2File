import SwiftUI
import API2FileCore

// MARK: - Sidebar Item

private enum SidebarItem: Hashable {
    case general
    case service(String)
    case activity
}

// MARK: - Main Preferences View

struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selection: SidebarItem? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // General
                Label("General", systemImage: "gear")
                    .tag(SidebarItem.general)
                    .testId("sidebar-general")

                // Services section
                Section("Services") {
                    ForEach(appState.services, id: \.serviceId) { service in
                        ServiceListRow(service: service)
                            .tag(SidebarItem.service(service.serviceId))
                            .testId("sidebar-service-\(service.serviceId)")
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
                }

                // Activity
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.activity)
                    .testId("sidebar-activity")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 6) {
                        Button {
                            appState.openAddServiceWindow()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .testId("sidebar-add-service")
                        .help("Add Service...")

                        Button {
                            if case .service(let id) = selection {
                                appState.removeService(serviceId: id)
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(!isServiceSelected)
                        .testId("sidebar-remove-service")
                        .help("Disconnect Service")

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        } detail: {
            detailView
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 540)
        .testId("preferences-window")
    }

    private var isServiceSelected: Bool {
        if case .service = selection { return true }
        return false
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralPane(config: $appState.config)
        case .service(let id):
            if let service = appState.services.first(where: { $0.serviceId == id }) {
                ServiceDetailView(service: service, appState: appState)
            } else {
                emptyDetail
            }
        case .activity:
            ActivityPane(appState: appState)
        case nil:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        Text("Select an item")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General Pane

struct GeneralPane: View {
    @Binding var config: GlobalConfig
    @State private var hasPendingAdapterUpdates = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Sync section
                GroupBox {
                    VStack(spacing: 10) {
                        settingRow("Sync Folder") {
                            TextField("", text: $config.syncFolder)
                                .textFieldStyle(.roundedBorder)
                                .testId("general-sync-folder")
                        }
                        settingRow("Sync Interval") {
                            HStack(spacing: 6) {
                                Stepper("\(config.defaultSyncInterval)s", value: $config.defaultSyncInterval, in: 10...600, step: 10)
                                    .testId("general-sync-interval")
                                Text("10–600s")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        settingRow("Adapters") {
                            HStack(spacing: 6) {
                                Text("~/.api2file/adapters")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                                if hasPendingAdapterUpdates {
                                    Circle()
                                        .fill(.yellow)
                                        .frame(width: 7, height: 7)
                                        .help("Adapter updates available")
                                        .testId("general-adapters-update-badge")
                                }
                                Button("Reveal") {
                                    NSWorkspace.shared.open(AdapterStore.userAdaptersURL)
                                }
                                .controlSize(.small)
                                .testId("general-adapters-reveal")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                }

                // Git section
                GroupBox {
                    VStack(spacing: 10) {
                        settingRow("Auto-commit") {
                            Toggle("", isOn: $config.gitAutoCommit)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .testId("general-git-auto-commit")
                        }
                        settingRow("Commit format") {
                            TextField("", text: $config.commitMessageFormat)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))
                                .testId("general-commit-format")
                        }
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                }

                // App section
                GroupBox {
                    VStack(spacing: 10) {
                        settingRow("Launch at login") {
                            Toggle("", isOn: $config.launchAtLogin)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .testId("general-launch-at-login")
                        }
                        settingRow("Notifications") {
                            Toggle("", isOn: $config.showNotifications)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .testId("general-show-notifications")
                        }
                        settingRow("Finder badges") {
                            Toggle("", isOn: $config.finderBadges)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .testId("general-finder-badges")
                        }
                        settingRow("Server port") {
                            Stepper("\(config.serverPort)", value: $config.serverPort, in: 1024...65535)
                                .testId("general-server-port")
                        }
                    }
                    .padding(.vertical, 2)
                } label: {
                    Label("App", systemImage: "app.badge.checkmark")
                        .font(.headline)
                }
            }
            .padding()
        }
        .task {
            hasPendingAdapterUpdates = await AdapterStore.shared.hasPendingUpdates()
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            content()
        }
    }
}

// MARK: - Activity Pane

struct ActivityPane: View {
    @ObservedObject var appState: AppState
    @State private var serviceFilter: String? = nil
    @State private var directionFilter: SyncDirection? = nil
    @State private var allActivity: [SyncHistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 10) {
                Picker("Service", selection: $serviceFilter) {
                    Text("All Services").tag(nil as String?)
                    ForEach(appState.services, id: \.serviceId) { service in
                        Text(service.displayName).tag(service.serviceId as String?)
                    }
                }
                .frame(maxWidth: 180)
                .testId("activity-service-filter")

                Picker("Direction", selection: $directionFilter) {
                    Text("All").tag(nil as SyncDirection?)
                    Text("↓ Pull").tag(SyncDirection.pull as SyncDirection?)
                    Text("↑ Push").tag(SyncDirection.push as SyncDirection?)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .testId("activity-direction-filter")

                Spacer()

                Text("\(filteredActivity.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if filteredActivity.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredActivity) { entry in
                            SyncHistoryRow(entry: entry, showServiceName: serviceFilter == nil)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 2)
                                .testId("activity-row-\(entry.id)")
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .testId("activity-scroll-view")
            }
        }
        .task {
            await loadActivity()
        }
        .onChange(of: serviceFilter) { _ in
            Task { await loadActivity() }
        }
    }

    private var filteredActivity: [SyncHistoryEntry] {
        var result = allActivity
        if let directionFilter {
            result = result.filter { $0.direction == directionFilter }
        }
        return result
    }

    private func loadActivity() async {
        if let serviceFilter {
            allActivity = await appState.getServiceHistory(serviceId: serviceFilter, limit: 100)
        } else {
            await appState.refreshHistory()
            allActivity = appState.recentActivity
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No sync activity yet")
                .font(.title3)
                .fontWeight(.medium)
            Text("Activity will appear here after\nyour first sync operation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .testId("activity-empty-state")
    }
}

// MARK: - Service List Row

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

    private var isDisabled: Bool {
        service.config.enabled == false
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .testId("service-row-status-\(service.serviceId)")
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .testId("service-row-name-\(service.serviceId)")
                HStack(spacing: 4) {
                    if isDisabled {
                        Text("Disabled")
                    } else {
                        Text("\(service.fileCount) files")
                            .testId("service-row-count-\(service.serviceId)")
                        if let time = service.lastSyncTime {
                            Text("·")
                            Text(time, style: .relative)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
        }
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}
