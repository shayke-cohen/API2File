import SwiftUI
import UIKit
import WebKit
import QuickLook
import API2FileCore

private enum FileViewMode: String, CaseIterable {
    case edit = "Edit"
    case preview = "Preview"
}

struct IOSFileDetailView: View {
    let service: ServiceInfo
    let serviceDir: URL
    let fileURL: URL
    let onOpenFile: (URL) -> Void
    let onSave: (URL) -> Void

    @State private var text = ""
    @State private var isDirty = false
    @State private var viewMode: FileViewMode = .preview
    @State private var diffText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard

                if isTextEditable, supportsPreviewToggle {
                    Picker("", selection: $viewMode) {
                        ForEach(FileViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("file-detail.mode-picker")
                }

                contentCard

                if let diffText, !diffText.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        IOSSectionTitle("Local changes", detail: "Quick diff against the last tracked version.")

                        ScrollView {
                            Text(diffText)
                                .font(.caption.monospaced())
                                .foregroundStyle(IOSTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 100, maxHeight: 220)
                    }
                    .iosCardStyle()
                    .accessibilityIdentifier("file-detail.diff")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 36)
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let externalDestination {
                    Button(externalDestination.title) {
                        UIApplication.shared.open(externalDestination.url)
                    }
                    .accessibilityIdentifier("file-detail.external-link")
                }
                if let objectURL = canonicalObjectFileURL {
                    Button("Object") {
                        onOpenFile(objectURL)
                    }
                    .accessibilityIdentifier("file-detail.object")
                }
                ShareLink(item: fileURL)
                    .accessibilityLabel("Share file")
                    .accessibilityIdentifier("file-detail.share")
                Button("Files") {
                    UIApplication.shared.open(fileURL)
                }
                .accessibilityLabel("Open in Files")
                .accessibilityIdentifier("file-detail.open-in-files")
                if isTextEditable {
                    Button("Save") {
                        save()
                    }
                    .disabled(!isDirty)
                    .accessibilityIdentifier("file-detail.save")
                }
            }
        }
        .task(id: fileURL) {
            loadFile()
            await loadDiff()
        }
        .accessibilityIdentifier(IOSScreenID.fileDetail)
        .iosScreenBackground()
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: previewIconName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(IOSTheme.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(fileURL.lastPathComponent)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(IOSTheme.textPrimary)

                    Text(service.displayName)
                        .font(.subheadline)
                        .foregroundStyle(IOSTheme.textSecondary)
                }

                Spacer(minLength: 12)

                if isDirty {
                    IOSStatusPill(title: "Unsaved", tint: IOSTheme.warning)
                } else {
                    IOSSecondaryPill("Synced view", systemImage: "checkmark.circle")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    IOSSecondaryPill(fileTypeLabel, systemImage: "doc.text")
                    IOSSecondaryPill(relativePathLabel, systemImage: "folder")
                    if let objectURL = canonicalObjectFileURL {
                        IOSSecondaryPill(objectURL.lastPathComponent, systemImage: "cube.transparent")
                    }
                }
            }
        }
        .iosCardStyle()
        .accessibilityIdentifier("file-detail.header")
    }

    @ViewBuilder
    private var contentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isTextEditable {
                IOSSectionTitle(
                    viewMode == .edit || !supportsPreviewToggle ? "Editor" : "Preview",
                    detail: supportsPreviewToggle ? "Switch between editing and rendered output." : "Edit the local file directly."
                )
            }

            if isTextEditable && (viewMode == .edit || !supportsPreviewToggle) {
                editorBody
            } else {
                previewBody
            }
        }
        .iosCardStyle()
        .accessibilityIdentifier("file-detail.container")
    }

    private var isTextEditable: Bool {
        switch fileURL.pathExtension.lowercased() {
        case "csv", "md", "markdown", "json", "txt", "yaml", "yml", "html", "htm", "ics", "vcf", "eml", "log", "swift", "js", "ts", "sql", "xml":
            return true
        default:
            return false
        }
    }

    private var supportsPreviewToggle: Bool {
        switch fileURL.pathExtension.lowercased() {
        case "md", "markdown", "html", "htm":
            return true
        default:
            return false
        }
    }

    private var previewIconName: String {
        switch fileURL.pathExtension.lowercased() {
        case "csv":
            return "tablecells"
        case "json":
            return "curlybraces"
        case "md", "markdown":
            return "text.document"
        case "png", "jpg", "jpeg", "gif", "bmp", "webp":
            return "photo"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    private var fileTypeLabel: String {
        let ext = fileURL.pathExtension.lowercased()
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }

    private var relativePathLabel: String {
        fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
    }

    @ViewBuilder
    private var editorBody: some View {
        if fileURL.pathExtension.lowercased() == "csv" {
            CSVEditor(text: $text, isDirty: $isDirty)
        } else {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 360)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("file-detail.editor")
                .onChange(of: text) { _, _ in
                    isDirty = true
                }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        switch previewContent {
        case .csv(let model):
            CSVRepeaterPreview(model: model)
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .foregroundStyle(IOSTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320, alignment: .top)
        case .markdown(let html):
            HTMLPreview(html: html)
                .frame(minHeight: 360)
        case .html(let html):
            HTMLPreview(html: html)
                .frame(minHeight: 360)
        case .image(let image):
            GeometryReader { proxy in
                ScrollView {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width)
                }
            }
            .frame(minHeight: 360)
        case .quickLook:
            QuickLookPreview(url: fileURL)
                .frame(minHeight: 420)
        }
    }

    private enum PreviewContent {
        case csv(CSVPresentationModel)
        case text(String)
        case markdown(String)
        case html(String)
        case image(UIImage)
        case quickLook
    }

    private var previewContent: PreviewContent {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "bmp", "webp":
            if let image = UIImage(contentsOfFile: fileURL.path) {
                return .image(image)
            }
            return .quickLook
        case "md", "markdown":
            return .markdown(renderMarkdownHTML(text))
        case "html", "htm":
            return .html(text)
        case "csv":
            return .csv(CSVPresentationSupport.makeModel(from: text))
        case "pdf", "docx", "xlsx", "pptx", "raw":
            return .quickLook
        default:
            if isTextEditable || String(contentsIfReadableAt: fileURL) != nil {
                return .text(text)
            }
            return .quickLook
        }
    }

    private var canonicalObjectFileURL: URL? {
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        guard let resource = owningResource(for: fileURL),
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

    private var externalDestination: (title: String, url: URL)? {
        let resource = ResourceBrowserSupport.resource(for: fileURL, in: service.config.resources, serviceRoot: serviceDir)

        if let dashboardURL = resource?.dashboardUrl ?? service.config.dashboardUrl,
           let url = URL(string: dashboardURL) {
            return ("Dashboard", url)
        }

        if let siteURL = resource?.siteUrl ?? service.config.siteUrl,
           let url = URL(string: siteURL) {
            return ("Website", url)
        }

        return nil
    }

    private func owningResource(for fileURL: URL) -> ResourceConfig? {
        let filePath = fileURL.path
        for resource in service.config.resources {
            let directory = resource.fileMapping.directory
            let baseDir = (directory == "." || directory.isEmpty)
                ? serviceDir
                : serviceDir.appendingPathComponent(directory)
            if resource.fileMapping.strategy == .collection {
                if let filename = resource.fileMapping.filename,
                   baseDir.appendingPathComponent(filename).path == filePath {
                    return resource
                }
            } else if filePath.hasPrefix(baseDir.path) {
                return resource
            }
        }
        return nil
    }

    private func loadFile() {
        text = String(contentsIfReadableAt: fileURL) ?? ""
        isDirty = false
        viewMode = supportsPreviewToggle ? .preview : .edit
    }

    private func save() {
        try? Data(text.utf8).write(to: fileURL, options: .atomic)
        isDirty = false
        onSave(fileURL)
        Task { await loadDiff() }
    }

    private func loadDiff() async {
        let git = GitManager(repoPath: serviceDir)
        let relativePath = fileURL.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
        diffText = try? await git.diffForFile(relativePath)
    }
}

