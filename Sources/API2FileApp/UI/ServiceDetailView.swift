import SwiftUI
import API2FileCore

struct ServiceDetailView: View {
    let service: ServiceInfo
    @ObservedObject var appState: AppState

    @State private var showDisconnectAlert = false
    @State private var showReAuth = false
    @State private var newAPIKey = ""
    @State private var recentHistory: [SyncHistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(service.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(statusColor.opacity(0.15)))
            }
            .padding(.bottom, 12)

            Divider()
                .padding(.bottom, 8)

            // Info
            Form {
                LabeledContent("Last synced") {
                    if let time = service.lastSyncTime {
                        Text(time, style: .relative)
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Files") {
                    Text("\(service.fileCount)")
                }

                LabeledContent("Folder") {
                    Button("~/API2File/\(service.serviceId)/") {
                        let url = appState.config.resolvedSyncFolder
                            .appendingPathComponent(service.serviceId)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.link)
                }
            }
            .formStyle(.columns)
            .padding(.bottom, 8)

            // Resources
            if !service.config.resources.isEmpty {
                Divider()
                    .padding(.bottom, 6)
                Text("Resources")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(service.config.resources, id: \.name) { resource in
                    HStack(spacing: 6) {
                        Image(systemName: formatIcon(resource.fileMapping.format.rawValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(resource.name)
                            .font(.callout)
                        Spacer()
                        Text(resource.fileMapping.format.rawValue)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if resource.fileMapping.readOnly == true {
                            Text("read-only")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            // Recent Activity
            if !recentHistory.isEmpty {
                Divider()
                    .padding(.bottom, 6)
                Text("Recent Activity")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                ForEach(recentHistory.prefix(10)) { entry in
                    SyncHistoryRow(entry: entry, showServiceName: false)
                }
            }

            // Error
            if let errorMessage = service.errorMessage, service.status == .error {
                Divider()
                    .padding(.vertical, 6)
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            Divider()
                .padding(.vertical, 8)

            // Actions
            HStack(spacing: 8) {
                Button {
                    appState.syncService(serviceId: service.serviceId)
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(service.status == .syncing)

                Button {
                    let url = appState.config.resolvedSyncFolder
                        .appendingPathComponent(service.serviceId)
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }

                Spacer()

                Button("Update Key...") {
                    newAPIKey = ""
                    showReAuth = true
                }

                Button("Disconnect...", role: .destructive) {
                    showDisconnectAlert = true
                }
            }
            .controlSize(.small)
        }
        .padding()
        .task {
            recentHistory = await appState.getServiceHistory(serviceId: service.serviceId, limit: 10)
        }
        .alert("Disconnect \(service.displayName)?", isPresented: $showDisconnectAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                appState.removeService(serviceId: service.serviceId)
            }
        } message: {
            Text("Syncing will stop. Your local files in ~/API2File/\(service.serviceId)/ will be kept.")
        }
        .sheet(isPresented: $showReAuth) {
            VStack(spacing: 16) {
                Text("Update API Key")
                    .font(.headline)
                Text("Enter a new API key for \(service.displayName)")
                    .foregroundStyle(.secondary)
                SecureField("New API Key", text: $newAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showReAuth = false }
                    Spacer()
                    Button("Save") {
                        appState.updateAPIKey(serviceId: service.serviceId, newKey: newAPIKey)
                        showReAuth = false
                    }
                    .disabled(newAPIKey.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 320)
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .connected: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch service.status {
        case .connected: return "Synced"
        case .syncing: return "Syncing..."
        case .paused: return "Paused"
        case .error: return "Error"
        case .disconnected: return "Disconnected"
        }
    }

    private func formatIcon(_ format: String) -> String {
        switch format {
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "md", "markdown": return "text.document"
        case "html": return "globe"
        case "ics": return "calendar"
        case "vcf": return "person.crop.rectangle"
        case "svg", "png": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}
