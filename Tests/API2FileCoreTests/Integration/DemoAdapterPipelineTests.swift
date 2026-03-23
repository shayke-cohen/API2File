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
        let client = makeClient()
        let request = APIRequest(method: .GET, url: "\(baseURL)\(endpoint)")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
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
            XCTAssertEqual(mdString, originalContent, "Markdown file should contain the note content")

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
}
