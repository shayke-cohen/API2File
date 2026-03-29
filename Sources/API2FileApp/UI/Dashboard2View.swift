import SwiftUI
import WebKit
import API2FileCore

struct Dashboard2View: View {
    @ObservedObject var appState: AppState
    let headerTitle: String
    let headerSubtitle: String
    let embeddedInWorkspace: Bool

    @State private var selectedServiceId: String?
    @State private var selectedFileURL: URL?
    @State private var searchText = ""
    @State private var showHiddenFiles = false
    @State private var expandedFolders: Set<String> = []
    @State private var isLoadingHistory = false
    @State private var syncState: SyncState?

    private let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.94, green: 0.97, blue: 1.0),
            Color(red: 0.96, green: 0.95, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    init(
        appState: AppState,
        headerTitle: String = "Dashboard",
        headerSubtitle: String = "A management portal for synced content: browse by folder, edit records in tables, refine Markdown content, and jump into the right tool faster.",
        embeddedInWorkspace: Bool = false
    ) {
        self.appState = appState
        self.headerTitle = headerTitle
        self.headerSubtitle = headerSubtitle
        self.embeddedInWorkspace = embeddedInWorkspace
    }

    var body: some View {
        ZStack {
            if !embeddedInWorkspace {
                background.ignoresSafeArea()
            }

            VStack(spacing: 12) {
                if embeddedInWorkspace {
                    workspaceDeck
                } else {
                    portalHeader
                    overviewStrip
                }

                if services.isEmpty {
                    portalEmptyState
                } else {
                    HSplitView {
                        contentBrowser
                            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

                        detailWorkspace
                            .frame(minWidth: 520, idealWidth: 760)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(embeddedInWorkspace ? 0 : 18)
        }
        .onAppear {
            selectDefaultServiceIfNeeded()
        }
        .onChange(of: services.map(\.serviceId)) { _ in
            selectDefaultServiceIfNeeded()
        }
        .onChange(of: selectedServiceId) { _ in
            selectedFileURL = nil
            expandedFolders = []
        }
        .task(id: selectedServiceId) {
            guard let selectedServiceId else { return }
            isLoadingHistory = true
            await appState.refreshHistory(serviceId: selectedServiceId)
            isLoadingHistory = false
            if let dir = selectedServiceDirectory {
                let stateURL = dir.appendingPathComponent(".api2file/state.json")
                syncState = try? SyncState.load(from: stateURL)
            }
        }
    }

    private var services: [ServiceInfo] {
        appState.services
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var selectedService: ServiceInfo? {
        services.first(where: { $0.serviceId == selectedServiceId }) ?? services.first
    }

    private var selectedServiceDirectory: URL? {
        guard let selectedService else { return nil }
        return appState.config.resolvedSyncFolder.appendingPathComponent(selectedService.serviceId)
    }

    private var visibleFiles: [URL] {
        guard let directory = selectedServiceDirectory else { return [] }
        return enumeratePortalFiles(in: directory)
            .filter { fileURL in
                searchText.isEmpty || portalLabel(for: fileURL, serviceDir: directory).localizedCaseInsensitiveContains(searchText)
            }
    }

    private var treeNodes: [PortalBrowserNode] {
        guard let directory = selectedServiceDirectory else { return [] }
        return PortalBrowserTreeBuilder.build(files: visibleFiles, serviceDir: directory)
    }

    private var portalHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                }

                HStack(spacing: 8) {
                    Button {
                        openSelectedServiceFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedService == nil)
                    .controlSize(.small)

                    Button {
                        if let serviceId = selectedService?.serviceId {
                            appState.launchCodingAgent(serviceId: serviceId)
                        }
                    } label: {
                        Label("Open \(appState.codingAgentDisplayName)", systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedService == nil)
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .background(portalGlassPanel(cornerRadius: 24))
    }

    private var workspaceDeck: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headerTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text(selectedService?.displayName ?? "Choose a workspace")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let selectedService {
                            PortalStatusPill(
                                title: portalStatusText(for: selectedService),
                                tint: portalStatusColor(for: selectedService)
                            )
                        }
                    }

                    Text(selectedService.map { "\($0.serviceId) · \(compactLastSyncSummary)" } ?? headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
            }

            workspaceControlStrip

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)],
                alignment: .leading,
                spacing: 10
            ) {
                PortalSummaryCard(
                    title: "Sync Status",
                    value: selectedService.map(portalStatusText(for:)) ?? "No workspace",
                    detail: selectedService == nil ? "Connect a service to start syncing" : "Last sync \(compactLastSyncSummary)",
                    icon: "dot.radiowaves.left.and.right",
                    tint: selectedService.map(portalStatusColor(for:)) ?? .secondary
                )

                PortalSummaryCard(
                    title: "Tracked Files",
                    value: selectedService.map { "\($0.fileCount)" } ?? "\(services.reduce(0) { $0 + $1.fileCount })",
                    detail: selectedService == nil ? "Across all connected services" : "Files mirrored for this workspace",
                    icon: "doc.stack",
                    tint: .secondary
                )

                PortalSummaryCard(
                    title: "Recent Pulls",
                    value: "\(recentPullFileCount)",
                    detail: recentPullSummary,
                    icon: "arrow.down.doc",
                    tint: .blue
                )

                PortalSummaryCard(
                    title: "Recent Pushes",
                    value: "\(recentPushFileCount)",
                    detail: recentPushSummary,
                    icon: "arrow.up.doc",
                    tint: .green
                )

                PortalSummaryCard(
                    title: "Explorer",
                    value: selectedService == nil ? "Select a workspace" : "\(folderCount) folders",
                    detail: selectedService == nil ? "Browse content after selecting a workspace" : "\(visibleFiles.count) visible files",
                    icon: "folder",
                    tint: .secondary
                )
            }
        }
        .padding(22)
        .background(portalGlassPanel(cornerRadius: 28))
    }

    @ViewBuilder
    private var workspaceControlStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                workspaceSelectorControl
                addServiceButton
                serviceEnabledToggle
                openActionsMenu
                Spacer(minLength: 12)
                syncNowButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    workspaceSelectorControl
                    addServiceButton
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    serviceEnabledToggle
                    openActionsMenu
                    Spacer(minLength: 0)
                    syncNowButton
                }
            }
        }
    }

    private var workspaceSelectorControl: some View {
        PortalWorkspaceSelector(
            services: services,
            selectedServiceId: Binding(
                get: { selectedService?.serviceId },
                set: { selectedServiceId = $0 }
            )
        )
    }

    private var addServiceButton: some View {
        Button {
            appState.openAddServiceWindow()
        } label: {
            Label("Add Service", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var serviceEnabledToggle: some View {
        Toggle(isOn: Binding(
            get: { selectedService?.config.enabled != false },
            set: { enabled in
                guard let serviceId = selectedService?.serviceId else { return }
                appState.setServiceEnabled(serviceId: serviceId, enabled: enabled)
            }
        )) {
            Text(selectedService?.config.enabled != false ? "Enabled" : "Disabled")
                .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(selectedService == nil)
    }

    private var openActionsMenu: some View {
        Menu {
            Button("Open Folder") {
                openSelectedServiceFolder()
            }
            .disabled(selectedService == nil)

            Button("Open \(appState.codingAgentDisplayName)") {
                if let serviceId = selectedService?.serviceId {
                    appState.launchCodingAgent(serviceId: serviceId)
                }
            }
            .disabled(selectedService == nil)
        } label: {
            Label("Open", systemImage: "folder")
        }
        .menuStyle(.borderedButton)
        .controlSize(.small)
        .disabled(selectedService == nil)
    }

    private var syncNowButton: some View {
        Button {
            if let serviceId = selectedService?.serviceId {
                appState.syncService(serviceId: serviceId)
            } else {
                appState.syncNow()
            }
        } label: {
            Label(selectedService == nil ? "Sync All" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(selectedService?.status == .syncing || selectedService?.config.enabled == false)
    }

    private var folderCount: Int {
        treeNodes.reduce(0) { $0 + $1.folderCount }
    }

    private var selectedServiceHistory: [SyncHistoryEntry] {
        guard let serviceId = selectedService?.serviceId else { return [] }
        return appState.recentActivity.filter { $0.serviceId == serviceId }
    }

    private var recentPullEntries: [SyncHistoryEntry] {
        selectedServiceHistory.filter { $0.direction == .pull }
    }

    private var recentPushEntries: [SyncHistoryEntry] {
        selectedServiceHistory.filter { $0.direction == .push }
    }

    private var recentPullFileCount: Int {
        recentPullEntries.reduce(0) { partial, entry in
            partial + entry.files.filter { $0.action == .downloaded }.count
        }
    }

    private var recentPushFileCount: Int {
        recentPushEntries.reduce(0) { partial, entry in
            partial + entry.files.filter { action in
                switch action.action {
                case .uploaded, .created, .updated, .deleted:
                    return true
                case .downloaded, .conflicted, .error:
                    return false
                }
            }.count
        }
    }

    private var recentPullSummary: String {
        if isLoadingHistory { return "Loading activity…" }
        if let latest = recentPullEntries.first?.timestamp {
            return "Last pull \(latest.formatted(.relative(presentation: .named)))"
        }
        return selectedService == nil ? "Select a workspace" : "No pull history yet"
    }

    private var recentPushSummary: String {
        if isLoadingHistory { return "Loading activity…" }
        if let latest = recentPushEntries.first?.timestamp {
            return "Last push \(latest.formatted(.relative(presentation: .named)))"
        }
        return selectedService == nil ? "Select a workspace" : "No push history yet"
    }

    private var compactLastSyncSummary: String {
        guard let date = selectedService?.lastSyncTime else { return "Not yet" }
        return date.formatted(.relative(presentation: .named))
    }

    private var overviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                PortalWorkspaceControl(
                    services: services,
                    selectedServiceId: Binding(
                        get: { selectedService?.serviceId },
                        set: { selectedServiceId = $0 }
                    ),
                    selectedService: selectedService,
                    onAddService: {
                        appState.openAddServiceWindow()
                    }
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Connected",
                    value: "\(services.count)",
                    detail: services.filter { $0.status == .connected }.isEmpty ? "No active services" : "\(services.filter { $0.status == .connected }.count) healthy",
                    icon: "bolt.horizontal.circle",
                    actionTitle: selectedService == nil ? "Sync All" : "Sync",
                    actionIcon: "arrow.triangle.2.circlepath",
                    action: {
                        if let serviceId = selectedService?.serviceId {
                            appState.syncService(serviceId: serviceId)
                        } else {
                            appState.syncNow()
                        }
                    }
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Tracked Files",
                    value: "\(services.reduce(0) { $0 + $1.fileCount })",
                    detail: selectedService.map { "\($0.fileCount) in \($0.displayName)" } ?? "Across all services",
                    icon: "doc.stack"
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Recent Pulls",
                    value: "\(recentPullFileCount)",
                    detail: recentPullSummary,
                    icon: "arrow.down.doc"
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Recent Pushes",
                    value: "\(recentPushFileCount)",
                    detail: recentPushSummary,
                    icon: "arrow.up.doc"
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Sync Status",
                    value: selectedService.map(portalStatusText(for:)) ?? "No workspace",
                    detail: "Last sync \(compactLastSyncSummary)",
                    icon: "dot.radiowaves.left.and.right",
                    tint: selectedService.map(portalStatusColor(for:)) ?? .secondary
                )

                PortalCompactDivider()

                PortalCompactStat(
                    title: "Explorer",
                    value: selectedService == nil ? "Select a workspace" : "\(folderCount) folders",
                    detail: selectedService == nil ? "Browse content after selecting a workspace" : "\(visibleFiles.count) visible files",
                    icon: "folder"
                )
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(portalGlassPanel(cornerRadius: 20))
    }

    private var contentBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Explorer")
                        .font(.headline)
                    Text(selectedService.map { "Browsing \($0.displayName) as folders and files" } ?? "Choose a workspace to browse content")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $showHiddenFiles) {
                    Image(systemName: showHiddenFiles ? "eye.fill" : "eye")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help(showHiddenFiles ? "Hide system files" : "Show system files")
            }

            TextField("Search files and folders", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Label("\(visibleFiles.count) files", systemImage: "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("\(folderCount) folders", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if treeNodes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No visible files yet" : "No matching files")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(treeNodes) { node in
                            PortalBrowserTreeRow(
                                node: node,
                                depth: 0,
                                serviceDir: selectedServiceDirectory!,
                                serviceConfig: selectedService?.config,
                                syncState: syncState,
                                selectedFileURL: $selectedFileURL,
                                expandedFolders: $expandedFolders,
                                onToggleResourceSync: { resourceName, enabled in
                                    if let serviceId = selectedService?.serviceId {
                                        appState.setResourceEnabled(serviceId: serviceId, resourceName: resourceName, enabled: enabled)
                                    }
                                },
                                onToggleFileExcluded: { relativePath, excluded in
                                    if let serviceId = selectedService?.serviceId {
                                        appState.setFileExcluded(serviceId: serviceId, relativePath: relativePath, excluded: excluded)
                                        if var state = syncState {
                                            if var fileState = state.files[relativePath] {
                                                fileState.excluded = excluded
                                                state.files[relativePath] = fileState
                                            } else {
                                                state.files[relativePath] = FileSyncState(remoteId: "", lastSyncedHash: "", excluded: excluded)
                                            }
                                            syncState = state
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(16)
        .background(portalGlassPanel(cornerRadius: 24))
    }

    @ViewBuilder
    private var detailWorkspace: some View {
        if let selectedFileURL, let serviceDir = selectedServiceDirectory {
            PortalDetailWorkspace(
                fileURL: selectedFileURL,
                serviceDir: serviceDir,
                serviceName: selectedService?.displayName ?? "",
                serviceConfig: selectedService?.config
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Content Workspace")
                    .font(.headline)
                Text("Select a file to edit it directly. CSV files open in a table editor. Markdown files open in a live editing workspace with preview. Other files get focused file actions and previews.")
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a file from the explorer")
                        .font(.title3.weight(.semibold))
                    Text("This side becomes your master-detail workspace for managing synced content.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            .background(portalGlassPanel(cornerRadius: 24))
        }
    }

    private var portalEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.full")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No services connected yet")
                .font(.title3.weight(.semibold))
            Text("Connect a service to start managing synced files from the new portal.")
                .foregroundStyle(.secondary)
            Button("Add Service") {
                appState.openAddServiceWindow()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(portalGlassPanel(cornerRadius: 24))
    }

    private func selectDefaultServiceIfNeeded() {
        guard let first = services.first else {
            selectedServiceId = nil
            selectedFileURL = nil
            return
        }
        if selectedServiceId == nil || !services.contains(where: { $0.serviceId == selectedServiceId }) {
            selectedServiceId = first.serviceId
        }
    }

    private func openSelectedServiceFolder() {
        guard let service = selectedService else { return }
        let url = appState.config.resolvedSyncFolder.appendingPathComponent(service.serviceId)
        FinderSupport.openInFinder(url)
    }

    private func portalStatusText(for service: ServiceInfo) -> String {
        switch service.status {
        case .connected: return "Ready"
        case .syncing: return "Syncing"
        case .paused: return "Paused"
        case .error: return "Needs attention"
        case .disconnected: return "Disconnected"
        }
    }

    private func portalStatusColor(for service: ServiceInfo) -> Color {
        switch service.status {
        case .connected: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    private func enumeratePortalFiles(in serviceDir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: serviceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relativePath = url.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
            if !showHiddenFiles, (relativePath.hasPrefix(".") || relativePath.contains("/.")) { continue }
            files.append(url)
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func portalLabel(for fileURL: URL, serviceDir: URL) -> String {
        fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
    }
}

private struct PortalCompactStat: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var tint: Color = .secondary
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if let actionTitle, let action {
                    Button {
                        action()
                    } label: {
                        Label(actionTitle, systemImage: actionIcon ?? "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 210, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PortalWorkspaceControl: View {
    let services: [ServiceInfo]
    @Binding var selectedServiceId: String?
    let selectedService: ServiceInfo?
    let onAddService: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Workspace", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Picker("", selection: $selectedServiceId) {
                    ForEach(services, id: \.serviceId) { service in
                        Text(service.displayName).tag(Optional(service.serviceId))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)

                Button {
                    onAddService()
                } label: {
                    Label("Add Service", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(selectedService?.serviceId ?? "Choose a workspace to browse content")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 430, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PortalCompactDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.45))
            .frame(width: 1, height: 54)
            .padding(.vertical, 10)
    }
}

private struct PortalWorkspaceSelector: View {
    let services: [ServiceInfo]
    @Binding var selectedServiceId: String?

    var body: some View {
        Picker("", selection: $selectedServiceId) {
            ForEach(services, id: \.serviceId) { service in
                Text(service.displayName).tag(Optional(service.serviceId))
            }
        }
        .pickerStyle(.menu)
        .frame(width: 320)
    }
}

private struct PortalStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
}

private struct PortalSummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(value)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.46))
        )
    }
}

private struct PortalBrowserNode: Identifiable {
    enum Kind {
        case folder
        case file(URL)
    }

    let name: String
    let relativePath: String
    let kind: Kind
    let children: [PortalBrowserNode]

    var id: String { relativePath }
    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    var folderCount: Int {
        guard isFolder else { return 0 }
        return 1 + children.reduce(0) { $0 + $1.folderCount }
    }
}

private enum PortalBrowserTreeBuilder {
    static func build(files: [URL], serviceDir: URL) -> [PortalBrowserNode] {
        let root = MutableFolderNode(name: "", relativePath: "")
        for fileURL in files {
            let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
            let components = relativePath.split(separator: "/").map(String.init)
            root.insert(components: components, fileURL: fileURL)
        }
        return root.snapshotChildren()
    }

    private final class MutableFolderNode {
        let name: String
        let relativePath: String
        var folders: [String: MutableFolderNode] = [:]
        var files: [PortalBrowserNode] = []

        init(name: String, relativePath: String) {
            self.name = name
            self.relativePath = relativePath
        }

        func insert(components: [String], fileURL: URL) {
            guard let head = components.first else { return }

            if components.count == 1 {
                files.append(
                    PortalBrowserNode(
                        name: head,
                        relativePath: relativePath.isEmpty ? head : "\(relativePath)/\(head)",
                        kind: .file(fileURL),
                        children: []
                    )
                )
                return
            }

            let nextPath = relativePath.isEmpty ? head : "\(relativePath)/\(head)"
            let folder = folders[head] ?? MutableFolderNode(name: head, relativePath: nextPath)
            folders[head] = folder
            folder.insert(components: Array(components.dropFirst()), fileURL: fileURL)
        }

        func snapshotChildren() -> [PortalBrowserNode] {
            let folderNodes = folders.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { folder in
                    PortalBrowserNode(
                        name: folder.name,
                        relativePath: folder.relativePath,
                        kind: .folder,
                        children: folder.snapshotChildren()
                    )
                }
            let fileNodes = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folderNodes + fileNodes
        }
    }
}

private struct PortalBrowserTreeRow: View {
    let node: PortalBrowserNode
    let depth: Int
    let serviceDir: URL
    let serviceConfig: AdapterConfig?
    let syncState: SyncState?
    @Binding var selectedFileURL: URL?
    @Binding var expandedFolders: Set<String>
    var onToggleResourceSync: ((String, Bool) -> Void)?
    var onToggleFileExcluded: ((String, Bool) -> Void)?

    private var rowPadding: CGFloat {
        CGFloat(depth) * 14
    }

    private var isExpanded: Bool {
        node.isFolder && expandedFolders.contains(node.relativePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if node.isFolder {
                folderRow
            } else {
                fileRow
            }

            if node.isFolder && isExpanded {
                ForEach(node.children) { child in
                    PortalBrowserTreeRow(
                        node: child,
                        depth: depth + 1,
                        serviceDir: serviceDir,
                        serviceConfig: serviceConfig,
                        syncState: syncState,
                        selectedFileURL: $selectedFileURL,
                        expandedFolders: $expandedFolders,
                        onToggleResourceSync: onToggleResourceSync,
                        onToggleFileExcluded: onToggleFileExcluded
                    )
                }
            }
        }
    }

    private var folderRow: some View {
        let resource = matchingResource(for: node.relativePath)
        let isDisabled = resource?.enabled == false
        return Button {
            toggleFolder()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .foregroundStyle(isDisabled ? Color.secondary : Color.accentColor)
                Text(node.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                Spacer()
                if isDisabled {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(node.children.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.10)))
                }
            }
            .padding(.leading, rowPadding)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.5 : 1.0)
        .contextMenu {
            Button("Open in Finder") {
                FinderSupport.openInFinder(serviceDir.appendingPathComponent(node.relativePath))
            }
            Button("Open in Terminal") {
                portalOpenInTerminal(serviceDir.appendingPathComponent(node.relativePath))
            }
            if let resource {
                Divider()
                if isDisabled {
                    Button("Enable Sync") {
                        onToggleResourceSync?(resource.name, true)
                    }
                } else {
                    Button("Disable Sync") {
                        onToggleResourceSync?(resource.name, false)
                    }
                }
            }
        }
    }

    private var fileRow: some View {
        let fileURL = nodeFileURL
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        let isExcluded = syncState?.files[relativePath]?.excluded == true
        return Button {
            selectedFileURL = fileURL
            expandAncestors()
        } label: {
            HStack(spacing: 10) {
                Color.clear.frame(width: 12)
                Image(systemName: portalIconName(for: fileURL))
                    .foregroundStyle(selectedFileURL == fileURL ? Color.accentColor : (isExcluded ? Color.secondary.opacity(0.5) : .secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isExcluded ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileURL.pathExtension.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isExcluded {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, rowPadding)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selectedFileURL == fileURL ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .opacity(isExcluded ? 0.6 : 1.0)
        .contextMenu {
            portalFileContextMenu(fileURL, relativePath: relativePath, isExcluded: isExcluded)
        }
    }

    private var nodeFileURL: URL {
        if case .file(let fileURL) = node.kind {
            return fileURL
        }
        preconditionFailure("Expected file node")
    }

    private func toggleFolder() {
        if expandedFolders.contains(node.relativePath) {
            expandedFolders.remove(node.relativePath)
        } else {
            expandedFolders.insert(node.relativePath)
        }
    }

    private func expandAncestors() {
        let parts = node.relativePath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return }
        var path = ""
        for part in parts.dropLast() {
            path = path.isEmpty ? part : "\(path)/\(part)"
            expandedFolders.insert(path)
        }
    }

    @ViewBuilder
    private func portalFileContextMenu(_ fileURL: URL, relativePath: String, isExcluded: Bool) -> some View {
        Button("Open in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        Button("Open in Terminal") {
            portalOpenInTerminal(fileURL.deletingLastPathComponent())
        }
        Button("Open in Default App") {
            NSWorkspace.shared.open(fileURL)
        }
        if let externalDestination = portalExternalDestination(for: fileURL, serviceConfig: serviceConfig, serviceDir: serviceDir) {
            Button(externalDestination.title) {
                NSWorkspace.shared.open(externalDestination.url)
            }
        }
        Button("Open Editor") {
            openFileInEditor(fileURL)
        }
        Divider()
        if isExcluded {
            Button("Include in Sync") {
                onToggleFileExcluded?(relativePath, false)
            }
        } else {
            Button("Exclude from Sync") {
                onToggleFileExcluded?(relativePath, true)
            }
        }
    }

    private func matchingResource(for folderPath: String) -> ResourceConfig? {
        guard let config = serviceConfig else { return nil }
        func check(_ res: ResourceConfig) -> ResourceConfig? {
            let dir = res.fileMapping.directory
            guard !dir.contains("{"), dir == folderPath else { return nil }
            return res
        }
        for resource in config.resources {
            if let found = check(resource) { return found }
            for child in resource.children ?? [] {
                if let found = check(child) { return found }
            }
        }
        return nil
    }
}

private struct PortalDetailWorkspace: View {
    let fileURL: URL
    let serviceDir: URL
    let serviceName: String
    let serviceConfig: AdapterConfig?
    @State private var isEditing = false

    private var relativePath: String {
        fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
    }

    private var fileExtension: String {
        fileURL.pathExtension.lowercased()
    }

    private var supportsInlineEditing: Bool {
        ["csv", "md", "markdown"].contains(fileExtension)
    }

    private var externalDestination: PortalExternalDestination? {
        portalExternalDestination(for: fileURL, serviceConfig: serviceConfig, serviceDir: serviceDir)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileURL.lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(serviceName) · \(relativePath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if supportsInlineEditing {
                    Button {
                        isEditing.toggle()
                    } label: {
                        Label(isEditing ? "Preview" : "Edit", systemImage: isEditing ? "eye" : "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Open in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    Button("Open in Terminal") {
                        portalOpenInTerminal(fileURL.deletingLastPathComponent())
                    }
                    Button("Open in Default App") {
                        NSWorkspace.shared.open(fileURL)
                    }
                    if let externalDestination {
                        Button(externalDestination.title) {
                            NSWorkspace.shared.open(externalDestination.url)
                        }
                    }
                    Divider()
                    Button("Open Editor") {
                        openFileInEditor(fileURL)
                    }
                } label: {
                    Label("File Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }

            switch fileExtension {
            case "csv":
                if isEditing {
                    EditableCSVWorkspace(fileURL: fileURL)
                } else {
                    CSVPreviewWorkspace(fileURL: fileURL)
                }
            case "md", "markdown":
                if isEditing {
                    EditableMarkdownWorkspace(fileURL: fileURL)
                } else {
                    PortalPreviewWorkspace(fileURL: fileURL)
                }
            default:
                PortalPreviewWorkspace(fileURL: fileURL)
            }
        }
        .padding(20)
        .background(portalGlassPanel(cornerRadius: 24))
        .onChange(of: fileURL) { _ in
            isEditing = false
        }
    }
}

private struct CSVPreviewWorkspace: View {
    let fileURL: URL

    @State private var headers: [String] = []
    @State private var rows: [[String]] = []
    @State private var didLoad = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Table Preview")
                        .font(.headline)
                    Text("Preview the table first. Use Edit when you want to change rows or values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") {
                    load()
                }
                .buttonStyle(.bordered)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if headers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tablecells")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("This CSV does not have visible columns yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                                Text(header)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: columnWidth(for: index), alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.10))
                            }
                        }

                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            HStack(spacing: 0) {
                                ForEach(Array(headers.enumerated()), id: \.offset) { columnIndex, _ in
                                    Text(row[safe: columnIndex] ?? "")
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(width: columnWidth(for: columnIndex), alignment: .topLeading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
                                        .lineLimit(3)
                                }
                            }
                            Divider()
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                    )
                }
            }
        }
        .task(id: fileURL) { load() }
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            errorMessage = "Could not read \(fileURL.lastPathComponent)."
            didLoad = false
            return
        }

        let parsed = PortalCSVCodec.decode(text)
        headers = parsed.headers
        rows = parsed.rows
        errorMessage = nil
        didLoad = true
    }

    private func columnWidth(for index: Int) -> CGFloat {
        let headerWidth = CGFloat(headers[safe: index]?.count ?? 8) * 7
        let rowWidth = rows.prefix(20).reduce(CGFloat(0)) { partial, row in
            let count = row[safe: index]?.count ?? 0
            return max(partial, CGFloat(count) * 7)
        }
        return max(120, min(max(headerWidth, rowWidth) + 28, 260))
    }
}

private struct EditableCSVWorkspace: View {
    let fileURL: URL

    @State private var headers: [String] = []
    @State private var rows: [[String]] = []
    @State private var didLoad = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Table Editor")
                        .font(.headline)
                    Text("Edit rows directly, add new records, remove stale ones, then save back to disk.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Row") {
                    rows.append(Array(repeating: "", count: headers.count))
                }
                .buttonStyle(.bordered)
                .disabled(headers.isEmpty)
                Button("Refresh") { load() }
                    .buttonStyle(.bordered)
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save Table")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!didLoad || isSaving)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if headers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tablecells")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("This CSV does not have visible columns yet.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        headerRow

                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, _ in
                            HStack(spacing: 0) {
                                actionCell(for: rowIndex)
                                ForEach(Array(headers.enumerated()), id: \.offset) { columnIndex, _ in
                                    TextField(
                                        "",
                                        text: Binding(
                                            get: { value(at: rowIndex, columnIndex: columnIndex) },
                                            set: { setValue($0, at: rowIndex, columnIndex: columnIndex) }
                                        ),
                                        axis: .vertical
                                    )
                                    .textFieldStyle(.plain)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: columnWidth(for: columnIndex), alignment: .topLeading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
                                }
                            }
                            Divider()
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                    )
                }
            }
        }
        .task(id: fileURL) { load() }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Row")
                .font(.caption.weight(.semibold))
                .frame(width: 70, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.10))

            ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                Text(header)
                    .font(.caption.weight(.semibold))
                    .frame(width: columnWidth(for: index), alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.10))
            }
        }
    }

    private func actionCell(for rowIndex: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(rowIndex + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                rows.remove(at: rowIndex)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 70, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.035))
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            errorMessage = "Could not read \(fileURL.lastPathComponent)."
            didLoad = false
            return
        }

        let parsed = PortalCSVCodec.decode(text)
        headers = parsed.headers
        rows = parsed.rows.map { row in
            if row.count < parsed.headers.count {
                return row + Array(repeating: "", count: parsed.headers.count - row.count)
            }
            return row
        }
        errorMessage = nil
        didLoad = true
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        do {
            let text = PortalCSVCodec.encode(headers: headers, rows: rows)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func value(at rowIndex: Int, columnIndex: Int) -> String {
        guard rowIndex < rows.count, columnIndex < rows[rowIndex].count else { return "" }
        return rows[rowIndex][columnIndex]
    }

    private func setValue(_ value: String, at rowIndex: Int, columnIndex: Int) {
        guard rowIndex < rows.count else { return }
        while rows[rowIndex].count < headers.count {
            rows[rowIndex].append("")
        }
        rows[rowIndex][columnIndex] = value
    }

    private func columnWidth(for index: Int) -> CGFloat {
        let headerWidth = CGFloat(headers[safe: index]?.count ?? 8) * 7
        let rowWidth = rows.prefix(20).reduce(CGFloat(0)) { partial, row in
            let count = row[safe: index]?.count ?? 0
            return max(partial, CGFloat(count) * 7)
        }
        return max(120, min(max(headerWidth, rowWidth) + 28, 260))
    }
}

