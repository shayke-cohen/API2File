import XCTest
@testable import API2FileCore

final class FormatConverterTests: XCTestCase {

    // MARK: - CSV: Encode

    func testCSVEncodeProducesHeadersAndRows() throws {
        let records: [[String: Any]] = [
            ["name": "Alice", "age": 30],
            ["name": "Bob", "age": 25]
        ]
        let data = try CSVFormat.encode(records: records, options: nil)
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        // Header row has sorted keys
        XCTAssertEqual(String(lines[0]), "age,name")
        // Data rows
        XCTAssertEqual(String(lines[1]), "30,Alice")
        XCTAssertEqual(String(lines[2]), "25,Bob")
    }

    func testCSVEncodeEmptyRecordsProducesEmptyData() throws {
        let data = try CSVFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    func testCSVEncodeIdColumnMappedToUnderscore() throws {
        let records: [[String: Any]] = [
            ["id": "abc123", "name": "Widget"]
        ]
        let data = try CSVFormat.encode(records: records, options: nil)
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        // id should appear as _id in the header
        XCTAssertTrue(lines[0].hasPrefix("_id"))
        XCTAssertEqual(String(lines[0]), "_id,name")
        XCTAssertEqual(String(lines[1]), "abc123,Widget")
    }

    func testCSVEncodeSpecialCharactersAreEscaped() throws {
        let records: [[String: Any]] = [
            ["value": "has,comma", "quote": "has\"quote", "newline": "line1\nline2"]
        ]
        let data = try CSVFormat.encode(records: records, options: nil)
        let csv = String(data: data, encoding: .utf8)!

        // Values with commas, quotes, or newlines should be quoted
        XCTAssertTrue(csv.contains("\"has,comma\""))
        XCTAssertTrue(csv.contains("\"has\"\"quote\""))
        XCTAssertTrue(csv.contains("\"line1\nline2\""))
    }

    func testCSVEncodeSparseRecordsMissingFieldsAreEmpty() throws {
        let records: [[String: Any]] = [
            ["a": 1, "b": 2],
            ["a": 3, "c": 4]
        ]
        let data = try CSVFormat.encode(records: records, options: nil)
        let csv = String(data: data, encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        // Headers should be a,b,c (all unique keys sorted)
        XCTAssertEqual(String(lines[0]), "a,b,c")
        // First record has a=1, b=2, c missing
        XCTAssertEqual(String(lines[1]), "1,2,")
        // Second record has a=3, b missing, c=4
        XCTAssertEqual(String(lines[2]), "3,,4")
    }

    // MARK: - CSV: Decode

    func testCSVDecodeCorrectTypes() throws {
        let csv = "_id,active,name,score\n1,true,Alice,9.5\n2,false,Bob,7\n"
        let data = csv.data(using: .utf8)!
        let records = try CSVFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 2)
        // _id maps back to id
        XCTAssertEqual(records[0]["id"] as? Int, 1)
        XCTAssertEqual(records[0]["active"] as? Bool, true)
        XCTAssertEqual(records[0]["name"] as? String, "Alice")
        XCTAssertEqual(records[0]["score"] as? Double, 9.5)

        XCTAssertEqual(records[1]["id"] as? Int, 2)
        XCTAssertEqual(records[1]["active"] as? Bool, false)
        XCTAssertEqual(records[1]["name"] as? String, "Bob")
        // 7 without a dot should be parsed as Int
        XCTAssertEqual(records[1]["score"] as? Int, 7)
    }

    func testCSVDecodeHeaderOnlyReturnsEmpty() throws {
        let csv = "name,age\n"
        let data = csv.data(using: .utf8)!
        let records = try CSVFormat.decode(data: data, options: nil)
        XCTAssertTrue(records.isEmpty)
    }

    func testCSVDecodeUnderscoreIdMapsToId() throws {
        let csv = "_id,name\nabc,Alice\n"
        let data = csv.data(using: .utf8)!
        let records = try CSVFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        // _id in CSV header becomes "id" in decoded record
        XCTAssertEqual(records[0]["id"] as? String, "abc")
        XCTAssertNil(records[0]["_id"])
    }

    func testCSVDecodeJSONObjectCellReturnsDictionary() throws {
        let csv = "_id,data\nabc,\"{\"\"title\"\":\"\"Featured\"\",\"\"itemCount\"\":12}\"\n"
        let data = csv.data(using: .utf8)!
        let records = try CSVFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        let dataField = try XCTUnwrap(records[0]["data"] as? [String: Any])
        XCTAssertEqual(dataField["title"] as? String, "Featured")
        XCTAssertEqual(dataField["itemCount"] as? Int, 12)
    }

    func testCSVDecodeJSONArrayCellReturnsArray() throws {
        let csv = "_id,tags\nabc,\"[\"\"featured\"\",\"\"sale\"\"]\"\n"
        let data = csv.data(using: .utf8)!
        let records = try CSVFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        let tags = try XCTUnwrap(records[0]["tags"] as? [Any])
        XCTAssertEqual(tags as? [String], ["featured", "sale"])
    }

    // MARK: - CSV: Round-trip

    func testCSVRoundTrip() throws {
        let original: [[String: Any]] = [
            ["id": "r1", "name": "Widget", "price": 9.99, "active": true],
            ["id": "r2", "name": "Gadget", "price": 19.99, "active": false]
        ]
        let encoded = try CSVFormat.encode(records: original, options: nil)
        let decoded = try CSVFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["id"] as? String, "r1")
        XCTAssertEqual(decoded[0]["name"] as? String, "Widget")
        XCTAssertEqual(decoded[0]["active"] as? Bool, true)
        XCTAssertEqual(decoded[1]["id"] as? String, "r2")
        XCTAssertEqual(decoded[1]["name"] as? String, "Gadget")
        XCTAssertEqual(decoded[1]["active"] as? Bool, false)
    }

