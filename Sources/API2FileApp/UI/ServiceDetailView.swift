import SwiftUI
import API2FileCore

struct ServiceDetailView: View {
    let service: ServiceInfo
    @ObservedObject var appState: AppState

    @State private var showDisconnectAlert = false
    @State private var showReAuth = false
    @State private var newAPIKey = ""
    @State private var recentHistory: [SyncHistoryEntry] = []
    @State private var resourcesExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // Sticky header bar
            headerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            // Scrollable content
            ScrollView {
                VStack(spacing: 12) {
                    infoCards
                    claudeCodeButton
                    resourcesSection
                    if !recentHistory.isEmpty {
                        activitySection
                    }
                    if let errorMessage = service.errorMessage, service.status == .error {
                        errorSection(errorMessage)
                    }
                }
                .padding(14)
            }
        }
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
            reAuthSheet
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .testId("detail-status-dot")
            Text(service.displayName)
                .font(.title3)
                .fontWeight(.semibold)
                .testId("detail-service-name")
            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor.opacity(0.12)))
                .testId("detail-status-badge")

            Spacer()

            Button {
                appState.syncService(serviceId: service.serviceId)
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(service.status == .syncing)
            .testId("detail-sync-now")

            Button {
                let url = appState.config.resolvedSyncFolder
                    .appendingPathComponent(service.serviceId)
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open", systemImage: "folder")
            }
            .controlSize(.small)
            .testId("detail-open-folder")

            Toggle(isOn: Binding(
                get: { service.config.enabled != false },
                set: { appState.setServiceEnabled(serviceId: service.serviceId, enabled: $0) }
            )) {
                Text(service.config.enabled != false ? "Enabled" : "Disabled")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .testId("detail-enabled-toggle")

            Menu {
                Button("Update Key...") {
                    newAPIKey = ""
                    showReAuth = true
                }
                .testId("detail-update-key")
                Divider()
                Button("Disconnect...", role: .destructive) {
                    showDisconnectAlert = true
                }
                .testId("detail-disconnect")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
    }

    // MARK: - Info Cards

    private var infoCards: some View {
        HStack(spacing: 8) {
            StatCard(label: "Last Synced", icon: "clock") {
                if let time = service.lastSyncTime {
                    Text(time, style: .relative)
                        .testId("detail-last-synced")
                } else {
                    Text("Never")
                        .foregroundStyle(.tertiary)
                        .testId("detail-last-synced")
                }
            }

            StatCard(label: "Files", icon: "doc.on.doc") {
                Text("\(service.fileCount)")
                    .testId("detail-file-count")
            }

            StatCard(label: "Folder", icon: "folder") {
                Button("~/API2File/\(service.serviceId)/") {
                    let url = appState.config.resolvedSyncFolder
                        .appendingPathComponent(service.serviceId)
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .testId("detail-folder-link")
            }

            if let siteUrl = service.config.siteUrl {
                StatCard(label: "Site", icon: "globe") {
                    Button(siteUrl) {
                        if let url = URL(string: siteUrl) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .testId("detail-site-url-link")
                }
            }

            if let dashboardUrl = service.config.dashboardUrl {
                StatCard(label: "Dashboard", icon: "rectangle.on.rectangle") {
                    Button(dashboardUrl) {
                        if let url = URL(string: dashboardUrl) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .testId("detail-dashboard-url-link")
                }
            }
        }
    }

    // MARK: - Claude Code Button

    private var claudeCodeButton: some View {
        Button {
            appState.launchClaudeCode(serviceId: service.serviceId)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 14))
                Text("Open Claude Code")
                    .fontWeight(.medium)
                Text("— work with \(service.displayName) data using AI")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .testId("detail-open-claude-code")
    }

    // MARK: - Resources Section

    private var resourcesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if resourcesExpanded {
                    let columns = [
                        GridItem(.flexible(), spacing: 2),
                        GridItem(.flexible(), spacing: 2)
                    ]
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(service.config.resources, id: \.name) { resource in
                            ResourceRow(resource: resource)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("Resources", systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                Text("\(service.config.resources.count) items")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        resourcesExpanded.toggle()
                    }
                } label: {
                    Image(systemName: resourcesExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recentHistory.prefix(5)) { entry in
                    SyncHistoryRow(entry: entry, showServiceName: false)
                    if entry.id != recentHistory.prefix(5).last?.id {
                        Divider()
                            .padding(.leading, 22)
                    }
                }
            }
        } label: {
            HStack {
                Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
            }
        }
    }

    // MARK: - Error Section

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.08)))
        .testId("detail-error-message")
    }

    // MARK: - Re-Auth Sheet

    private var reAuthSheet: some View {
        VStack(spacing: 16) {
            Text("Update API Key")
                .font(.headline)
                .testId("reauth-title")
            Text("Enter a new API key for \(service.displayName)")
                .foregroundStyle(.secondary)
            SecureField("New API Key", text: $newAPIKey)
                .textFieldStyle(.roundedBorder)
                .testId("reauth-key-field")
            HStack {
                Button("Cancel") { showReAuth = false }
                    .keyboardShortcut(.cancelAction)
                    .testId("reauth-cancel")
                Spacer()
                Button("Save") {
                    appState.updateAPIKey(serviceId: service.serviceId, newKey: newAPIKey)
                    showReAuth = false
                }
                .disabled(newAPIKey.isEmpty)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .testId("reauth-save")
            }
        }
        .padding()
        .frame(width: 340)
        .testId("reauth-sheet")
    }

    // MARK: - Helpers

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
}

// MARK: - Stat Card

private struct StatCard<Content: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Resource Row

private struct ResourceRow: View {
    let resource: ResourceConfig

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: formatIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(resource.name)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Text(resource.fileMapping.format.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            if resource.fileMapping.readOnly == true {
                Text("read-only")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var formatIcon: String {
        switch resource.fileMapping.format.rawValue {
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "md", "markdown": return "text.document"
        case "html": return "globe"
        case "ics": return "calendar"
        case "vcf": return "person.crop.rectangle"
        case "svg", "png": return "photo"
        case "pdf": return "doc.richtext"
        case "raw": return "doc.zipper"
        default: return "doc"
        }
    }
}
