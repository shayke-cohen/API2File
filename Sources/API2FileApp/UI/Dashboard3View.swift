import SwiftUI
import API2FileCore

struct Dashboard3View: View {
    @ObservedObject var appState: AppState

    @State private var selectedServiceId: String?

    private var services: [ServiceInfo] {
        appState.services
            .filter { $0.config.enabled != false }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var selectedService: ServiceInfo? {
        services.first(where: { $0.serviceId == selectedServiceId }) ?? services.first
    }

    private var selectedServiceDirectory: URL? {
        guard let selectedService else { return nil }
        return appState.config.resolvedSyncFolder.appendingPathComponent(selectedService.serviceId, isDirectory: true)
    }

    private var suggestedFileURL: URL? {
        guard let selectedServiceDirectory else { return nil }
        return SyncedFilePreviewSupport.defaultPreviewCandidate(in: selectedServiceDirectory)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                dashboardHeader

                if services.isEmpty {
                    emptyState
                } else {
                    HSplitView {
                        serviceRail
                            .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)

                        servicePanel
                            .frame(minWidth: 560, idealWidth: 820, maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
        }
        .onAppear {
            selectDefaultServiceIfNeeded()
        }
        .onChange(of: services.map(\.serviceId)) { _ in
            selectDefaultServiceIfNeeded()
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dashboard 3")
                    .font(.system(size: 26, weight: .semibold))
                Text("Minimal control surface for services, sync status, and the next file to preview or edit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    appState.openAddServiceWindow()
                } label: {
                    Label("Add Service", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    appState.syncNow()
                } label: {
                    Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(services.isEmpty)
            }
        }
        .padding(18)
        .background(dashboardPanel())
    }

    private var serviceRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Services")
                        .font(.headline)
                    Text("\(services.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(services, id: \.serviceId) { service in
                        serviceRow(for: service)
                    }
                }
            }
        }
        .padding(16)
        .background(dashboardPanel())
    }

    private func serviceRow(for service: ServiceInfo) -> some View {
        let isSelected = selectedService?.serviceId == service.serviceId
        return Button {
            selectedServiceId = service.serviceId
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusColor(for: service))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(serviceFreshnessText(for: service))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(statusLabel(for: service))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(for: service))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(statusColor(for: service).opacity(0.12))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var servicePanel: some View {
        if let service = selectedService,
           let serviceDirectory = selectedServiceDirectory {
            let snapshot = suggestedFileURL.map { Dashboard3PreviewSnapshot(fileURL: $0, serviceDirectory: serviceDirectory) }

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(service.displayName)
                                .font(.system(size: 28, weight: .semibold))
                            Text(service.serviceId)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Dashboard3StatusPill(
                            label: statusLabel(for: service),
                            tint: statusColor(for: service)
                        )
                    }

                    if let errorMessage = service.errorMessage,
                       service.status == .error {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 12) {
                    Dashboard3StatCard(title: "Status", value: statusLabel(for: service), detail: serviceFreshnessText(for: service))
                    Dashboard3StatCard(
                        title: "Last Sync",
                        value: service.lastSyncTime?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet",
                        detail: service.lastSyncTime.map(relativeDateString) ?? "Sync once to populate files"
                    )
                    Dashboard3StatCard(
                        title: "Files",
                        value: "\(service.fileCount)",
                        detail: snapshot?.kindLabel ?? "No preview candidate yet"
                    )
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    Dashboard3ActionButton(
                        title: "Sync now",
                        subtitle: "Run a sync for this service",
                        icon: "arrow.triangle.2.circlepath"
                    ) {
                        appState.syncService(serviceId: service.serviceId)
                    }

                    Dashboard3ActionButton(
                        title: "Open folder",
                        subtitle: "Reveal synced files in Finder",
                        icon: "folder"
                    ) {
                        FinderSupport.openInFinder(serviceDirectory)
                    }

                    Dashboard3ActionButton(
                        title: "Preview file",
                        subtitle: snapshot == nil ? "No user-facing file available" : "Open the suggested file in preview mode",
                        icon: "eye"
                    ) {
                        openSuggestedFile(in: serviceDirectory, launchMode: .preview)
                    }
                    .disabled(snapshot == nil)

                    Dashboard3ActionButton(
                        title: "Edit file",
                        subtitle: snapshot == nil ? "No user-facing file available" : "Open the suggested file in editor mode",
                        icon: "square.and.pencil"
                    ) {
                        openSuggestedFile(in: serviceDirectory, launchMode: .edit)
                    }
                    .disabled(snapshot == nil)
                }

                if let snapshot,
                   let suggestedFileURL {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Suggested File")
                                    .font(.headline)
                                Text(snapshot.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(snapshot.kindLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.10))
                                )
                        }

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: dashboard3Icon(for: suggestedFileURL))
                                .font(.title2)
                                .foregroundStyle(.accentColor)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 6) {
                                Text(suggestedFileURL.lastPathComponent)
                                    .font(.title3.weight(.medium))
                                    .lineLimit(1)
                                Text(snapshot.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.secondary.opacity(0.05))
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Suggested File")
                            .font(.headline)
                        Text("No preview candidate yet. Sync the service or add user-facing files to enable preview and edit shortcuts.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.secondary.opacity(0.05))
                    )
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(dashboardPanel())
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select a service")
                    .font(.title3.weight(.semibold))
                Text("Choose a connected service from the left rail to inspect sync status and actions.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .background(dashboardPanel())
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No services connected")
                .font(.title3.weight(.semibold))
            Text("Add a service to start syncing and previewing files from one minimal dashboard.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Service") {
                appState.openAddServiceWindow()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .background(dashboardPanel())
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

    private func openSuggestedFile(in serviceDirectory: URL, launchMode: FileEditorWindow.LaunchMode) {
        guard let suggestedFileURL else { return }
        FileEditorWindow.open(fileURL: suggestedFileURL, serviceDir: serviceDirectory, launchMode: launchMode)
    }

    private func relativeDateString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func serviceFreshnessText(for service: ServiceInfo) -> String {
        guard let lastSyncTime = service.lastSyncTime else { return "Never synced" }
        return "Last sync \(relativeDateString(lastSyncTime))"
    }

    private func statusLabel(for service: ServiceInfo) -> String {
        switch service.status {
        case .connected:
            return "Ready"
        case .syncing:
            return "Syncing"
        case .paused:
            return "Paused"
        case .error:
            return "Error"
        case .disconnected:
            return "Offline"
        }
    }

    private func statusColor(for service: ServiceInfo) -> Color {
        switch service.status {
        case .connected:
            return .green
        case .syncing:
            return .blue
        case .paused:
            return .gray
        case .error:
            return .red
        case .disconnected:
            return .secondary
        }
    }
}

private struct Dashboard3StatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}

private struct Dashboard3StatusPill: View {
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
    }
}