private struct CSVEditor: View {
    @Binding var text: String
    @Binding var isDirty: Bool

    var body: some View {
        let model = CSVPresentationSupport.makeModel(from: text)

        VStack(spacing: 14) {
            HStack {
                IOSSectionTitle("CSV editor", detail: "Edit raw content and keep a live human-friendly preview.")
                Spacer()
                Button("Add Row") {
                    let headers = CSVPresentationSupport.parseRows(from: text).first ?? []
                    let newRow = Array(repeating: "", count: max(headers.count, 1)).joined(separator: ",")
                    text = text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + newRow
                    isDirty = true
                }
                .buttonStyle(IOSOutlineButtonStyle())
                .frame(maxWidth: 132)
                .accessibilityIdentifier("file-detail.csv.add-row")
            }

            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 240)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityIdentifier("file-detail.csv.editor")
                .onChange(of: text) { _, _ in
                    isDirty = true
                }

            if model.totalRowCount > 0 {
                CSVRepeaterPreview(model: model)
                    .frame(maxHeight: 360)
                .accessibilityIdentifier("file-detail.csv.preview")
            }
        }
    }
}

private struct CSVRepeaterPreview: View {
    let model: CSVPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                IOSSecondaryPill("\(model.totalRowCount) row\(model.totalRowCount == 1 ? "" : "s")", systemImage: "list.bullet.rectangle")
                IOSSecondaryPill("\(model.visibleColumnCount) visible column\(model.visibleColumnCount == 1 ? "" : "s")", systemImage: "rectangle.split.3x1")
                if model.hiddenColumnCount > 0 {
                    IOSSecondaryPill("\(model.hiddenColumnCount) hidden metadata", systemImage: "eye.slash")
                }
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { offset, row in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.title ?? "Row \(offset + 1)")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(IOSTheme.textPrimary)
                                    .lineLimit(2)

