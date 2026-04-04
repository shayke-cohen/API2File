import SwiftUI
import API2FileCore

private enum DashboardResourceGrouping {
    static func flattenedResources(_ resources: [ResourceConfig]) -> [ResourceConfig] {
        resources.flatMap { resource in
            [resource] + flattenedResources(resource.children ?? [])
        }
    }

    static func groupTitle(for resource: ResourceConfig) -> String {
        let directory = resource.fileMapping.directory
        if directory == "." || directory.isEmpty {
            return "Root"
        }
        return directory.split(separator: "/").first.map { first in
            first.replacingOccurrences(of: "-", with: " ").capitalized
        } ?? "Root"
    }
}

private func dashboardStatusText(for service: ServiceInfo) -> String {
    switch service.status {
    case .connected: return "Ready"
    case .syncing: return "Syncing"
    case .paused: return "Paused"
    case .error: return "Needs attention"
    case .disconnected: return "Disconnected"
    }
}

private func dashboardStatusColor(for service: ServiceInfo) -> Color {
    switch service.status {
    case .connected: return .green
    case .syncing: return .blue
    case .paused: return .gray
    case .error: return .red
    case .disconnected: return .secondary
    }
}

private func dashboardStorageModeTitle(for service: ServiceInfo) -> String {
    switch service.config.storageMode ?? .plainSync {
    case .plainSync: return "Plain Sync"
    case .managedWorkspace: return "Managed Workspace"
    }
}

private func dashboardStorageModeColor(for service: ServiceInfo) -> Color {
    switch service.config.storageMode ?? .plainSync {
    case .plainSync: return .secondary
    case .managedWorkspace: return .orange
    }
}

private func dashboardRelativeSyncSummary(for service: ServiceInfo?) -> String {
    guard let service else { return "Never synced" }
    if let lastSyncTime = service.lastSyncTime {
        return lastSyncTime.formatted(.relative(presentation: .named))
    }
    return "Never synced"
}

private struct DashboardStat {
    let title: String
    let value: String
    let icon: String
    let tint: Color
}

private enum DashboardActionLabelMode {
    case full
    case short
    case iconOnly
}

struct DashboardTopBar: View {
    @ObservedObject var appState: AppState
    let services: [ServiceInfo]
    @Binding var selectedServiceId: String?
    @Binding var showingActivityPopover: Bool

    private var selectedService: ServiceInfo? {
        services.first(where: { $0.serviceId == selectedServiceId }) ?? services.first
    }

    private var resourceCount: Int {
        selectedService.map { DashboardResourceGrouping.flattenedResources($0.config.resources).count } ?? 0
    }

    private var topStats: [DashboardStat] {
        guard let selectedService else { return [] }
        return [
            DashboardStat(title: "Files", value: "\(selectedService.fileCount)", icon: "doc.on.doc", tint: .secondary),
            DashboardStat(title: "Resources", value: "\(resourceCount)", icon: "square.grid.2x2", tint: .secondary),
            DashboardStat(title: "Last Sync", value: dashboardRelativeSyncSummary(for: selectedService), icon: "clock", tint: dashboardStatusColor(for: selectedService))
        ]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            mediumLayout
            narrowLayout
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(dashboardGlassPanel(cornerRadius: 24))
    }

    private var wideLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                serviceControls(showLabel: true, pickerWidth: 240, stacked: false)
                    .layoutPriority(2)

                Spacer(minLength: 8)

