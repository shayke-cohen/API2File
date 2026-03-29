import SwiftUI

struct IOSRootView: View {
    @Bindable var appState: IOSAppState
    @State private var showingAddService = false

    var body: some View {
        ZStack {
            IOSScreenBackground()

            TabView(selection: $appState.selectedTab) {
                NavigationStack {
                    IOSServicesView(
                        appState: appState,
                        selectedTab: $appState.selectedTab,
                        showingAddService: $showingAddService
                    )
                }
                .background(Color.clear)
                .tag(IOSRootTab.services)
                .tabItem {
                    Label(IOSRootTab.services.title, systemImage: IOSRootTab.services.systemImage)
                        .accessibilityIdentifier(IOSRootTab.services.accessibilityID)
                }

                IOSBrowserView(appState: appState)
                    .background(Color.clear)
                    .tag(IOSRootTab.browser)
                    .tabItem {
                        Label(IOSRootTab.browser.title, systemImage: IOSRootTab.browser.systemImage)
                            .accessibilityIdentifier(IOSRootTab.browser.accessibilityID)
                    }

                NavigationStack {
                    IOSDataExplorerView(appState: appState)
                }
                .background(Color.clear)
                .tag(IOSRootTab.dataExplorer)
                .tabItem {
                    Label(IOSRootTab.dataExplorer.title, systemImage: IOSRootTab.dataExplorer.systemImage)
                        .accessibilityIdentifier(IOSRootTab.dataExplorer.accessibilityID)
                }

                NavigationStack {
                    IOSActivityView(appState: appState)
                }
                .background(Color.clear)
                .tag(IOSRootTab.activity)
                .tabItem {
                    Label(IOSRootTab.activity.title, systemImage: IOSRootTab.activity.systemImage)
                        .accessibilityIdentifier(IOSRootTab.activity.accessibilityID)
                }

                NavigationStack {
                    IOSSettingsView(appState: appState)
                }
                .background(Color.clear)
                .tag(IOSRootTab.settings)
                .tabItem {
                    Label(IOSRootTab.settings.title, systemImage: IOSRootTab.settings.systemImage)
                        .accessibilityIdentifier(IOSRootTab.settings.accessibilityID)
                }
            }
            .background(Color.clear)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .accessibilityIdentifier("root.tab-view")
        .sheet(isPresented: $showingAddService) {
            AddServiceSheet(appState: appState)
        }
        .alert("Sync Error", isPresented: Binding(
            get: { appState.lastError != nil },
            set: { if !$0 { appState.lastError = nil } }
        )) {
            Button("OK", role: .cancel) {
                appState.lastError = nil
            }
        } message: {
            Text(appState.lastError ?? "")
        }
    }
}
