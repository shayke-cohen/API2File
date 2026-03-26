import SwiftUI
import WebKit
import AppKit
import API2FileCore

// MARK: - Window Launcher

enum FileEditorWindow {
    private static var windows: [String: NSWindow] = [:]

    @MainActor
    static func open(fileURL: URL, serviceDir: URL? = nil) {
        let key = fileURL.path

        if let window = windows[key], window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Auto-detect service dir by walking up to find .git
        let svcDir = serviceDir ?? detectServiceDir(for: fileURL)
        let view = FileEditorView(fileURL: fileURL, serviceDir: svcDir)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = fileURL.lastPathComponent
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 860, height: 560))
        window.minSize = NSSize(width: 500, height: 300)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        windows[key] = window
    }

    private static func detectServiceDir(for fileURL: URL) -> URL? {
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

// MARK: - File Type

private enum FileType {
    case csv
    case markdown
    case json
    case text

    init(ext: String) {
        switch ext.lowercased() {
        case "csv": self = .csv
        case "md", "markdown": self = .markdown
        case "json": self = .json
        default: self = .text
        }
    }

    var label: String {
        switch self {
        case .csv: return "CSV"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .text: return "Text"
        }
    }
}

// MARK: - View Mode

private enum ViewMode: String, CaseIterable {
    case edit = "Edit"
    case table = "Table"
    case preview = "Preview"
    case diff = "Diff"
}

// MARK: - File Editor View

private struct FileEditorView: View {
    let fileURL: URL
    let serviceDir: URL?
    @StateObject private var watcher: FileWatcherHelper
    @StateObject private var undoer = EditorUndoManager()
    @State private var text = ""
    @State private var isDirty = false
    @State private var lastLoadedContent = ""
    @State private var viewMode: ViewMode
    @State private var wordCount = 0
    @State private var lineCount = 0
    @State private var diffText: String?

    private let fileType: FileType

    init(fileURL: URL, serviceDir: URL?) {
        self.fileURL = fileURL
        self.serviceDir = serviceDir
        self.fileType = FileType(ext: fileURL.pathExtension)
        _watcher = StateObject(wrappedValue: FileWatcherHelper(fileURL: fileURL))
        // Default mode based on file type
        switch FileType(ext: fileURL.pathExtension) {
        case .csv: _viewMode = State(initialValue: .table)
        case .markdown: _viewMode = State(initialValue: .preview)
        default: _viewMode = State(initialValue: .edit)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
            Divider()
            statusBar
        }
        .onAppear { loadFile(); Task { await loadDiff() } }
        .onChange(of: watcher.lastModified) { _ in
            if !isDirty { loadFile() }
            Task { await loadDiff() }
        }
        .onChange(of: text) { newValue in
            let lines = newValue.components(separatedBy: .newlines)
            lineCount = lines.count
            wordCount = newValue.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Mode picker
            Picker("", selection: $viewMode) {
                Text("Edit").tag(ViewMode.edit)
                if fileType == .csv {
                    Text("Table").tag(ViewMode.table)
                }
                if fileType == .markdown {
                    Text("Preview").tag(ViewMode.preview)
                }
                if diffText != nil {
                    Text("Diff").tag(ViewMode.diff)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: segmentWidth)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button { performUndo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .controlSize(.small)
            .disabled(!undoer.canUndo)
            .help("Undo (⌘Z)")
            .keyboardShortcut("z", modifiers: .command)

            Button { performRedo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .controlSize(.small)
            .disabled(!undoer.canRedo)
            .help("Redo (⇧⌘Z)")
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button {
                loadFile(force: true)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Reload from disk (discards unsaved changes)")

            Button {
                formatContent()
            } label: {
                Label("Format", systemImage: "text.alignleft")
            }
            .controlSize(.small)
            .help("Auto-format content")
            .disabled(fileType == .text)

            Button {
                saveFile()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var segmentWidth: CGFloat {
        let hasDiff = diffText != nil
        switch fileType {
        case .csv, .markdown: return hasDiff ? 230 : 160
        case .json, .text: return hasDiff ? 140 : 70
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        switch viewMode {
        case .edit:
            RawTextEditor(text: $text, isDirty: $isDirty)
        case .table:
            CSVTableEditor(text: $text, isDirty: $isDirty, undoer: undoer)
        case .preview:
            HSplitView {
                RawTextEditor(text: $text, isDirty: $isDirty)
                    .frame(minWidth: 250)
                MarkdownPreview(markdown: text)
                    .frame(minWidth: 250)
            }
        case .diff:
            if let diff = diffText {
                GitDiffPanel(diff: diff)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.green)
                    Text("No changes").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text(fileType.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            Text("\(lineCount) lines, \(wordCount) words")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isDirty {
                Circle().fill(.orange).frame(width: 6, height: 6)
            } else {
                Circle().fill(.green).frame(width: 6, height: 6)
            }
            Text(isDirty ? "Modified" : "Saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - Actions

    private func loadFile(force: Bool = false) {
        guard let content = watcher.readContent() else { return }
        if !force && content == lastLoadedContent { return }
        lastLoadedContent = content
        text = content
        isDirty = false
        if force { undoer.clear() }
    }

    private func performUndo() {
        if viewMode == .edit || viewMode == .preview {
            // NSTextView has its own undo; send Cmd+Z to the responder chain
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        } else {
            undoer.undo()
        }
    }

    private func performRedo() {
        if viewMode == .edit || viewMode == .preview {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        } else {
            undoer.redo()
        }
    }

    private func saveFile() {
        try? watcher.writeContent(text)
        lastLoadedContent = text
        isDirty = false
        Task { await loadDiff() }
    }

    private func loadDiff() async {
        guard let svcDir = serviceDir else { diffText = nil; return }
        let git = GitManager(repoPath: svcDir)
        let relativePath = fileURL.path.replacingOccurrences(of: svcDir.path + "/", with: "")
        let diff = try? await git.diffForFile(relativePath)
        diffText = (diff?.isEmpty == false) ? diff : nil
    }

    private func formatContent() {
        switch fileType {
        case .json:
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let formatted = String(data: pretty, encoding: .utf8) {
                text = formatted
                isDirty = true
            }
        case .csv:
            // Normalize CSV — trim whitespace from fields
            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let formatted = lines.map { line in
                parseCSVLine(line).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
            }.joined(separator: "\n") + "\n"
            text = formatted
            isDirty = true
        default:
            break
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for char in line {
            if char == "\"" { inQuotes.toggle() }
            else if char == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(char) }
        }
        fields.append(current)
        return fields
    }
}

// MARK: - Raw Text Editor (NSTextView)

private struct RawTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isDirty: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.delegate = context.coordinator
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text && !context.coordinator.isEditing {
            let ranges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = ranges
        }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RawTextEditor
        var isEditing = false

        init(_ parent: RawTextEditor) { self.parent = parent }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }
        func textDidEndEditing(_ notification: Notification) { isEditing = false }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.isDirty = true
        }
    }
}

// MARK: - CSV Table Editor

private struct CSVTableEditor: View {
    @Binding var text: String
    @Binding var isDirty: Bool
    @ObservedObject var undoer: EditorUndoManager

    @State private var headers: [String] = []
    @State private var rows: [[String]] = []
    @State private var editingCell: CellID?
    @State private var editText = ""
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var searchText = ""
    @State private var isSyncing = false
    @State private var selectedRow: Int?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("Filter rows...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("\(rows.count) rows")
                    .font(.caption).foregroundStyle(.tertiary)

                Button { insertRow(at: (selectedRow ?? rows.count - 1) + 1) } label: {
                    Label("Insert Below", systemImage: "plus")
                }.controlSize(.small)

                Button { deleteSelectedRow() } label: {
                    Label("Delete Row", systemImage: "minus")
                }
                .controlSize(.small)
                .disabled(selectedRow == nil)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if headers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Empty CSV").foregroundStyle(.secondary)
                    Button("Add Header Row") {
                        headers = ["column1", "column2", "column3"]
                        syncToText()
                    }.controlSize(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableContent
            }
        }
        .onAppear { parseFromText() }
        .onChange(of: text) { _ in
            if !isSyncing { parseFromText() }
        }
    }

    // MARK: - Table Content

    private var tableContent: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                dataRows
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .center)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))

            ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, header in
                Button {
                    if sortColumn == colIdx { sortAscending.toggle() }
                    else { sortColumn = colIdx; sortAscending = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(header).fontWeight(.semibold).lineLimit(1)
                        if sortColumn == colIdx {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                    }
                    .font(.caption2)
                    .frame(width: colWidth(colIdx), alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.secondary.opacity(0.08))
            }

            // Spacer for action column
            Color.clear.frame(width: 50, height: 1)
                .background(Color.secondary.opacity(0.08))
        }
    }

    private var dataRows: some View {
        ForEach(Array(filteredRows.enumerated()), id: \.offset) { displayIdx, entry in
            dataRow(displayIdx: displayIdx, rowIdx: entry.0, row: entry.1)
        }
    }

    private func dataRow(displayIdx: Int, rowIdx: Int, row: [String]) -> some View {
        let isSelected = selectedRow == rowIdx
        let bgColor: Color = isSelected
            ? Color.accentColor.opacity(0.08)
            : (displayIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.03))

        return HStack(spacing: 0) {
            rowNumberCell(rowIdx: rowIdx, isSelected: isSelected)
            ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, _ in
                cellView(rowIdx: rowIdx, colIdx: colIdx, row: row)
            }
            rowActions(rowIdx: rowIdx)
        }
        .background(bgColor)
    }

    private func rowNumberCell(rowIdx: Int, isSelected: Bool) -> some View {
        Text("\(rowIdx + 1)")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .fontWeight(isSelected ? .bold : .regular)
            .frame(width: 40, alignment: .center)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { selectedRow = (selectedRow == rowIdx) ? nil : rowIdx }
    }

    private func rowActions(rowIdx: Int) -> some View {
        HStack(spacing: 2) {
            Button { insertRow(at: rowIdx + 1) } label: {
                Image(systemName: "plus").font(.system(size: 8))
                    .foregroundStyle(Color.green.opacity(0.6))
            }.buttonStyle(.plain).help("Insert row below")

            Button { deleteRow(at: rowIdx) } label: {
                Image(systemName: "minus").font(.system(size: 8))
                    .foregroundStyle(Color.red.opacity(0.6))
            }.buttonStyle(.plain).help("Delete this row")
        }
        .frame(width: 50)
    }

    // MARK: - Cell View

    @ViewBuilder
    private func cellView(rowIdx: Int, colIdx: Int, row: [String]) -> some View {
        let cellId = CellID(row: rowIdx, col: colIdx)
        let val = colIdx < row.count ? row[colIdx] : ""

        if editingCell == cellId {
            CSVCellTextField(
                text: $editText,
                onCommit: { commitEdit(cellId) },
                onTab: { moveToNextCell(from: cellId) },
                onEscape: { cancelEdit() }
            )
            .frame(width: colWidth(colIdx))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, lineWidth: 1)
            )
        } else {
            Text(val.isEmpty ? " " : val)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .frame(width: colWidth(colIdx), alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    finishCurrentEdit()
                    selectedRow = rowIdx
                    editingCell = cellId
                    editText = val
                }
        }
    }

    // MARK: - Filtered + Sorted Rows

    private var filteredRows: [(Int, [String])] {
        var indexed = rows.enumerated().map { ($0.offset, $0.element) }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            indexed = indexed.filter { $0.1.contains { $0.lowercased().contains(q) } }
        }
        if let col = sortColumn {
            indexed.sort { a, b in
                let av = col < a.1.count ? a.1[col] : ""
                let bv = col < b.1.count ? b.1[col] : ""
                return sortAscending
                    ? av.localizedStandardCompare(bv) == .orderedAscending
                    : av.localizedStandardCompare(bv) == .orderedDescending
            }
        }
        return indexed
    }

    // MARK: - Parsing

    private func parseFromText() {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let first = lines.first else { headers = []; rows = []; return }
        let newHeaders = csvParse(first)
        let newRows = lines.dropFirst().map { csvParse($0) }
        if newHeaders != headers { headers = newHeaders }
        if newRows != rows { rows = newRows }
    }

    private func syncToText() {
        let oldText = text
        isSyncing = true
        var lines = [csvEncode(headers)]
        for row in rows { lines.append(csvEncode(row)) }
        let newText = lines.joined(separator: "\n") + "\n"
        text = newText
        isDirty = true
        undoer.recordChange(old: oldText, new: newText) { [self] restored in
            self.text = restored
            self.isDirty = true
        }
        DispatchQueue.main.async { isSyncing = false }
    }

    // MARK: - Edit Actions

    private func finishCurrentEdit() {
        if let cell = editingCell {
            commitEdit(cell)
        }
    }

    private func commitEdit(_ cellId: CellID) {
        guard cellId.row < rows.count else { editingCell = nil; return }
        while rows[cellId.row].count <= cellId.col { rows[cellId.row].append("") }
        if rows[cellId.row][cellId.col] != editText {
            rows[cellId.row][cellId.col] = editText
            syncToText()
        }
        editingCell = nil
    }

    private func cancelEdit() {
        editingCell = nil
    }

    private func moveToNextCell(from cellId: CellID) {
        commitEdit(cellId)
        let nextCol = cellId.col + 1
        if nextCol < headers.count {
            let next = CellID(row: cellId.row, col: nextCol)
            editingCell = next
            editText = (cellId.row < rows.count && nextCol < rows[cellId.row].count) ? rows[cellId.row][nextCol] : ""
        } else if cellId.row + 1 < rows.count {
            let next = CellID(row: cellId.row + 1, col: 0)
            editingCell = next
            editText = rows[cellId.row + 1].first ?? ""
        }
    }

    // MARK: - Row Actions

    private func insertRow(at index: Int) {
        finishCurrentEdit()
        let emptyRow = Array(repeating: "", count: headers.count)
        let clampedIndex = min(index, rows.count)
        rows.insert(emptyRow, at: clampedIndex)
        selectedRow = clampedIndex
        syncToText()
        // Auto-edit first cell of new row
        editingCell = CellID(row: clampedIndex, col: 0)
        editText = ""
    }

    private func deleteRow(at index: Int) {
        finishCurrentEdit()
        guard index < rows.count else { return }
        rows.remove(at: index)
        if selectedRow == index { selectedRow = nil }
        syncToText()
    }

    private func deleteSelectedRow() {
        guard let row = selectedRow else { return }
        deleteRow(at: row)
    }

    // MARK: - Helpers

    private func colWidth(_ idx: Int) -> CGFloat {
        let hLen = idx < headers.count ? headers[idx].count : 5
        let maxData = rows.prefix(30).reduce(hLen) { m, r in
            idx < r.count ? max(m, r[idx].count) : m
        }
        return max(70, min(CGFloat(maxData) * 7.5 + 20, 260))
    }

    private func csvParse(_ line: String) -> [String] {
        var fields: [String] = []; var cur = ""; var q = false
        for c in line {
            if c == "\"" { q.toggle() }
            else if c == "," && !q { fields.append(cur); cur = "" }
            else { cur.append(c) }
        }
        fields.append(cur); return fields
    }

    private func csvEncode(_ fields: [String]) -> String {
        fields.map { f in
            (f.contains(",") || f.contains("\"") || f.contains("\n"))
                ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : f
        }.joined(separator: ",")
    }
}

