import AppKit
import SwiftUI

private enum Dashboard3Tab: Hashable {
    case fileExplorer
    case dataExplorer
    case activity
}

struct DashboardRootView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Dashboard3WorkspaceView(appState: appState)
            .frame(minWidth: 900, idealWidth: 1280, minHeight: 620, idealHeight: 820)
            .onAppear {
                appState.registerDashboardWindowOpener {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

private struct Dashboard3WorkspaceView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: Dashboard3Tab = .fileExplorer

    private let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.94, green: 0.97, blue: 1.0),
            Color(red: 0.96, green: 0.95, blue: 0.99)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dashboard")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Files, local mirror data, and sync activity in one place.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 16)

                    Picker("Workspace Section", selection: $selectedTab) {
                        Text("File Explorer").tag(Dashboard3Tab.fileExplorer)
                        Text("Data Explorer").tag(Dashboard3Tab.dataExplorer)
                        Text("Activity").tag(Dashboard3Tab.activity)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 420)
                }
                .padding(20)
                .background(dashboardShellPanel(cornerRadius: 28))
                .padding(.horizontal, 18)
                .padding(.top, 18)

                Group {
                    switch selectedTab {
                    case .fileExplorer:
                        Dashboard2View(
                            appState: appState,
                            headerTitle: "File Explorer",
                            headerSubtitle: "Browse synced files, edit records in place, and jump into the right tool faster.",
                            embeddedInWorkspace: true
                        )
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    case .dataExplorer:
                        SQLExplorerPane(appState: appState, initialServiceId: nil)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    case .activity:
                        ActivityPane(appState: appState)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 18)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $appState.showingSettings) {
            NavigationStack {
                GeneralPane(config: $appState.config)
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appState.showingSettings = false }
                        }
                    }
            }
            .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 520)
        }
    }

    private func dashboardShellPanel(cornerRadius: CGFloat) -> some View {
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
            .shadow(color: Color.black.opacity(0.05), radius: 16, x: 0, y: 10)
    }
}
