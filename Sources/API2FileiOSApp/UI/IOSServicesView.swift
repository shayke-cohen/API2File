import SwiftUI
import API2FileCore

struct IOSServicesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Bindable var appState: IOSAppState
    @Binding var selectedTab: IOSRootTab
    @Binding var showingAddService: Bool

    var body: some View {
        Group {
            if appState.isBootstrappingWorkspace || (!appState.hasCompletedInitialLoad && appState.services.isEmpty) {
                loadingContent
            } else if appState.services.isEmpty {
                emptyStateContent
            } else {
                connectedServicesContent
            }
        }
        .accessibilityIdentifier(IOSScreenID.services)
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await appState.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh services")
                .accessibilityIdentifier("services.toolbar.refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddService = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add service")
                .accessibilityIdentifier("services.toolbar.add")
            }
        }
        .refreshable {
            await appState.refresh()
            await appState.syncAllServices()
        }
        .iosScreenBackground()
    }

    private var loadingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewHero
                    .accessibilityIdentifier("services.hero")

                IOSSectionTitle(
                    "Preparing your workspace",
                    eyebrow: "Workspace",
                    detail: "Loading services, checking files, and reconnecting sync state."
                )

                HStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(.circular)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading services")
                            .font(.headline)
                            .foregroundStyle(IOSTheme.textPrimary)

                        Text("Your adapters and synced folders will appear here in a moment.")
                            .font(.subheadline)
                            .foregroundStyle(IOSTheme.textSecondary)
                    }

                    Spacer(minLength: 0)
                }
                .iosCardStyle()
                .accessibilityIdentifier("services.loading")
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .padding(.bottom, IOSTheme.contentBottomInset)
        }
    }

    private var emptyStateContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overviewHero
                    .accessibilityIdentifier("services.hero")

                IOSSectionTitle(
                    appState.services.isEmpty ? "Start with your first service" : "Connected services",
                    eyebrow: "Workspace",
                    detail: appState.services.isEmpty
                        ? "Adapters turn APIs into browsable, editable files."
                        : nil
                )

                if appState.services.isEmpty {
                    IOSEmptyStateCard(
                        title: "No services yet",
                        message: "Connect an adapter-driven service to unlock file browsing, editing, uploads, and share flows in one place.",
                        systemImage: "tray.full",
                        actionTitle: "Add a Service"
                    ) {
                        showingAddService = true
                    }
                    .accessibilityIdentifier("services.empty")
                }
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .padding(.bottom, IOSTheme.contentBottomInset)
        }
    }

    private var connectedServicesContent: some View {
        List {
            Section("Workspace") {
                connectedHero
                    .accessibilityIdentifier("services.hero")
                    .listRowInsets(serviceRowInsets(top: 8, bottom: 12))
                    .listRowBackground(Color.clear)
            }

            Section("Connected Services") {
                ForEach(appState.services, id: \.serviceId) { service in
                    ServiceCard(
                        service: service,
                        onToggleEnabled: { enabled in
                            Task { await appState.toggleService(service.serviceId, enabled: enabled) }
                        },
                        onSync: {
                            appState.selectedServiceID = service.serviceId
                            Task { await appState.sync(serviceID: service.serviceId) }
                        },
                        onOpenBrowser: {
                            appState.selectedServiceID = service.serviceId
                            selectedTab = .browser
                        },
                        onDisconnect: {
                            Task { await appState.removeService(service.serviceId) }
                        }
                    )
                    .listRowInsets(serviceRowInsets(top: 8, bottom: 8))
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .accessibilityIdentifier("services.cards")
    }

    @ViewBuilder
    private var overviewHero: some View {
        if appState.services.isEmpty {
            onboardingHero
        } else {
            connectedHero
        }
    }

    private var onboardingHero: some View {
        IOSHeroCard {
            VStack(alignment: .leading, spacing: IOSTheme.compactHeroSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API workspace")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .tracking(1.2)

                    Text("Your APIs, shaped like files.")
                        .font(horizontalSizeClass == .compact ? .title3.weight(.bold) : .title2.weight(.bold))
                        .foregroundStyle(.white)

                    Text("Browse, edit, import, and sync API-backed content from one file-native workspace.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.84))
                }

                heroMetrics
            }
        }
    }

    private var connectedHero: some View {
        IOSHeroCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Live workspace")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .tracking(1.2)

                Text(summaryHeadline)
                    .font(horizontalSizeClass == .compact ? .title3.weight(.bold) : .title2.weight(.bold))
                    .foregroundStyle(.white)

                connectedSummaryPills
            }
        }
    }

    @ViewBuilder
    private var heroMetrics: some View {
        if horizontalSizeClass == .compact {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    metricBadge(label: "Services", value: "\(appState.services.count)", systemImage: "shippingbox.fill")
                        .accessibilityIdentifier("services.summary.count")
                    metricBadge(label: "Syncing", value: "\(appState.services.filter { $0.status == .syncing }.count)", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                        .accessibilityIdentifier("services.summary.syncing")
                    metricBadge(label: "Files managed", value: "\(appState.services.reduce(0) { $0 + $1.fileCount })", systemImage: "doc.on.doc.fill")
                        .accessibilityIdentifier("services.summary.files")
                }
            }
            .scrollClipDisabled()
        } else {
            LazyVGrid(columns: heroMetricColumns, spacing: 12) {
                metricBadge(label: "Services", value: "\(appState.services.count)", systemImage: "shippingbox.fill")
                    .accessibilityIdentifier("services.summary.count")
                metricBadge(label: "Syncing", value: "\(appState.services.filter { $0.status == .syncing }.count)", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                    .accessibilityIdentifier("services.summary.syncing")
                metricBadge(label: "Files managed", value: "\(appState.services.reduce(0) { $0 + $1.fileCount })", systemImage: "doc.on.doc.fill")
                    .accessibilityIdentifier("services.summary.files")
            }
        }
    }

    private func metricBadge(label: String, value: String, systemImage: String) -> some View {
        IOSMetricBadge(label: label, value: value, systemImage: systemImage)
            .frame(width: horizontalSizeClass == .compact ? 156 : nil)
    }

    private var connectedSummaryPills: some View {
        VStack(alignment: .leading, spacing: 10) {
            IOSSecondaryPill("\(appState.services.reduce(0) { $0 + $1.fileCount }) files mirrored", systemImage: "doc.on.doc")
            HStack(spacing: 10) {
                IOSSecondaryPill("\(appState.services.count) services", systemImage: "shippingbox")
                IOSSecondaryPill("\(appState.services.filter { $0.status == .syncing }.count) syncing", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var summaryHeadline: String {
        let serviceCount = appState.services.count
        let fileCount = appState.services.reduce(0) { $0 + $1.fileCount }
        let serviceLabel = serviceCount == 1 ? "service" : "services"
        let fileLabel = fileCount == 1 ? "file" : "files"
        return "\(serviceCount) \(serviceLabel) connected, \(fileCount) \(fileLabel) ready."
    }

    private var heroMetricColumns: [GridItem] {
        let columnCount = horizontalSizeClass == .compact ? 2 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columnCount)
    }

    private func serviceRowInsets(top: CGFloat, bottom: CGFloat) -> EdgeInsets {
        let horizontalInset = horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset
        return EdgeInsets(top: top, leading: horizontalInset, bottom: bottom, trailing: horizontalInset)
    }
}

private struct ServiceCard: View {
    let service: ServiceInfo
    let onToggleEnabled: (Bool) -> Void
    let onSync: () -> Void
    let onOpenBrowser: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: service.config.icon ?? "cloud.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(IOSTheme.accent.opacity(0.26), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(service.displayName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(IOSTheme.textPrimary)
                            .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "section"))

                        Spacer(minLength: 12)

                        IOSStatusPill(status: service.status)
                            .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "status"))
                    }

                    Text(serviceSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                IOSSecondaryPill(service.serviceId, systemImage: "shippingbox")
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "service-id"))

                IOSSecondaryPill("\(service.fileCount) files", systemImage: "doc.text")
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "files"))

                IOSSecondaryPill(lastSyncedText, systemImage: "clock")
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "last-sync"))
            }

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { service.config.enabled != false },
                    set: onToggleEnabled
                )
            )
            .tint(IOSTheme.accent)
            .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "enabled"))

            HStack(spacing: 12) {
                Button("Sync Now", action: onSync)
                    .buttonStyle(IOSProminentButtonStyle())
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "sync-now"))

                Button("Open Browser", action: onOpenBrowser)
                    .buttonStyle(IOSOutlineButtonStyle())
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "open-in-browser"))
            }

            portalButtons

            Button("Disconnect", role: .destructive, action: onDisconnect)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IOSTheme.danger)
                .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "disconnect"))
        }
        .iosCardStyle()
        .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "card"))
    }

    private var serviceSubtitle: String {
        if let errorMessage = service.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        switch service.status {
        case .connected:
            return "Connected and ready for local edits, imports, and sync."
        case .syncing:
            return "Refreshing files and reconciling API changes right now."
        case .paused:
            return "Paused locally. You can resume syncing any time."
        case .error:
            return "This service needs attention before syncing can continue."
        case .disconnected:
            return "Not currently authenticated."
        }
    }

    private var lastSyncedText: String {
        guard let lastSyncTime = service.lastSyncTime else {
            return "Never synced"
        }
        return lastSyncTime.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var portalButtons: some View {
        let dashboardURL = service.config.dashboardUrl.flatMap(URL.init(string:))
        let siteURL = service.config.siteUrl.flatMap(URL.init(string:))

        if dashboardURL != nil || siteURL != nil {
            HStack(spacing: 12) {
                if let dashboardURL {
                    Button("Open Dashboard") {
                        UIApplication.shared.open(dashboardURL)
                    }
                    .buttonStyle(IOSOutlineButtonStyle())
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "open-dashboard"))
                }

                if let siteURL {
                    Button("Open Website") {
                        UIApplication.shared.open(siteURL)
                    }
                    .buttonStyle(IOSOutlineButtonStyle())
                    .accessibilityIdentifier(IOSAccessibility.id("services", service.serviceId, "open-website"))
                }
            }
        }
    }
}
