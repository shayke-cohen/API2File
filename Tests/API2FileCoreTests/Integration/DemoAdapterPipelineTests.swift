import XCTest
@testable import API2FileCore

/// E2E pipeline tests for all demo adapter format/resource combinations.
/// Each test: fetch from DemoAPIServer → encode to target format → write to file → read back → verify.
final class DemoAdapterPipelineTests: XCTestCase {

    // MARK: - Properties

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var tempDir: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Random port to avoid conflicts
        let randomPort = UInt16.random(in: 19000...29999)
        let candidateServer = DemoAPIServer(port: randomPort)
        try await candidateServer.start()
        server = candidateServer
        port = randomPort

        // Wait for server to be ready
        var ready = false
        for attempt in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let url = URL(string: "\(baseURL)/api/tasks")!
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    ready = true
                    break
                }
            } catch {
                if attempt == 9 {
                    XCTFail("Server not ready after 10 attempts on port \(randomPort): \(error)")
                }
            }
        }
        guard ready else { return }

        await server.reset()

        // Create temp directory for file output
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let server { await server.stop() }
        server = nil
        port = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() -> HTTPClient { HTTPClient() }

    private func fetchRecords(endpoint: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(baseURL)\(endpoint)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: data)
        if let array = json as? [[String: Any]] { return array }
        if let dict = json as? [String: Any] { return [dict] }
        XCTFail("Unexpected response format from \(endpoint)")
        return []
    }

    // MARK: - TeamBoard: Config → YAML

    func testPullPipeline_ConfigToYAML() async throws {
        let records = try await fetchRecords(endpoint: "/api/config")
        XCTAssertEqual(records.count, 1)

        // Encode to YAML
        let yamlData = try YAMLFormat.encode(records: records, options: nil)

        // Write to file
        let yamlFile = tempDir.appendingPathComponent("settings.yaml")
        try yamlData.write(to: yamlFile)

        // Read back
        let readData = try Data(contentsOf: yamlFile)
        let yamlString = String(data: readData, encoding: .utf8)!

        // Verify YAML structure
        XCTAssertTrue(yamlString.contains("siteName:"), "YAML should contain siteName key")
        XCTAssertTrue(yamlString.contains("My Demo Site"), "YAML should contain site name value")
        XCTAssertTrue(yamlString.contains("theme:"), "YAML should contain theme key")
        XCTAssertTrue(yamlString.contains("light"), "YAML should contain theme value")
        XCTAssertTrue(yamlString.contains("language:"), "YAML should contain language key")

        // Decode back and verify round-trip
        let decoded = try YAMLFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["siteName"] as? String, "My Demo Site")
        XCTAssertEqual(decoded[0]["theme"] as? String, "light")
        XCTAssertEqual(decoded[0]["language"] as? String, "en")
        XCTAssertEqual(decoded[0]["timezone"] as? String, "America/New_York")
    }

    // MARK: - PeopleHub: Contacts → VCF (one-per-record)

    func testPullPipeline_ContactsToVCF() async throws {
        let records = try await fetchRecords(endpoint: "/api/contacts")
        XCTAssertEqual(records.count, 2, "Should have 2 seed contacts")

        // Encode each contact to its own VCF file
        let contactsDir = tempDir.appendingPathComponent("contacts")
        try FileManager.default.createDirectory(at: contactsDir, withIntermediateDirectories: true)

        for record in records {
            let firstName = (record["firstName"] as? String ?? "").lowercased()
            let lastName = (record["lastName"] as? String ?? "").lowercased()
            let filename = "\(firstName)-\(lastName).vcf"

            let vcfData = try VCFFormat.encode(records: [record], options: nil)
            let vcfFile = contactsDir.appendingPathComponent(filename)
            try vcfData.write(to: vcfFile)

            // Read back and verify
            let readData = try Data(contentsOf: vcfFile)
            let vcfString = String(data: readData, encoding: .utf8)!

            XCTAssertTrue(vcfString.contains("BEGIN:VCARD"), "VCF should start with BEGIN:VCARD")
            XCTAssertTrue(vcfString.contains("END:VCARD"), "VCF should end with END:VCARD")
            XCTAssertTrue(vcfString.contains("VERSION:3.0"), "VCF should have version 4.0")

            // Decode back
            let decoded = try VCFFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["firstName"] as? String, record["firstName"] as? String)
            XCTAssertEqual(decoded[0]["lastName"] as? String, record["lastName"] as? String)
            XCTAssertEqual(decoded[0]["email"] as? String, record["email"] as? String)
        }

        // Verify both files exist with correct names
        let files = try FileManager.default.contentsOfDirectory(at: contactsDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["alice-johnson.vcf", "bob-smith.vcf"])
    }

    // MARK: - PeopleHub: Notes → Markdown (one-per-record)

    func testPullPipeline_NotesToMarkdown() async throws {
        let records = try await fetchRecords(endpoint: "/api/notes")
        XCTAssertEqual(records.count, 2, "Should have 2 seed notes")

        let notesDir = tempDir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        for record in records {
            let title = (record["title"] as? String ?? "untitled")
                .lowercased().replacingOccurrences(of: " ", with: "-")
            let filename = "\(title).md"

            let mdData = try MarkdownFormat.encode(records: [record], options: nil)
            let mdFile = notesDir.appendingPathComponent(filename)
            try mdData.write(to: mdFile)

            // Read back and verify content
            let readData = try Data(contentsOf: mdFile)
            let mdString = String(data: readData, encoding: .utf8)!
            let originalContent = record["content"] as? String ?? ""
            XCTAssertTrue(mdString.contains(originalContent), "Markdown file should contain the note content")

            // Decode back
            let decoded = try MarkdownFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["content"] as? String, originalContent)
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["ideas.md", "meeting-notes.md"])
    }

    // MARK: - CalSync: Events → ICS (collection)

    func testPullPipeline_EventsToICS() async throws {
        let records = try await fetchRecords(endpoint: "/api/events")
        XCTAssertEqual(records.count, 3, "Should have 3 seed events")

        // Encode all events to one ICS file
        let icsData = try ICSFormat.encode(records: records, options: nil)
        let icsFile = tempDir.appendingPathComponent("calendar.ics")
        try icsData.write(to: icsFile)

        // Read back and verify ICS structure
        let readData = try Data(contentsOf: icsFile)
        let icsString = String(data: readData, encoding: .utf8)!

        XCTAssertTrue(icsString.contains("BEGIN:VCALENDAR"), "ICS should have VCALENDAR")
        XCTAssertTrue(icsString.contains("END:VCALENDAR"), "ICS should end with VCALENDAR")
        XCTAssertTrue(icsString.contains("VERSION:2.0"), "ICS should have version 2.0")

        // Count VEVENT blocks
        let veventCount = icsString.components(separatedBy: "BEGIN:VEVENT").count - 1
        XCTAssertEqual(veventCount, 3, "Should have 3 VEVENT blocks")

        // Verify specific event content
        XCTAssertTrue(icsString.contains("SUMMARY:Team Standup"), "Should contain Team Standup event")
        XCTAssertTrue(icsString.contains("SUMMARY:Product Launch"), "Should contain Product Launch event")
        XCTAssertTrue(icsString.contains("SUMMARY:Design Review"), "Should contain Design Review event")
        XCTAssertTrue(icsString.contains("LOCATION:Zoom"), "Should contain Zoom location")

        // Decode back and verify round-trip
        let decoded = try ICSFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 events")

        let standup = decoded.first(where: { ($0["title"] as? String) == "Team Standup" })
        XCTAssertNotNil(standup)
        XCTAssertEqual(standup?["location"] as? String, "Zoom")
        XCTAssertEqual(standup?["status"] as? String, "confirmed")
    }

    // MARK: - CalSync: Tasks → CSV as Action Items (collection)

    func testPullPipeline_TasksToCSVAsActionItems() async throws {
        let records = try await fetchRecords(endpoint: "/api/tasks")
        XCTAssertEqual(records.count, 3, "Should have 3 seed tasks")

        // Encode to CSV
        let csvData = try CSVFormat.encode(records: records, options: nil)
        let csvFile = tempDir.appendingPathComponent("action-items.csv")
        try csvData.write(to: csvFile)

        // Read back and decode
        let readData = try Data(contentsOf: csvFile)
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 action items")

        // Spot-check
        let buyGroceries = decoded.first(where: { ($0["name"] as? String) == "Buy groceries" })
        XCTAssertNotNil(buyGroceries)
        XCTAssertEqual(buyGroceries?["assignee"] as? String, "Alice")
    }

    // MARK: - PageCraft: Pages → HTML (one-per-record)

    func testPullPipeline_PagesToHTML() async throws {
        let records = try await fetchRecords(endpoint: "/api/pages")
        XCTAssertEqual(records.count, 2, "Should have 2 seed pages")

        let pagesDir = tempDir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)

        for record in records {
            let slug = record["slug"] as? String ?? "untitled"
            let filename = "\(slug).html"

            let htmlData = try HTMLFormat.encode(records: [record], options: nil)
            let htmlFile = pagesDir.appendingPathComponent(filename)
            try htmlData.write(to: htmlFile)

            // Read back and verify HTML content
            let readData = try Data(contentsOf: htmlFile)
            let htmlString = String(data: readData, encoding: .utf8)!
            let originalContent = record["content"] as? String ?? ""
            XCTAssertEqual(htmlString, originalContent, "HTML file should contain page content")

            // Decode back
            let decoded = try HTMLFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["content"] as? String, originalContent)
        }

        // Verify files exist with slug-based names
        let files = try FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["about.html", "home.html"])
    }

    // MARK: - PageCraft: Notes → Markdown as Blog Posts (one-per-record)

    func testPullPipeline_NotesToMarkdownAsBlogPosts() async throws {
        let records = try await fetchRecords(endpoint: "/api/notes")
        XCTAssertEqual(records.count, 2, "Should have 2 seed notes")

        let blogDir = tempDir.appendingPathComponent("blog")
        try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)

        for record in records {
            let title = (record["title"] as? String ?? "untitled")
                .lowercased().replacingOccurrences(of: " ", with: "-")
            let filename = "\(title).md"

            let mdData = try MarkdownFormat.encode(records: [record], options: nil)
            let mdFile = blogDir.appendingPathComponent(filename)
            try mdData.write(to: mdFile)

            // Read back
            let readData = try Data(contentsOf: mdFile)
            let decoded = try MarkdownFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["content"] as? String, record["content"] as? String)
        }

        // Verify blog/ directory contents
        let files = try FileManager.default.contentsOfDirectory(at: blogDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["ideas.md", "meeting-notes.md"])
    }

    // MARK: - PageCraft: Config → JSON (collection)

    func testPullPipeline_ConfigToJSON() async throws {
        let records = try await fetchRecords(endpoint: "/api/config")
        XCTAssertEqual(records.count, 1)

        // Encode to JSON
        let jsonData = try JSONFormat.encode(records: records, options: nil)
        let jsonFile = tempDir.appendingPathComponent("site.json")
        try jsonData.write(to: jsonFile)

        // Read back and verify JSON structure
        let readData = try Data(contentsOf: jsonFile)
        let decoded = try JSONFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["siteName"] as? String, "My Demo Site")
        XCTAssertEqual(decoded[0]["theme"] as? String, "light")
        XCTAssertEqual(decoded[0]["language"] as? String, "en")
        XCTAssertEqual(decoded[0]["timezone"] as? String, "America/New_York")
        XCTAssertEqual(decoded[0]["notifications"] as? Bool, true)

        // Verify it's valid pretty-printed JSON
        let jsonString = String(data: readData, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"siteName\""), "JSON should have siteName key")
        XCTAssertTrue(jsonString.contains("\n"), "JSON should be pretty-printed")
    }

    // MARK: - DevOps: Services → JSON (one-per-record)

    func testPullPipeline_ServicesToJSON() async throws {
        let records = try await fetchRecords(endpoint: "/api/services")
        XCTAssertEqual(records.count, 3, "Should have 3 seed services")

        let servicesDir = tempDir.appendingPathComponent("services")
        try FileManager.default.createDirectory(at: servicesDir, withIntermediateDirectories: true)

        for record in records {
            let name = (record["name"] as? String ?? "unknown")
            let filename = "\(name).json" // already slugified in seed data

            let jsonData = try JSONFormat.encode(records: [record], options: nil)
            let jsonFile = servicesDir.appendingPathComponent(filename)
            try jsonData.write(to: jsonFile)

            // Read back and decode
            let readData = try Data(contentsOf: jsonFile)
            let decoded = try JSONFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["name"] as? String, name)
            XCTAssertNotNil(decoded[0]["status"])
            XCTAssertNotNil(decoded[0]["version"])
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: servicesDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["auth-service.json", "payment-api.json", "search-index.json"])

        // Spot-check degraded service
        let paymentData = try Data(contentsOf: servicesDir.appendingPathComponent("payment-api.json"))
        let payment = try JSONFormat.decode(data: paymentData, options: nil)
        XCTAssertEqual(payment[0]["status"] as? String, "degraded")
        XCTAssertEqual(payment[0]["version"] as? String, "2.0.4")
    }

    // MARK: - DevOps: Incidents → CSV (collection)

    func testPullPipeline_IncidentsToCSV() async throws {
        let records = try await fetchRecords(endpoint: "/api/incidents")
        XCTAssertEqual(records.count, 4, "Should have 4 seed incidents")

        // Encode to CSV
        let csvData = try CSVFormat.encode(records: records, options: nil)
        let csvFile = tempDir.appendingPathComponent("incidents.csv")
        try csvData.write(to: csvFile)

        // Read back and verify CSV structure
        let readData = try Data(contentsOf: csvFile)
        let csvString = String(data: readData, encoding: .utf8)!
        let lines = csvString.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 5, "Header + 4 data rows")

        let headers = lines[0]
        XCTAssertTrue(headers.contains("severity"), "CSV should have severity column")
        XCTAssertTrue(headers.contains("service"), "CSV should have service column")
        XCTAssertTrue(headers.contains("message"), "CSV should have message column")
        XCTAssertTrue(headers.contains("resolved"), "CSV should have resolved column")

        // Decode and verify content
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 4, "Should decode 4 incidents")

        let critical = decoded.first(where: { ($0["severity"] as? String) == "critical" })
        XCTAssertNotNil(critical)
        XCTAssertEqual(critical?["service"] as? String, "payment-api")
        XCTAssertEqual(critical?["message"] as? String, "Database connection pool exhausted")
    }

    // MARK: - MediaManager: Logos → SVG (one-per-record)

    func testPullPipeline_LogosToSVG() async throws {
        let records = try await fetchRecords(endpoint: "/api/logos")
        XCTAssertEqual(records.count, 3, "Should have 3 seed logos")

        let logosDir = tempDir.appendingPathComponent("logos")
        try FileManager.default.createDirectory(at: logosDir, withIntermediateDirectories: true)

        for record in records {
            let name = record["name"] as? String ?? "untitled"
            let filename = "\(name).svg"

            let svgData = try SVGFormat.encode(records: [record], options: nil)
            let svgFile = logosDir.appendingPathComponent(filename)
            try svgData.write(to: svgFile)

            // Read back and verify SVG content
            let readData = try Data(contentsOf: svgFile)
            let svgString = String(data: readData, encoding: .utf8)!
            XCTAssertTrue(svgString.contains("<svg"), "File should contain SVG markup")
            XCTAssertTrue(svgString.contains("</svg>"), "File should have closing SVG tag")

            // Decode back
            let decoded = try SVGFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertTrue((decoded[0]["content"] as? String ?? "").contains("<svg"))
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: logosDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["app-icon.svg", "badge.svg", "chart-icon.svg"])
    }

    // MARK: - MediaManager: Photos → PNG via Raw/base64 (one-per-record)

    func testPullPipeline_PhotosToPNG() async throws {
        let records = try await fetchRecords(endpoint: "/api/photos")
        XCTAssertEqual(records.count, 3, "Should have 3 seed photos")

        let photosDir = tempDir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)

        for record in records {
            let name = record["name"] as? String ?? "untitled"
            let filename = "\(name).png"

            // RawFormat expects a "data" field with base64 — which our photos have
            let pngData = try RawFormat.encode(records: [record], options: nil)
            let pngFile = photosDir.appendingPathComponent(filename)
            try pngData.write(to: pngFile)

            // Verify the file is a valid PNG (starts with PNG magic bytes)
            let readData = try Data(contentsOf: pngFile)
            XCTAssertGreaterThan(readData.count, 8, "PNG should have at least 8 bytes")
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47] // \x89PNG
            let fileHeader = [UInt8](readData.prefix(4))
            XCTAssertEqual(fileHeader, pngSignature, "\(name).png should start with PNG magic bytes")

            // Decode back to base64
            let decoded = try RawFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            let roundTripBase64 = decoded[0]["data"] as? String ?? ""
            XCTAssertNotNil(Data(base64Encoded: roundTripBase64), "Round-trip base64 should be valid")
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["blue-swatch.png", "green-swatch.png", "red-swatch.png"])
    }

    // MARK: - MediaManager: Documents → PDF via Raw/base64 (one-per-record)

    func testPullPipeline_DocumentsToPDF() async throws {
        let records = try await fetchRecords(endpoint: "/api/documents")
        XCTAssertEqual(records.count, 2, "Should have 2 seed documents")

        let docsDir = tempDir.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        for record in records {
            let name = record["name"] as? String ?? "untitled"
            let filename = "\(name).pdf"

            // RawFormat expects a "data" field with base64
            let pdfData = try RawFormat.encode(records: [record], options: nil)
            let pdfFile = docsDir.appendingPathComponent(filename)
            try pdfData.write(to: pdfFile)

            // Verify the file is a valid PDF (starts with %PDF)
            let readData = try Data(contentsOf: pdfFile)
            let pdfHeader = String(data: readData.prefix(5), encoding: .utf8)
            XCTAssertEqual(pdfHeader, "%PDF-", "\(name).pdf should start with %PDF- header")

            // Decode back
            let decoded = try RawFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["invoice-1042.pdf", "q1-report.pdf"])
    }

    // MARK: - Office: Spreadsheets → XLSX (collection)

    func testPullPipeline_SpreadsheetsToXLSX() async throws {
        let records = try await fetchRecords(endpoint: "/api/spreadsheets")
        XCTAssertEqual(records.count, 3, "Should have 3 seed spreadsheets")

        // Encode to XLSX
        let xlsxData = try XLSXFormat.encode(records: records, options: nil)
        let xlsxFile = tempDir.appendingPathComponent("inventory.xlsx")
        try xlsxData.write(to: xlsxFile)

        // Read back and verify XLSX
        let readData = try Data(contentsOf: xlsxFile)
        XCTAssertTrue(readData.count > 100, "XLSX file should have substantial size")

        // Decode back and verify round-trip
        let decoded = try XLSXFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 spreadsheet rows")

        // Spot-check fields
        let mouse = decoded.first(where: { ($0["name"] as? String) == "Wireless Mouse" })
        XCTAssertNotNil(mouse)
        XCTAssertEqual(mouse?["category"] as? String, "Electronics")

        let cable = decoded.first(where: { ($0["name"] as? String) == "USB-C Cable" })
        XCTAssertNotNil(cable)
        XCTAssertEqual(cable?["category"] as? String, "Accessories")
    }

    // MARK: - Office: Reports → DOCX (one-per-record)

    func testPullPipeline_ReportsToDOCX() async throws {
        let records = try await fetchRecords(endpoint: "/api/reports")
        XCTAssertEqual(records.count, 2, "Should have 2 seed reports")

        let reportsDir = tempDir.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

        for record in records {
            let title = (record["title"] as? String ?? "untitled")
                .lowercased().replacingOccurrences(of: " ", with: "-")
            let filename = "\(title).docx"

            let docxData = try DOCXFormat.encode(records: [record], options: nil)
            let docxFile = reportsDir.appendingPathComponent(filename)
            try docxData.write(to: docxFile)

            // Read back and verify
            let readData = try Data(contentsOf: docxFile)
            XCTAssertTrue(readData.count > 100, "DOCX file should have substantial size")

            // Decode back
            let decoded = try DOCXFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            let content = decoded[0]["content"] as? String ?? ""
            let originalContent = record["content"] as? String ?? ""
            // Verify key content survived round-trip
            let firstLine = originalContent.components(separatedBy: "\n").first ?? ""
            XCTAssertTrue(content.contains(firstLine), "DOCX round-trip should preserve content")
        }

        // Verify files exist
        let files = try FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["project-proposal.docx", "quarterly-review.docx"])
    }

    // MARK: - Office: Presentations → PPTX (collection)

    func testPullPipeline_PresentationsToPPTX() async throws {
        let records = try await fetchRecords(endpoint: "/api/presentations")
        XCTAssertEqual(records.count, 3, "Should have 3 seed presentations")

        // Encode to PPTX
        let pptxData = try PPTXFormat.encode(records: records, options: nil)
        let pptxFile = tempDir.appendingPathComponent("deck.pptx")
        try pptxData.write(to: pptxFile)

        // Read back and verify PPTX
        let readData = try Data(contentsOf: pptxFile)
        XCTAssertTrue(readData.count > 100, "PPTX file should have substantial size")

        // Decode back and verify slide count
        let decoded = try PPTXFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 slides")

        // Spot-check slide content
        let overview = decoded.first(where: { ($0["title"] as? String) == "API2File Overview" })
        XCTAssertNotNil(overview)
        let content = overview?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Sync cloud API data"))

        let roadmap = decoded.first(where: { ($0["title"] as? String) == "Roadmap" })
        XCTAssertNotNil(roadmap)
    }

    // MARK: - Wix: Contacts → CSV (wrapped response with JSONPath extraction)

    func testPullPipeline_WixContactsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/contacts")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Parse wrapped response and extract with JSONPath-like key
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let contacts = dict["contacts"] as? [[String: Any]] else {
            XCTFail("Expected wrapped contacts response")
            return
        }
        XCTAssertEqual(contacts.count, 3)

        // Verify we got the right data before encoding
        // Note: contacts have nested info structure; the real adapter would flatten first.
        // For this test, we just verify the wrapped response extraction and basic CSV output.
        let alice = contacts.first(where: { ($0["primaryEmail"] as? String) == "alice@example.com" })
        XCTAssertNotNil(alice)
        XCTAssertNotNil(alice?["id"] as? String, "Wix contacts use string IDs")

        let info = alice?["info"] as? [String: Any]
        XCTAssertNotNil(info)
        let name = info?["name"] as? [String: Any]
        XCTAssertEqual(name?["first"] as? String, "Alice")
        XCTAssertEqual(name?["last"] as? String, "Johnson")

        // Encode flat fields to CSV (simulating what happens after transforms)
        let flatRecords: [[String: Any]] = contacts.map { contact in
            var flat: [String: Any] = [:]
            flat["id"] = contact["id"]
            flat["primaryEmail"] = contact["primaryEmail"]
            flat["createdDate"] = contact["createdDate"]
            if let info = contact["info"] as? [String: Any],
               let nameInfo = info["name"] as? [String: Any] {
                flat["first"] = nameInfo["first"]
                flat["last"] = nameInfo["last"]
            }
            return flat
        }
        let csvData = try CSVFormat.encode(records: flatRecords, options: nil)
        let csvFile = tempDir.appendingPathComponent("contacts.csv")
        try csvData.write(to: csvFile)

        // Read back and verify
        let readData = try Data(contentsOf: csvFile)
        let csvString = String(data: readData, encoding: .utf8)!
        let lines = csvString.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "Header + 3 data rows")

        let headers = lines[0]
        XCTAssertTrue(headers.contains("_id"), "CSV should have _id column")
        XCTAssertTrue(headers.contains("primaryEmail"), "CSV should have primaryEmail column")
        XCTAssertTrue(headers.contains("first"), "CSV should have first column after flatten")

        // Decode back
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 contacts")

        let aliceDecoded = decoded.first(where: { ($0["primaryEmail"] as? String) == "alice@example.com" })
        XCTAssertNotNil(aliceDecoded)
    }

    // MARK: - Wix: Blog Posts → Markdown (one-per-record)

    func testPullPipeline_WixBlogPostsToMarkdown() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/posts")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Extract from wrapped response
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let posts = dict["posts"] as? [[String: Any]] else {
            XCTFail("Expected wrapped posts response")
            return
        }
        XCTAssertEqual(posts.count, 2)

        let blogDir = tempDir.appendingPathComponent("blog")
        try FileManager.default.createDirectory(at: blogDir, withIntermediateDirectories: true)

        for post in posts {
            let slug = post["slug"] as? String ?? "untitled"
            let filename = "\(slug).md"
            let postId = post["id"] as? String ?? ""

            let detailRequest = APIRequest(method: .GET, url: "\(baseURL)/api/wix/posts/\(postId)")
            let detailResponse = try await client.request(detailRequest)
            XCTAssertEqual(detailResponse.statusCode, 200)
            let detailJSON = try JSONSerialization.jsonObject(with: detailResponse.body)
            guard let detailDict = detailJSON as? [String: Any],
                  let detailedPost = detailDict["post"] as? [String: Any] else {
                XCTFail("Expected wrapped post detail response")
                return
            }

            let mdData = try MarkdownFormat.encode(
                records: [detailedPost],
                options: FormatOptions(fieldMapping: ["content": "contentText"])
            )

            let mdFile = blogDir.appendingPathComponent(filename)
            try mdData.write(to: mdFile)

            let readData = try Data(contentsOf: mdFile)
            let readString = String(data: readData, encoding: .utf8)!
            let content = detailedPost["contentText"] as? String ?? ""
            XCTAssertTrue(readString.contains(content))
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: blogDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["advanced-sync-patterns.md", "getting-started-with-api2file.md"])
    }

    // MARK: - Wix: Products → CSV (wrapped response with nested priceData/stock)

    func testPullPipeline_WixProductsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/products")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Extract from wrapped response
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let products = dict["products"] as? [[String: Any]] else {
            XCTFail("Expected wrapped products response")
            return
        }
        XCTAssertEqual(products.count, 3)

        // Verify raw data extraction
        let mouse = products.first(where: { ($0["name"] as? String) == "Wireless Mouse" })
        XCTAssertNotNil(mouse)
        let priceData = mouse?["priceData"] as? [String: Any]
        XCTAssertEqual(priceData?["currency"] as? String, "USD")
        XCTAssertEqual(priceData?["price"] as? Double, 29.99)
        let stock = mouse?["stock"] as? [String: Any]
        XCTAssertEqual(stock?["inventoryStatus"] as? String, "IN_STOCK")

        // Encode flat fields to CSV (simulating what happens after flatten transforms)
        let flatRecords: [[String: Any]] = products.map { product in
            var flat: [String: Any] = [:]
            flat["id"] = product["id"]
            flat["name"] = product["name"]
            flat["productType"] = product["productType"]
            flat["description"] = product["description"]
            flat["visible"] = product["visible"]
            if let pd = product["priceData"] as? [String: Any] {
                flat["currency"] = pd["currency"]
                flat["price"] = pd["price"]
                flat["discountedPrice"] = pd["discountedPrice"]
            }
            if let st = product["stock"] as? [String: Any] {
                flat["inventoryStatus"] = st["inventoryStatus"]
                flat["quantity"] = st["quantity"]
            }
            return flat
        }
        let csvData = try CSVFormat.encode(records: flatRecords, options: nil)
        let csvFile = tempDir.appendingPathComponent("products.csv")
        try csvData.write(to: csvFile)

        // Read back and verify
        let readData = try Data(contentsOf: csvFile)
        let csvString = String(data: readData, encoding: .utf8)!
        let lines = csvString.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "Header + 3 data rows")

        let headers = lines[0]
        XCTAssertTrue(headers.contains("name"), "CSV should have name column")
        XCTAssertTrue(headers.contains("productType"), "CSV should have productType column")
        XCTAssertTrue(headers.contains("currency"), "CSV should have currency column after flatten")
        XCTAssertTrue(headers.contains("inventoryStatus"), "CSV should have inventoryStatus after flatten")

        // Decode back
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 products")

        let mouseDecoded = decoded.first(where: { ($0["name"] as? String) == "Wireless Mouse" })
        XCTAssertNotNil(mouseDecoded)
        XCTAssertEqual(mouseDecoded?["currency"] as? String, "USD")
    }

    // MARK: - Wix: Media → Raw mirror files

    func testPullPipeline_WixMediaToRawFiles() async throws {
        let mediaURL = URL(string: "\(baseURL)/api/wix/media")!
        let (responseData, response) = try await URLSession.shared.data(from: mediaURL)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: responseData)
        guard let dict = json as? [String: Any],
              let files = dict["files"] as? [[String: Any]] else {
            XCTFail("Expected wrapped media response")
            return
        }
        XCTAssertEqual(files.count, 5)

        let mediaDir = tempDir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        for file in files {
            let displayName = file["displayName"] as? String ?? "asset.bin"
            let url = try XCTUnwrap(URL(string: file["url"] as? String ?? ""))
            let (assetData, assetResponse) = try await URLSession.shared.data(from: url)
            let assetHTTPResponse = try XCTUnwrap(assetResponse as? HTTPURLResponse)
            XCTAssertEqual(assetHTTPResponse.statusCode, 200)

            let decoded = try RawFormat.decode(data: assetData, options: nil)
            let reencoded = try RawFormat.encode(records: decoded, options: nil)
            try reencoded.write(to: mediaDir.appendingPathComponent(displayName))
        }

        let filesOnDisk = try FileManager.default.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)
        let names = filesOnDisk.map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["gallery-shot.png", "homepage-hero.png", "launch-teaser.mp4", "podcast-intro.mp3", "pricing-guide.pdf"])
    }

    // MARK: - Wix: Bookings Services → CSV

    func testPullPipeline_WixBookingsServicesToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/services")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let services = dict["services"] as? [[String: Any]] else {
            XCTFail("Expected wrapped services response")
            return
        }
        XCTAssertEqual(services.count, 2)

        let csvData = try CSVFormat.encode(records: services, options: nil)
        let csvFile = tempDir.appendingPathComponent("services.csv")
        try csvData.write(to: csvFile)

        let readData = try Data(contentsOf: csvFile)
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 2)

        let workshop = decoded.first(where: { ($0["name"] as? String) == "Group Workshop" })
        XCTAssertNotNil(workshop)
        XCTAssertEqual(workshop?["category"] as? String, "Training")
    }

    // MARK: - Wix: Appointments → CSV

    func testPullPipeline_WixAppointmentsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/appointments")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let bookings = dict["bookings"] as? [[String: Any]] else {
            XCTFail("Expected wrapped appointments response")
            return
        }
        XCTAssertEqual(bookings.count, 2)

        let flatRecords: [[String: Any]] = bookings.map { booking in
            var flat: [String: Any] = [:]
            flat["id"] = booking["id"]
            flat["startDate"] = booking["startDate"]
            flat["endDate"] = booking["endDate"]
            flat["status"] = booking["status"]
            if let bookedEntity = booking["bookedEntity"] as? [String: Any] {
                flat["serviceName"] = bookedEntity["title"]
            }
            if let contactDetails = booking["contactDetails"] as? [String: Any] {
                flat["guestFirstName"] = contactDetails["firstName"]
                flat["guestLastName"] = contactDetails["lastName"]
                flat["guestEmail"] = contactDetails["email"]
            }
            return flat
        }

        let csvData = try CSVFormat.encode(records: flatRecords, options: nil)
        let csvFile = tempDir.appendingPathComponent("appointments.csv")
        try csvData.write(to: csvFile)

        let readData = try Data(contentsOf: csvFile)
        let decoded = try CSVFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?["serviceName"] as? String, "One-on-One Consultation")
    }

    // MARK: - Wix: Groups → CSV

    func testPullPipeline_WixGroupsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/groups")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let groups = dict["groups"] as? [[String: Any]] else {
            XCTFail("Expected wrapped groups response")
            return
        }
        XCTAssertEqual(groups.count, 2)

        let flatRecords: [[String: Any]] = groups.map { group in
            var flat = group
            if let settings = group["settings"] as? [String: Any] {
                flat["welcomeMessage"] = settings["memberWelcomeMessage"]
            }
            flat.removeValue(forKey: "settings")
            return flat
        }

        let csvData = try CSVFormat.encode(records: flatRecords, options: nil)
        let csvFile = tempDir.appendingPathComponent("groups.csv")
        try csvData.write(to: csvFile)

        let decoded = try CSVFormat.decode(data: try Data(contentsOf: csvFile), options: nil)
        XCTAssertEqual(decoded.count, 2)
        let founders = decoded.first(where: { ($0["slug"] as? String) == "founders-circle" })
        XCTAssertEqual(founders?["welcomeMessage"] as? String, "Welcome to the founders circle.")
    }

    // MARK: - Wix: Comments → CSV

    func testPullPipeline_WixCommentsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/comments")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let comments = dict["comments"] as? [[String: Any]] else {
            XCTFail("Expected wrapped comments response")
            return
        }
        XCTAssertEqual(comments.count, 2)

        let flatRecords: [[String: Any]] = comments.map { comment in
            var flat: [String: Any] = [:]
            flat["id"] = comment["id"]
            flat["entityId"] = comment["entityId"]
            flat["status"] = comment["status"]
            flat["createdDate"] = comment["createdDate"]
            if let author = comment["author"] as? [String: Any] {
                flat["authorMemberId"] = author["memberId"]
            }
            if let content = comment["content"] as? [String: Any] {
                flat["text"] = content["plainText"]
            }
            return flat
        }

        let csvData = try CSVFormat.encode(records: flatRecords, options: nil)
        let csvFile = tempDir.appendingPathComponent("comments.csv")
        try csvData.write(to: csvFile)

        let decoded = try CSVFormat.decode(data: try Data(contentsOf: csvFile), options: nil)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue((decoded.first?["text"] as? String ?? "").contains("first sync flow"))
    }

    // MARK: - Wix: Bookings → JSON (one-per-record)

    func testPullPipeline_WixBookingsToJSON() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/services")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Extract from wrapped response
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let services = dict["services"] as? [[String: Any]] else {
            XCTFail("Expected wrapped services response")
            return
        }
        XCTAssertEqual(services.count, 2)

        let bookingsDir = tempDir.appendingPathComponent("bookings")
        try FileManager.default.createDirectory(at: bookingsDir, withIntermediateDirectories: true)

        for service in services {
            let name = (service["name"] as? String ?? "unknown")
                .lowercased().replacingOccurrences(of: " ", with: "-")
            let filename = "\(name).json"

            let jsonData = try JSONFormat.encode(records: [service], options: nil)
            let jsonFile = bookingsDir.appendingPathComponent(filename)
            try jsonData.write(to: jsonFile)

            // Read back and decode
            let readData = try Data(contentsOf: jsonFile)
            let decoded = try JSONFormat.decode(data: readData, options: nil)
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0]["name"] as? String, service["name"] as? String)
        }

        // Verify files
        let files = try FileManager.default.contentsOfDirectory(at: bookingsDir, includingPropertiesForKeys: nil)
        let filenames = files.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(filenames, ["group-workshop.json", "one-on-one-consultation.json"])
    }

    // MARK: - Wix: Collections → JSON (collection)

    func testPullPipeline_WixCollectionsToJSON() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/collections")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        // Extract from wrapped response
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let collections = dict["collections"] as? [[String: Any]] else {
            XCTFail("Expected wrapped collections response")
            return
        }
        XCTAssertEqual(collections.count, 3)

        // Encode to JSON (collection — all records in one file)
        let jsonData = try JSONFormat.encode(records: collections, options: nil)
        let jsonFile = tempDir.appendingPathComponent("collections.json")
        try jsonData.write(to: jsonFile)

        // Read back and verify
        let readData = try Data(contentsOf: jsonFile)
        let decoded = try JSONFormat.decode(data: readData, options: nil)
        XCTAssertEqual(decoded.count, 3, "Should decode 3 collections")

        let products = decoded.first(where: { ($0["displayName"] as? String) == "Products" })
        XCTAssertNotNil(products)
        XCTAssertEqual(products?["fields"] as? Int, 12)
        XCTAssertEqual(products?["items"] as? Int, 156)

        let jsonString = String(data: readData, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"displayName\""), "JSON should contain displayName")
        XCTAssertTrue(jsonString.contains("\n"), "JSON should be pretty-printed")
    }

    // MARK: - Wix: Collection Items → CSV

    func testPullPipeline_WixCollectionItemsToCSV() async throws {
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/wix/collections/col-002/items")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let dict = json as? [String: Any],
              let items = dict["dataItems"] as? [[String: Any]] else {
            XCTFail("Expected wrapped collection item response")
            return
        }
        XCTAssertEqual(items.count, 3)

        let csvData = try CSVFormat.encode(records: items, options: nil)
        let csvFile = tempDir.appendingPathComponent("items.csv")
        try csvData.write(to: csvFile)

        let decoded = try CSVFormat.decode(data: try Data(contentsOf: csvFile), options: nil)
        XCTAssertEqual(decoded.count, 3)
        let stickers = decoded.first(where: { ($0["slug"] as? String) == "developer-sticker-pack" })
        XCTAssertEqual(stickers?["status"] as? String, "HIDDEN")
    }
}
