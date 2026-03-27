import SwiftUI
import WebKit
import API2FileCore

/// Opens a file in the built-in editor window.
@MainActor
func openFileInEditor(_ fileURL: URL) {
    let ext = fileURL.pathExtension.lowercased()
    let textExts = Set(["csv", "md", "markdown", "json", "txt", "html", "htm",
                        "xml", "yaml", "yml", "ics", "vcf", "eml", "log", "ini",
                        "toml", "swift", "py", "js", "ts", "sh", "zsh", "rb",
                        "go", "rs", "c", "h", "cpp", "java", "kt", "sql", "svg"])
    if textExts.contains(ext) {
        FileEditorWindow.open(fileURL: fileURL)
    } else {
        NSWorkspace.shared.open(fileURL)
    }
}

struct ServiceDetailView: View {
    let service: ServiceInfo
    @ObservedObject var appState: AppState

    @State private var showDisconnectAlert = false
    @State private var showReAuth = false
    @State private var newAPIKey = ""
    @State private var recentHistory: [SyncHistoryEntry] = []
    @State private var resourcesExpanded = true
    @State private var expandedFolders: Set<String> = []
    @State private var selectedFile: URL?
    @State private var showHiddenFiles = false
    @State private var gitStatuses: [String: String] = [:]
    @State private var gitDiff: String = ""
    @State private var refreshTick = false

