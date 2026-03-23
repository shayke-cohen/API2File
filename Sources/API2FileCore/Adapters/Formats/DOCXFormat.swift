import Foundation

/// DOCX format converter — generates/parses minimal Word documents (OOXML).
/// Opens natively in Pages and Word. Zero external dependencies.
public enum DOCXFormat: FormatConverter {
    public static let format: FileFormat = .docx

    // MARK: - Encode

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else {
            return try buildDocument(paragraphs: [])
        }

        let contentField = options?.fieldMapping?["content"] ?? "content"
        let text = (record[contentField] as? String) ?? ""

        // Split text into paragraphs by newlines
        let paragraphs = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }

        return try buildDocument(paragraphs: paragraphs)
    }

    // MARK: - Decode

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        let files = try ZIPHelper.extractZIP(data: data)

        guard let docData = files["word/document.xml"],
              let docXML = String(data: docData, encoding: .utf8) else {
            throw FormatError.decodingFailed("Missing word/document.xml in DOCX")
        }

        let contentField = options?.fieldMapping?["content"] ?? "content"
        let text = extractText(from: docXML)
        return [[contentField: text]]
    }

    // MARK: - Document Builder

    private static func buildDocument(paragraphs: [String]) throws -> Data {
        var paraXML = ""
        for para in paragraphs {
            if para.isEmpty {
                paraXML += "<w:p/>\n"
            } else {
                paraXML += "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(para))</w:t></w:r></w:p>\n"
            }
        }

        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <w:body>
            \(paraXML)</w:body>
            </w:document>
            """

        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
            </Types>
            """

        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """

        let docRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """

        let styles = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/>
            <w:rPr><w:sz w:val="24"/></w:rPr>
            </w:style>
            </w:styles>
            """

        return try ZIPHelper.createZIP(files: [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(rels.utf8),
            "word/document.xml": Data(documentXML.utf8),
            "word/_rels/document.xml.rels": Data(docRels.utf8),
            "word/styles.xml": Data(styles.utf8),
        ])
    }

    // MARK: - Text Extraction

    private static func extractText(from xml: String) -> String {
        // Extract text from <w:t>...</w:t> tags, preserving paragraph structure
        var paragraphs: [String] = []
        let nsXML = xml as NSString

        let paraPattern = "<w:p[^>]*>(.*?)</w:p>"
        guard let paraRegex = try? NSRegularExpression(pattern: paraPattern, options: .dotMatchesLineSeparators) else {
            return ""
        }

        let textPattern = "<w:t[^>]*>(.*?)</w:t>"
        guard let textRegex = try? NSRegularExpression(pattern: textPattern, options: .dotMatchesLineSeparators) else {
            return ""
        }

        let paraMatches = paraRegex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))

        for paraMatch in paraMatches {
            let paraContent = nsXML.substring(with: paraMatch.range(at: 1))
            let nsPara = paraContent as NSString
            let textMatches = textRegex.matches(in: paraContent, range: NSRange(location: 0, length: nsPara.length))

            var paraText = ""
            for textMatch in textMatches {
                paraText += xmlUnescape(nsPara.substring(with: textMatch.range(at: 1)))
            }
            paragraphs.append(paraText)
        }

        return paragraphs.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
