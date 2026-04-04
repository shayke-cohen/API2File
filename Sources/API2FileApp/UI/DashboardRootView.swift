import AppKit
import SwiftUI
import API2FileCore

enum DashboardSection: String, CaseIterable, Hashable {
    case general
    case fileExplorer
    case dataExplorer
    case settings

    var title: String {
        switch self {
        case .general: return "General"
        case .fileExplorer: return "File Explorer"
        case .dataExplorer: return "Data Explorer"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .fileExplorer: return "folder"
        case .dataExplorer: return "cylinder.split.1x2"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardRootView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        DashboardWorkspaceShell(appState: appState)
            .frame(minWidth: 980, idealWidth: 1280, minHeight: 680, idealHeight: 820)
            .onAppear {
                appState.registerDashboardWindowOpener {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

private struct DashboardWorkspaceShell: View {
    @ObservedObject var appState: AppState
    @State private var selectedSection: DashboardSection = .general
    @State private var selectedServiceId: String?
    @State private var showingActivityPopover = false

    private let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.94, green: 0.97, blue: 1.0),
            Color(red: 0.96, green: 0.95, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var services: [ServiceInfo] {
        appState.services
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var selectedService: ServiceInfo? {
        services.first(where: { $0.serviceId == selectedServiceId }) ?? services.first
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 10) {
                DashboardTopBar(
                    appState: appState,
                    services: services,
                    selectedServiceId: $selectedServiceId,
                    showingActivityPopover: $showingActivityPopover
                )
                .padding(.horizontal, 12)
                .padding(.top, 12)

                HStack(spacing: 10) {
                    DashboardSidebar(selection: $selectedSection)
                        .frame(width: 190)

                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            selectDefaultServiceIfNeeded()
            handlePendingOpenPath(appState.pendingOpenPath)
        }
        .onChange(of: services.map(\.serviceId)) { _ in
            selectDefaultServiceIfNeeded()
        }
        .onChange(of: appState.pendingOpenPath?.serviceId) { _ in
            handlePendingOpenPath(appState.pendingOpenPath)
        }
        .onChange(of: appState.showingSettings) { showingSettings in
            guard showingSettings else { return }
            selectedSection = .settings
            appState.showingSettings = false
            appState.openDashboardWindow()
        }
        .task(id: selectedService?.serviceId) {
            guard let serviceId = selectedService?.serviceId else {
                await appState.refreshHistory()
                return
            }
            await appState.refreshHistory(serviceId: serviceId)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if services.isEmpty {
            DashboardEmptyState(onAddService: appState.openAddServiceWindow)
        } else {
            switch selectedSection {
            case .general:
                DashboardGeneralView(
                    appState: appState,
                    selectedService: selectedService
                )
            case .fileExplorer:
                Dashboard2View(
                    appState: appState,
                    headerTitle: "File Explorer",
                    headerSubtitle: "Browse synced files, edit records in place, and jump into the right tool faster.",
                    embeddedInWorkspace: false,
                    selectedServiceIdOverride: selectedService?.serviceId,
                    layout: .explorerOnly
                )
            case .dataExplorer:
                SQLExplorerPane(
                    appState: appState,
                    initialServiceId: selectedService?.serviceId,
                    selectedServiceIdOverride: selectedService?.serviceId,
                    suppressServicePicker: true
                )
            case .settings:
                DashboardSettingsView(
                    appState: appState,
                    selectedService: selectedService
                )
            }
        }
    }

    private func selectDefaultServiceIfNeeded() {
        guard let first = services.first else {
            selectedServiceId = nil
            return
        }
        if selectedServiceId == nil || !services.contains(where: { $0.serviceId == selectedServiceId }) {
            selectedServiceId = first.serviceId
        }
    }

    private func handlePendingOpenPath(_ pending: (serviceId: String, relativePath: String?)?) {
        guard let pending else { return }
        selectedServiceId = pending.serviceId
        selectedSection = .fileExplorer
    }
}