private struct EditableMarkdownWorkspace: View {
    let fileURL: URL

    @State private var text = ""
    @State private var didLoad = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Markdown Workspace")
                        .font(.headline)
                    Text("Edit Markdown directly and use the preview beside it to review structure and content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { load() }
                    .buttonStyle(.bordered)
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save Markdown")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!didLoad || isSaving)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !didLoad {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Editor")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                            )
                    }
                    .frame(minWidth: 260, idealWidth: 360)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        PortalHTMLView(html: portalRenderMarkdownHTML(text))
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .frame(minWidth: 260, idealWidth: 380)
                }
            }
        }
        .task(id: fileURL) { load() }
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            errorMessage = "Could not read \(fileURL.lastPathComponent)."
            didLoad = false
            return
        }

        self.text = text
        errorMessage = nil
        didLoad = true
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct PortalPreviewWorkspace: View {
    let fileURL: URL
    @State private var content: PortalPreviewContent = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    content = loadPreviewContent(for: fileURL)
                }
                .buttonStyle(.bordered)
            }

            Group {
                switch content {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text), .json(let text):
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                case .markdown(let html), .html(let html):
                    PortalHTMLView(html: html)
                case .image(let image):
                    PreviewImageView(image: image)
                        .padding(12)
                case .unsupported:
                    VStack(spacing: 10) {
                        Image(systemName: "doc.questionmark")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No rich preview for this file type yet.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
            )
        }
        .task(id: fileURL) { content = loadPreviewContent(for: fileURL) }
    }
}

