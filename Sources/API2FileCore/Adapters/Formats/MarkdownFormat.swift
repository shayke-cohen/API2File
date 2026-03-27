import Foundation

/// Markdown format converter — stores records as Markdown files with optional YAML frontmatter.
///
/// When a record has more than just the content field, all other fields are written as YAML
/// frontmatter (---\nkey: value\n---) before the content body. On decode, frontmatter is
/// parsed back into the record alongside the body.
///
/// The body field is determined by `options.fieldMapping["content"]` (defaults to `"content"`).
public enum MarkdownFormat: FormatConverter {
    public static let format: FileFormat = .markdown

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let richContentField = options?.fieldMapping?["richContent"]

        // Separate body content from frontmatter fields
        var frontmatter = record
        let bodyValue = frontmatter.removeValue(forKey: contentField)
        let richContentValue = richContentField.flatMap { frontmatter.removeValue(forKey: $0) }
        let body = richContentValue.flatMap(markdownFromRichContent)
            ?? (bodyValue as? String)
            ?? ""

        var output = ""

        // Write YAML frontmatter if there are non-body fields
        if !frontmatter.isEmpty {
            output += "---\n"
            for key in frontmatter.keys.sorted() {
                if let value = frontmatter[key] {
                    output += "\(key): \(serializeYAMLScalar(value))\n"
                }
            }
            output += "---\n\n"
        }

        output += body

