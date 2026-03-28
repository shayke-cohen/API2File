import Foundation
import Quartz
import API2FileCore
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let fileURL = request.fileURL

        if SyncedFilePreviewSupport.passthroughContentType(for: fileURL) != nil {
            let reply = QLPreviewReply(fileURL: fileURL)
            reply.title = fileURL.lastPathComponent
            return reply
        }

        let html = QuickLookPreviewRenderer.html(for: fileURL)
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 900, height: 680)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            return Data(html.utf8)
        }
        reply.title = fileURL.lastPathComponent
        return reply
    }
}

private enum QuickLookPreviewRenderer {
    static func html(for fileURL: URL) -> String {
        switch SyncedFilePreviewSupport.kind(for: fileURL) {
        case .csv:
            return page(title: fileURL.lastPathComponent, body: csvPreview(for: fileURL))
        case .markdown:
            return page(title: fileURL.lastPathComponent, body: markdownPreview(for: fileURL))
        case .json:
            return page(title: fileURL.lastPathComponent, body: textPreview(for: fileURL, prettyJSON: true))
        case .yaml, .text, .calendar, .contact, .email:
            return page(title: fileURL.lastPathComponent, body: textPreview(for: fileURL, prettyJSON: false))
        case .office, .archive, .binary:
            return page(title: fileURL.lastPathComponent, body: metadataPreview(for: fileURL))
        case .html, .image, .svg, .pdf, .audio, .movie:
            return page(title: fileURL.lastPathComponent, body: metadataPreview(for: fileURL))
        }
    }

    private static func csvPreview(for fileURL: URL) -> String {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return metadataPreview(for: fileURL)
        }

        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let headerLine = lines.first else {
            return "<p class=\"muted\">This CSV file is empty.</p>"
        }

        let headers = parseCSVLine(headerLine)
        let rows = lines.dropFirst().prefix(20).map(parseCSVLine)

        let headerHTML = headers.map { "<th>\(escapeHTML($0))</th>" }.joined()
        let rowsHTML = rows.map { row in
            let columns = headers.indices.map { index in
                "<td>\(escapeHTML(row[safe: index] ?? ""))</td>"
            }.joined()
            return "<tr>\(columns)</tr>"
        }.joined()

