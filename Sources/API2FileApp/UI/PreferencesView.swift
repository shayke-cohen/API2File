import SwiftUI
import API2FileCore

struct PreferencesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            GeneralTab(config: $appState.config)
                .tabItem { Label("General", systemImage: "gear") }

            ServicesTab(services: appState.services)
                .tabItem { Label("Services", systemImage: "cloud") }
        }
        .frame(width: 500, height: 350)
    }
}

struct GeneralTab: View {
    @Binding var config: GlobalConfig

    var body: some View {
        Form {
            TextField("Sync Folder:", text: $config.syncFolder)
            Toggle("Launch at login", isOn: $config.launchAtLogin)
            Toggle("Auto-commit to git", isOn: $config.gitAutoCommit)
            TextField("Commit message format:", text: $config.commitMessageFormat)
            Stepper("Default sync interval: \(config.defaultSyncInterval)s", value: $config.defaultSyncInterval, in: 10...600, step: 10)
            Toggle("Show notifications", isOn: $config.showNotifications)
            Toggle("Finder badges", isOn: $config.finderBadges)
            Stepper("Server port: \(config.serverPort)", value: $config.serverPort, in: 1024...65535)
        }
        .padding()
    }
}

struct ServicesTab: View {
    let services: [ServiceInfo]

    var body: some View {
        VStack {
            if services.isEmpty {
                Text("No services connected")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                List(services, id: \.serviceId) { service in
                    HStack {
                        Circle()
                            .fill(service.status == .error ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                        Text(service.displayName)
                        Spacer()
                        Text("\(service.fileCount) files")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Add Service...") {
                    // TODO: Open add service flow
                }
            }
            .padding()
        }
    }
}