        guard let data = output.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode Markdown as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("Markdown is not valid UTF-8")
        }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let richContentField = options?.fieldMapping?["richContent"]

        var record: [String: Any] = [:]
        var body = text

        // Parse YAML frontmatter block (--- ... ---)
        if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
            let afterOpen = text.hasPrefix("---\r\n") ? String(text.dropFirst(5)) : String(text.dropFirst(4))
            // Find closing ---
            if let closeRange = afterOpen.range(of: "\n---\n") ?? afterOpen.range(of: "\n---\r\n") {
                let yamlText = String(afterOpen[..<closeRange.lowerBound])
                let rawBody = closeRange.upperBound < afterOpen.endIndex
                    ? String(afterOpen[closeRange.upperBound...])
                    : ""
                // Strip leading newline from body
                body = rawBody.hasPrefix("\n") ? String(rawBody.dropFirst()) : rawBody
                record = parseSimpleYAML(yamlText)
                _ = yamlText  // suppress unused warning
            }
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        record[contentField] = richContentField == nil ? trimmedBody : plainTextFromMarkdown(trimmedBody)
        if let richContentField {
            record[richContentField] = richContentFromMarkdown(trimmedBody)
        }
        return [record]
    }

    // MARK: - Rich Content Helpers

    private static func markdownFromRichContent(_ value: Any) -> String? {
        if let text = value as? String {
            return text
        }

        guard let richContent = value as? [String: Any],
              let nodes = richContent["nodes"] as? [[String: Any]]
        else {
            return nil
        }

        let blocks = nodes.map(renderRichContentNode)
        let joined = blocks.joined(separator: "\n\n")
        return normalizeMarkdownSpacing(joined)
    }

    private static func renderRichContentNode(_ node: [String: Any]) -> String {
        let type = (node["type"] as? String)?.uppercased() ?? ""

        switch type {
        case "PARAGRAPH":
            return renderInlineNodes(node["nodes"] as? [[String: Any]] ?? [])

        case "HEADING":
            let level = max(1, min(6, (node["headingData"] as? [String: Any])?["level"] as? Int ?? 1))
            let text = renderInlineNodes(node["nodes"] as? [[String: Any]] ?? [])
            return text.isEmpty ? "" : "\(String(repeating: "#", count: level)) \(text)"

        case "BULLETED_LIST":
            let items = (node["nodes"] as? [[String: Any]] ?? []).compactMap(renderListItem)
            return items.enumerated().map { _, item in "- \(item)" }.joined(separator: "\n")

        case "NUMBERED_LIST":
            let items = (node["nodes"] as? [[String: Any]] ?? []).compactMap(renderListItem)
            return items.enumerated().map { index, item in "\(index + 1). \(item)" }.joined(separator: "\n")

        case "BLOCKQUOTE":
            let text = normalizeMarkdownSpacing(renderChildBlocks(node["nodes"] as? [[String: Any]] ?? []))
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.isEmpty ? ">" : "> \(line)" }
                .joined(separator: "\n")

        case "DIVIDER":
            return "---"

        case "IMAGE":
            let imageData = node["imageData"] as? [String: Any]
            let altText = (imageData?["altText"] as? String)
                ?? captionText(from: node)
                ?? ""
            let source: String
            if let src = ((imageData?["image"] as? [String: Any])?["src"] as? [String: Any])?["id"] as? String {
                source = "wix:image:\(src)"
            } else {
                source = ""
            }
            return "![\(altText)](\(source))"

        default:
            let fallback = renderInlineNodes(node["nodes"] as? [[String: Any]] ?? [])
            if !fallback.isEmpty {
                return fallback
            }
            return normalizeMarkdownSpacing(renderChildBlocks(node["nodes"] as? [[String: Any]] ?? []))
        }
    }

    private static func renderListItem(_ node: [String: Any]) -> String? {
        let text = normalizeMarkdownSpacing(renderChildBlocks(node["nodes"] as? [[String: Any]] ?? []))
        return text.isEmpty ? nil : text
    }

    private static func renderChildBlocks(_ nodes: [[String: Any]]) -> String {
        nodes.map(renderRichContentNode).joined(separator: "\n\n")
    }

    private static func renderInlineNodes(_ nodes: [[String: Any]]) -> String {
        nodes.map { node in
            let type = (node["type"] as? String)?.uppercased() ?? ""
            switch type {
            case "TEXT":
                return (node["textData"] as? [String: Any])?["text"] as? String ?? ""
            default:
                return renderInlineNodes(node["nodes"] as? [[String: Any]] ?? [])
            }
        }.joined()
    }

    private static func captionText(from imageNode: [String: Any]) -> String? {
        let captions = imageNode["nodes"] as? [[String: Any]] ?? []
        let captionNodes = Array(
            captions
                .compactMap { $0["nodes"] as? [[String: Any]] }
                .joined()
        )
        let text = renderInlineNodes(captionNodes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func richContentFromMarkdown(_ markdown: String) -> [String: Any] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var nodes: [[String: Any]] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if isDivider(trimmed) {
                nodes.append(dividerNode())
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                nodes.append(headingNode(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let image = parseImage(line) {
                nodes.append(imageNode(altText: image.altText, source: image.source))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                nodes.append(blockquoteNode(text: quoteLines.joined(separator: "\n")))
                continue
            }

            if let listMarker = parseListMarker(line) {
                var items: [String] = [listMarker.text]
                index += 1
                while index < lines.count, let nextMarker = parseListMarker(lines[index]), nextMarker.ordered == listMarker.ordered {
                    items.append(nextMarker.text)
                    index += 1
                }
                nodes.append(listNode(ordered: listMarker.ordered, items: items))
                continue
            }

            var paragraphLines = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty ||
                    isDivider(candidateTrimmed) ||
                    parseHeading(candidate) != nil ||
                    parseImage(candidate) != nil ||
                    candidateTrimmed.hasPrefix(">") ||
                    parseListMarker(candidate) != nil {
                    break
                }
                paragraphLines.append(candidateTrimmed)
                index += 1
            }
            nodes.append(paragraphNode(text: paragraphLines.joined(separator: " ")))
        }

        return [
            "nodes": nodes,
            "documentStyle": [:],
        ]
    }

    private static func plainTextFromMarkdown(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var output: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if output.last != "" {
                    output.append("")
                }
                continue
            }

            if let heading = parseHeading(line) {
                output.append(heading.text)
                continue
            }

            if let image = parseImage(line) {
                output.append(image.altText)
                continue
            }

            if let listMarker = parseListMarker(line) {
                output.append(listMarker.text)
                continue
            }

            if trimmed.hasPrefix(">") {
                output.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            if isDivider(trimmed) {
                continue
            }

            output.append(trimmed)
        }

        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paragraphNode(text: String) -> [String: Any] {
        [
            "type": "PARAGRAPH",
            "id": UUID().uuidString,
            "nodes": text.isEmpty ? [] : [textNode(text)],
            "paragraphData": [:],
        ]
    }

    private static func headingNode(level: Int, text: String) -> [String: Any] {
        [
            "type": "HEADING",
            "id": UUID().uuidString,
            "nodes": text.isEmpty ? [] : [textNode(text)],
            "headingData": [
                "level": level,
                "textStyle": [
                    "textAlignment": "AUTO",
                ],
            ],
        ]
    }

    private static func blockquoteNode(text: String) -> [String: Any] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(paragraphNode)

        return [
            "type": "BLOCKQUOTE",
            "id": UUID().uuidString,
            "nodes": paragraphs,
        ]
    }

    private static func listNode(ordered: Bool, items: [String]) -> [String: Any] {
        let listItems = items.map { item in
            [
                "type": "LIST_ITEM",
                "id": UUID().uuidString,
                "nodes": [paragraphNode(text: item)],
            ]
        }

        return [
            "type": ordered ? "NUMBERED_LIST" : "BULLETED_LIST",
            "id": UUID().uuidString,
            "nodes": listItems,
        ]
    }

    private static func dividerNode() -> [String: Any] {
        [
            "type": "DIVIDER",
            "id": UUID().uuidString,
            "nodes": [],
        ]
    }

    private static func imageNode(altText: String, source: String) -> [String: Any] {
        let srcValue: [String: Any]
        if source.hasPrefix("wix:image:") {
            srcValue = ["id": String(source.dropFirst("wix:image:".count))]
        } else if source.isEmpty {
            srcValue = [:]
        } else {
            srcValue = ["url": source]
        }

        return [
            "type": "IMAGE",
            "id": UUID().uuidString,
            "nodes": [
                [
                    "type": "CAPTION",
                    "id": UUID().uuidString,
                    "nodes": altText.isEmpty ? [] : [textNode(altText)],
                ],
            ],
            "imageData": [
                "containerData": [
                    "width": ["size": "CONTENT"],
                    "alignment": "CENTER",
                    "height": ["custom": "100%"],
                    "textWrap": true,
                ],
                "image": [
                    "src": srcValue,
                ],
                "altText": altText,
                "caption": altText,
            ],
        ]
    }

    private static func textNode(_ text: String) -> [String: Any] {
        [
            "type": "TEXT",
            "id": "",
            "nodes": [],
            "textData": [
                "text": text,
                "decorations": [],
            ],
        ]
    }

    private static func normalizeMarkdownSpacing(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var normalized: [String] = []
        var previousBlank = false

        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                if !previousBlank {
                    normalized.append("")
                }
            } else {
                normalized.append(line)
            }
            previousBlank = isBlank
        }

        return normalized.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || trimmed == "***" || trimmed == "___"
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        let hashes = trimmed.prefix { $0 == "#" }
        let remainder = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (min(6, hashes.count), remainder)
    }

    private static func parseListMarker(_ line: String) -> (ordered: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        for marker in ["- ", "* "] where trimmed.hasPrefix(marker) {
            return (false, String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }

        var digits = ""
        var iterator = trimmed.makeIterator()
        while let char = iterator.next(), char.isNumber {
            digits.append(char)
        }

        if !digits.isEmpty,
           trimmed.dropFirst(digits.count).hasPrefix(". ") {
            let text = String(trimmed.dropFirst(digits.count + 2)).trimmingCharacters(in: .whitespaces)
            return (true, text)
        }

        return nil
    }

    private static func parseImage(_ line: String) -> (altText: String, source: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["),
              let altEnd = trimmed.firstIndex(of: "]"),
              trimmed[trimmed.index(after: altEnd)...].hasPrefix("("),
              let sourceEnd = trimmed.lastIndex(of: ")"),
              sourceEnd > altEnd
        else {
            return nil
        }

        let altText = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
        let sourceStart = trimmed.index(altEnd, offsetBy: 2)
        let source = String(trimmed[sourceStart..<sourceEnd])
        return (altText, source)
    }

    // MARK: - YAML Helpers

    /// Serialize a scalar value as a YAML-safe string.
    private static func serializeYAMLScalar(_ value: Any) -> String {
        switch value {
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return "\(i)"
        case let d as Double:
            return d == Double(Int(d)) ? "\(Int(d))" : "\(d)"
        case let s as String:
            // Quote strings that contain colons, hashes, leading/trailing spaces, or newlines
            if s.contains(":") || s.contains("#") || s.contains("\n") ||
               s.hasPrefix(" ") || s.hasSuffix(" ") || s.isEmpty ||
               s == "true" || s == "false" || s == "null" {
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"")
                                .replacingOccurrences(of: "\n", with: "\\n")
                return "\"\(escaped)\""
            }
            return s
        default:
            return "\(value)"
        }
    }

    /// Parse a simple YAML block (key: value lines only — no nesting, no arrays).
    private static func parseSimpleYAML(_ yaml: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for line in yaml.components(separatedBy: "\n") {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let rawValue = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            result[key] = parseYAMLScalar(rawValue)
        }
        return result
    }

    /// Parse a YAML scalar string to a typed Swift value.
    private static func parseYAMLScalar(_ str: String) -> Any {
        // Quoted string
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) ||
           (str.hasPrefix("'") && str.hasSuffix("'")) {
            let inner = String(str.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
        if str == "true" { return true }
        if str == "false" { return false }
        if str == "null" || str == "~" || str.isEmpty { return "" }
        if let i = Int(str) { return i }
        if let d = Double(str) { return d }
        return str
    }
}
