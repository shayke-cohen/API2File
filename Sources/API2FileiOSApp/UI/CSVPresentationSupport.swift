import Foundation

struct CSVPresentationField: Equatable, Hashable {
    let title: String
    let value: String
}

struct CSVPresentationRow: Equatable, Hashable {
    let id: String
    let title: String?
    let fields: [CSVPresentationField]
}

struct CSVPresentationModel: Equatable, Hashable {
    let rows: [CSVPresentationRow]
    let visibleColumnCount: Int
    let hiddenColumnCount: Int
    let totalRowCount: Int
}

enum CSVPresentationSupport {
    private static let hiddenColumnNames: Set<String> = [
        "id", "_id", "remoteid", "boardid", "groupid", "siteid", "revision",
        "etag", "slug", "url", "_url", "href", "link", "createdat", "updatedat",
        "created_at", "updated_at", "ownerid", "accountid", "itemid", "cursor"
    ]

    private static let preferredTitleColumns = [
        "name", "title", "subject", "label", "displayname", "full name", "fullname"
    ]

    static func makeModel(from text: String) -> CSVPresentationModel {
        let rows = parseRows(from: text)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            return CSVPresentationModel(rows: [], visibleColumnCount: 0, hiddenColumnCount: 0, totalRowCount: 0)
        }

        let dataRows = rows.dropFirst().filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        guard !dataRows.isEmpty else {
            return CSVPresentationModel(rows: [], visibleColumnCount: 0, hiddenColumnCount: headerRow.count, totalRowCount: 0)
        }

        let normalizedHeaders = normalizedHeaders(from: headerRow)
        let visibleIndices = visibleColumnIndices(headers: normalizedHeaders, dataRows: Array(dataRows))
        let titleIndex = preferredTitleIndex(headers: normalizedHeaders, visibleIndices: visibleIndices)

        let presentationRows = Array(dataRows.enumerated()).map { offset, row in
            let rowTitle: String?
            if let index = titleIndex, index < row.count {
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                rowTitle = value.isEmpty ? nil : value
            } else {
                rowTitle = nil
            }

            let fields = visibleIndices.compactMap { index -> CSVPresentationField? in
                guard index < normalizedHeaders.count, index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                guard index != titleIndex else { return nil }
                return CSVPresentationField(title: normalizedHeaders[index], value: value)
            }

            return CSVPresentationRow(
                id: "\(offset)-\(rowTitle ?? "row")",
                title: rowTitle,
                fields: fields
            )
        }

        return CSVPresentationModel(
            rows: presentationRows,
            visibleColumnCount: visibleIndices.count,
            hiddenColumnCount: max(normalizedHeaders.count - visibleIndices.count, 0),
            totalRowCount: presentationRows.count
        )
    }

    static func parseRows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var iterator = text.makeIterator()
        var inQuotes = false

        while let char = iterator.next() {
            switch char {
            case "\"":
                if inQuotes {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            process(next, into: &rows, row: &row, field: &field, inQuotes: &inQuotes)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            default:
                process(char, into: &rows, row: &row, field: &field, inQuotes: &inQuotes)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows
    }

    private static func process(
        _ char: Character,
        into rows: inout [[String]],
        row: inout [String],
        field: inout String,
        inQuotes: inout Bool
    ) {
        if inQuotes {
            field.append(char)
            return
        }

        switch char {
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(char)
        }
    }

    private static func normalizedHeaders(from row: [String]) -> [String] {
        row.enumerated().map { index, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Column \(index + 1)"
            }
            return trimmed
        }
    }

    private static func visibleColumnIndices(headers: [String], dataRows: [[String]]) -> [Int] {
        let indices = headers.indices.filter { index in
            let header = headers[index]
            let values = dataRows.compactMap { index < $0.count ? $0[index] : nil }
            return shouldShowColumn(header: header, values: values)
        }
        return indices.isEmpty ? Array(headers.indices) : indices
    }

    private static func preferredTitleIndex(headers: [String], visibleIndices: [Int]) -> Int? {
        for preferred in preferredTitleColumns {
            if let match = visibleIndices.first(where: {
                normalizedHeaderKey(headers[$0]) == preferred
            }) {
                return match
            }
        }
        return visibleIndices.first
    }

    private static func shouldShowColumn(header: String, values: [String]) -> Bool {
        let normalizedKey = normalizedHeaderKey(header)
        let trimmedValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmptyValues = trimmedValues.filter { !$0.isEmpty }

        if nonEmptyValues.isEmpty {
            return false
        }

        if header.hasPrefix("_") || hiddenColumnNames.contains(normalizedKey) {
            return false
        }

        let structuredRatio = Double(nonEmptyValues.filter(isStructuredPayload).count) / Double(nonEmptyValues.count)
        if structuredRatio >= 0.6 {
            return false
        }

        let opaqueRatio = Double(nonEmptyValues.filter(isOpaqueValue).count) / Double(nonEmptyValues.count)
        if opaqueRatio >= 0.8, !preferredTitleColumns.contains(normalizedKey) {
            return false
        }

        return true
    }

    private static func normalizedHeaderKey(_ header: String) -> String {
        header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func isOpaqueValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return false
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return true
        }
        if trimmed.count >= 24 && !trimmed.contains(" ") {
            return true
        }
        if trimmed.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func isStructuredPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return false
        }

        if trimmed.contains(#""id""#) || trimmed.contains(#""title""#) || trimmed.contains(#""items""#) {
            return true
        }

        if trimmed.contains("},{") || trimmed.contains("\":") || trimmed.contains("}]") {
            return true
        }

        return trimmed.count > 80
    }
}