private enum PortalPreviewContent {
    case loading
    case text(String)
    case markdown(String)
    case json(String)
    case html(String)
    case image(NSImage)
    case unsupported
}

private struct PortalHTMLView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: nil)
    }
}

private enum PortalCSVCodec {
    static func decode(_ text: String) -> (headers: [String], rows: [[String]]) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first else { return ([], []) }
        let headers = parseLine(headerLine)
        let rows = lines.dropFirst().map(parseLine)
        return (headers, rows)
    }

    static func encode(headers: [String], rows: [[String]]) -> String {
        let allRows = [headers] + rows.map { row in
            Array((0..<headers.count).map { index in row[safe: index] ?? "" })
        }
        return allRows.map { row in
            row.map(escapeField).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
    }

    private static func parseLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                if inQuotes {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else {
                            inQuotes = false
                            if next == "," {
                                result.append(current)
                                current = ""
                            } else {
                                current.append(next)
                            }
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }

    private static func escapeField(_ field: String) -> String {
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}

private func loadPreviewContent(for fileURL: URL) -> PortalPreviewContent {
    let ext = fileURL.pathExtension.lowercased()
    let imageExts = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "svg"]

    if imageExts.contains(ext), let image = PreviewImageLoader.load(from: fileURL) {
        return .image(image)
    }

    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        return .unsupported
    }

    switch ext {
    case "md", "markdown":
        return .markdown(portalRenderMarkdownHTML(text))
    case "json":
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let formatted = String(data: pretty, encoding: .utf8) {
            return .json(formatted)
        }
        return .json(text)
    case "html", "htm":
        return .html(text)
    default:
        return .text(text)
    }
}

