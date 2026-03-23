import Foundation

/// XLSX format converter — generates/parses minimal Excel spreadsheets (OOXML).
/// Opens natively in Numbers and Excel. Zero external dependencies.
public enum XLSXFormat: FormatConverter {
    public static let format: FileFormat = .xlsx

    // MARK: - Encode

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard !records.isEmpty else {
            return try buildEmptyWorkbook()
        }

        // Collect all unique keys for column headers
        var keySet: [String] = []
        var seen = Set<String>()
        for record in records {
            for key in record.keys.sorted() {
                if !seen.contains(key) {
                    seen.insert(key)
                    keySet.append(key)
                }
            }
        }

        // Build shared strings table
        var sharedStrings: [String] = []
        var stringIndex: [String: Int] = [:]

        func addSharedString(_ s: String) -> Int {
            if let idx = stringIndex[s] { return idx }
            let idx = sharedStrings.count
            sharedStrings.append(s)
            stringIndex[s] = idx
            return idx
        }

        // Header row strings
        for key in keySet { _ = addSharedString(key) }

        // Data cell strings
        for record in records {
            for key in keySet {
                if let value = record[key] {
                    let str = stringValue(value)
                    if !isNumeric(value) {
                        _ = addSharedString(str)
                    }
                }
            }
        }

        // Calculate column widths based on content length
        var colWidths: [Int: Int] = [:]  // col index -> max character count
        for (col, key) in keySet.enumerated() {
            colWidths[col] = key.count
        }
        for record in records {
            for (col, key) in keySet.enumerated() {
                if let value = record[key] {
                    let len = stringValue(value).count
                    colWidths[col] = max(colWidths[col] ?? 0, len)
                }
            }
        }

        // Build column width XML
        var colsXML = "<cols>"
        for (col, _) in keySet.enumerated() {
            let charWidth = colWidths[col] ?? 8
            // Excel column width is roughly characters + 2 for padding, minimum 8
            let width = max(Double(charWidth) + 2.0, 8.0)
            colsXML += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(width)\" bestFit=\"1\" customWidth=\"1\"/>"
        }
        colsXML += "</cols>"

        // Build sheet XML
        var sheetRows = ""
        // Header row — uses style index 1 (bold)
        sheetRows += "<row r=\"1\">"
        for (col, key) in keySet.enumerated() {
            let ref = cellRef(row: 1, col: col)
            let idx = stringIndex[key]!
            sheetRows += "<c r=\"\(ref)\" t=\"s\" s=\"1\"><v>\(idx)</v></c>"
        }
        sheetRows += "</row>\n"

        // Data rows
        for (rowIdx, record) in records.enumerated() {
            let rowNum = rowIdx + 2
            sheetRows += "<row r=\"\(rowNum)\">"
            for (col, key) in keySet.enumerated() {
                let ref = cellRef(row: rowNum, col: col)
                if let value = record[key] {
                    if isNumeric(value) {
                        // Numeric values: no t attribute (defaults to number type)
                        sheetRows += "<c r=\"\(ref)\"><v>\(stringValue(value))</v></c>"
                    } else {
                        let str = stringValue(value)
                        let idx = stringIndex[str]!
                        sheetRows += "<c r=\"\(ref)\" t=\"s\"><v>\(idx)</v></c>"
                    }
                }
            }
            sheetRows += "</row>\n"
        }

        let lastCol = cellColLetter(keySet.count - 1)
        let lastRow = records.count + 1
        let dimension = "A1:\(lastCol)\(lastRow)"

        let sheetXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <dimension ref="\(dimension)"/>
            \(colsXML)
            <sheetData>
            \(sheetRows)</sheetData>
            </worksheet>
            """

        // Shared strings XML
        var ssEntries = ""
        for s in sharedStrings {
            ssEntries += "<si><t>\(xmlEscape(s))</t></si>"
        }
        let sharedStringsXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="\(sharedStrings.count)" uniqueCount="\(sharedStrings.count)">
            \(ssEntries)
            </sst>
            """

        let files = buildOOXMLFiles(
            sheetXML: sheetXML,
            sharedStringsXML: sharedStringsXML
        )