                actionButtons(mode: .full)
                    .layoutPriority(1)
            }

            HStack(alignment: .center, spacing: 10) {
                serviceMeta
                Spacer(minLength: 8)
                statsStrip(compactTitles: false)
            }
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                serviceControls(showLabel: true, pickerWidth: 220, stacked: false)
                Spacer(minLength: 8)
                statsStrip(compactTitles: false)
            }

            HStack(alignment: .center, spacing: 10) {
                serviceMeta
                Spacer(minLength: 8)
                actionButtons(mode: .short)
            }
        }
    }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            serviceControls(showLabel: true, pickerWidth: 230, stacked: true)

            HStack(alignment: .center, spacing: 8) {
                serviceMeta
                Spacer(minLength: 6)
            }

            HStack(alignment: .top, spacing: 8) {
                statsStrip(compactTitles: true)
                Spacer(minLength: 6)
                actionButtons(mode: .iconOnly)
            }
        }
    }

    @ViewBuilder
    private func serviceControls(showLabel: Bool, pickerWidth: CGFloat, stacked: Bool) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                if showLabel {
                    serviceLabel
                }
                HStack(alignment: .center, spacing: 10) {
                    servicePicker(width: pickerWidth)
                    statusControls
                }
            }
        } else {
            HStack(spacing: 10) {
                if showLabel {
                    serviceLabel
                }
                servicePicker(width: pickerWidth)
                statusControls
            }
        }
    }

    private var serviceLabel: some View {
        Text("Connected Service")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func servicePicker(width: CGFloat) -> some View {
        Picker(selection: $selectedServiceId) {
            if services.isEmpty {
                Text("No connected services").tag(nil as String?)
            } else {
                ForEach(services, id: \.serviceId) { service in
                    Text(service.displayName).tag(Optional(service.serviceId))
                }
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Connected Service")
        .frame(width: width)
    }

    private var statusControls: some View {
        Group {
            if let selectedService {
                HStack(spacing: 10) {
                    DashboardStatusChip(
                        title: dashboardStatusText(for: selectedService),
                        tint: dashboardStatusColor(for: selectedService)
                    )
                    Toggle(isOn: Binding(
                        get: { selectedService.config.enabled != false },
                        set: { enabled in
                            appState.setServiceEnabled(serviceId: selectedService.serviceId, enabled: enabled)
                        }
                    )) {
                        Text(selectedService.config.enabled != false ? "Enabled" : "Disabled")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                DashboardStatusChip(title: "No Service", tint: .secondary)
            }
        }
    }

    private func actionButtons(mode: DashboardActionLabelMode) -> some View {
        let buttons = [
            DashboardActionButtonDefinition(
                title: "Activity",
                shortTitle: "Activity",
                systemImage: "clock.arrow.circlepath",
                isProminent: false,
                isDisabled: false,
                action: { showingActivityPopover.toggle() }
            ),
            DashboardActionButtonDefinition(
                title: "Open \(appState.codingAgentDisplayName)",
                shortTitle: "Claude",
                systemImage: "terminal",
                isProminent: false,
                isDisabled: selectedService == nil,
                action: {
                    if let serviceId = selectedService?.serviceId {
                        appState.launchCodingAgent(serviceId: serviceId)
                    } else {
                        appState.launchCodingAgent()
                    }
                }
            ),
            DashboardActionButtonDefinition(
                title: "Open Folder",
                shortTitle: "Folder",
                systemImage: "folder",
                isProminent: false,
                isDisabled: selectedService == nil,
                action: {
                    guard let selectedService else { return }
                    FinderSupport.openInFinder(appState.serviceSurfaceURL(for: selectedService))
                }
            ),
            DashboardActionButtonDefinition(
                title: "Sync",
                shortTitle: "Sync",
                systemImage: "arrow.triangle.2.circlepath",
                isProminent: true,
                isDisabled: selectedService?.status == .syncing || selectedService?.config.enabled == false,
                action: {
                    if let serviceId = selectedService?.serviceId {
                        appState.syncService(serviceId: serviceId)
                    } else {
                        appState.syncNow()
                    }
                }
            )
        ]

        let content = Group {
            if mode == .iconOnly {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, definition in
                        actionButton(definition: definition, mode: mode)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, definition in
                        actionButton(definition: definition, mode: mode)
                    }
                }
            }
        }

        return content
    }

    @ViewBuilder
    private func actionButton(definition: DashboardActionButtonDefinition, mode: DashboardActionLabelMode) -> some View {
        let baseButton = Button {
            definition.action()
        } label: {
            dashboardActionLabel(
                title: definition.title,
                shortTitle: definition.shortTitle,
                systemImage: definition.systemImage,
                mode: mode
            )
        }
        if definition.isProminent {
            baseButton
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(definition.isDisabled)
                .fixedSize(horizontal: true, vertical: false)
                .modifier(ActivityPopoverModifier(
                    isPresented: $showingActivityPopover,
                    shouldAttach: definition.title == "Activity",
                    appState: appState,
                    selectedService: selectedService
                ))
        } else {
            baseButton
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(definition.isDisabled)
                .fixedSize(horizontal: true, vertical: false)
                .modifier(ActivityPopoverModifier(
                    isPresented: $showingActivityPopover,
                    shouldAttach: definition.title == "Activity",
                    appState: appState,
                    selectedService: selectedService
                ))
        }
    }

    @ViewBuilder
    private func dashboardActionLabel(
        title: String,
        shortTitle: String,
        systemImage: String,
        mode: DashboardActionLabelMode
    ) -> some View {
        switch mode {
        case .full:
            Label(title, systemImage: systemImage)
        case .short:
            Label(shortTitle, systemImage: systemImage)
        case .iconOnly:
            Image(systemName: systemImage)
        }
    }

    private var serviceMeta: some View {
        Group {
            if let selectedService {
                HStack(spacing: 8) {
                    Text(selectedService.serviceId)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Circle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 4, height: 4)
                    Text(dashboardStorageModeTitle(for: selectedService))
                        .font(.caption)
                        .foregroundStyle(dashboardStorageModeColor(for: selectedService))
                }
            } else {
                Text("Connect a service to start exploring synced content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statsStrip(compactTitles: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(topStats, id: \.title) { stat in
                DashboardCompactTopStat(stat: stat, compactTitles: compactTitles)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DashboardActionButtonDefinition {
    let title: String
    let shortTitle: String
    let systemImage: String
    let isProminent: Bool
    let isDisabled: Bool
    let action: () -> Void
}

private struct ActivityPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let shouldAttach: Bool
    @ObservedObject var appState: AppState
    let selectedService: ServiceInfo?

    func body(content: Content) -> some View {
        if shouldAttach {
            content.popover(isPresented: $isPresented, arrowEdge: .top) {
                DashboardActivityPopover(
                    appState: appState,
                    selectedService: selectedService
                )
                .frame(width: 420, height: 360)
                .padding(16)
            }
        } else {
            content
        }
    }
}

struct DashboardSidebar: View {
    @Binding var selection: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            ForEach(DashboardSection.allCases, id: \.self) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 16)
                        Text(section.title)
                            .font(.callout.weight(.medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(selection == section ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(12)
        .background(dashboardGlassPanel(cornerRadius: 22))
    }
}

struct DashboardGeneralView: View {
    @ObservedObject var appState: AppState
    let selectedService: ServiceInfo?

    private var serviceResources: [ResourceConfig] {
        DashboardResourceGrouping.flattenedResources(selectedService?.config.resources ?? [])
            .sorted { lhs, rhs in
                let leftGroup = DashboardResourceGrouping.groupTitle(for: lhs)
                let rightGroup = DashboardResourceGrouping.groupTitle(for: rhs)
                if leftGroup != rightGroup {
                    return leftGroup.localizedStandardCompare(rightGroup) == .orderedAscending
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var groupedResources: [(String, [ResourceConfig])] {
        let grouped = Dictionary(grouping: serviceResources, by: DashboardResourceGrouping.groupTitle(for:))
        return grouped.keys.sorted().map { key in
            (key, grouped[key] ?? [])
        }
    }

    private func shouldShowGroupTitle(_ title: String, resources: [ResourceConfig]) -> Bool {
        guard resources.count > 1 else { return false }
        let normalizedTitle = title.replacingOccurrences(of: "-", with: " ").lowercased()
        let distinctNames = Set(resources.map { resource in
            resource.name.replacingOccurrences(of: "-", with: " ").lowercased()
        })
        return distinctNames.count > 1 || !distinctNames.contains(normalizedTitle)
    }

    private var summaryCards: [DashboardStat] {
        guard let selectedService else { return [] }
        let files = enumerateVisibleFiles(service: selectedService).count
        let folders = enumerateFolderCount(service: selectedService)
        let history = appState.recentActivity
        let pulls = history.filter { $0.direction == .pull }.count
        let pushes = history.filter { $0.direction == .push }.count
        return [
            DashboardStat(title: "Tracked Files", value: "\(selectedService.fileCount)", icon: "doc.on.doc", tint: .secondary),
            DashboardStat(title: "Visible Files", value: "\(files)", icon: "eye", tint: .blue),
            DashboardStat(title: "Folders", value: "\(folders)", icon: "folder", tint: .secondary),
            DashboardStat(title: "Recent Pulls", value: "\(pulls)", icon: "arrow.down.doc", tint: .blue),
            DashboardStat(title: "Recent Pushes", value: "\(pushes)", icon: "arrow.up.doc", tint: .green)
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let selectedService {
                    DashboardOverviewCard(service: selectedService)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 122), spacing: 8, alignment: .top)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(summaryCards, id: \.title) { stat in
                            DashboardSummaryCard(stat: stat)
                        }
                    }

                    resourcesCard(for: selectedService)
                } else {
                    DashboardEmptyState(onAddService: appState.openAddServiceWindow)
                }
            }
            .padding(2)
        }
        .background(dashboardGlassPanel(cornerRadius: 22))
        .padding(1)
    }

    private func resourcesCard(for service: ServiceInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resources & Folders to Sync")
                        .font(.headline)
                    Text("Enable or disable sync per resource for the selected service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Logs") {
                    appState.openLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ForEach(groupedResources, id: \.0) { groupTitle, resources in
                VStack(alignment: .leading, spacing: 4) {
                    if shouldShowGroupTitle(groupTitle, resources: resources) {
                        Text(groupTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    ForEach(resources, id: \.name) { resource in
                        DashboardResourceToggleRow(
                            service: service,
                            resource: resource,
                            appState: appState
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(dashboardGlassPanel(cornerRadius: 22))
    }

    private func enumerateVisibleFiles(service: ServiceInfo) -> [URL] {
        let serviceDir = appState.serviceSurfaceURL(for: service)
        guard let enumerator = FileManager.default.enumerator(
            at: serviceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(url)
        }
        return files
    }

    private func enumerateFolderCount(service: ServiceInfo) -> Int {
        let serviceDir = appState.serviceSurfaceURL(for: service)
        guard let enumerator = FileManager.default.enumerator(
            at: serviceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                count += 1
            }
        }
        return count
    }
}

private struct DashboardOverviewCard: View {
    let service: ServiceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service Overview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(service.displayName)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(service.serviceId)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 10) {
                    DashboardStatusChip(
                        title: dashboardStatusText(for: service),
                        tint: dashboardStatusColor(for: service)
                    )
                    DashboardStatusChip(
                        title: dashboardStorageModeTitle(for: service),
                        tint: dashboardStorageModeColor(for: service)
                    )
                }
            }

            HStack(spacing: 8) {
                dashboardMetaPill("Status: \(dashboardStatusText(for: service))")
                dashboardMetaPill("Enabled: \(service.config.enabled != false ? "On" : "Off")")
                dashboardMetaPill("Last sync: \(dashboardRelativeSyncSummary(for: service))")
            }

            if let errorMessage = service.errorMessage, service.status == .error {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }
        }
        .padding(14)
        .background(dashboardGlassPanel(cornerRadius: 22))
    }

    private func dashboardMetaPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.46)))
    }
}

private struct DashboardResourceToggleRow: View {
    let service: ServiceInfo
    let resource: ResourceConfig
    @ObservedObject var appState: AppState

    private var surfaceRoot: URL {
        appState.serviceSurfaceURL(for: service)
    }

    private var titleText: String {
        resource.name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var detailText: String {
        let mapping = resource.fileMapping
        if mapping.strategy == .collection {
            let filename = mapping.filename ?? resource.name
            return mapping.directory == "." ? filename : "\(mapping.directory)/\(filename)"
        }
        if mapping.strategy == .mirror {
            return mapping.directory.isEmpty ? "Mirror remote structure" : mapping.directory
        }
        return mapping.directory
    }

    private var accessoryText: String? {
        let trimmed = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalizedTitle = titleText.lowercased()
        let normalizedDetail = trimmed
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()

        guard normalizedDetail != normalizedTitle else { return nil }
        guard resource.fileMapping.strategy == .collection || trimmed.contains("/") else { return nil }
        return trimmed
    }

    private var countLabel: String {
        let path = resourceURL
        switch resource.fileMapping.strategy {
        case .collection:
            return FileManager.default.fileExists(atPath: path.path) ? "1 file" : "Missing"
        case .onePerRecord, .mirror:
            let count = fileCount(in: path)
            return count == 1 ? "1 file" : "\(count) files"
        }
    }

    private var resourceURL: URL {
        switch resource.fileMapping.strategy {
        case .collection:
            return ResourceBrowserSupport.collectionURL(for: resource, serviceRoot: surfaceRoot)
        case .onePerRecord, .mirror:
            return ResourceBrowserSupport.directoryURL(for: resource, serviceRoot: surfaceRoot)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { resource.enabled != false },
                set: { enabled in
                    appState.setResourceEnabled(serviceId: service.serviceId, resourceName: resource.name, enabled: enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let accessoryText {
                    Text(accessoryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(countLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.46)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.36))
        )
        .opacity(resource.enabled == false ? 0.65 : 1)
    }

    private func fileCount(in url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            count += 1
        }
        return count
    }
}

struct DashboardSettingsView: View {
    @ObservedObject var appState: AppState
    let selectedService: ServiceInfo?
    @State private var isUpdatingAdapters = false
    @State private var adapterUpdateResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Form {
                    Section {
                        LabeledContent("Sync Folder") {
                            Text(appState.config.syncFolder)
                                .font(.system(.callout, design: .monospaced))
                        }

                        LabeledContent("Default Interval") {
                            Stepper(value: $appState.config.defaultSyncInterval, in: 10...600, step: 10) {
                                Text("\(appState.config.defaultSyncInterval) s")
                                    .monospacedDigit()
                            }
                        }

                        Toggle("Auto-commit", isOn: $appState.config.gitAutoCommit)
                        Toggle("Notifications", isOn: $appState.config.showNotifications)
                        Toggle("Finder badges", isOn: $appState.config.finderBadges)
                        Toggle("Generate snapshots", isOn: $appState.config.enableSnapshots)
                        Toggle("Generate companion Markdown files", isOn: $appState.config.generateCompanionFiles)

                        LabeledContent("Commit format") {
                            TextField("", text: $appState.config.commitMessageFormat)
                                .font(.system(.callout, design: .monospaced))
                        }
                    } header: {
                        Label("App Settings", systemImage: "gearshape")
                    }
                }
                .formStyle(.grouped)
                .background(dashboardGlassPanel(cornerRadius: 22))

                selectedServiceSettingsCard
            }
            .padding(2)
        }
        .background(dashboardGlassPanel(cornerRadius: 22))
        .padding(1)
    }

    @ViewBuilder
    private var selectedServiceSettingsCard: some View {
        if let selectedService {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selected Service Settings")
                            .font(.headline)
                        Text(selectedService.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isUpdatingAdapters ? "Updating…" : "Update Adapters") {
                        Task {
                            isUpdatingAdapters = true
                            adapterUpdateResult = nil
                            let count = await appState.updateInstalledAdapters()
                            adapterUpdateResult = count > 0 ? "Updated \(count)" : "Up to date"
                            isUpdatingAdapters = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isUpdatingAdapters)
                }

                HStack(spacing: 10) {
                    Toggle("Service Enabled", isOn: Binding(
                        get: { selectedService.config.enabled != false },
                        set: { enabled in
                            appState.setServiceEnabled(serviceId: selectedService.serviceId, enabled: enabled)
                        }
                    ))
                    .toggleStyle(.switch)

                    Button("Sync Now") {
                        appState.syncService(serviceId: selectedService.serviceId)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedService.status == .syncing || selectedService.config.enabled == false)

                    Button("Open Logs") {
                        appState.openLogs()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let adapterUpdateResult {
                    Text(adapterUpdateResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Resource Toggles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(DashboardResourceGrouping.flattenedResources(selectedService.config.resources), id: \.name) { resource in
                        HStack {
                            Text(resource.name.replacingOccurrences(of: "-", with: " ").capitalized)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { resource.enabled != false },
                                set: { enabled in
                                    appState.setResourceEnabled(serviceId: selectedService.serviceId, resourceName: resource.name, enabled: enabled)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(14)
            .background(dashboardGlassPanel(cornerRadius: 22))
        } else {
            DashboardEmptyState(onAddService: appState.openAddServiceWindow)
        }
    }
}

private struct DashboardActivityPopover: View {
    @ObservedObject var appState: AppState
    let selectedService: ServiceInfo?
    @State private var entries: [SyncHistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Activity")
                        .font(.headline)
                    Text(selectedService?.displayName ?? "All services")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedService?.status == .syncing {
                    DashboardStatusChip(title: "Syncing now", tint: .blue)
                }
            }

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No recent sync activity")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.direction == .pull ? "Pull" : "Push")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(entry.direction == .pull ? .blue : .green)
                                    Spacer()
                                    Text(entry.timestamp.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.summary)
                                    .font(.callout.weight(.medium))
                                Text(entry.serviceName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.42))
                            )
                        }
                    }
                }
            }
        }
        .task(id: selectedService?.serviceId) {
            if let serviceId = selectedService?.serviceId {
                entries = await appState.getServiceHistory(serviceId: serviceId, limit: 25)
            } else {
                await appState.refreshHistory()
                entries = appState.recentActivity
            }
        }
    }
}

struct DashboardEmptyState: View {
    let onAddService: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray.full")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No connected services yet")
                .font(.title3.weight(.semibold))
            Text("Connect a service to start managing synced files from the redesigned dashboard.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Service") {
                onAddService()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(dashboardGlassPanel(cornerRadius: 22))
    }
}

private struct DashboardCompactTopStat: View {
    let stat: DashboardStat
    let compactTitles: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(compactTitles ? compactTitle : stat.title, systemImage: stat.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Circle()
                    .fill(stat.tint)
                    .frame(width: 7, height: 7)
                Text(stat.value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.42))
        )
    }

    private var compactTitle: String {
        switch stat.title {
        case "Resources": return "Res"
        case "Last Sync": return "Last"
        default: return stat.title
        }
    }
}

private struct DashboardStatusChip: View {
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct DashboardSummaryCard: View {
    let stat: DashboardStat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(compactTitle, systemImage: stat.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Circle()
                    .fill(stat.tint)
                    .frame(width: 7, height: 7)
                Text(stat.value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.46))
        )
    }

    private var compactTitle: String {
        switch stat.title {
        case "Tracked Files": return "Tracked"
        case "Visible Files": return "Visible"
        case "Recent Pulls": return "Pulls"
        case "Recent Pushes": return "Pushes"
        default: return stat.title
        }
    }
}

func dashboardGlassPanel(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.72),
                    Color.white.opacity(0.56)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 8)
}
