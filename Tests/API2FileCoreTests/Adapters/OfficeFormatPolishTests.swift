import XCTest
@testable import API2FileCore

final class OfficeFormatPolishTests: XCTestCase {

    // MARK: - XLSX: Bold Header Row

    func testXLSXHeaderRowHasBoldStyle() throws {
        let records: [[String: Any]] = [
            ["name": "Alice", "score": 95],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let sheetXML = String(data: files["xl/worksheets/sheet1.xml"]!, encoding: .utf8)!

        // Header cells should use style index s="1" (the bold style)
        // Data cells should either have s="0" or no s attribute
        XCTAssertTrue(sheetXML.contains("s=\"1\""), "Header row cells should reference bold style index 1")
    }

    func testXLSXStylesContainBoldFont() throws {
        let records: [[String: Any]] = [
            ["x": 1],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let stylesXML = String(data: files["xl/styles.xml"]!, encoding: .utf8)!

        // styles.xml should define a bold font (<b/>)
        XCTAssertTrue(stylesXML.contains("<b/>"), "Styles should contain a bold font definition")
        // Should have at least 2 fonts (normal + bold)
        XCTAssertTrue(stylesXML.contains("fonts count=\"2\""), "Should define 2 fonts")
        // Should have at least 2 cell format entries (normal + bold header)
        XCTAssertTrue(stylesXML.contains("cellXfs count=\"2\""), "Should define 2 cell formats")
    }

    // MARK: - XLSX: Column Widths

    func testXLSXColumnWidthsBasedOnContent() throws {
        let records: [[String: Any]] = [
            ["short": "a", "a_much_longer_column_header": "value"],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let sheetXML = String(data: files["xl/worksheets/sheet1.xml"]!, encoding: .utf8)!

        // Sheet should contain <cols> element with column width definitions
        XCTAssertTrue(sheetXML.contains("<cols>"), "Sheet should contain column width definitions")
        XCTAssertTrue(sheetXML.contains("bestFit=\"1\""), "Columns should have bestFit attribute")
        XCTAssertTrue(sheetXML.contains("customWidth=\"1\""), "Columns should have customWidth attribute")
    }

    // MARK: - XLSX: Number Formatting

    func testXLSXNumbersFormattedAsNumbers() throws {
        let records: [[String: Any]] = [
            ["label": "test", "count": 42, "price": 9.99],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let sheetXML = String(data: files["xl/worksheets/sheet1.xml"]!, encoding: .utf8)!

        // Numeric cells should NOT have t="s" (shared string type)
        // They should just have <c r="..."><v>42</v></c> without t attribute
        // Extract row 2 (data row)
        let rows = sheetXML.components(separatedBy: "<row")
        // Find data row (row 2)
        let dataRow = rows.first { $0.contains("r=\"2\"") } ?? ""

        // The numeric cells should not have t="s"
        // Find cells that contain the value 42
        XCTAssertTrue(dataRow.contains("<v>42</v>"), "Should contain numeric value 42")
        XCTAssertTrue(dataRow.contains("<v>9.99</v>"), "Should contain numeric value 9.99")

        // Verify the round-trip preserves types
        let decoded = try XLSXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded[0]["count"] as? Int, 42)
        XCTAssertEqual(decoded[0]["price"] as? Double, 9.99)
        XCTAssertEqual(decoded[0]["label"] as? String, "test")
    }

    // MARK: - XLSX: Round-trip with enhancements

    func testXLSXEnhancedRoundTrip() throws {
        let records: [[String: Any]] = [
            ["name": "Widget", "price": 9.99, "quantity": 100],
            ["name": "Gadget", "price": 24.99, "quantity": 50],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let decoded = try XLSXFormat.decode(data: data, options: nil)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["name"] as? String, "Widget")
        XCTAssertEqual(decoded[1]["name"] as? String, "Gadget")
        XCTAssertEqual(decoded[0]["quantity"] as? Int, 100)
        XCTAssertEqual(decoded[1]["quantity"] as? Int, 50)
    }

    // MARK: - DOCX: Heading Styles

    func testDOCXHeading1Style() throws {
        let records: [[String: Any]] = [["content": "# Main Title\n\nSome body text."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        // Should contain Heading1 style reference
        XCTAssertTrue(docXML.contains("Heading1"), "Should contain Heading1 style for # lines")
        // The heading text should appear
        XCTAssertTrue(docXML.contains("Main Title"), "Heading text should be present")
    }

    func testDOCXHeading2Style() throws {
        let records: [[String: Any]] = [["content": "## Sub Heading\n\nParagraph text."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        // Should contain Heading2 style reference
        XCTAssertTrue(docXML.contains("Heading2"), "Should contain Heading2 style for ## lines")
        XCTAssertTrue(docXML.contains("Sub Heading"), "Heading text should be present")
    }

    func testDOCXHeadingStylesInStylesXML() throws {
        let records: [[String: Any]] = [["content": "# Title"]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let stylesXML = String(data: files["word/styles.xml"]!, encoding: .utf8)!

        // styles.xml should define both Heading1 and Heading2 styles
        XCTAssertTrue(stylesXML.contains("styleId=\"Heading1\""), "Should define Heading1 style")
        XCTAssertTrue(stylesXML.contains("styleId=\"Heading2\""), "Should define Heading2 style")
        // Heading styles should have larger font sizes
        XCTAssertTrue(stylesXML.contains("w:val=\"48\""), "Heading1 should use large font size (48 half-points = 24pt)")
        XCTAssertTrue(stylesXML.contains("w:val=\"36\""), "Heading2 should use medium font size (36 half-points = 18pt)")
    }

    // MARK: - DOCX: Bold and Italic

    func testDOCXBoldFormatting() throws {
        let records: [[String: Any]] = [["content": "This has **bold text** in it."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        // Should contain bold run property <w:b/>
        XCTAssertTrue(docXML.contains("<w:b/>"), "Should contain bold run property")
        XCTAssertTrue(docXML.contains("bold text"), "Bold text content should be present")
    }

    func testDOCXItalicFormatting() throws {
        let records: [[String: Any]] = [["content": "This has *italic text* in it."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        // Should contain italic run property <w:i/>
        XCTAssertTrue(docXML.contains("<w:i/>"), "Should contain italic run property")
        XCTAssertTrue(docXML.contains("italic text"), "Italic text content should be present")
    }

    func testDOCXMixedFormatting() throws {
        let records: [[String: Any]] = [["content": "Normal **bold** and *italic* text."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        XCTAssertTrue(docXML.contains("<w:b/>"), "Should contain bold formatting")
        XCTAssertTrue(docXML.contains("<w:i/>"), "Should contain italic formatting")
        XCTAssertTrue(docXML.contains("Normal "), "Normal text should be present")
        XCTAssertTrue(docXML.contains("bold"), "Bold text should be present")
        XCTAssertTrue(docXML.contains("italic"), "Italic text should be present")
    }

    // MARK: - DOCX: Paragraph Spacing

    func testDOCXParagraphSpacing() throws {
        let records: [[String: Any]] = [["content": "First paragraph.\n\nSecond paragraph."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let docXML = String(data: files["word/document.xml"]!, encoding: .utf8)!

        // Should contain spacing properties
        XCTAssertTrue(docXML.contains("w:spacing"), "Should contain paragraph spacing")
        XCTAssertTrue(docXML.contains("w:before="), "Should have before spacing")
        XCTAssertTrue(docXML.contains("w:after="), "Should have after spacing")
    }

    // MARK: - DOCX: Inline Formatting Parser

    func testDOCXInlineFormattingParser() {
        // Test the parser directly
        let runs1 = DOCXFormat.parseInlineFormatting("hello **world** end")
        XCTAssertEqual(runs1.count, 3)
        XCTAssertEqual(runs1[0].text, "hello ")
        XCTAssertFalse(runs1[0].bold)
        XCTAssertEqual(runs1[1].text, "world")
        XCTAssertTrue(runs1[1].bold)
        XCTAssertEqual(runs1[2].text, " end")
        XCTAssertFalse(runs1[2].bold)

        let runs2 = DOCXFormat.parseInlineFormatting("start *italic* end")
        XCTAssertEqual(runs2.count, 3)
        XCTAssertEqual(runs2[0].text, "start ")
        XCTAssertFalse(runs2[0].italic)
        XCTAssertEqual(runs2[1].text, "italic")
        XCTAssertTrue(runs2[1].italic)
        XCTAssertEqual(runs2[2].text, " end")
        XCTAssertFalse(runs2[2].italic)
    }

    func testDOCXLineParser() {
        let heading1 = DOCXFormat.parseLine("# Title")
        XCTAssertEqual(heading1.style, .heading1)
        XCTAssertEqual(heading1.runs.first?.text, "Title")

        let heading2 = DOCXFormat.parseLine("## Subtitle")
        XCTAssertEqual(heading2.style, .heading2)
        XCTAssertEqual(heading2.runs.first?.text, "Subtitle")

        let normal = DOCXFormat.parseLine("Just text")
        XCTAssertEqual(normal.style, .normal)
        XCTAssertEqual(normal.runs.first?.text, "Just text")

        let empty = DOCXFormat.parseLine("")
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - DOCX: Round-trip

    func testDOCXEnhancedRoundTrip() throws {
        let records: [[String: Any]] = [["content": "# Title\n\nSome text with **bold** and *italic*.\n\n## Section\n\nMore text."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        let decoded = try DOCXFormat.decode(data: data, options: nil)

        XCTAssertEqual(decoded.count, 1)
        let content = decoded[0]["content"] as? String ?? ""
        // The decoded text should contain the original text content (without markdown markers)
        XCTAssertTrue(content.contains("Title"), "Should contain heading text")
        XCTAssertTrue(content.contains("bold"), "Should contain bold text")
        XCTAssertTrue(content.contains("italic"), "Should contain italic text")
        XCTAssertTrue(content.contains("Section"), "Should contain subheading text")
        XCTAssertTrue(content.contains("More text"), "Should contain body text")
    }

    // MARK: - PPTX: Title Font Size

    func testPPTXTitleSize24pt() throws {
        let records: [[String: Any]] = [
            ["title": "Big Title", "content": "Content here"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let slideXML = String(data: files["ppt/slides/slide1.xml"]!, encoding: .utf8)!

        // Title should use sz="2400" (24pt in hundredths of a point)
        XCTAssertTrue(slideXML.contains("sz=\"2400\""), "Title should be 24pt (2400 hundredths)")
        // Title should be bold
        XCTAssertTrue(slideXML.contains("b=\"1\""), "Title should be bold")
    }

    // MARK: - PPTX: Bullet Points

    func testPPTXBulletPoints() throws {
        let records: [[String: Any]] = [
            ["title": "Features", "content": "Feature A\nFeature B\nFeature C"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let slideXML = String(data: files["ppt/slides/slide1.xml"]!, encoding: .utf8)!

        // Content paragraphs should have bullet character
        XCTAssertTrue(slideXML.contains("buChar"), "Content should use bullet characters")
        // All three features should be present
        XCTAssertTrue(slideXML.contains("Feature A"), "Should contain Feature A")
        XCTAssertTrue(slideXML.contains("Feature B"), "Should contain Feature B")
        XCTAssertTrue(slideXML.contains("Feature C"), "Should contain Feature C")
    }

    func testPPTXBulletPointsWithIndent() throws {
        let records: [[String: Any]] = [
            ["title": "List", "content": "Item 1\nItem 2"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)
        let slideXML = String(data: files["ppt/slides/slide1.xml"]!, encoding: .utf8)!

        // Bullet paragraphs should have margin/indent for proper bullet alignment
        XCTAssertTrue(slideXML.contains("marL="), "Bullet paragraphs should have left margin")
        XCTAssertTrue(slideXML.contains("indent="), "Bullet paragraphs should have indent")
    }

    // MARK: - PPTX: Slide Numbers

    func testPPTXSlideNumbers() throws {
        let records: [[String: Any]] = [
            ["title": "Slide 1", "content": "First"],
            ["title": "Slide 2", "content": "Second"],
            ["title": "Slide 3", "content": "Third"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let files = try ZIPHelper.extractZIP(data: data)

        // Each slide should have a slide number shape
        for i in 1...3 {
            let slideXML = String(data: files["ppt/slides/slide\(i).xml"]!, encoding: .utf8)!
            XCTAssertTrue(slideXML.contains("ph type=\"sldNum\""), "Slide \(i) should contain slide number placeholder")
            XCTAssertTrue(slideXML.contains("SlideNumber"), "Slide \(i) should have SlideNumber shape")
        }
    }

    func testPPTXSlideNumbersNotInDecodedContent() throws {
        let records: [[String: Any]] = [
            ["title": "Test", "content": "Body text"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let decoded = try PPTXFormat.decode(data: data, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["title"] as? String, "Test")
        let content = decoded[0]["content"] as? String ?? ""
        XCTAssertEqual(content, "Body text", "Slide number should not appear in decoded content")
    }

    // MARK: - PPTX: Round-trip with enhancements

    func testPPTXEnhancedRoundTrip() throws {
        let records: [[String: Any]] = [
            ["title": "Overview", "content": "Point A\nPoint B"],
            ["title": "Details", "content": "Detail 1\nDetail 2\nDetail 3"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let decoded = try PPTXFormat.decode(data: data, options: nil)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["title"] as? String, "Overview")
        XCTAssertEqual(decoded[1]["title"] as? String, "Details")

        let content1 = decoded[0]["content"] as? String ?? ""
        XCTAssertTrue(content1.contains("Point A"))
        XCTAssertTrue(content1.contains("Point B"))

        let content2 = decoded[1]["content"] as? String ?? ""
        XCTAssertTrue(content2.contains("Detail 1"))
        XCTAssertTrue(content2.contains("Detail 3"))
    }
}
