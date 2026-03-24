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

        // Separate body content from frontmatter fields
        var frontmatter = record
        let bodyValue = frontmatter.removeValue(forKey: contentField)
        let body = bodyValue as? String ?? ""

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

        var record: [String: Any] = [:]
        var body = text

        // Parse YAML frontmatter block (--- ... ---)
        if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
            let afterOpen = text.hasPrefix("---\r\n") ? String(text.dropFirst(5)) : String(text.dropFirst(4))
            // Find closing ---
            if let closeRange = afterOpen.range(of: "\n---\n") ?? afterOpen.range(of: "\n---\r\n") {
                let yamlText = String(afterOpen[..<closeRange.lowerBound])
                let bodyStart = afterOpen.index(after: closeRange.upperBound == afterOpen.endIndex ? closeRange.lowerBound : closeRange.upperBound)
                let rawBody = closeRange.upperBound < afterOpen.endIndex
                    ? String(afterOpen[closeRange.upperBound...])
                    : ""
                // Strip leading newline from body
                body = rawBody.hasPrefix("\n") ? String(rawBody.dropFirst()) : rawBody
                record = parseSimpleYAML(yamlText)
                _ = yamlText  // suppress unused warning
            }
        }

        record[contentField] = body
        return [record]
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
