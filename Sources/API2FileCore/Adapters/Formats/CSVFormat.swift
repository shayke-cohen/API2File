import Foundation

/// CSV format converter — tabular data as RFC 4180 CSV
/// First column is always `_id` (server record ID)
public enum CSVFormat: FormatConverter {
    public static let format: FileFormat = .csv

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard !records.isEmpty else {
            return Data()
        }

        // Collect all unique keys, with _id first
        var allKeys = Set<String>()
        for record in records {
            allKeys.formUnion(record.keys)
        }

        // Order: _id first (if present), then sorted alphabetically
        var orderedKeys: [String] = []
        if allKeys.contains("_id") {
            orderedKeys.append("_id")
            allKeys.remove("_id")
        } else if let idField = records.first?.keys.first(where: { $0.lowercased() == "id" }) {
            // Map "id" to "_id" in CSV
            orderedKeys.append("_id")
            allKeys.remove(idField)
        }
        orderedKeys.append(contentsOf: allKeys.sorted())

        var lines: [String] = []

        // Header row
        lines.append(orderedKeys.map { escapeCSV($0) }.joined(separator: ","))

        // Data rows
        for record in records {
            let values = orderedKeys.map { key -> String in
                let lookupKey = (key == "_id") ? (record["_id"] != nil ? "_id" : "id") : key
                guard let value = record[lookupKey] else { return "" }
                return escapeCSV(stringValue(value))
            }
            lines.append(values.joined(separator: ","))
        }

        let csv = lines.joined(separator: "\n") + "\n"
        guard let data = csv.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode CSV as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let csv = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("CSV is not valid UTF-8")
        }

        let lines = parseCSVLines(csv)
        guard lines.count >= 2 else {
            // Header only or empty
            return []
        }

        let headers = parseCSVRow(lines[0])
        var records: [[String: Any]] = []

        for i in 1..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let values = parseCSVRow(line)
            var record: [String: Any] = [:]

            for (index, header) in headers.enumerated() {
                let value = index < values.count ? values[index] : ""
                // Convert _id back to id for API compatibility
                let key = header == "_id" ? "id" : header
                record[key] = inferType(value)
            }

            records.append(record)
        }

        return records
    }

    // MARK: - CSV Helpers

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(n) {
                return n.boolValue ? "true" : "false"
            }
            if n.doubleValue == Double(n.intValue) {
                return "\(n.intValue)"
            }
            return "\(n.doubleValue)"
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return "\(i)"
        case let d as Double:
            if d == Double(Int(d)) { return "\(Int(d))" }
            return "\(d)"
        default: return "\(value)"
        }
    }

    private static func parseCSVLines(_ csv: String) -> [String] {
        // Handle CRLF and LF line endings
        let normalized = csv.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        var current = ""
        var inQuotes = false

        for char in normalized {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "\n" && !inQuotes {
                lines.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = row.startIndex

        while i < row.endIndex {
            let char = row[i]
            if char == "\"" {
                if inQuotes {
                    let next = row.index(after: i)
                    if next < row.endIndex && row[next] == "\"" {
                        // Escaped quote
                        current.append("\"")
                        i = row.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if char == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            i = row.index(after: i)
        }
        fields.append(current)
        return fields
    }

    private static func inferType(_ value: String) -> Any {
        if value.isEmpty { return value }
        if value == "true" { return true }
        if value == "false" { return false }
        if let intVal = Int(value) { return intVal }
        if let doubleVal = Double(value), value.contains(".") { return doubleVal }
        return value
    }
}
