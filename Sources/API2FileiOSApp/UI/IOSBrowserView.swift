import SwiftUI
import UniformTypeIdentifiers
import UIKit
import API2FileCore

private struct BrowserResourceAction: Identifiable, Hashable {
    let serviceID: String
    let resourceName: String

    var id: String { "\(serviceID):\(resourceName)" }
}

private struct BrowserSelectedFile: Identifiable, Hashable {
    let url: URL

    var id: String { url.path }
}

private struct NewFileDraft: Identifiable, Hashable {
    let action: BrowserResourceAction
    var fileName = ""
    var content = ""

    var id: String { action.id }
}

private struct PhotoImportRequest: Identifiable, Hashable {
    let action: BrowserResourceAction
    let sourceType: UIImagePickerController.SourceType

    var id: String { "\(action.id):\(sourceType.rawValue)" }
}

private enum BrowserSheet: Identifiable {
    case newFile(NewFileDraft)
    case photoImport(PhotoImportRequest)

    var id: String {
        switch self {
        case .newFile(let draft):
            return "new-file:\(draft.id)"
        case .photoImport(let request):
            return "photo-import:\(request.id)"
        }
    }
}

struct IOSBrowserView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var appState: IOSAppState

    @State private var selectedFile: BrowserSelectedFile?
    @State private var presentedFile: BrowserSelectedFile?
    @State private var pendingImporterAction: BrowserResourceAction?
    @State private var presentedSheet: BrowserSheet?
    @State private var showsResourceTools = false
    @State private var expandedFolders: Set<String> = []

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { pendingImporterAction != nil },
                set: { if !$0 { pendingImporterAction = nil } }
            ),
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard let action = pendingImporterAction else { return }
            pendingImporterAction = nil
            if case .success(let urls) = result, let sourceURL = urls.first {
                importFile(action: action, sourceURL: sourceURL)
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .newFile(let draft):
                NewFileSheet(draft: draft) { name, content in
                    createTextFile(action: draft.action, name: name, content: content)
                }
            case .photoImport(let request):
                ImagePicker(sourceType: request.sourceType) { image in
                    saveImage(image, for: request.action)
                }
            }
        }
        .task(id: appState.selectedServiceID) {
            guard let service = currentService else {
                selectedFile = nil
                presentedFile = nil
                return
            }
            if let firstVisibleFile = firstVisibleFile(in: service) {
                selectFile(firstVisibleFile, autoPresent: false)
            } else {
                selectedFile = nil
                presentedFile = nil
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List(appState.services, id: \.serviceId, selection: $appState.selectedServiceID) { service in
                HStack(spacing: 12) {
                    Image(systemName: service.config.icon ?? "cloud.fill")
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(IOSTheme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.displayName)
                            .font(.headline)
                        Text(service.status.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(Optional(service.serviceId))
                .accessibilityIdentifier(IOSAccessibility.id("browser", "service", service.serviceId))
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
            .accessibilityIdentifier("browser.services.list")
            .navigationTitle("Services")
        } content: {
            if let service = currentService {
                browserContent(for: service)
                    .navigationTitle(service.displayName)
            } else {
                browserEmptyState
                    .navigationTitle("Browser")
            }
        } detail: {
            detailContent
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            Group {
                if let service = currentService {
                    browserContent(for: service)
                        .navigationDestination(item: $presentedFile) { selection in
                            fileDetailView(for: selection.url, service: service)
                        }
                } else {
                    browserEmptyState
                }
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func browserContent(for service: ServiceInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                browserHero(for: service)
                    .accessibilityIdentifier("browser.hero")

                if horizontalSizeClass != .regular && appState.services.count > 1 {
                    servicePickerCard
                }

                IOSSectionTitle(
                    "Files",
                    eyebrow: "File browser",
                    detail: "Browse the real files in this service folder first. Resource tools stay tucked away until you need them."
                )

                fileExplorerCard(for: service)
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "files"))

                if let selectedFile {
                    selectedFilePreviewCard(for: service, fileURL: selectedFile.url)
                        .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "selected-preview"))
                }

                resourceToolsCard(for: service)
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "resource-tools"))
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? IOSTheme.compactHorizontalInset : IOSTheme.regularHorizontalInset)
            .padding(.top, IOSTheme.contentTopInset)
            .padding(.bottom, IOSTheme.contentBottomInset)
        }
        .accessibilityIdentifier(IOSScreenID.browser)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await appState.sync(serviceID: service.serviceId) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Sync service")
                .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "sync"))
            }
        }
        .refreshable {
            await appState.sync(serviceID: service.serviceId)
        }
        .iosScreenBackground()
    }

    private func resourceToolsCard(for service: ServiceInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $showsResourceTools) {
                LazyVStack(spacing: 14) {
                    ForEach(service.config.resources.sorted(by: ResourceBrowserSupport.sortResources), id: \.name) { resource in
                        if resource.fileMapping.strategy == .collection {
                            collectionCard(service: service, resource: resource)
                        } else {
                            folderCard(service: service, resource: resource)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resource tools")
                        .font(.headline)
                        .foregroundStyle(IOSTheme.textPrimary)
                    Text("Import, create, and manage files through adapter-specific resources only when you need those controls.")
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                }
            }
        }
        .tint(IOSTheme.accent)
        .iosCardStyle()
    }

    private var servicePickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            IOSSectionTitle("Current service", detail: "Switch context without leaving the browser.")

            Picker("Service", selection: $appState.selectedServiceID) {
                ForEach(appState.services, id: \.serviceId) { option in
                    Text(option.displayName)
                        .tag(Optional(option.serviceId))
                }
            }
            .pickerStyle(.menu)
            .tint(IOSTheme.accent)
            .accessibilityIdentifier("browser.service-picker")
        }
        .iosCardStyle()
    }

    private func browserHero(for service: ServiceInfo) -> some View {
        let visibleFiles = visibleServiceFiles(in: service)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(IOSTheme.textPrimary)

                    Text(serviceBrowserSubtitle(service))
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                IOSStatusPill(status: service.status)
            }

            HStack(spacing: 10) {
                IOSSecondaryPill("\(service.config.resources.count) resources", systemImage: "square.grid.2x2.fill")
                IOSSecondaryPill("\(visibleFiles.count) synced files", systemImage: "doc.on.doc")
            }
        }
        .iosCardStyle()
    }

    @ViewBuilder
    private var detailContent: some View {
        if let service = currentService, let selectedFile {
            fileDetailView(for: selectedFile.url, service: service)
        } else {
            IOSEmptyStateCard(
                title: "Choose a file",
                message: "Preview, edit, upload, and share synced files from here.",
                systemImage: "doc.text.magnifyingglass"
            )
            .padding(20)
            .accessibilityIdentifier("browser.empty.file")
            .iosScreenBackground()
        }
    }

    private var currentService: ServiceInfo? {
        appState.services.first(where: { $0.serviceId == appState.selectedServiceID })
    }

    private var browserEmptyState: some View {
        ScrollView {
            IOSEmptyStateCard(
                title: "Choose a service",
                message: "Select a connected service to browse its files, then drill into resource-specific actions if needed.",
                systemImage: "folder.fill.badge.plus"
            )
            .padding(20)
            .accessibilityIdentifier("browser.empty.service")
        }
        .iosScreenBackground()
    }

    @ViewBuilder
    private func fileExplorerCard(for service: ServiceInfo) -> some View {
        let root = serviceDirectory(for: service)
        let items = BrowserFileExplorerSupport.items(for: visibleServiceFiles(in: service), root: root)
        let tree = BrowserFileExplorerSupport.tree(for: items)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                IOSSecondaryPill("\(tree.fileCount) synced file\(tree.fileCount == 1 ? "" : "s")", systemImage: "doc.on.doc")
                if tree.nestedFolderCount > 0 {
                    IOSSecondaryPill("\(tree.nestedFolderCount) folder\(tree.nestedFolderCount == 1 ? "" : "s")", systemImage: "folder")
                }
                Spacer(minLength: 12)
                if let selectedFile {
                    IOSSecondaryPill(selectedFile.url.lastPathComponent, systemImage: "doc.text")
                }
            }

            if items.isEmpty {
                Text("No visible files yet. Once this service syncs content, it will appear here immediately.")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(tree.folders) { folder in
                        folderSection(folder, service: service, depth: 0)
                    }

                    if !tree.files.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Service root")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(IOSTheme.textSecondary)

                            ForEach(tree.files) { item in
                                fileRow(for: item, service: service)
                            }
                        }
                    }
                }
            }
        }
        .iosCardStyle()
    }

    private func selectedFilePreviewCard(for service: ServiceInfo, fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected file")
                        .font(.headline)
                        .foregroundStyle(IOSTheme.textPrimary)

                    Text(fileURL.lastPathComponent)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(IOSTheme.textPrimary)

                    Text(BrowserFileExplorerSupport.relativePath(for: fileURL, in: serviceDirectory(for: service)))
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Button("Open preview") {
                    selectFile(fileURL, autoPresent: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(IOSTheme.accent)
                .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "open-selected-file"))
            }

            if let previewExcerpt = previewExcerpt(for: fileURL) {
                Text(previewExcerpt)
                    .font(.callout.monospaced())
                    .foregroundStyle(IOSTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, "selected-preview-text"))
            } else {
                Label("Preview this file to inspect its contents.", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .iosCardStyle()
    }

    private func collectionCard(service: ServiceInfo, resource: ResourceConfig) -> some View {
        let fileURL = ResourceBrowserSupport.collectionURL(for: resource, serviceRoot: serviceDirectory(for: service))

        return VStack(alignment: .leading, spacing: 14) {
            resourceHeader(service: service, resource: resource, fileCount: FileManager.default.fileExists(atPath: fileURL.path) ? 1 : 0)

            Button {
                selectFile(fileURL)
            } label: {
                HStack(spacing: 14) {
                    fileGlyph(for: fileURL)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)
                            .foregroundStyle(IOSTheme.textPrimary)
                        Text(resource.description ?? "Collection resource")
                            .font(.subheadline)
                            .foregroundStyle(IOSTheme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(IOSTheme.textSecondary)
                }
                .padding(16)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, fileURL.lastPathComponent))
        }
        .iosCardStyle()
        .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "card"))
    }

    private func folderCard(service: ServiceInfo, resource: ResourceConfig) -> some View {
        let files = filesForResource(resource, service: service)

        return VStack(alignment: .leading, spacing: 14) {
            resourceHeader(service: service, resource: resource, fileCount: files.count)

            if files.isEmpty {
                Text("No files yet")
                    .font(.subheadline)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "empty"))
            } else {
                VStack(spacing: 10) {
                    ForEach(files, id: \.path) { fileURL in
                        Button {
                            selectFile(fileURL)
                        } label: {
                            HStack(spacing: 14) {
                                fileGlyph(for: fileURL)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fileURL.lastPathComponent)
                                        .font(.headline)
                                        .foregroundStyle(IOSTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(fileURL.pathExtension.uppercased().isEmpty ? "File" : fileURL.pathExtension.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(IOSTheme.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(IOSTheme.textSecondary)
                            }
                            .padding(16)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, fileURL.lastPathComponent))
                    }
                }
            }
        }
        .iosCardStyle()
        .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "card"))
    }

    private func resourceHeader(service: ServiceInfo, resource: ResourceConfig, fileCount: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(resource.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(IOSTheme.textPrimary)
                    Spacer(minLength: 12)
                    if resource.fileMapping.readOnly == true {
                        IOSSecondaryPill("Read only", systemImage: "lock.fill")
                    }
                }

                if let description = resource.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                }

                HStack(spacing: 8) {
                    IOSSecondaryPill("\(fileCount) item\(fileCount == 1 ? "" : "s")", systemImage: "doc.on.doc")
                    IOSSecondaryPill(resource.fileMapping.format.rawValue.uppercased(), systemImage: "doc.text")
                }
            }

            resourceActions(for: service, resource: resource)
        }
    }

    @ViewBuilder
    private func resourceActions(for service: ServiceInfo, resource: ResourceConfig) -> some View {
        VStack(spacing: 10) {
            if ResourceBrowserSupport.canCreateTextFile(resource) {
                resourceActionButton(
                    systemImage: "square.and.pencil",
                    label: "Create file in \(resource.name)",
                    id: IOSAccessibility.id("browser", service.serviceId, resource.name, "new-file")
                ) {
                    presentedSheet = .newFile(
                        NewFileDraft(action: BrowserResourceAction(serviceID: service.serviceId, resourceName: resource.name))
                    )
                }
            }

            if ResourceBrowserSupport.canImportFile(resource) {
                Menu {
                    Button("Import File") {
                        pendingImporterAction = BrowserResourceAction(serviceID: service.serviceId, resourceName: resource.name)
                    }
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "import-file"))

                    Button("Choose Photo") {
                        presentedSheet = .photoImport(
                            PhotoImportRequest(
                                action: BrowserResourceAction(serviceID: service.serviceId, resourceName: resource.name),
                                sourceType: .photoLibrary
                            )
                        )
                    }
                    .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "choose-photo"))

                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo") {
                            presentedSheet = .photoImport(
                                PhotoImportRequest(
                                    action: BrowserResourceAction(serviceID: service.serviceId, resourceName: resource.name),
                                    sourceType: .camera
                                )
                            )
                        }
                        .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "take-photo"))
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel("Import into \(resource.name)")
                .accessibilityIdentifier(IOSAccessibility.id("browser", service.serviceId, resource.name, "import-menu"))
            }
        }
    }

    private func resourceActionButton(systemImage: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func fileGlyph(for url: URL) -> some View {
        Image(systemName: icon(for: url))
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(IOSTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fileDetailView(for fileURL: URL, service: ServiceInfo) -> some View {
        IOSFileDetailView(
            service: service,
            serviceDir: serviceDirectory(for: service),
            fileURL: fileURL,
            onOpenFile: { selectedFile = BrowserSelectedFile(url: $0) },
            onSave: { url in
                Task { await appState.markFileChanged(serviceID: service.serviceId, fileURL: url) }
            }
        )
    }

    private func serviceDirectory(for service: ServiceInfo) -> URL {
        appState.syncRootURL.appendingPathComponent(service.serviceId, isDirectory: true)
    }

    private func fileRow(for item: BrowserFileItem, service: ServiceInfo) -> some View {
        Button {
            selectFile(item.url)
        } label: {
            FileExplorerRow(
                fileURL: item.url,
                relativePath: item.relativePath,
                metadata: item.metadata,
                isSelected: selectedFile?.url == item.url
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            IOSAccessibility.id(
                "browser",
                service.serviceId,
                "file",
                item.relativePath
            )
        )
    }

    private func folderSection(_ folder: BrowserFolderGroup, service: ServiceInfo, depth: Int) -> AnyView {
        AnyView(
            DisclosureGroup(
            isExpanded: Binding(
                get: { expandedFolders.contains(folderExpansionID(for: folder, service: service)) },
                set: { isExpanded in
                    let id = folderExpansionID(for: folder, service: service)
                    if isExpanded {
                        expandedFolders.insert(id)
                    } else {
                        expandedFolders.remove(id)
                    }
                }
            )
        ) {
            VStack(spacing: 10) {
                ForEach(folder.files) { item in
                    fileRow(for: item, service: service)
                }

                ForEach(folder.folders) { child in
                    folderSection(child, service: service, depth: depth + 1)
                }
            }
            .padding(.top, 8)
        } label: {
            FolderExplorerRow(folder: folder, depth: depth)
                .accessibilityIdentifier(
                    IOSAccessibility.id("browser", service.serviceId, "folder", folder.relativePath)
                )
        }
        .tint(IOSTheme.accent)
        .padding(.leading, depth == 0 ? 0 : 8)
        )
    }

    private func folderExpansionID(for folder: BrowserFolderGroup, service: ServiceInfo) -> String {
        "\(service.serviceId):\(folder.relativePath)"
    }

    private func filesForResource(_ resource: ResourceConfig, service: ServiceInfo) -> [URL] {
        let directory = ResourceBrowserSupport.directoryURL(
            for: resource,
            serviceRoot: serviceDirectory(for: service)
        )
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func visibleServiceFiles(in service: ServiceInfo) -> [URL] {
        let root = serviceDirectory(for: service)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let relative = BrowserFileExplorerSupport.relativePath(for: url, in: root)
            if relative.hasPrefix(".api2file/") || relative.hasPrefix(".api2file-git/") || relative.hasPrefix(".git/") {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            if values?.isRegularFile == true {
                files.append(url)
            }
        }

        return files.sorted {
            BrowserFileExplorerSupport.relativePath(for: $0, in: root).localizedStandardCompare(
                BrowserFileExplorerSupport.relativePath(for: $1, in: root)
            ) == .orderedAscending
        }
    }

    private func firstVisibleFile(in service: ServiceInfo) -> URL? {
        let serviceFiles = visibleServiceFiles(in: service)
        if let firstNonGuideFile = serviceFiles.first(where: {
            !BrowserFileExplorerSupport.isGuideFile(
                path: BrowserFileExplorerSupport.relativePath(for: $0, in: serviceDirectory(for: service))
            )
        }) {
            return firstNonGuideFile
        }

        if let firstVisibleServiceFile = serviceFiles.first {
            return firstVisibleServiceFile
        }

        for resource in service.config.resources.sorted(by: ResourceBrowserSupport.sortResources) {
            if resource.fileMapping.strategy == .collection {
                let url = ResourceBrowserSupport.collectionURL(for: resource, serviceRoot: serviceDirectory(for: service))
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            } else if let first = filesForResource(resource, service: service).first {
                return first
            }
        }
        return nil
    }

    private func resource(for action: BrowserResourceAction) -> (ServiceInfo, ResourceConfig)? {
        guard let service = appState.services.first(where: { $0.serviceId == action.serviceID }),
              let resource = service.config.resources.first(where: { $0.name == action.resourceName }) else {
            return nil
        }
        return (service, resource)
    }

    private func selectFile(_ fileURL: URL, autoPresent: Bool = true) {
        let selection = BrowserSelectedFile(url: fileURL)
        selectedFile = selection
        if horizontalSizeClass == .compact {
            presentedFile = autoPresent ? selection : nil
        }
    }

    private func createTextFile(action: BrowserResourceAction, name: String, content: String) {
        guard let (service, resource) = resource(for: action) else { return }
        let directory = ResourceBrowserSupport.directoryURL(
            for: resource,
            serviceRoot: serviceDirectory(for: service)
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeName.isEmpty else { return }

        let ext = ResourceBrowserSupport.defaultExtension(for: resource.fileMapping.format)
        let filename = safeName.contains(".") ? safeName : "\(safeName).\(ext)"
        let fileURL = directory.appendingPathComponent(filename)
        try? Data(content.utf8).write(to: fileURL, options: .atomic)
        selectFile(fileURL)
        Task { await appState.markFileChanged(serviceID: service.serviceId, fileURL: fileURL) }
    }

    private func importFile(action: BrowserResourceAction, sourceURL: URL) {
        guard let (service, resource) = resource(for: action) else { return }
        let directory = ResourceBrowserSupport.directoryURL(
            for: resource,
            serviceRoot: serviceDirectory(for: service)
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destinationURL = ResourceBrowserSupport.uniqueDestinationURL(
            originalName: sourceURL.lastPathComponent,
            directory: directory
        )
        try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        selectFile(destinationURL)
        Task { await appState.markFileChanged(serviceID: service.serviceId, fileURL: destinationURL) }
    }

    private func saveImage(_ image: UIImage, for action: BrowserResourceAction) {
        guard let (service, resource) = resource(for: action) else { return }
        let directory = ResourceBrowserSupport.directoryURL(
            for: resource,
            serviceRoot: serviceDirectory(for: service)
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destinationURL = ResourceBrowserSupport.uniqueDestinationURL(
            originalName: "image-\(Int(Date().timeIntervalSince1970)).jpg",
            directory: directory
        )
        if let data = image.jpegData(compressionQuality: 0.92) {
            try? data.write(to: destinationURL, options: .atomic)
            selectFile(destinationURL)
            Task { await appState.markFileChanged(serviceID: service.serviceId, fileURL: destinationURL) }
        }
    }

    private func icon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "csv":
            return "tablecells"
        case "json":
            return "curlybraces"
        case "md", "markdown":
            return "text.document"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    private func previewExcerpt(for fileURL: URL) -> String? {
        let supportedExtensions = ["txt", "md", "markdown", "json", "csv", "yaml", "yml", "html", "log", "ics", "vcf", "eml"]
        guard supportedExtensions.contains(fileURL.pathExtension.lowercased()),
              let content = try? String(contentsOf: fileURL),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let clipped = content
            .components(separatedBy: .newlines)
            .prefix(8)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !clipped.isEmpty else { return nil }
        if clipped.count <= 320 {
            return clipped
        }
        return String(clipped.prefix(320)) + "…"
    }

    private func serviceBrowserSubtitle(_ service: ServiceInfo) -> String {
        switch service.status {
        case .connected:
            return "Open the synced files directly, then drop into resource-level actions only when you need them."
        case .syncing:
            return "Fresh data is flowing in right now. You can still inspect the current local files."
        case .paused:
            return "This service is paused locally. Existing files stay available for browsing."
        case .error:
            return service.errorMessage ?? "Sync needs attention before the browser can fully refresh."
        case .disconnected:
            return "Reconnect this service to pull down the latest files."
        }
    }
}

private struct FileExplorerRow: View {
    let fileURL: URL
    let relativePath: String
    let metadata: BrowserFileMetadata
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.headline.weight(.semibold))
                .foregroundStyle(IOSTheme.accent)
                .frame(width: 42, height: 42)
                .background(IOSTheme.accent.opacity(isSelected ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(fileURL.lastPathComponent)
                    .font(.headline)
                    .foregroundStyle(IOSTheme.textPrimary)
                    .lineLimit(1)

                Text(pathSummary)
                    .font(.caption)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .lineLimit(1)

                Text(metadata.detailDescription)
                    .font(.caption2)
                    .foregroundStyle(IOSTheme.textSecondary.opacity(0.92))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IOSTheme.textSecondary)
        }
        .padding(16)
        .background(
            isSelected ? IOSTheme.accent.opacity(0.08) : IOSTheme.cardBackground,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(IOSTheme.cardStroke, lineWidth: 1)
        }
    }

    private var pathSummary: String {
        let folder = (relativePath as NSString).deletingLastPathComponent
        let location = folder.isEmpty || folder == "." ? "Service root" : folder
        let ext = fileURL.pathExtension.uppercased().isEmpty ? "File" : fileURL.pathExtension.uppercased()
        return "\(ext) · \(location)"
    }

    private var iconName: String {
        switch fileURL.pathExtension.lowercased() {
        case "csv":
            return "tablecells"
        case "json":
            return "curlybraces"
        case "md", "markdown":
            return "text.document"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

private struct FolderExplorerRow: View {
    let folder: BrowserFolderGroup
    let depth: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(IOSTheme.accent)
                .frame(width: 42, height: 42)
                .background(IOSTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(folder.name)
                    .font(.headline)
                    .foregroundStyle(IOSTheme.textPrimary)
                    .lineLimit(1)

                Text(folderSummary)
                    .font(.caption)
                    .foregroundStyle(IOSTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.leading, CGFloat(depth) * 8)
        .padding(16)
        .background(IOSTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(IOSTheme.cardStroke, lineWidth: 1)
        }
    }

    private var folderSummary: String {
        var parts: [String] = []
        if folder.fileCount > 0 {
            parts.append("\(folder.fileCount) file\(folder.fileCount == 1 ? "" : "s")")
        }
        if folder.nestedFolderCount > 0 {
            parts.append("\(folder.nestedFolderCount) folder\(folder.nestedFolderCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NewFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var content: String

    let onCreate: (String, String) -> Void

    init(draft: NewFileDraft, onCreate: @escaping (String, String) -> Void) {
        _name = State(initialValue: draft.fileName)
        _content = State(initialValue: draft.content)
        self.onCreate = onCreate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    IOSHeroCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Create a new file")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Start with a clean file and push it through the same sync pipeline as every other resource.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.84))
                        }
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("File name")
                            .font(.headline)
                            .foregroundStyle(IOSTheme.textPrimary)

                        TextField("roadmap", text: $name)
                            .textInputAutocapitalization(.never)
                            .padding(14)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("new-file.name")

                        Text("Starting content")
                            .font(.headline)
                            .foregroundStyle(IOSTheme.textPrimary)

                        TextEditor(text: $content)
                            .frame(minHeight: 220)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("new-file.content")
                    }
                    .iosCardStyle()
                    .accessibilityIdentifier("new-file.form")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationTitle("New File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("new-file.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, content)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("new-file.create")
                }
            }
            .iosScreenBackground()
        }
    }
}