        return try ZIPHelper.createZIP(files: files)
    }

    // MARK: - Decode

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        let files = try ZIPHelper.extractZIP(data: data)

        // Parse shared strings
        var sharedStrings: [String] = []
        if let ssData = files["xl/sharedStrings.xml"],
           let ssXML = String(data: ssData, encoding: .utf8) {
            sharedStrings = parseSharedStrings(ssXML)
        }

        // Parse sheet
        guard let sheetData = files["xl/worksheets/sheet1.xml"],
              let sheetXML = String(data: sheetData, encoding: .utf8) else {
            throw FormatError.decodingFailed("Missing sheet1.xml in XLSX")
        }

        let rows = parseSheetRows(sheetXML, sharedStrings: sharedStrings)
        guard rows.count >= 2 else { return [] }

        let headers = rows[0]
        var records: [[String: Any]] = []
        for i in 1..<rows.count {
            var record: [String: Any] = [:]
            for (j, header) in headers.enumerated() {
                if j < rows[i].count {
                    let val = rows[i][j]
                    record[header] = inferType(val)
                }
            }
            records.append(record)
        }
        return records
    }

    // MARK: - OOXML Structure

    private static func buildOOXMLFiles(sheetXML: String, sharedStringsXML: String) -> [String: Data] {
        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """

        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """

        let workbook = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """

        let workbookRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """

        // Styles with bold font for header row:
        // Font 0: Normal (Calibri 11)
        // Font 1: Bold (Calibri 11 bold)
        // cellXfs 0: default style (font 0)
        // cellXfs 1: bold header style (font 1)
        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2">
            <font><sz val="11"/><name val="Calibri"/></font>
            <font><b/><sz val="11"/><name val="Calibri"/></font>
            </fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border><left/><right/><top/><bottom/></border></borders>
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
            <cellXfs count="2">
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
            <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
            </cellXfs>
            </styleSheet>
            """

        return [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(rels.utf8),
            "xl/workbook.xml": Data(workbook.utf8),
            "xl/_rels/workbook.xml.rels": Data(workbookRels.utf8),
            "xl/worksheets/sheet1.xml": Data(sheetXML.utf8),
            "xl/sharedStrings.xml": Data(sharedStringsXML.utf8),
            "xl/styles.xml": Data(styles.utf8),
        ]
    }

    private static func buildEmptyWorkbook() throws -> Data {
        let sheetXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetData/>
            </worksheet>
            """
        let ssXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="0" uniqueCount="0"/>
            """
        return try ZIPHelper.createZIP(files: buildOOXMLFiles(sheetXML: sheetXML, sharedStringsXML: ssXML))
    }

    // MARK: - Helpers

    private static func cellRef(row: Int, col: Int) -> String {
        "\(cellColLetter(col))\(row)"
    }

    private static func cellColLetter(_ col: Int) -> String {
        var result = ""
        var c = col
        repeat {
            result = String(UnicodeScalar(65 + (c % 26))!) + result
            c = c / 26 - 1
        } while c >= 0
        return result
    }

    private static func isNumeric(_ value: Any) -> Bool {
        value is Int || value is Double || value is Float
    }

    private static func stringValue(_ value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let i = value as? Int { return "\(i)" }
        if let d = value as? Double {
            if d == Double(Int(d)) { return "\(Int(d))" }
            return "\(d)"
        }
        return "\(value)"
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inferType(_ s: String) -> Any {
        if s == "true" { return true }
        if s == "false" { return false }
        if let i = Int(s) { return i }
        if let d = Double(s), s.contains(".") { return d }
        return s
    }

    // MARK: - XML Parsing

    private static func parseSharedStrings(_ xml: String) -> [String] {
        var strings: [String] = []
        // Simple regex-based extraction: <t>...</t> or <t ...>...</t>
        let pattern = "<t[^>]*>(.*?)</t>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return strings
        }
        let nsXML = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))
        for match in matches {
            if match.numberOfRanges >= 2 {
                let value = nsXML.substring(with: match.range(at: 1))
                strings.append(xmlUnescape(value))
            }
        }
        return strings
    }

    private static func parseSheetRows(_ xml: String, sharedStrings: [String]) -> [[String]] {
        var rows: [[String]] = []
        let nsXML = xml as NSString

        // Extract each <row>...</row>
        let rowPattern = "<row[^>]*>(.*?)</row>"
        guard let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: .dotMatchesLineSeparators) else {
            return rows
        }
        let rowMatches = rowRegex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))

        // Cell pattern: <c ...><v>...</v></c>
        let cellPattern = "<c\\s([^>]*)><v>(.*?)</v></c>"
        guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: .dotMatchesLineSeparators) else {
            return rows
        }

        for rowMatch in rowMatches {
            let rowContent = nsXML.substring(with: rowMatch.range(at: 1))
            let nsRow = rowContent as NSString
            let cellMatches = cellRegex.matches(in: rowContent, range: NSRange(location: 0, length: nsRow.length))

            var cells: [String] = []
            for cellMatch in cellMatches {
                let attrsRange = cellMatch.range(at: 1)
                let valueRange = cellMatch.range(at: 2)
                let attrs = nsRow.substring(with: attrsRange)
                let value = nsRow.substring(with: valueRange)

                // Check if t="s" attribute is present
                let isSharedString = attrs.contains("t=\"s\"")

                if isSharedString, let idx = Int(value), idx < sharedStrings.count {
                    cells.append(sharedStrings[idx])
                } else {
                    cells.append(value)
                }
            }
            rows.append(cells)
        }
        return rows
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