    func testCSVRoundTripWithSpecialCharacters() throws {
        let original: [[String: Any]] = [
            ["text": "hello, world", "note": "she said \"hi\"", "body": "line1\nline2"]
        ]
        let encoded = try CSVFormat.encode(records: original, options: nil)
        let decoded = try CSVFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["text"] as? String, "hello, world")
        XCTAssertEqual(decoded[0]["note"] as? String, "she said \"hi\"")
        XCTAssertEqual(decoded[0]["body"] as? String, "line1\nline2")
    }

    // MARK: - JSON: Encode

    func testJSONEncodeSingleRecordProducesObject() throws {
        let records: [[String: Any]] = [
            ["name": "Alice", "age": 30]
        ]
        let data = try JSONFormat.encode(records: records, options: nil)
        let parsed = try JSONSerialization.jsonObject(with: data)

        // Single record should be a dictionary, not an array
        XCTAssertTrue(parsed is [String: Any])
        let dict = parsed as! [String: Any]
        XCTAssertEqual(dict["name"] as? String, "Alice")
        XCTAssertEqual(dict["age"] as? Int, 30)
    }

    func testJSONEncodeMultipleRecordsProducesArray() throws {
        let records: [[String: Any]] = [
            ["name": "Alice"],
            ["name": "Bob"]
        ]
        let data = try JSONFormat.encode(records: records, options: nil)
        let parsed = try JSONSerialization.jsonObject(with: data)

        // Multiple records should be an array
        XCTAssertTrue(parsed is [[String: Any]])
        let arr = parsed as! [[String: Any]]
        XCTAssertEqual(arr.count, 2)
    }

    // MARK: - JSON: Decode

    func testJSONDecodeSingleObjectReturnsArrayWithOneElement() throws {
        let json = "{\"name\": \"Alice\", \"age\": 30}"
        let data = json.data(using: .utf8)!
        let records = try JSONFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["name"] as? String, "Alice")
        XCTAssertEqual(records[0]["age"] as? Int, 30)
    }

    func testJSONDecodeArrayReturnsArray() throws {
        let json = "[{\"name\": \"Alice\"}, {\"name\": \"Bob\"}]"
        let data = json.data(using: .utf8)!
        let records = try JSONFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0]["name"] as? String, "Alice")
        XCTAssertEqual(records[1]["name"] as? String, "Bob")
    }

    func testJSONDecodeInvalidThrows() {
        let data = "not json at all {{".data(using: .utf8)!
        XCTAssertThrowsError(try JSONFormat.decode(data: data, options: nil))
    }

    // MARK: - JSON: Round-trip

    func testJSONRoundTripSingleRecord() throws {
        let original: [[String: Any]] = [
            ["id": "r1", "count": 42, "active": true, "label": "test"]
        ]
        let encoded = try JSONFormat.encode(records: original, options: nil)
        let decoded = try JSONFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["id"] as? String, "r1")
        XCTAssertEqual(decoded[0]["count"] as? Int, 42)
        XCTAssertEqual(decoded[0]["active"] as? Bool, true)
        XCTAssertEqual(decoded[0]["label"] as? String, "test")
    }

    func testJSONRoundTripMultipleRecords() throws {
        let original: [[String: Any]] = [
            ["name": "Alice"],
            ["name": "Bob"]
        ]
        let encoded = try JSONFormat.encode(records: original, options: nil)
        let decoded = try JSONFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["name"] as? String, "Alice")
        XCTAssertEqual(decoded[1]["name"] as? String, "Bob")
    }

    // MARK: - HTML: Encode

    func testHTMLEncodeExtractsContentField() throws {
        let records: [[String: Any]] = [
            ["content": "<h1>Hello</h1>", "title": "ignored"]
        ]
        let data = try HTMLFormat.encode(records: records, options: nil)
        let html = String(data: data, encoding: .utf8)!

        XCTAssertEqual(html, "<h1>Hello</h1>")
    }

    func testHTMLEncodeEmptyRecordsReturnsEmptyData() throws {
        let data = try HTMLFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - HTML: Decode

    func testHTMLDecodeWrapsInContentField() throws {
        let html = "<p>Hello World</p>"
        let data = html.data(using: .utf8)!
        let records = try HTMLFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["content"] as? String, "<p>Hello World</p>")
    }

    // MARK: - HTML: Custom content field

    func testHTMLCustomContentFieldViaFormatOptions() throws {
        let options = FormatOptions(fieldMapping: ["content": "body"])
        let records: [[String: Any]] = [
            ["body": "<h1>Custom</h1>"]
        ]

        let encoded = try HTMLFormat.encode(records: records, options: options)
        let html = String(data: encoded, encoding: .utf8)!
        XCTAssertEqual(html, "<h1>Custom</h1>")

        let decoded = try HTMLFormat.decode(data: encoded, options: options)
        XCTAssertEqual(decoded[0]["body"] as? String, "<h1>Custom</h1>")
    }

    // MARK: - HTML: Round-trip

    func testHTMLRoundTrip() throws {
        let original: [[String: Any]] = [
            ["content": "<div><h1>Title</h1><p>Body text</p></div>"]
        ]
        let encoded = try HTMLFormat.encode(records: original, options: nil)
        let decoded = try HTMLFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["content"] as? String, original[0]["content"] as? String)
    }

    // MARK: - Markdown: Encode

    func testMarkdownEncodeExtractsContentField() throws {
        let records: [[String: Any]] = [
            ["content": "# Hello\n\nWorld"]
        ]
        let data = try MarkdownFormat.encode(records: records, options: nil)
        let md = String(data: data, encoding: .utf8)!

        XCTAssertEqual(md, "# Hello\n\nWorld")
    }

    // MARK: - Markdown: Decode

    func testMarkdownDecodeWrapsInContentField() throws {
        let md = "## Section\n\nParagraph text."
        let data = md.data(using: .utf8)!
        let records = try MarkdownFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["content"] as? String, "## Section\n\nParagraph text.")
    }

    // MARK: - Markdown: Round-trip

    func testMarkdownRoundTrip() throws {
        let original: [[String: Any]] = [
            ["content": "# Title\n\n- item 1\n- item 2\n\n> quote"]
        ]
        let encoded = try MarkdownFormat.encode(records: original, options: nil)
        let decoded = try MarkdownFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["content"] as? String, original[0]["content"] as? String)
    }

    func testMarkdownEncodePrefersRichContentFieldWhenConfigured() throws {
        let options = FormatOptions(fieldMapping: [
            "content": "contentText",
            "richContent": "richContent",
        ])
        let record: [String: Any] = [
            "title": "Rich Post",
            "contentText": "fallback text",
            "richContent": [
                "nodes": [
                    [
                        "type": "HEADING",
                        "id": "heading-1",
                        "nodes": [
                            [
                                "type": "TEXT",
                                "id": "",
                                "nodes": [],
                                "textData": [
                                    "text": "Hello",
                                    "decorations": [],
                                ],
                            ],
                        ],
                        "headingData": ["level": 2],
                    ],
                    [
                        "type": "PARAGRAPH",
                        "id": "paragraph-1",
                        "nodes": [
                            [
                                "type": "TEXT",
                                "id": "",
                                "nodes": [],
                                "textData": [
                                    "text": "World",
                                    "decorations": [],
                                ],
                            ],
                        ],
                        "paragraphData": [:],
                    ],
                ],
                "documentStyle": [:],
            ],
        ]

        let data = try MarkdownFormat.encode(records: [record], options: options)
        let markdown = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(markdown.contains("title: Rich Post"))
        XCTAssertTrue(markdown.contains("## Hello"))
        XCTAssertTrue(markdown.contains("World"))
        XCTAssertFalse(markdown.contains("fallback text"))
    }

    func testMarkdownDecodeBuildsRichContentWhenConfigured() throws {
        let markdown = """
        ---
        title: Rich Post
        ---

        ## Heading

        First paragraph.

        - one
        - two
        """
        let options = FormatOptions(fieldMapping: [
            "content": "contentText",
            "richContent": "richContent",
        ])

        let records = try MarkdownFormat.decode(data: Data(markdown.utf8), options: options)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record["title"] as? String, "Rich Post")
        XCTAssertEqual(record["contentText"] as? String, "Heading\n\nFirst paragraph.\n\none\ntwo")

        let richContent = try XCTUnwrap(record["richContent"] as? [String: Any])
        let nodes = try XCTUnwrap(richContent["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.first?["type"] as? String, "HEADING")
        XCTAssertEqual(nodes.dropFirst().first?["type"] as? String, "PARAGRAPH")
        XCTAssertEqual(nodes.last?["type"] as? String, "BULLETED_LIST")
    }

    // MARK: - YAML: Encode

    func testYAMLEncodeProducesKeyValueLines() throws {
        let records: [[String: Any]] = [
            ["name": "Alice", "age": 30]
        ]
        let data = try YAMLFormat.encode(records: records, options: nil)
        let yaml = String(data: data, encoding: .utf8)!

        XCTAssertTrue(yaml.contains("age: 30"))
        XCTAssertTrue(yaml.contains("name: Alice"))
    }

    // MARK: - YAML: Decode

    func testYAMLDecodesParsesKeyValuePairs() throws {
        let yaml = "name: Alice\nage: 30\n"
        let data = yaml.data(using: .utf8)!
        let records = try YAMLFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["name"] as? String, "Alice")
        XCTAssertEqual(records[0]["age"] as? Int, 30)
    }

    func testYAMLDecodesBooleansNumbersAndNull() throws {
        let yaml = "active: true\ndisabled: false\ncount: 42\nprice: 3.14\nmissing: null\n"
        let data = yaml.data(using: .utf8)!
        let records = try YAMLFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["active"] as? Bool, true)
        XCTAssertEqual(records[0]["disabled"] as? Bool, false)
        XCTAssertEqual(records[0]["count"] as? Int, 42)
        XCTAssertEqual(records[0]["price"] as? Double, 3.14)
        XCTAssertTrue(records[0]["missing"] is NSNull)
    }

    func testYAMLDecodesTildeAsNull() throws {
        let yaml = "value: ~\n"
        let data = yaml.data(using: .utf8)!
        let records = try YAMLFormat.decode(data: data, options: nil)

        XCTAssertTrue(records[0]["value"] is NSNull)
    }

    func testYAMLDecodesEmptyStringReturnsEmpty() throws {
        let yaml = ""
        let data = yaml.data(using: .utf8)!
        let records = try YAMLFormat.decode(data: data, options: nil)

        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - YAML: Round-trip

    func testYAMLRoundTrip() throws {
        let original: [[String: Any]] = [
            ["name": "Widget", "count": 5, "active": true]
        ]
        let encoded = try YAMLFormat.encode(records: original, options: nil)
        let decoded = try YAMLFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["name"] as? String, "Widget")
        XCTAssertEqual(decoded[0]["count"] as? Int, 5)
        XCTAssertEqual(decoded[0]["active"] as? Bool, true)
    }

    // MARK: - Text: Encode/Decode

    func testTextEncodeExtractsContentField() throws {
        let records: [[String: Any]] = [
            ["content": "Hello, plain text!"]
        ]
        let data = try TextFormat.encode(records: records, options: nil)
        let text = String(data: data, encoding: .utf8)!

        XCTAssertEqual(text, "Hello, plain text!")
    }

    func testTextDecodeWrapsInContentField() throws {
        let text = "Some plain text content."
        let data = text.data(using: .utf8)!
        let records = try TextFormat.decode(data: data, options: nil)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["content"] as? String, "Some plain text content.")
    }

    func testTextEmptyRecordsReturnsEmptyData() throws {
        let data = try TextFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - Text: Round-trip

    func testTextRoundTrip() throws {
        let original: [[String: Any]] = [
            ["content": "Line 1\nLine 2\nLine 3"]
        ]
        let encoded = try TextFormat.encode(records: original, options: nil)
        let decoded = try TextFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["content"] as? String, "Line 1\nLine 2\nLine 3")
    }

    // MARK: - Raw: Encode

    func testRawEncodeWithBase64DataField() throws {
        let originalBytes = Data([0x00, 0x01, 0x02, 0xFF])
        let base64 = originalBytes.base64EncodedString()
        let records: [[String: Any]] = [
            ["data": base64]
        ]
        let data = try RawFormat.encode(records: records, options: nil)

        XCTAssertEqual(data, originalBytes)
    }

    func testRawEncodeWithRawDataField() throws {
        let originalBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let records: [[String: Any]] = [
            ["data": originalBytes]
        ]
        let data = try RawFormat.encode(records: records, options: nil)

        XCTAssertEqual(data, originalBytes)
    }

    func testRawEncodeMissingDataFieldThrows() {
        let records: [[String: Any]] = [
            ["notdata": "value"]
        ]
        XCTAssertThrowsError(try RawFormat.encode(records: records, options: nil))
    }

    func testRawEncodeEmptyRecordsReturnsEmptyData() throws {
        let data = try RawFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.isEmpty)
    }

    // MARK: - Raw: Decode

    func testRawDecodeProducesBase64String() throws {
        let originalBytes = Data([0x00, 0x01, 0x02, 0xFF])
        let records = try RawFormat.decode(data: originalBytes, options: nil)

        XCTAssertEqual(records.count, 1)
        let base64 = records[0]["data"] as? String
        XCTAssertNotNil(base64)
        XCTAssertEqual(Data(base64Encoded: base64!), originalBytes)
    }

    // MARK: - Raw: Round-trip

    func testRawRoundTrip() throws {
        let originalBytes = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let base64 = originalBytes.base64EncodedString()
        let original: [[String: Any]] = [
            ["data": base64]
        ]
        let encoded = try RawFormat.encode(records: original, options: nil)
        let decoded = try RawFormat.decode(data: encoded, options: nil)

        XCTAssertEqual(decoded.count, 1)
        let decodedBase64 = decoded[0]["data"] as? String
        XCTAssertNotNil(decodedBase64)
        XCTAssertEqual(Data(base64Encoded: decodedBase64!), originalBytes)
    }

    // MARK: - FormatConverterFactory

    func testFactoryReturnsCorrectConverterForEachFormat() throws {
        XCTAssertTrue(try FormatConverterFactory.converter(for: .json) == JSONFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .csv) == CSVFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .html) == HTMLFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .markdown) == MarkdownFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .yaml) == YAMLFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .text) == TextFormat.self)
        XCTAssertTrue(try FormatConverterFactory.converter(for: .raw) == RawFormat.self)
    }

    func testFactoryReturnsConverterForAllSupportedFormats() {
        // All formats should now have converters (including xlsx, docx, pptx stubs)
        let allFormats: [FileFormat] = [.json, .csv, .html, .markdown, .yaml, .text, .raw, .ics, .vcf, .eml, .svg, .webloc, .xlsx, .docx, .pptx]
        for format in allFormats {
            XCTAssertNoThrow(try FormatConverterFactory.converter(for: format), "Should have converter for \(format.rawValue)")
        }
    }

    func testFactoryEncodeDecodeConvenienceMethods() throws {
        // Test the convenience encode/decode methods on the factory
        let records: [[String: Any]] = [
            ["name": "Test", "value": 42]
        ]
        let encoded = try FormatConverterFactory.encode(records: records, format: .json)
        let decoded = try FormatConverterFactory.decode(data: encoded, format: .json)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["name"] as? String, "Test")
        XCTAssertEqual(decoded[0]["value"] as? Int, 42)
    }

    // MARK: - XLSX Format Tests

    func testXLSXEncodeDecodeRoundTrip() throws {
        let records: [[String: Any]] = [
            ["name": "Widget", "price": 9.99, "quantity": 100],
            ["name": "Gadget", "price": 24.99, "quantity": 50],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        XCTAssertTrue(data.count > 100, "XLSX should have substantial size")

        let decoded = try XLSXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["name"] as? String, "Widget")
        XCTAssertEqual(decoded[1]["name"] as? String, "Gadget")
    }

    func testXLSXEmptyRecords() throws {
        let data = try XLSXFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.count > 0, "Empty XLSX should still be valid")
        let decoded = try XLSXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 0)
    }

    func testXLSXPreservesTypes() throws {
        let records: [[String: Any]] = [
            ["text": "hello", "number": 42, "decimal": 3.14, "flag": true],
        ]
        let data = try XLSXFormat.encode(records: records, options: nil)
        let decoded = try XLSXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["text"] as? String, "hello")
        XCTAssertEqual(decoded[0]["number"] as? Int, 42)
    }

    // MARK: - DOCX Format Tests

    func testDOCXEncodeDecodeRoundTrip() throws {
        let records: [[String: Any]] = [["content": "Hello World\n\nThis is a test document.\n\nThird paragraph."]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        XCTAssertTrue(data.count > 100, "DOCX should have substantial size")

        let decoded = try DOCXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        let content = decoded[0]["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Hello World"))
        XCTAssertTrue(content.contains("Third paragraph"))
    }

    func testDOCXEmptyContent() throws {
        let records: [[String: Any]] = [["content": ""]]
        let data = try DOCXFormat.encode(records: records, options: nil)
        XCTAssertTrue(data.count > 0)
        let decoded = try DOCXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
    }

    func testDOCXCustomContentField() throws {
        let records: [[String: Any]] = [["body": "Custom field content"]]
        let options = FormatOptions(fieldMapping: ["content": "body"])
        let data = try DOCXFormat.encode(records: records, options: options)
        let decoded = try DOCXFormat.decode(data: data, options: options)
        XCTAssertEqual(decoded.count, 1)
        let body = decoded[0]["body"] as? String ?? ""
        XCTAssertTrue(body.contains("Custom field content"))
    }

    // MARK: - PPTX Format Tests

    func testPPTXEncodeDecodeRoundTrip() throws {
        let records: [[String: Any]] = [
            ["title": "Slide One", "content": "First slide content"],
            ["title": "Slide Two", "content": "Second slide content"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        XCTAssertTrue(data.count > 100, "PPTX should have substantial size")

        let decoded = try PPTXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0]["title"] as? String, "Slide One")
        XCTAssertEqual(decoded[1]["title"] as? String, "Slide Two")
    }

    func testPPTXEmptyRecords() throws {
        let data = try PPTXFormat.encode(records: [], options: nil)
        XCTAssertTrue(data.count > 0)
    }

    func testPPTXSlideContent() throws {
        let records: [[String: Any]] = [
            ["title": "Features", "content": "Feature A\nFeature B\nFeature C"],
        ]
        let data = try PPTXFormat.encode(records: records, options: nil)
        let decoded = try PPTXFormat.decode(data: data, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["title"] as? String, "Features")
        let content = decoded[0]["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Feature A"))
        XCTAssertTrue(content.contains("Feature C"))
    }
}