private func portalRenderMarkdownHTML(_ markdown: String) -> String {
    let escaped = markdown
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")

    let html = escaped
        .components(separatedBy: "\n\n")
        .map { block in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }

            let renderedBlock = trimmed
                .components(separatedBy: .newlines)
                .map { line -> String in
                    if line.hasPrefix("### ") {
                        return "<h3>\(String(line.dropFirst(4)))</h3>"
                    }
                    if line.hasPrefix("## ") {
                        return "<h2>\(String(line.dropFirst(3)))</h2>"
                    }
                    if line.hasPrefix("# ") {
                        return "<h1>\(String(line.dropFirst(2)))</h1>"
                    }
                    if line.hasPrefix("- ") {
                        return "• \(String(line.dropFirst(2)))"
                    }
                    return line
                }
                .joined(separator: "<br>")
                .replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
                .replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
                .replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
                .replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)

            if renderedBlock.hasPrefix("<h") {
                return renderedBlock
            }
            return "<p>\(renderedBlock)</p>"
        }
        .joined(separator: "\n")

    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #222; background: #ffffff; margin: 0; padding: 18px; line-height: 1.65; }
    h1, h2, h3 { font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    h1 { font-size: 28px; margin: 0 0 12px; }
    h2 { font-size: 21px; margin: 18px 0 10px; }
    h3 { font-size: 17px; margin: 14px 0 8px; }
    p { margin: 0 0 12px; }
    a { color: #0a84ff; text-decoration: none; }
    code { font-family: Menlo, monospace; background: rgba(0,0,0,0.06); padding: 2px 5px; border-radius: 5px; }
    </style></head><body>\(html)</body></html>
    """
}

private func portalGlassPanel(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        )
}

private struct PortalExternalDestination {
    let title: String
    let url: URL
}

private func portalExternalDestination(for fileURL: URL, serviceConfig: AdapterConfig?, serviceDir: URL) -> PortalExternalDestination? {
    guard let serviceConfig else { return nil }

    let resource = ResourceBrowserSupport.resource(for: fileURL, in: serviceConfig.resources, serviceRoot: serviceDir)

    if let dashboardURL = resource?.dashboardUrl ?? serviceConfig.dashboardUrl,
       let url = URL(string: dashboardURL) {
        return PortalExternalDestination(title: "Open Dashboard", url: url)
    }

    if let siteURL = resource?.siteUrl ?? serviceConfig.siteUrl,
       let url = URL(string: siteURL) {
        return PortalExternalDestination(title: "Open Website", url: url)
    }

    return nil
}

private func portalIconName(for fileURL: URL) -> String {
    switch fileURL.pathExtension.lowercased() {
    case "csv": return "tablecells"
    case "json": return "curlybraces"
    case "md", "markdown": return "text.document"
    case "html", "htm": return "globe"
    case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
    case "pdf": return "doc.richtext"
    default: return "doc"
    }
}

private func portalOpenInTerminal(_ directoryURL: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Terminal", directoryURL.path]
    try? process.run()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