    // Timer for auto-refresh (fires every 3s)
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

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
            await refreshGitStatus()
        }
        .onReceive(refreshTimer) { _ in
            Task { await refreshGitStatus() }
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
                    Button(shortenURL(siteUrl)) {
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
                    Button(shortenURL(dashboardUrl)) {
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

    // MARK: - Helpers

    private func shortenURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        let path = url.path
        // Collapse UUID segments (e.g. "acac6517-f1b2-4cfe-aa9c-ad35ca8363e7") to "…"
        let shortened = path.components(separatedBy: "/").map { segment in
            let uuid = try? NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
            if uuid?.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) != nil {
                return "…"
            }
            return segment
        }.joined(separator: "/")
        let result = host + shortened
        return result.hasSuffix("/") ? String(result.dropLast()) : result
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
        let serviceDir = appState.config.resolvedSyncFolder
            .appendingPathComponent(service.serviceId)
        return GroupBox {
            if resourcesExpanded {
                HStack(spacing: 0) {
                    // Left: resource list
                    resourceList(serviceDir: serviceDir)
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)

                    Divider()

                    // Right: preview
                    resourcePreview(serviceDir: serviceDir)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 340)
            }
        } label: {
            HStack {
                Label("Resources", systemImage: "square.grid.2x2")
                    .font(.headline)
                Spacer()
                Toggle(isOn: $showHiddenFiles) {
                    Image(systemName: "eye")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .help(showHiddenFiles ? "Hide system files" : "Show system files")
                Text("\(sortedResources.count) items")
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

    /// Resources sorted: folders first, then files, alphabetical within each group.
    private var sortedResources: [ResourceConfig] {
        service.config.resources.sorted { a, b in
            let aIsFolder = a.fileMapping.strategy != .collection
            let bIsFolder = b.fileMapping.strategy != .collection
            if aIsFolder != bIsFolder { return aIsFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - Resource List (Left Pane)

    private func resourceList(serviceDir: URL) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sortedResources, id: \.name) { resource in
                    let isFolder = resource.fileMapping.strategy != .collection
                    if isFolder {
                        folderRow(resource: resource, serviceDir: serviceDir)
                    } else {
                        fileResourceRow(resource: resource, serviceDir: serviceDir)
                    }
                }
            }
        }
    }

    private func folderRow(resource: ResourceConfig, serviceDir: URL) -> some View {
        let isExpanded = expandedFolders.contains(resource.name)
        let mapping = resource.fileMapping
        let dir = (mapping.directory == "." || mapping.directory.isEmpty)
            ? serviceDir
            : serviceDir.appendingPathComponent(mapping.directory)
        let count = resourceCount(for: resource, serviceDir: serviceDir)

        return VStack(alignment: .leading, spacing: 0) {
            // Folder header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded { expandedFolders.remove(resource.name) }
                    else { expandedFolders.insert(resource.name) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.caption)
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                        .frame(width: 14)
                    Text(resource.name)
                        .font(.callout)
                        .lineLimit(1)
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    Spacer()
                    Text(mapping.format.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
                    if resource.fileMapping.readOnly == true {
                        Text("read-only")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded files
            if isExpanded {
                let files = loadFiles(in: dir)
                ForEach(files, id: \.lastPathComponent) { fileURL in
                    fileRow(fileURL: fileURL, indented: true)
                }
            }
        }
    }

    private func fileResourceRow(resource: ResourceConfig, serviceDir: URL) -> some View {
        let mapping = resource.fileMapping
        let dir = (mapping.directory == "." || mapping.directory.isEmpty)
            ? serviceDir
            : serviceDir.appendingPathComponent(mapping.directory)
        let fileURL = mapping.filename.map { dir.appendingPathComponent($0) }
        let count = resourceCount(for: resource, serviceDir: serviceDir)
        let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        return Button {
            if let url = fileURL { selectedFile = url }
        } label: {
            HStack(spacing: 4) {
                Color.clear.frame(width: 10) // indent alignment
                Image(systemName: formatIcon(for: mapping.format.rawValue))
                    .font(.caption)
                    .foregroundStyle(exists ? .secondary : .quaternary)
                    .frame(width: 14)
                Text(resource.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundColor(exists ? .primary : .gray.opacity(0.5))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                if let status = resourceGitStatus(resource, serviceDir: serviceDir) {
                    GitStatusBadge(status: status)
                }
                Spacer()
                Text(mapping.format.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
                if resource.fileMapping.readOnly == true {
                    Text("read-only")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selectedFile == fileURL ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let url = fileURL { openFileInEditor(url) }
        })
    }

    private func fileRow(fileURL: URL, indented: Bool) -> some View {
        let isSelected = selectedFile == fileURL

        return Button {
            selectedFile = fileURL
        } label: {
            HStack(spacing: 4) {
                if indented { Color.clear.frame(width: 24) }
                Image(systemName: fileIcon(for: fileURL))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(fileURL.lastPathComponent)
                    .font(.system(.caption))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status = gitStatus(for: fileURL) {
                    GitStatusBadge(status: status)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            openFileInEditor(fileURL)
        })
    }

    // MARK: - Resource Preview (Right Pane)

    /// Find the resource config that owns the selected file.
    private func resourceForFile(_ fileURL: URL, serviceDir: URL) -> ResourceConfig? {
        let filePath = fileURL.path
        for resource in service.config.resources {
            let mapping = resource.fileMapping
            let dir = (mapping.directory == "." || mapping.directory.isEmpty)
                ? serviceDir
                : serviceDir.appendingPathComponent(mapping.directory)
            if mapping.strategy == .collection {
                if let filename = mapping.filename,
                   dir.appendingPathComponent(filename).path == filePath {
                    return resource
                }
            } else {
                if filePath.hasPrefix(dir.path) {
                    return resource
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func resourcePreview(serviceDir: URL) -> some View {
        if let fileURL = selectedFile {
            let objectFileURL = canonicalObjectFileURL(for: fileURL, serviceDir: serviceDir)
            FilePreviewPanel(
                fileURL: fileURL,
                objectFileURL: objectFileURL,
                serviceDir: serviceDir,
                gitStatus: gitStatus(for: fileURL),
                dashboardUrl: resourceForFile(fileURL, serviceDir: serviceDir)?.dashboardUrl ?? service.config.dashboardUrl
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { selectedFile = nil }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title)
                    .foregroundStyle(.quaternary)
                Text("Select a file to preview")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatIcon(for format: String) -> String {
        switch format {
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

    private func fileIcon(for url: URL) -> String {
        formatIcon(for: url.pathExtension.lowercased())
    }

    /// Count records for a resource: CSV rows (minus header), folder files, JSON array items.
    private func resourceCount(for resource: ResourceConfig, serviceDir: URL) -> Int? {
        let mapping = resource.fileMapping
        let dir = (mapping.directory == "." || mapping.directory.isEmpty)
            ? serviceDir
            : serviceDir.appendingPathComponent(mapping.directory)

        if mapping.strategy != .collection {
            // Folder: count files
            let files = loadFiles(in: dir)
            return files.isEmpty ? nil : files.count
        }

        guard let filename = mapping.filename else { return nil }
        let fileURL = dir.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }

        switch mapping.format {
        case .csv:
            // Count non-empty lines minus header
            let lineCount = data.withUnsafeBytes { buf in
                buf.reduce(0) { count, byte in count + (byte == UInt8(ascii: "\n") ? 1 : 0) }
            }
            let str = String(data: data, encoding: .utf8) ?? ""
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return max(0, lines.count - 1) // minus header
        case .json:
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                if let arr = obj as? [Any] { return arr.count }
                if obj is [String: Any] { return 1 }
            }
            return nil
        default:
            return nil
        }
    }

    private func refreshGitStatus() async {
        let serviceDir = appState.config.resolvedSyncFolder
            .appendingPathComponent(service.serviceId)
        let git = GitManager(repoPath: serviceDir)
        let statuses = (try? await git.statusForFiles()) ?? [:]
        if statuses != gitStatuses {
            gitStatuses = statuses
        }
    }

    /// Resolve the git status for a file URL relative to the service directory.
    private func gitStatus(for fileURL: URL) -> String? {
        let serviceDir = appState.config.resolvedSyncFolder
            .appendingPathComponent(service.serviceId)
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        return gitStatuses[relativePath]
    }

    /// Git status for a collection resource (single file).
    private func resourceGitStatus(_ resource: ResourceConfig, serviceDir: URL) -> String? {
        guard resource.fileMapping.strategy == .collection, let filename = resource.fileMapping.filename else { return nil }
        let dir = resource.fileMapping.directory
        let relativePath = (dir == "." || dir.isEmpty) ? filename : "\(dir)/\(filename)"
        return gitStatuses[relativePath]
    }

    private func loadFiles(in directory: URL) -> [URL] {
        let opts: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: opts
        ) else { return [] }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func canonicalObjectFileURL(for fileURL: URL, serviceDir: URL) -> URL? {
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        guard let resource = resourceForFile(fileURL, serviceDir: serviceDir),
              let objectPath = ObjectFileManager.canonicalObjectFilePath(
                forDisplayedFile: relativePath,
                strategy: resource.fileMapping.strategy
              ) else {
            return nil
        }

        let objectURL = serviceDir.appendingPathComponent(objectPath)
        guard FileManager.default.fileExists(atPath: objectURL.path) else { return nil }
        return objectURL
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

// MARK: - File Preview Panel

private struct FilePreviewPanel: View {
    let fileURL: URL
    let objectFileURL: URL?
    let serviceDir: URL
    var gitStatus: String?
    var dashboardUrl: String?
    let onClose: () -> Void

    @State private var content: PreviewContent = .loading
    @State private var diffText: String?
    @State private var showDiff = false

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 6) {
                    Image(systemName: headerIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fileURL.lastPathComponent)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let status = gitStatus {
                        GitStatusBadge(status: status)
                    }
                    Spacer()
                    if diffText != nil {
                        Picker("", selection: $showDiff) {
                            Text("Preview").tag(false)
                            Text("Changes").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    if let dashboardUrl, let url = URL(string: dashboardUrl) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Dashboard", systemImage: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }
                    if let objectFileURL {
                        Button {
                            openFileInEditor(objectFileURL)
                        } label: {
                            Label("Object", systemImage: "curlybraces")
                                .font(.caption)
                        }
                        .controlSize(.small)
                        .help("Open the canonical object file")
                    }
                    Button {
                        openFileInEditor(fileURL)
                    } label: {
                        Label("Edit", systemImage: "pencil.line")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)

                Divider()

                // Content
                if showDiff, let diff = diffText {
                    DiffView(diff: diff)
                        .frame(maxWidth: .infinity, maxHeight: 350, alignment: .topLeading)
                } else {
                    previewBody
                        .frame(maxWidth: .infinity, maxHeight: 350, alignment: .topLeading)
                }
            }
        } label: {
            EmptyView()
        }
        .task(id: fileURL) {
            content = loadContent()
            await loadDiff()
        }
    }

    private func loadDiff() async {
        guard gitStatus != nil else { diffText = nil; return }
        let git = GitManager(repoPath: serviceDir)
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        let diff = try? await git.diffForFile(relativePath)
        diffText = (diff?.isEmpty == false) ? diff : nil
    }

    @ViewBuilder
    private var previewBody: some View {
        switch content {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 60)
        case .text(let text):
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        case .markdownHTML(let html):
            HTMLPreviewView(html: html)
        case .json(let formatted):
            JSONPreviewView(json: formatted)
        case .csv(let headers, let rows):
            CSVTableView(headers: headers, rows: rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image(let image):
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 340)
                    .frame(maxWidth: .infinity)
                    .padding(4)
            }
        case .html(let htmlString):
            HTMLPreviewView(html: htmlString)
                .frame(minHeight: 200)
        case .unsupported:
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No preview available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open in Default App") {
                    NSWorkspace.shared.open(fileURL)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func loadContent() -> PreviewContent {
        let ext = fileURL.pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .unsupported }

        // Images
        let imageExts = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "ico"]
        if imageExts.contains(ext) {
            if let image = NSImage(contentsOf: fileURL) { return .image(image) }
            return .unsupported
        }
        if ext == "svg" {
            if let image = NSImage(contentsOf: fileURL) { return .image(image) }
            // fallback: show SVG source
            if let text = try? String(contentsOf: fileURL, encoding: .utf8) { return .text(text) }
            return .unsupported
        }
        if ext == "pdf" { return .unsupported } // PDFs are better opened externally

        // Text-based files
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return .unsupported }

        switch ext {
        case "md", "markdown":
            return .markdownHTML(renderMarkdownHTML(text))
        case "csv":
            return parseCSV(text)
        case "json":
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let formatted = String(data: pretty, encoding: .utf8) {
                return .json(formatted)
            }
            return .json(text)
        case "html", "htm":
            return .html(text)
        case "txt", "ics", "vcf", "xml", "yaml", "yml", "eml", "log", "ini", "toml", "swift", "py", "js", "ts", "sh", "zsh", "bash", "rb", "go", "rs", "c", "h", "cpp", "java", "kt", "sql":
            return .text(text)
        default:
            // Try reading as text for unknown extensions
            return .text(text)
        }
    }

    private func parseCSV(_ text: String) -> PreviewContent {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first else { return .text(text) }
        let headers = parseCSVLine(headerLine)
        let rows = lines.dropFirst().prefix(200).map { parseCSVLine($0) }
        return .csv(headers, Array(rows))
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private var headerIcon: String {
        switch fileURL.pathExtension.lowercased() {
        case "csv": return "tablecells"
        case "json": return "curlybraces"
        case "md", "markdown": return "text.document"
        case "html", "htm": return "globe"
        case "txt", "log": return "doc.text"
        case "ics": return "calendar"
        case "vcf": return "person.crop.rectangle"
        case "svg", "png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp": return "photo"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

private enum PreviewContent {
    case loading
    case text(String)
    case markdownHTML(String)
    case json(String)
    case csv([String], [[String]])
    case image(NSImage)
    case html(String)
    case unsupported
}

// MARK: - CSV Table View

private struct CSVTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
                        tableHeaderCell(header, width: columnWidth(for: idx), isLast: idx == headers.count - 1)
                    }
                }
                .background(Color.secondary.opacity(0.10))

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, _ in
                            tableDataCell(
                                cell(at: colIdx, in: row),
                                width: columnWidth(for: colIdx),
                                isLast: colIdx == headers.count - 1
                            )
                        }
                    }
                    .background(rowIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.035))

                    if rowIdx < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func columnWidth(for index: Int) -> CGFloat {
        let headerLen = index < headers.count ? headers[index].count : 5
        // Sample a few rows to estimate width
        let sampleRows = rows.prefix(20)
        let maxDataLen = sampleRows.reduce(headerLen) { maxLen, row in
            guard index < row.count else { return maxLen }
            return max(maxLen, row[index].count)
        }
        let charWidth: CGFloat = 7
        return max(60, min(CGFloat(maxDataLen) * charWidth + 16, 220))
    }

    private func cell(at index: Int, in row: [String]) -> String {
        guard index < row.count else { return "" }
        return row[index]
    }

    private func tableHeaderCell(_ text: String, width: CGFloat, isLast: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .overlay(alignment: .trailing) {
                if !isLast {
                    Divider().opacity(0.5)
                }
            }
    }

    private func tableDataCell(_ text: String, width: CGFloat, isLast: Bool) -> some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) {
                if !isLast {
                    Divider().opacity(0.35)
                }
            }
    }
}

// MARK: - HTML Preview View

private struct HTMLPreviewView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(false, forKey: "javaScriptEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Markdown HTML Renderer

private func renderMarkdownHTML(_ md: String) -> String {
    func esc(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
    var html = esc(md)
    // Code blocks
    html = html.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)
    html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
    // Line-by-line
    let lines = html.components(separatedBy: "\n")
    html = lines.map { line in
        if line.hasPrefix("###### ") { return "<h6>\(line.dropFirst(7))</h6>" }
        if line.hasPrefix("##### ") { return "<h5>\(line.dropFirst(6))</h5>" }
        if line.hasPrefix("#### ") { return "<h4>\(line.dropFirst(5))</h4>" }
        if line.hasPrefix("### ") { return "<h3>\(line.dropFirst(4))</h3>" }
        if line.hasPrefix("## ") { return "<h2>\(line.dropFirst(3))</h2>" }
        if line.hasPrefix("# ") { return "<h1>\(line.dropFirst(2))</h1>" }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return "<li>\(line.dropFirst(2))</li>" }
        if line.hasPrefix("> ") { return "<blockquote>\(line.dropFirst(2))</blockquote>" }
        if line.isEmpty { return "<br>" }
        return "<p>\(line)</p>"
    }.joined(separator: "\n")
    // Inline
    html = html.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>", options: .regularExpression)
    html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
    html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
    html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
    html = html.replacingOccurrences(of: "~~(.+?)~~", with: "<del>$1</del>", options: .regularExpression)
    html = html.replacingOccurrences(of: "<p>---</p>", with: "<hr>")

    return """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    body { font-family: -apple-system, sans-serif; font-size: 13px; line-height: 1.6;
           color: #e0e0e0; background: #1e1e1e; padding: 12px; margin: 0; }
    @media (prefers-color-scheme: light) {
        body { color: #333; background: #fff; }
        code { background: #f0f0f0; } pre { background: #f5f5f5; }
        blockquote { border-color: #ddd; color: #666; } hr { border-color: #ddd; }
    }
    h1 { font-size: 1.5em; margin: 0.6em 0 0.3em; border-bottom: 1px solid #444; padding-bottom: 0.2em; }
    h2 { font-size: 1.25em; margin: 0.6em 0 0.3em; }
    h3 { font-size: 1.1em; margin: 0.5em 0 0.2em; }
    p { margin: 0.3em 0; }
    code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em;
           background: #2d2d2d; padding: 1px 4px; border-radius: 3px; }
    pre { background: #2d2d2d; padding: 10px; border-radius: 6px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #555; margin: 0.4em 0; padding: 0.1em 10px; color: #aaa; }
    li { margin: 0.15em 0; margin-left: 18px; }
    a { color: #58a6ff; } hr { border: none; border-top: 1px solid #444; margin: 0.8em 0; }
    del { color: #888; } strong { font-weight: 600; }
    </style></head><body>\(html)</body></html>
    """
}

// MARK: - JSON Preview View

private struct JSONPreviewView: NSViewRepresentable {
    let json: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString(renderJSONHTML(json), baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(renderJSONHTML(json), baseURL: nil)
    }

    private func renderJSONHTML(_ json: String) -> String {
        let escaped = json
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        // Syntax highlight JSON with regex
        var highlighted = escaped
        // Strings (keys and values)
        highlighted = highlighted.replacingOccurrences(
            of: "(&quot;|\")(.*?)(\\1)",
            with: "<span class=\"s\">$1$2$3</span>",
            options: .regularExpression
        )
        // Numbers
        highlighted = highlighted.replacingOccurrences(
            of: ":\\s*(-?[0-9]+\\.?[0-9]*(?:[eE][+-]?[0-9]+)?)",
            with: ": <span class=\"n\">$1</span>",
            options: .regularExpression
        )
        // Booleans and null
        highlighted = highlighted.replacingOccurrences(
            of: ":\\s*(true|false|null)",
            with: ": <span class=\"k\">$1</span>",
            options: .regularExpression
        )

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        body { font-family: 'SF Mono', Menlo, monospace; font-size: 12px; line-height: 1.5;
               color: #d4d4d4; background: #1e1e1e; padding: 10px; margin: 0;
               white-space: pre-wrap; word-wrap: break-word; }
        @media (prefers-color-scheme: light) {
            body { color: #333; background: #fff; }
            .s { color: #a31515; }
            .n { color: #098658; }
            .k { color: #0000ff; }
        }
        .s { color: #ce9178; }
        .n { color: #b5cea8; }
        .k { color: #569cd6; }
        </style></head><body>\(highlighted)</body></html>
        """
    }
}

// MARK: - Git Status Badge

private struct GitStatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color))
    }

    private var label: String {
        switch status {
        case "M", "MM", "AM": return "M"
        case "A": return "A"
        case "??": return "N"
        case "D": return "D"
        case "R": return "R"
        default: return status.prefix(1).uppercased()
        }
    }

    private var color: Color {
        switch status {
        case "M", "MM", "AM": return .orange
        case "A": return .green
        case "??": return .green
        case "D": return .red
        default: return .orange
        }
    }
}

// MARK: - Diff View

private struct DiffView: View {
    let diff: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(line.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 0.5)
                        .background(line.background)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
    }

    private var diffLines: [DiffLine] {
        diff.components(separatedBy: "\n").map { line in
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                return DiffLine(text: line, color: Color(nsColor: .systemGreen), background: Color.green.opacity(0.08))
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                return DiffLine(text: line, color: Color(nsColor: .systemRed), background: Color.red.opacity(0.08))
            } else if line.hasPrefix("@@") {
                return DiffLine(text: line, color: .cyan, background: Color.cyan.opacity(0.05))
            } else if line.hasPrefix("diff") || line.hasPrefix("index") || line.hasPrefix("---") || line.hasPrefix("+++") {
                return DiffLine(text: line, color: .secondary, background: .clear)
            } else {
                return DiffLine(text: line, color: .primary, background: .clear)
            }
        }
    }
}

private struct DiffLine {
    let text: String
    let color: Color
    let background: Color
}
