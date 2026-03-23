import XCTest
@testable import API2FileCore

final class EMLSVGWeblocFormatTests: XCTestCase {

    // MARK: - EML: Encode Email with All Fields

    func testEMLEncodeAllFields() throws {
        let records: [[String: Any]] = [
            [
                "from": "sender@example.com",
                "to": "recipient@example.com",
                "subject": "Test Email",
                "date": "Mon, 15 Jul 2024 10:30:00 +0000",
                "body": "<h1>Hello</h1><p>World</p>"
            ]
        ]
        let data = try EMLFormat.encode(records: records, options: nil)
        let eml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(eml.contains("From: sender@example.com"))
        XCTAssertTrue(eml.contains("To: recipient@example.com"))
        XCTAssertTrue(eml.contains("Subject: Test Email"))
        XCTAssertTrue(eml.contains("Date: Mon, 15 Jul 2024 10:30:00 +0000"))
        XCTAssertTrue(eml.contains("MIME-Version: 1.0"))
        XCTAssertTrue(eml.contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertTrue(eml.contains("<h1>Hello</h1><p>World</p>"))
    }

    // MARK: - EML: Decode Email Back to Record

    func testEMLDecodeBackToRecord() throws {
        let eml = "From: sender@example.com\r\nTo: recipient@example.com\r\nSubject: Test Email\r\nDate: Mon, 15 Jul 2024 10:30:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<h1>Hello</h1><p>World</p>"
        let data = eml.data(using: .utf8)!
        let records = try EMLFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["from"] as? String, "sender@example.com")
        XCTAssertEqual(records[0]["to"] as? String, "recipient@example.com")
        XCTAssertEqual(records[0]["subject"] as? String, "Test Email")
        XCTAssertEqual(records[0]["date"] as? String, "Mon, 15 Jul 2024 10:30:00 +0000")
        XCTAssertEqual(records[0]["body"] as? String, "<h1>Hello</h1><p>World</p>")
    }

    // MARK: - EML: Round-trip

