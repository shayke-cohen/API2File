import Foundation

/// YAML format converter — simple flat key-value YAML (no external dependency)
/// For nested structures, falls back to JSON-in-YAML
public enum YAMLFormat: FormatConverter {
    public static let format: FileFormat = .yaml

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        var output = ""
        let items = records.count == 1 ? records : records

        if items.count == 1, let record = items.first {
            output = encodeDict(record, indent: 0)
        } else {
            for record in items {
                output += "- "
                let dictYaml = encodeDict(record, indent: 1)
                // Remove the first indentation for the first key after "- "
                let lines = dictYaml.split(separator: "\n", omittingEmptySubsequences: false)
                for (i, line) in lines.enumerated() {
                    if i == 0 {
                        output += line.drop(while: { $0 == " " }) + "\n"
                    } else {
                        output += String(line) + "\n"
                    }
                }
            }
        }

        guard let data = output.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode YAML as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("YAML is not valid UTF-8")
        }
        // Simple flat YAML parser: key: value pairs
        var record: [String: Any] = [:]
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                record[key] = parseYAMLValue(value)
            }
        }
        return record.isEmpty ? [] : [record]
    }

    // MARK: - Helpers

    private static func encodeDict(_ dict: [String: Any], indent: Int) -> String {
        let prefix = String(repeating: "  ", count: indent)
        var output = ""
        for key in dict.keys.sorted() {
            let value = dict[key]!
            output += "\(prefix)\(key): \(yamlValue(value))\n"
        }
        return output
    }

    private static func yamlValue(_ value: Any) -> String {
        switch value {
        case let s as String:
            if s.contains("\n") || s.contains(":") || s.contains("#") {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return "\(i)"
        case let d as Double:
            if d == Double(Int(d)) { return "\(Int(d))" }
            return "\(d)"
        case is NSNull: return "null"
        default: return "\"\(value)\""
        }
    }

    private static func parseYAMLValue(_ value: String) -> Any {
        if value.isEmpty { return "" }
        if value == "true" { return true }
        if value == "false" { return false }
        if value == "null" || value == "~" { return NSNull() }
        if let i = Int(value) { return i }
        if let d = Double(value), value.contains(".") { return d }
        // Strip quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
