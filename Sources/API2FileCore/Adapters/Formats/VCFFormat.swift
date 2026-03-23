import Foundation

/// VCF (vCard) format converter — contacts as RFC 6350 vCard
public enum VCFFormat: FormatConverter {
    public static let format: FileFormat = .vcf

    // Default field mapping: record key → vCard property
    private static let defaultMapping: [String: String] = [
        "firstName": "FN_FIRST",
        "lastName": "FN_LAST",
        "email": "EMAIL",
        "phone": "TEL",
        "company": "ORG",
        "jobTitle": "TITLE",
        "notes": "NOTE"
    ]

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard !records.isEmpty else {
            return Data()
        }

        let fieldMapping = mergedMapping(options: options)
        var vcards: [String] = []

        for record in records {
            var lines: [String] = []
            lines.append("BEGIN:VCARD")
            lines.append("VERSION:3.0")

            // Resolve first name and last name fields from mapping
            let firstNameKey = fieldMapping.first(where: { $0.value == "FN_FIRST" })?.key ?? "firstName"
            let lastNameKey = fieldMapping.first(where: { $0.value == "FN_LAST" })?.key ?? "lastName"

            let firstName = stringValue(record[firstNameKey])
            let lastName = stringValue(record[lastNameKey])

            // FN (formatted name) — required in vCard
            let fullName: String
            if !firstName.isEmpty && !lastName.isEmpty {
                fullName = "\(firstName) \(lastName)"
            } else if !firstName.isEmpty {
                fullName = firstName
            } else if !lastName.isEmpty {
                fullName = lastName
            } else {
                fullName = ""
            }
            if !fullName.isEmpty {
                lines.append("FN:\(escapeVCardText(fullName))")
                lines.append("N:\(escapeVCardText(lastName));\(escapeVCardText(firstName));;;")
            }

            // Other properties
            for (recordKey, vcardProp) in fieldMapping.sorted(by: { $0.value < $1.value }) {
                // Skip name fields — already handled above
                if vcardProp == "FN_FIRST" || vcardProp == "FN_LAST" { continue }

                guard let value = record[recordKey] else { continue }
                let stringVal = stringValue(value)
                guard !stringVal.isEmpty else { continue }

                lines.append("\(vcardProp):\(escapeVCardText(stringVal))")
            }

            lines.append("END:VCARD")
            vcards.append(lines.joined(separator: "\r\n"))
        }

        let vcf = vcards.joined(separator: "\r\n") + "\r\n"
        guard let data = vcf.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode VCF as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("VCF is not valid UTF-8")
        }

        let fieldMapping = mergedMapping(options: options)
        // Build reverse mapping: vCard property → record key
        var reverseMapping: [String: String] = [:]
        for (recordKey, vcardProp) in fieldMapping {
            reverseMapping[vcardProp] = recordKey
        }

        // Resolve name field keys
        let firstNameKey = reverseMapping["FN_FIRST"] ?? "firstName"
        let lastNameKey = reverseMapping["FN_LAST"] ?? "lastName"

        // Normalize line endings
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Unfold lines: lines starting with a space or tab are continuations
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var unfoldedLines: [String] = []
        for line in rawLines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !unfoldedLines.isEmpty {
                unfoldedLines[unfoldedLines.count - 1] += String(line.dropFirst())
            } else {
                unfoldedLines.append(line)
            }
        }

        var records: [[String: Any]] = []
        var currentCard: [String: Any]? = nil

        for line in unfoldedLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased() == "BEGIN:VCARD" {
                currentCard = [:]
            } else if trimmed.uppercased() == "END:VCARD" {
                if let card = currentCard {
                    records.append(card)
                }
                currentCard = nil
            } else if currentCard != nil {
                guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
                let propPart = String(trimmed[trimmed.startIndex..<colonIndex])
                let valuePart = String(trimmed[trimmed.index(after: colonIndex)...])

                // Strip parameters (e.g., TEL;TYPE=WORK:...)
                let propName = propPart.split(separator: ";").first.map(String.init) ?? propPart

                switch propName.uppercased() {
                case "N":
                    // N:LastName;FirstName;;;
                    let components = valuePart.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                    if components.count >= 2 {
                        currentCard?[lastNameKey] = unescapeVCardText(components[0])
                        currentCard?[firstNameKey] = unescapeVCardText(components[1])
                    } else if components.count == 1 {
                        currentCard?[lastNameKey] = unescapeVCardText(components[0])
                    }
                case "FN":
                    // FN is the formatted name — we extract names from N instead
                    // Only use FN if N wasn't present (we'll check at the end)
                    // Store it temporarily
                    currentCard?["_fn"] = unescapeVCardText(valuePart)
                default:
                    if let recordKey = reverseMapping[propName.uppercased()] {
                        currentCard?[recordKey] = unescapeVCardText(valuePart)
                    }
                }
            }
        }

        // Post-process: if firstName/lastName not set but FN is available, derive from FN
        records = records.map { record in
            var record = record
            if record[firstNameKey] == nil && record[lastNameKey] == nil, let fn = record["_fn"] as? String {
                let parts = fn.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count >= 2 {
                    record[firstNameKey] = parts[0]
                    record[lastNameKey] = parts[1]
                } else if parts.count == 1 {
                    record[firstNameKey] = parts[0]
                }
            }
            record.removeValue(forKey: "_fn")
            return record
        }

        return records
    }

    // MARK: - Helpers

    /// Merge user-provided fieldMapping with defaults.
    /// If a custom entry maps to a vCard property already claimed by a default entry
    /// (with a different record key), the default entry is removed.
    private static func mergedMapping(options: FormatOptions?) -> [String: String] {
        guard let custom = options?.fieldMapping, !custom.isEmpty else {
            return defaultMapping
        }
        // When custom mapping is provided, it completely replaces the default.
        // This avoids conflicts between default keys and custom keys mapping to the same vCard properties.
        return custom
    }

    /// Escape text per vCard spec.
    private static func escapeVCardText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: ";", with: "\\;")
        result = result.replacingOccurrences(of: ",", with: "\\,")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "")
        return result
    }

    /// Unescape vCard text.
    private static func unescapeVCardText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\N", with: "\n")
        result = result.replacingOccurrences(of: "\\;", with: ";")
        result = result.replacingOccurrences(of: "\\,", with: ",")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        return result
    }

    private static func stringValue(_ value: Any?) -> String {
        guard let value = value else { return "" }
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
