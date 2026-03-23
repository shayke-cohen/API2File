import Foundation

/// ICS (iCalendar) format converter — calendar events as RFC 5545 iCalendar
public enum ICSFormat: FormatConverter {
    public static let format: FileFormat = .ics

    // Default field mapping: record key → iCal property
    private static let defaultMapping: [String: String] = [
        "title": "SUMMARY",
        "description": "DESCRIPTION",
        "startDate": "DTSTART",
        "endDate": "DTEND",
        "location": "LOCATION",
        "id": "UID",
        "status": "STATUS"
    ]

    // Status value mapping: record value → iCal STATUS value
    private static let statusMapping: [String: String] = [
        "confirmed": "CONFIRMED",
        "tentative": "TENTATIVE",
        "cancelled": "CANCELLED"
    ]

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard !records.isEmpty else {
            return Data()
        }

        let fieldMapping = mergedMapping(options: options)
        // Build the reverse: record field → iCal property
        // fieldMapping is already record-key → iCal-property

        var lines: [String] = []
        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//API2File//EN")

        for record in records {
            lines.append("BEGIN:VEVENT")

            for (recordKey, icalProp) in fieldMapping.sorted(by: { $0.value < $1.value }) {
                guard let value = record[recordKey] else { continue }
                let stringVal = stringValue(value)
                guard !stringVal.isEmpty else { continue }

                switch icalProp {
                case "DTSTART", "DTEND":
                    lines.append("\(icalProp):\(formatDateValue(stringVal))")
                case "STATUS":
                    let mapped = statusMapping[stringVal.lowercased()] ?? stringVal.uppercased()
                    lines.append("\(icalProp):\(mapped)")
                case "DESCRIPTION":
                    // Escape special characters in DESCRIPTION per RFC 5545
                    lines.append("\(icalProp):\(escapeICalText(stringVal))")
                default:
                    lines.append("\(icalProp):\(escapeICalText(stringVal))")
                }
            }

            lines.append("END:VEVENT")
        }

        lines.append("END:VCALENDAR")

        let ics = lines.joined(separator: "\r\n") + "\r\n"
        guard let data = ics.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode ICS as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("ICS is not valid UTF-8")
        }

        let fieldMapping = mergedMapping(options: options)
        // Build reverse mapping: iCal property → record key
        var reverseMapping: [String: String] = [:]
        for (recordKey, icalProp) in fieldMapping {
            reverseMapping[icalProp] = recordKey
        }

        // Normalize line endings
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Unfold lines: lines starting with a space or tab are continuations
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var unfoldedLines: [String] = []
        for line in rawLines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !unfoldedLines.isEmpty {
                // Continuation line — append to previous (strip leading whitespace char)
                unfoldedLines[unfoldedLines.count - 1] += String(line.dropFirst())
            } else {
                unfoldedLines.append(line)
            }
        }

        var records: [[String: Any]] = []
        var currentEvent: [String: Any]? = nil

        for line in unfoldedLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "BEGIN:VEVENT" {
                currentEvent = [:]
            } else if trimmed == "END:VEVENT" {
                if let event = currentEvent {
                    records.append(event)
                }
                currentEvent = nil
            } else if currentEvent != nil {
                // Parse property:value
                guard let colonIndex = findPropertyColon(in: trimmed) else { continue }
                let propPart = String(trimmed[trimmed.startIndex..<colonIndex])
                let valuePart = String(trimmed[trimmed.index(after: colonIndex)...])

                // Strip parameters (e.g., DTSTART;VALUE=DATE:20240101)
                let propName = propPart.split(separator: ";").first.map(String.init) ?? propPart

                if let recordKey = reverseMapping[propName] {
                    switch propName {
                    case "DTSTART", "DTEND":
                        currentEvent?[recordKey] = parseDateValue(valuePart)
                    case "STATUS":
                        // Reverse status mapping
                        let reverseStatus = statusMapping.first(where: { $0.value == valuePart })?.key ?? valuePart.lowercased()
                        currentEvent?[recordKey] = reverseStatus
                    default:
                        currentEvent?[recordKey] = unescapeICalText(valuePart)
                    }
                }
            }
        }

        return records
    }

    // MARK: - Helpers

    /// Merge user-provided fieldMapping with defaults.
    /// User fieldMapping overrides defaults: keys are record field names, values are iCal property names.
    /// If a custom entry maps to an iCal property already claimed by a default entry
    /// (with a different record key), the default entry is removed.
    private static func mergedMapping(options: FormatOptions?) -> [String: String] {
        var mapping = defaultMapping
        if let custom = options?.fieldMapping {
            // Collect the iCal property values that custom entries claim
            let customValues = Set(custom.values)
            // Remove default entries whose iCal property is being reassigned by a custom key
            for (defaultKey, defaultValue) in defaultMapping {
                if customValues.contains(defaultValue) && custom[defaultKey] == nil {
                    mapping.removeValue(forKey: defaultKey)
                }
            }
            for (key, value) in custom {
                mapping[key] = value
            }
        }
        return mapping
    }

    /// Format a date string to iCalendar format (YYYYMMDDTHHMMSSZ).
    /// Accepts ISO 8601 strings and passes through already-formatted iCal dates.
    private static func formatDateValue(_ value: String) -> String {
        // Already in iCal format
        if value.count == 16 && value.contains("T") && value.hasSuffix("Z") && !value.contains("-") {
            return value
        }

        // Try ISO 8601 parsing
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) {
            return icalDateString(from: date)
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return icalDateString(from: date)
        }

        // Try date-only format (YYYY-MM-DD)
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        if let date = dateOnly.date(from: value) {
            return icalDateString(from: date)
        }

        // Return as-is if we can't parse it
        return value
    }

    private static func icalDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Parse an iCal date string back to ISO 8601.
    private static func parseDateValue(_ value: String) -> String {
        // iCal format: YYYYMMDDTHHMMSSZ
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        if cleaned.count == 16, cleaned.contains("T") {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: cleaned) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                return iso.string(from: date)
            }
        }
        // Date-only: YYYYMMDD
        if cleaned.count == 8, cleaned.allSatisfy(\.isNumber) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            if let date = formatter.date(from: cleaned) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                return iso.string(from: date)
            }
        }
        return cleaned
    }

    /// Find the colon that separates property name from value.
    /// Must handle properties with parameters like DTSTART;VALUE=DATE:20240101
    private static func findPropertyColon(in line: String) -> String.Index? {
        // The first colon in the line is the separator (parameters use ; not :)
        return line.firstIndex(of: ":")
    }

    /// Escape text per RFC 5545 (backslash, semicolon, comma, newline).
    private static func escapeICalText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: ";", with: "\\;")
        result = result.replacingOccurrences(of: ",", with: "\\,")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    /// Unescape iCal text.
    private static func unescapeICalText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\;", with: ";")
        result = result.replacingOccurrences(of: "\\,", with: ",")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        return result
    }

    private static func stringValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let i as Int: return "\(i)"
        case let d as Double:
            if d == Double(Int(d)) { return "\(Int(d))" }
            return "\(d)"
        case let b as Bool: return b ? "true" : "false"
        default: return "\(value)"
        }
    }
}