        return """
        <div class="section-header">
          <p class="eyebrow">CSV Preview</p>
          <h1>\(escapeHTML(fileURL.lastPathComponent))</h1>
        </div>
        <div class="table-wrap">
          <table>
            <thead><tr>\(headerHTML)</tr></thead>
            <tbody>\(rowsHTML)</tbody>
          </table>
        </div>
        """
    }

    private static func markdownPreview(for fileURL: URL) -> String {
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return metadataPreview(for: fileURL)
        }

        let escaped = escapeHTML(markdown)
        let body = escaped
            .components(separatedBy: "\n\n")
            .map { block -> String in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "" }

                let rendered = trimmed
                    .components(separatedBy: .newlines)
                    .map { line -> String in
                        if line.hasPrefix("### ") { return "<h3>\(String(line.dropFirst(4)))</h3>" }
                        if line.hasPrefix("## ") { return "<h2>\(String(line.dropFirst(3)))</h2>" }
                        if line.hasPrefix("# ") { return "<h1>\(String(line.dropFirst(2)))</h1>" }
                        if line.hasPrefix("- ") { return "• \(String(line.dropFirst(2)))" }
                        return line
                    }
                    .joined(separator: "<br>")
                    .replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
                    .replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
                    .replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)
                    .replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>", options: .regularExpression)

                if rendered.hasPrefix("<h") {
                    return rendered
                }
                return "<p>\(rendered)</p>"
            }
            .joined(separator: "\n")

        return """
        <div class="section-header">
          <p class="eyebrow">Markdown Preview</p>
          <h1>\(escapeHTML(fileURL.lastPathComponent))</h1>
        </div>
        \(body)
        """
    }

    private static func textPreview(for fileURL: URL, prettyJSON: Bool) -> String {
        guard let rawText = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return metadataPreview(for: fileURL)
        }

        let displayText: String
        if prettyJSON,
           let data = rawText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
           let formatted = String(data: pretty, encoding: .utf8) {
            displayText = formatted
        } else {
            displayText = rawText
        }

        return """
        <div class="section-header">
          <p class="eyebrow">Text Preview</p>
          <h1>\(escapeHTML(fileURL.lastPathComponent))</h1>
        </div>
        <pre>\(escapeHTML(String(displayText.prefix(8000))))</pre>
        """
    }

    private static func metadataPreview(for fileURL: URL) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeValue = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"

        return """
        <div class="section-header">
          <p class="eyebrow">File Preview</p>
          <h1>\(escapeHTML(fileURL.lastPathComponent))</h1>
          <p class="muted">Quick Look falls back to metadata for this file type in API2File.</p>
        </div>
        <dl class="meta-grid">
          <div><dt>Kind</dt><dd>\(escapeHTML(SyncedFilePreviewSupport.fileKindLabel(for: fileURL)))</dd></div>
          <div><dt>Extension</dt><dd>\(escapeHTML(fileURL.pathExtension.uppercased().isEmpty ? "None" : fileURL.pathExtension.uppercased()))</dd></div>
          <div><dt>Size</dt><dd>\(escapeHTML(formatter.string(fromByteCount: sizeValue)))</dd></div>
          <div><dt>Modified</dt><dd>\(escapeHTML(modified))</dd></div>
          <div class="wide"><dt>Path</dt><dd>\(escapeHTML(fileURL.path))</dd></div>
        </dl>
        """
    }

    private static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          background: linear-gradient(180deg, #f7f8fb 0%, #eef2f7 100%);
          color: #18212f;
          margin: 0;
          padding: 24px;
          line-height: 1.55;
        }
        .section-header {
          margin-bottom: 18px;
        }
        .eyebrow {
          margin: 0 0 6px;
          font-size: 12px;
          font-weight: 600;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: #667085;
        }
        h1, h2, h3 {
          margin: 0 0 12px;
          font-weight: 650;
        }
        p {
          margin: 0 0 12px;
        }
        .muted {
          color: #667085;
        }
        .table-wrap, pre, .meta-grid {
          background: rgba(255,255,255,0.86);
          border: 1px solid rgba(15, 23, 42, 0.08);
          border-radius: 18px;
          box-shadow: 0 14px 30px rgba(15, 23, 42, 0.06);
        }
        table {
          width: 100%;
          border-collapse: collapse;
          font-size: 13px;
        }
        th, td {
          padding: 10px 12px;
          border-bottom: 1px solid rgba(15, 23, 42, 0.08);
          text-align: left;
          vertical-align: top;
        }
        th {
          background: rgba(15, 23, 42, 0.04);
          font-size: 12px;
          letter-spacing: 0.04em;
          text-transform: uppercase;
          color: #667085;
        }
        pre {
          padding: 18px;
          overflow: auto;
          white-space: pre-wrap;
          word-break: break-word;
          font-family: Menlo, Monaco, monospace;
          font-size: 12px;
        }
        code {
          font-family: Menlo, Monaco, monospace;
          background: rgba(15, 23, 42, 0.06);
          padding: 2px 5px;
          border-radius: 6px;
        }
        a {
          color: #0a84ff;
          text-decoration: none;
        }
        .meta-grid {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: 0;
          overflow: hidden;
        }
        .meta-grid div {
          padding: 14px 16px;
          border-bottom: 1px solid rgba(15, 23, 42, 0.08);
        }
        .meta-grid div:nth-child(odd) {
          border-right: 1px solid rgba(15, 23, 42, 0.08);
        }
        .meta-grid .wide {
          grid-column: 1 / -1;
          border-right: none;
        }
        dt {
          margin: 0 0 4px;
          font-size: 12px;
          font-weight: 600;
          color: #667085;
          text-transform: uppercase;
        }
        dd {
          margin: 0;
          font-size: 13px;
          word-break: break-word;
        }
        @media (prefers-color-scheme: dark) {
          body {
            background: linear-gradient(180deg, #0f1720 0%, #111827 100%);
            color: #edf2f7;
          }
          .muted, .eyebrow, th, dt {
            color: #9aa4b2;
          }
          .table-wrap, pre, .meta-grid {
            background: rgba(17, 24, 39, 0.88);
            border-color: rgba(148, 163, 184, 0.18);
            box-shadow: none;
          }
          th, td, .meta-grid div {
            border-color: rgba(148, 163, 184, 0.14);
          }
          th {
            background: rgba(255,255,255,0.04);
          }
          code {
            background: rgba(255,255,255,0.08);
          }
        }
        </style>
        <title>\(escapeHTML(title))</title>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == "," && !inQuotes {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        values.append(current)
        return values
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