private struct CellID: Equatable, Hashable { let row: Int; let col: Int }

// MARK: - CSV Cell TextField (NSTextField wrapper for Tab/Escape handling)

// MARK: - Editor Undo Manager

@MainActor
private final class EditorUndoManager: ObservableObject {
    @Published var canUndo = false
    @Published var canRedo = false

    private struct UndoEntry {
        let oldText: String
        let newText: String
        let restore: (String) -> Void
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private let maxHistory = 100

    func recordChange(old: String, new: String, restore: @escaping (String) -> Void) {
        guard old != new else { return }
        undoStack.append(UndoEntry(oldText: old, newText: new, restore: restore))
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(entry)
        entry.restore(entry.oldText)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(entry)
        entry.restore(entry.newText)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
    }
}

private struct CSVCellTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onTab: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tf.isBordered = false
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.stringValue = text
        tf.delegate = context.coordinator
        // Auto-focus
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if tf.stringValue != text && !context.coordinator.isEditing {
            tf.stringValue = text
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CSVCellTextField
        var isEditing = false

        init(_ parent: CSVCellTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }
        func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.text = (control as? NSTextField)?.stringValue ?? parent.text
                parent.onTab()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}

// MARK: - Markdown Preview

private struct MarkdownPreview: View {
    let markdown: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Preview", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))
            Divider()
            MarkdownWebView(markdown: markdown)
        }
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero)
        wv.loadHTMLString(renderHTML(markdown), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(renderHTML(markdown), baseURL: nil)
    }

    private func renderHTML(_ md: String) -> String {
        var html = escapeHTML(md)

        // Code blocks
        html = html.replacingOccurrences(of: "```([\\s\\S]*?)```", with: "<pre><code>$1</code></pre>", options: .regularExpression)
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)

        // Process line by line
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

        // Inline formatting
        html = html.replacingOccurrences(of: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        html = html.replacingOccurrences(of: "~~(.+?)~~", with: "<del>$1</del>", options: .regularExpression)
        html = html.replacingOccurrences(of: "<p>---</p>", with: "<hr>")

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        body { font-family: -apple-system, sans-serif; font-size: 14px; line-height: 1.6;
               color: #e0e0e0; background: #1e1e1e; padding: 16px; margin: 0; }
        @media (prefers-color-scheme: light) {
            body { color: #333; background: #fff; }
            code { background: #f0f0f0; } pre { background: #f5f5f5; }
            blockquote { border-color: #ddd; color: #666; } hr { border-color: #ddd; }
        }
        h1 { font-size: 1.6em; margin: 0.8em 0 0.4em; }
        h2 { font-size: 1.3em; margin: 0.8em 0 0.4em; }
        h3 { font-size: 1.1em; margin: 0.6em 0 0.3em; }
        p { margin: 0.4em 0; }
        code { font-family: 'SF Mono', Menlo, monospace; font-size: 0.9em;
               background: #2d2d2d; padding: 1px 4px; border-radius: 3px; }
        pre { background: #2d2d2d; padding: 12px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid #555; margin: 0.5em 0; padding: 0.2em 12px; color: #aaa; }
        li { margin: 0.2em 0; margin-left: 20px; }
        a { color: #58a6ff; } hr { border: none; border-top: 1px solid #444; margin: 1em 0; }
        del { color: #888; } strong { font-weight: 600; }
        </style></head><body>\(html)</body></html>
        """
    }

    private func escapeHTML(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Git Diff Panel

private struct GitDiffPanel: View {
    let diff: String

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack(spacing: 12) {
                Label("Changes", systemImage: "plus.forwardslash.minus")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("+\(addedCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                }
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("-\(removedCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Diff content
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parsedLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            // Line number gutter
                            Text(line.lineNum)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 50, alignment: .trailing)
                                .padding(.trailing, 6)
                                .background(line.background.opacity(0.5))

                            // Content
                            Text(line.text)
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(line.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(line.background)
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 2)
            }
        }
    }

    private var addedCount: Int {
        diff.components(separatedBy: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
    }

    private var removedCount: Int {
        diff.components(separatedBy: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    }

    private struct DiffLine {
        let text: String
        let lineNum: String
        let color: Color
        let background: Color
    }

    private var parsedLines: [DiffLine] {
        var result: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                // Parse hunk header: @@ -a,b +c,d @@
                if let range = line.range(of: "\\+([0-9]+)", options: .regularExpression) {
                    newLine = (Int(line[range].dropFirst()) ?? 1) - 1
                }
                if let range = line.range(of: "-([0-9]+)", options: .regularExpression) {
                    oldLine = (Int(line[range].dropFirst()) ?? 1) - 1
                }
                result.append(DiffLine(text: line, lineNum: "...", color: .cyan, background: Color.cyan.opacity(0.06)))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                newLine += 1
                result.append(DiffLine(text: line, lineNum: "\(newLine)", color: Color(nsColor: .systemGreen), background: Color.green.opacity(0.1)))
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                oldLine += 1
                result.append(DiffLine(text: line, lineNum: "\(oldLine)", color: Color(nsColor: .systemRed), background: Color.red.opacity(0.1)))
            } else if line.hasPrefix("diff") || line.hasPrefix("index") || line.hasPrefix("---") || line.hasPrefix("+++") {
                result.append(DiffLine(text: line, lineNum: "", color: .secondary, background: .clear))
            } else {
                oldLine += 1; newLine += 1
                result.append(DiffLine(text: line, lineNum: "\(newLine)", color: .primary, background: .clear))
            }
        }
        return result
    }
}
