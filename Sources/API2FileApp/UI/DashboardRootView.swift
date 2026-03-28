import SwiftUI

private enum DashboardWorkspaceTab: Hashable {
    case classic
    case portal
}

struct DashboardRootView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: DashboardWorkspaceTab = .portal

    var body: some View {
        TabView(selection: $selectedTab) {
            PreferencesView(appState: appState)
                .tabItem {
                    Label("Dashboard", systemImage: "sidebar.left")
                }
                .tag(DashboardWorkspaceTab.classic)

            Dashboard2View(appState: appState)
                .tabItem {
                    Label("Dashboard 2", systemImage: "rectangle.3.group.bubble.left")
                }
                .tag(DashboardWorkspaceTab.portal)
        }
        .frame(minWidth: 900, idealWidth: 1280, minHeight: 620, idealHeight: 820)
    }
}
