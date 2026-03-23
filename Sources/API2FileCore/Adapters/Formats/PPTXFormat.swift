import Foundation

/// PPTX format converter — generates/parses minimal PowerPoint presentations (OOXML).
/// Opens natively in Keynote and PowerPoint. Zero external dependencies.
public enum PPTXFormat: FormatConverter {
    public static let format: FileFormat = .pptx

    // MARK: - Encode

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard !records.isEmpty else {
            return try buildPresentation(slides: [])
        }

        let titleField = options?.fieldMapping?["title"] ?? "title"
        let contentField = options?.fieldMapping?["content"] ?? "content"

        let slides = records.map { record -> (title: String, content: String) in
            let title = (record[titleField] as? String) ?? "Untitled"
            let content = (record[contentField] as? String) ?? ""
            return (title, content)
        }

        return try buildPresentation(slides: slides)
    }

    // MARK: - Decode

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        let files = try ZIPHelper.extractZIP(data: data)

        let titleField = options?.fieldMapping?["title"] ?? "title"
        let contentField = options?.fieldMapping?["content"] ?? "content"

        // Find all slide files
        var slideFiles: [(index: Int, data: Data)] = []
        for (path, fileData) in files {
            if path.hasPrefix("ppt/slides/slide") && path.hasSuffix(".xml") {
                let filename = (path as NSString).lastPathComponent
                let numStr = filename.replacingOccurrences(of: "slide", with: "").replacingOccurrences(of: ".xml", with: "")
                if let num = Int(numStr) {
                    slideFiles.append((num, fileData))
                }
            }
        }

        slideFiles.sort { $0.index < $1.index }

        var records: [[String: Any]] = []
        for (_, slideData) in slideFiles {
            guard let xml = String(data: slideData, encoding: .utf8) else { continue }
            let (title, content) = extractSlideText(from: xml)
            records.append([titleField: title, contentField: content])
        }

        return records
    }

    // MARK: - Presentation Builder

    private static func buildPresentation(slides: [(title: String, content: String)]) throws -> Data {
        var files: [String: Data] = [:]

        // Content types — register each slide
        var slideOverrides = ""
        for i in 1...max(slides.count, 1) {
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>\n"
        }

        let contentTypes = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
            \(slideOverrides)</Types>
            """
        files["[Content_Types].xml"] = Data(contentTypes.utf8)

        // Root rels
        let rels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """
        files["_rels/.rels"] = Data(rels.utf8)

        // Presentation XML — list slides
        var slideRefs = ""
        var slideRels = ""
        for i in 1...max(slides.count, 1) {
            slideRefs += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i)\"/>"
            slideRels += "<Relationship Id=\"rId\(i)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>\n"
        }

        let presentation = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
            <p:sldIdLst>\(slideRefs)</p:sldIdLst>
            <p:sldSz cx="9144000" cy="6858000"/>
            <p:notesSz cx="6858000" cy="9144000"/>
            </p:presentation>
            """
        files["ppt/presentation.xml"] = Data(presentation.utf8)

        let presRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            \(slideRels)</Relationships>
            """
        files["ppt/_rels/presentation.xml.rels"] = Data(presRels.utf8)

        // Generate each slide
        if slides.isEmpty {
            files["ppt/slides/slide1.xml"] = Data(buildSlideXML(title: "", content: "").utf8)
            files["ppt/slides/_rels/slide1.xml.rels"] = Data(emptyRels.utf8)
        } else {
            for (i, slide) in slides.enumerated() {
                files["ppt/slides/slide\(i + 1).xml"] = Data(buildSlideXML(title: slide.title, content: slide.content).utf8)
                files["ppt/slides/_rels/slide\(i + 1).xml.rels"] = Data(emptyRels.utf8)
            }
        }

        return try ZIPHelper.createZIP(files: files)
    }

    private static let emptyRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
        """

    private static func buildSlideXML(title: String, content: String) -> String {
        // Title shape at top
        let titleShape = """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
              <p:spPr><a:xfrm><a:off x="457200" y="274638"/><a:ext cx="8229600" cy="1143000"/></a:xfrm></p:spPr>
              <p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en-US" sz="3200" b="1"/><a:t>\(xmlEscape(title))</a:t></a:r></a:p></p:txBody>
            </p:sp>
            """

        // Content shape — split by newlines into paragraphs
        let contentParas = content.components(separatedBy: "\n")
            .map { "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"1800\"/><a:t>\(xmlEscape($0))</a:t></a:r></a:p>" }
            .joined(separator: "\n")

        let contentShape = """
            <p:sp>
              <p:nvSpPr><p:cNvPr id="3" name="Content"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr>
              <p:spPr><a:xfrm><a:off x="457200" y="1600200"/><a:ext cx="8229600" cy="4525963"/></a:xfrm></p:spPr>
              <p:txBody><a:bodyPr/>\(contentParas)</p:txBody>
            </p:sp>
            """

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                   xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <p:cSld><p:spTree>
              <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
              <p:grpSpPr/>
              \(titleShape)
              \(contentShape)
            </p:spTree></p:cSld>
            </p:sld>
            """
    }

    // MARK: - Text Extraction

    private static func extractSlideText(from xml: String) -> (title: String, content: String) {
        let nsXML = xml as NSString

        // Extract text from <a:t>...</a:t> inside shapes
        // First shape with ph type="title" → title, rest → content
        let shapePattern = "<p:sp>(.*?)</p:sp>"
        guard let shapeRegex = try? NSRegularExpression(pattern: shapePattern, options: .dotMatchesLineSeparators) else {
            return ("", "")
        }

        let textPattern = "<a:t>(.*?)</a:t>"
        guard let textRegex = try? NSRegularExpression(pattern: textPattern, options: .dotMatchesLineSeparators) else {
            return ("", "")
        }

        let shapeMatches = shapeRegex.matches(in: xml, range: NSRange(location: 0, length: nsXML.length))

        var title = ""
        var contentParts: [String] = []

        for shapeMatch in shapeMatches {
            let shapeContent = nsXML.substring(with: shapeMatch.range(at: 1))
            let nsShape = shapeContent as NSString
            let isTitle = shapeContent.contains("ph type=\"title\"")

            let textMatches = textRegex.matches(in: shapeContent, range: NSRange(location: 0, length: nsShape.length))
            let texts = textMatches.map { xmlUnescape(nsShape.substring(with: $0.range(at: 1))) }

            if isTitle {
                title = texts.joined()
            } else {
                contentParts.append(contentsOf: texts)
            }
        }

        return (title, contentParts.joined(separator: "\n"))
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
