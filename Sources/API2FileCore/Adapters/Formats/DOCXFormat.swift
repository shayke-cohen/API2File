import Foundation

/// DOCX format converter — generates/parses minimal Word documents (OOXML).
/// Opens natively in Pages and Word. Zero external dependencies.
///
/// Supports basic Markdown-style formatting during encode:
/// - `# Heading` → Heading1 style
/// - `## Heading` → Heading2 style
/// - `**bold**` → bold run
/// - `*italic*` → italic run
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
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }

        // Parse each line into a structured paragraph
        var paragraphs: [DocParagraph] = []
        for line in lines {
            paragraphs.append(parseLine(line))
        }

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

    // MARK: - Paragraph Model

    /// Represents a parsed paragraph with optional heading level and formatted runs.
    struct DocParagraph {
        enum Style {
            case normal
            case heading1
            case heading2
        }

        struct Run {
            let text: String
            let bold: Bool
            let italic: Bool
        }

        let style: Style
        let runs: [Run]
        let isEmpty: Bool
    }

    // MARK: - Line Parser

    /// Parse a single line into a DocParagraph with heading detection and inline formatting.
    static func parseLine(_ line: String) -> DocParagraph {
        if line.isEmpty {
            return DocParagraph(style: .normal, runs: [], isEmpty: true)
        }

        var style = DocParagraph.Style.normal
        var content = line

        // Detect heading level
        if content.hasPrefix("## ") {
            style = .heading2
            content = String(content.dropFirst(3))
        } else if content.hasPrefix("# ") {
            style = .heading1
            content = String(content.dropFirst(2))
        }

        // Parse inline formatting: **bold** and *italic*
        let runs = parseInlineFormatting(content)

        return DocParagraph(style: style, runs: runs, isEmpty: false)
    }

    /// Parse inline bold and italic markers into formatted runs.
    static func parseInlineFormatting(_ text: String) -> [DocParagraph.Run] {
        var runs: [DocParagraph.Run] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Look for **bold**
            if remaining.hasPrefix("**") {
                let afterOpen = remaining.index(remaining.startIndex, offsetBy: 2)
                let searchRange = afterOpen..<remaining.endIndex
                if let closeRange = remaining.range(of: "**", range: searchRange) {
                    let boldText = String(remaining[afterOpen..<closeRange.lowerBound])
                    if !boldText.isEmpty {
                        runs.append(DocParagraph.Run(text: boldText, bold: true, italic: false))
                        remaining = remaining[closeRange.upperBound...]
                        continue
                    }
                }
            }

            // Look for *italic* (but not **)
            if remaining.hasPrefix("*") && !remaining.hasPrefix("**") {
                let afterOpen = remaining.index(remaining.startIndex, offsetBy: 1)
                let searchRange = afterOpen..<remaining.endIndex
                if let closeRange = remaining.range(of: "*", range: searchRange),
                   // Make sure it's not the start of **
                   (closeRange.upperBound == remaining.endIndex || remaining[closeRange.upperBound] != "*") {
                    let italicText = String(remaining[afterOpen..<closeRange.lowerBound])
                    if !italicText.isEmpty {
                        runs.append(DocParagraph.Run(text: italicText, bold: false, italic: true))
                        remaining = remaining[closeRange.upperBound...]
                        continue
                    }
                }
            }

            // Plain text: consume until next * or end
            var endIdx = remaining.index(after: remaining.startIndex)
            while endIdx < remaining.endIndex && remaining[endIdx] != "*" {
                endIdx = remaining.index(after: endIdx)
            }
            let plainText = String(remaining[remaining.startIndex..<endIdx])
            runs.append(DocParagraph.Run(text: plainText, bold: false, italic: false))
            remaining = remaining[endIdx...]
        }

        return runs
    }

    // MARK: - Document Builder

    private static func buildDocument(paragraphs: [DocParagraph]) throws -> Data {
        var paraXML = ""
        for para in paragraphs {
            if para.isEmpty {
                paraXML += "<w:p/>\n"
            } else {
                paraXML += "<w:p>"

                // Paragraph properties (style + spacing)
                var pPr = ""
                switch para.style {
                case .heading1:
                    pPr += "<w:pStyle w:val=\"Heading1\"/>"
                case .heading2:
                    pPr += "<w:pStyle w:val=\"Heading2\"/>"
                case .normal:
                    break
                }
                // Add paragraph spacing (120 twips = ~2.1mm before, 80 twips after)
                pPr += "<w:spacing w:before=\"120\" w:after=\"80\"/>"

                if !pPr.isEmpty {
                    paraXML += "<w:pPr>\(pPr)</w:pPr>"
                }

                // Runs
                for run in para.runs {
                    paraXML += "<w:r>"
                    // Run properties (bold, italic)
                    if run.bold || run.italic {
                        paraXML += "<w:rPr>"
                        if run.bold { paraXML += "<w:b/>" }
                        if run.italic { paraXML += "<w:i/>" }
                        paraXML += "</w:rPr>"
                    }
                    paraXML += "<w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t>"
                    paraXML += "</w:r>"
                }

                paraXML += "</w:p>\n"
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
            <w:pPr><w:spacing w:after="80"/></w:pPr>
            <w:rPr><w:sz w:val="24"/></w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading1">
            <w:name w:val="heading 1"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="48"/></w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading2">
            <w:name w:val="heading 2"/>
            <w:basedOn w:val="Normal"/>
            <w:next w:val="Normal"/>
            <w:pPr><w:spacing w:before="200" w:after="100"/></w:pPr>
            <w:rPr><w:b/><w:sz w:val="36"/></w:rPr>
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