private struct Dashboard3ActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.accentColor)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct Dashboard3PreviewSnapshot {
    let relativePath: String
    let kindLabel: String
    let summary: String

    init(fileURL: URL, serviceDirectory: URL) {
        relativePath = SyncedFilePreviewSupport.relativePath(for: fileURL, serviceRoot: serviceDirectory) ?? fileURL.lastPathComponent
        kindLabel = SyncedFilePreviewSupport.fileKindLabel(for: fileURL)
        summary = Dashboard3PreviewSnapshot.makeSummary(for: fileURL)
    }

    private static func makeSummary(for fileURL: URL) -> String {
        switch SyncedFilePreviewSupport.kind(for: fileURL) {
        case .csv, .markdown, .json, .html, .yaml, .text, .calendar, .contact, .email:
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return "Text preview unavailable."
            }
            let compact = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(4)
                .joined(separator: " ")
            return compact.isEmpty ? "File is empty." : String(compact.prefix(220))
        case .image, .svg, .pdf, .audio, .movie, .office, .archive, .binary:
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .file
            return "Preview opens externally. Size \(formatter.string(fromByteCount: size))."
        }
    }
}

private func dashboardPanel() -> some View {
    RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
}

private func dashboard3Icon(for fileURL: URL) -> String {
    switch SyncedFilePreviewSupport.kind(for: fileURL) {
    case .csv:
        return "tablecells"
    case .markdown:
        return "text.document"
    case .json:
        return "curlybraces"
    case .html:
        return "globe"
    case .yaml:
        return "slider.horizontal.3"
    case .text:
        return "doc.text"
    case .image, .svg:
        return "photo"
    case .pdf, .office:
        return "doc.richtext"
    case .audio:
        return "waveform"
    case .movie:
        return "film"
    case .calendar:
        return "calendar"
    case .contact:
        return "person.crop.rectangle"
    case .email:
        return "envelope"
    case .archive, .binary:
        return "doc"
    }
}