                                Spacer(minLength: 8)

                                IOSSecondaryPill("Row \(offset + 1)", systemImage: "number")
                            }

                            if row.fields.isEmpty {
                                Text("No human-facing fields in this row.")
                                    .font(.subheadline)
                                    .foregroundStyle(IOSTheme.textSecondary)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(Array(row.fields.enumerated()), id: \.offset) { _, field in
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(field.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(IOSTheme.textSecondary)
                                                .frame(width: 110, alignment: .leading)

                                            Text(field.value)
                                                .font(.subheadline)
                                                .foregroundStyle(IOSTheme.textPrimary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .padding(12)
                                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .background(IOSTheme.cardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(IOSTheme.cardStroke, lineWidth: 1)
                        }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 420, alignment: .top)
        }
    }
}

private struct HTMLPreview: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }
    }
}

private func renderMarkdownHTML(_ markdown: String) -> String {
    func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    var html = escape(markdown)
    html = html.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)
    html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)

    let lines = html.components(separatedBy: "\n")
    html = lines.map { line in
        if line.hasPrefix("### ") { return "<h3>\(line.dropFirst(4))</h3>" }
        if line.hasPrefix("## ") { return "<h2>\(line.dropFirst(3))</h2>" }
        if line.hasPrefix("# ") { return "<h1>\(line.dropFirst(2))</h1>" }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return "<li>\(line.dropFirst(2))</li>" }
        if line.isEmpty { return "<br>" }
        return "<p>\(line)</p>"
    }.joined(separator: "\n")

    html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
    html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
    html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)

    return """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { font-family: -apple-system, sans-serif; padding: 16px; line-height: 1.55; color: #f8fafc; background: transparent; }
        p, li, h1, h2, h3 { color: #f8fafc; }
        code, pre { font-family: ui-monospace, Menlo, monospace; background: rgba(255,255,255,0.08); border-radius: 8px; color: #f8fafc; }
        code { padding: 2px 4px; }
        pre { padding: 12px; overflow-x: auto; }
        a { color: #5ac8fa; }
      </style>
    </head>
    <body>\(html)</body>
    </html>
    """
}

private extension String {
    init?(contentsIfReadableAt url: URL) {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        self = value
    }
}