    func testEMLRoundTrip() throws {
        let original: [[String: Any]] = [
            [
                "from": "alice@example.com",
                "to": "bob@example.com",
                "subject": "Round Trip Test",
                "date": "Tue, 16 Jul 2024 08:00:00 +0000",
                "body": "<p>Testing round-trip encoding</p>"
            ]
        ]
        let encoded = try EMLFormat.encode(records: original, options: nil)
        let decoded = try EMLFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["from"] as? String, "alice@example.com")
        XCTAssertEqual(decoded[0]["to"] as? String, "bob@example.com")
        XCTAssertEqual(decoded[0]["subject"] as? String, "Round Trip Test")
        XCTAssertEqual(decoded[0]["date"] as? String, "Tue, 16 Jul 2024 08:00:00 +0000")
        XCTAssertEqual(decoded[0]["body"] as? String, "<p>Testing round-trip encoding</p>")
    }

    // MARK: - EML: Custom Field Mapping

    func testEMLCustomFieldMapping() throws {
        let options = FormatOptions(fieldMapping: [
            "from": "sender",
            "to": "receiver",
            "subject": "title",
            "date": "sentAt",
            "body": "content"
        ])
        let records: [[String: Any]] = [
            [
                "sender": "custom@example.com",
                "receiver": "dest@example.com",
                "title": "Custom Fields",
                "sentAt": "Wed, 17 Jul 2024 12:00:00 +0000",
                "content": "<p>Custom body</p>"
            ]
        ]
        let data = try EMLFormat.encode(records: records, options: options)
        let eml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(eml.contains("From: custom@example.com"))
        XCTAssertTrue(eml.contains("To: dest@example.com"))
        XCTAssertTrue(eml.contains("Subject: Custom Fields"))
        XCTAssertTrue(eml.contains("<p>Custom body</p>"))

        // Decode back with same options
        let decoded = try EMLFormat.decode(data: data, options: options)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["sender"] as? String, "custom@example.com")
        XCTAssertEqual(decoded[0]["receiver"] as? String, "dest@example.com")
        XCTAssertEqual(decoded[0]["title"] as? String, "Custom Fields")
        XCTAssertEqual(decoded[0]["content"] as? String, "<p>Custom body</p>")
    }

    // MARK: - EML: Handle Missing Optional Fields

    func testEMLHandleMissingOptionalFields() throws {
        let records: [[String: Any]] = [
            [
                "subject": "Minimal Email",
                "body": "Just a body"
            ]
        ]
        let data = try EMLFormat.encode(records: records, options: nil)
        let eml = String(data: data, encoding: .utf8)!

        XCTAssertFalse(eml.contains("From:"))
        XCTAssertFalse(eml.contains("To:"))
        XCTAssertTrue(eml.contains("Subject: Minimal Email"))
        XCTAssertTrue(eml.contains("MIME-Version: 1.0"))
        XCTAssertTrue(eml.contains("Just a body"))

        // Decode back — missing fields should not appear
        let decoded = try EMLFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0]["from"])
        XCTAssertNil(decoded[0]["to"])
        XCTAssertEqual(decoded[0]["subject"] as? String, "Minimal Email")
    }

    // MARK: - EML: Multiline Body

    func testEMLMultilineBody() throws {
        let multilineBody = "<html>\r\n<body>\r\n<h1>Title</h1>\r\n<p>Paragraph 1</p>\r\n<p>Paragraph 2</p>\r\n</body>\r\n</html>"
        let records: [[String: Any]] = [
            [
                "from": "test@example.com",
                "to": "dest@example.com",
                "subject": "Multiline",
                "body": multilineBody
            ]
        ]
        let data = try EMLFormat.encode(records: records, options: nil)
        let decoded = try EMLFormat.decode(data: data, options: nil)

        XCTAssertEqual(decoded.count, 1)
        let decodedBody = decoded[0]["body"] as? String ?? ""
        XCTAssertTrue(decodedBody.contains("<h1>Title</h1>"))
        XCTAssertTrue(decodedBody.contains("<p>Paragraph 1</p>"))
        XCTAssertTrue(decodedBody.contains("<p>Paragraph 2</p>"))
    }

    // MARK: - SVG: Encode Content

    func testSVGEncodeContent() throws {
        let svgContent = """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
          <circle cx="50" cy="50" r="40" fill="red"/>
        </svg>
        """
        let records: [[String: Any]] = [["content": svgContent]]
        let data = try SVGFormat.encode(records: records, options: nil)
        let output = String(data: data, encoding: .utf8)!

        XCTAssertTrue(output.contains("<svg"))
        XCTAssertTrue(output.contains("<circle"))
        XCTAssertTrue(output.contains("fill=\"red\""))
    }

    // MARK: - SVG: Decode Content

    func testSVGDecodeContent() throws {
        let svgContent = "<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"10\"/></svg>"
        let data = svgContent.data(using: .utf8)!
        let records = try SVGFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["content"] as? String, svgContent)
    }

    // MARK: - SVG: Round-trip

    func testSVGRoundTrip() throws {
        let svgContent = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 200\"><text x=\"10\" y=\"20\">Hello</text></svg>"
        let original: [[String: Any]] = [["content": svgContent]]
        let encoded = try SVGFormat.encode(records: original, options: nil)
        let decoded = try SVGFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["content"] as? String, svgContent)
    }

    // MARK: - SVG: Custom Content Field

    func testSVGCustomContentField() throws {
        let options = FormatOptions(fieldMapping: ["content": "svgData"])
        let svgContent = "<svg><line x1=\"0\" y1=\"0\" x2=\"100\" y2=\"100\"/></svg>"
        let records: [[String: Any]] = [["svgData": svgContent]]

        let data = try SVGFormat.encode(records: records, options: options)
        let decoded = try SVGFormat.decode(data: data, options: options)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["svgData"] as? String, svgContent)
    }

    // MARK: - WEBLOC: Encode URL to Plist

    func testWeblocEncodeURL() throws {
        let records: [[String: Any]] = [["url": "https://www.apple.com"]]
        let data = try WeblocFormat.encode(records: records, options: nil)
        let plist = String(data: data, encoding: .utf8)!

        XCTAssertTrue(plist.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(plist.contains("<!DOCTYPE plist"))
        XCTAssertTrue(plist.contains("<plist version=\"1.0\">"))
        XCTAssertTrue(plist.contains("<key>URL</key>"))
        XCTAssertTrue(plist.contains("<string>https://www.apple.com</string>"))
        XCTAssertTrue(plist.contains("</dict>"))
        XCTAssertTrue(plist.contains("</plist>"))
    }

    // MARK: - WEBLOC: Decode Plist Back to URL

    func testWeblocDecodeBackToURL() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>URL</key>
        \t<string>https://www.example.com/page</string>
        </dict>
        </plist>
        """
        let data = plist.data(using: .utf8)!
        let records = try WeblocFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["url"] as? String, "https://www.example.com/page")
    }

    // MARK: - WEBLOC: Round-trip

    func testWeblocRoundTrip() throws {
        let original: [[String: Any]] = [["url": "https://developer.apple.com/swift"]]
        let encoded = try WeblocFormat.encode(records: original, options: nil)
        let decoded = try WeblocFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["url"] as? String, "https://developer.apple.com/swift")
    }

    // MARK: - WEBLOC: Custom URL Field

    func testWeblocCustomURLField() throws {
        let options = FormatOptions(fieldMapping: ["url": "link"])
        let records: [[String: Any]] = [["link": "https://github.com"]]

        let data = try WeblocFormat.encode(records: records, options: options)
        let decoded = try WeblocFormat.decode(data: data, options: options)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["link"] as? String, "https://github.com")
    }

    // MARK: - WEBLOC: Handle URL with Special Characters

    func testWeblocURLWithSpecialCharacters() throws {
        let url = "https://example.com/search?q=hello&lang=en&page=1"
        let records: [[String: Any]] = [["url": url]]

        let data = try WeblocFormat.encode(records: records, options: nil)
        let plist = String(data: data, encoding: .utf8)!

        // The & should be escaped in XML
        XCTAssertTrue(plist.contains("&amp;"))

        // Round-trip should preserve the original URL
        let decoded = try WeblocFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["url"] as? String, url)
    }

    // MARK: - Factory: EML Registration

    func testEMLFactoryRegistration() throws {
        let converter = try FormatConverterFactory.converter(for: .eml)
        XCTAssertTrue(converter == EMLFormat.self)
    }

    // MARK: - Factory: SVG Registration

    func testSVGFactoryRegistration() throws {
        let converter = try FormatConverterFactory.converter(for: .svg)
        XCTAssertTrue(converter == SVGFormat.self)
    }

    // MARK: - Factory: WEBLOC Registration

    func testWeblocFactoryRegistration() throws {
        let converter = try FormatConverterFactory.converter(for: .webloc)
        XCTAssertTrue(converter == WeblocFormat.self)
    }
}
