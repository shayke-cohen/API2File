import Foundation

/// EML (email message) format converter — RFC 2822 email messages
public enum EMLFormat: FormatConverter {
    public static let format: FileFormat = .eml

    // Default header field names used in records
    private static let defaultFields = (
        from: "from",
        to: "to",
        subject: "subject",
        date: "date",
        body: "body"
    )

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }

        let fm = options?.fieldMapping
        let fromField = fm?["from"] ?? defaultFields.from
        let toField = fm?["to"] ?? defaultFields.to
        let subjectField = fm?["subject"] ?? defaultFields.subject
        let dateField = fm?["date"] ?? defaultFields.date
        let bodyField = fm?["body"] ?? defaultFields.body

        var lines: [String] = []

        if let from = record[fromField] as? String, !from.isEmpty {
            lines.append("From: \(from)")
        }
        if let to = record[toField] as? String, !to.isEmpty {
            lines.append("To: \(to)")
        }
        if let subject = record[subjectField] as? String, !subject.isEmpty {
            lines.append("Subject: \(subject)")
        }
        if let date = record[dateField] as? String, !date.isEmpty {
            lines.append("Date: \(date)")
        }
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("") // blank line separates headers from body

        let body = (record[bodyField] as? String) ?? ""
        lines.append(body)

        let eml = lines.joined(separator: "\r\n")
        guard let data = eml.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode EML as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("EML is not valid UTF-8")
        }

        let fm = options?.fieldMapping
        let fromField = fm?["from"] ?? defaultFields.from
        let toField = fm?["to"] ?? defaultFields.to
        let subjectField = fm?["subject"] ?? defaultFields.subject
        let dateField = fm?["date"] ?? defaultFields.date
        let bodyField = fm?["body"] ?? defaultFields.body

        // Normalize line endings
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Split headers from body at the first blank line
        var headerSection = ""
        var bodySection = ""

        if let blankLineRange = normalized.range(of: "\n\n") {
            headerSection = String(normalized[normalized.startIndex..<blankLineRange.lowerBound])
            bodySection = String(normalized[blankLineRange.upperBound...])
        } else {
            // No blank line — treat everything as headers
            headerSection = normalized
        }

        // Parse headers (handle folded headers: continuation lines start with whitespace)
        let headerLines = headerSection.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var unfoldedHeaders: [String] = []
        for line in headerLines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")) && !unfoldedHeaders.isEmpty {
                unfoldedHeaders[unfoldedHeaders.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfoldedHeaders.append(line)
            }
        }

        var record: [String: Any] = [:]

        // Map header name (lowercased) to record field
        let headerToField: [String: String] = [
            "from": fromField,
            "to": toField,
            "subject": subjectField,
            "date": dateField
        ]

        for header in unfoldedHeaders {
            guard let colonIndex = header.firstIndex(of: ":") else { continue }
            let name = header[header.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = header[header.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

            if let field = headerToField[name] {
                record[field] = value
            }
        }

        record[bodyField] = bodySection

        return [record]
    }
}
