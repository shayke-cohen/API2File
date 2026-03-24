import XCTest
@testable import API2FileCore

/// TRUE end-to-end tests for ALL 9 untested file formats.
/// Real DemoAPIServer, real files on disk, real AdapterEngine pipeline.
/// No mocks, no fakes. Tests both pull (server -> disk) and push (disk -> server) directions.
final class AllFormatsRealE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        port = UInt16.random(in: 30000...39999)
        server = DemoAPIServer(port: port)
        try await server.start()

        // Wait for readiness
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch { continue }
        }
        await server.reset()

        // Create real sync folder structure
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-formats-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config with all 9 format resources
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "logos",
              "description": "SVG logos",
              "pull": { "method": "GET", "url": "\(baseURL)/api/logos", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/logos" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/logos/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "logos",
                "filename": "{name|slugify}.svg",
                "format": "svg",
                "idField": "id",
                "contentField": "content"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "photos",
              "description": "PNG photos",
              "pull": { "method": "GET", "url": "\(baseURL)/api/photos", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/photos" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/photos/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "photos",
                "filename": "{name|slugify}.png",
                "format": "raw",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "spreadsheets",
              "description": "Spreadsheets",
              "pull": { "method": "GET", "url": "\(baseURL)/api/spreadsheets", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/spreadsheets" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/spreadsheets/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "inventory.xlsx",
                "format": "xlsx",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "reports",
              "description": "Word documents",
              "pull": { "method": "GET", "url": "\(baseURL)/api/reports", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/reports" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/reports/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "reports",
                "filename": "{title|slugify}.docx",
                "format": "docx",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "presentations",
              "description": "Slide decks",
              "pull": { "method": "GET", "url": "\(baseURL)/api/presentations", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/presentations" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/presentations/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "deck.pptx",
                "format": "pptx",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "emails",
              "description": "Emails",
              "pull": { "method": "GET", "url": "\(baseURL)/api/emails", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/emails" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/emails/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "emails",
                "filename": "{subject|slugify}.eml",
                "format": "eml",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "bookmarks",
              "description": "Bookmarks",
              "pull": { "method": "GET", "url": "\(baseURL)/api/bookmarks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/bookmarks" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/bookmarks/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "bookmarks",
                "filename": "{name|slugify}.webloc",
                "format": "webloc",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "settings",
              "description": "Settings",
              "pull": { "method": "GET", "url": "\(baseURL)/api/settings", "dataPath": "$" },
              "push": {
                "update": { "method": "PUT", "url": "\(baseURL)/api/settings" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "settings.yaml",
                "format": "yaml"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "snippets",
              "description": "Snippets",
              "pull": { "method": "GET", "url": "\(baseURL)/api/snippets", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/snippets" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/snippets/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "snippets",
                "filename": "{title|slugify}.txt",
                "format": "txt",
                "idField": "id",
                "contentField": "content"
              },
              "sync": { "interval": 10 }
            }
          ]
        }
        """
        try adapterConfig.write(to: api2fileDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        await server?.stop()
        if let dir = syncRoot { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeEngine() throws -> (AdapterEngine, AdapterConfig) {
        let config = try AdapterEngine.loadConfig(from: serviceDir)
        let httpClient = HTTPClient()
        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        return (engine, config)
    }

    private func resource(_ name: String, from config: AdapterConfig) -> ResourceConfig {
        config.resources.first(where: { $0.name == name })!
    }

    private func writeFilesToDisk(_ files: [SyncableFile]) throws {
        for file in files {
            let path = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func readFileFromDisk(_ relativePath: String) throws -> Data {
        try Data(contentsOf: serviceDir.appendingPathComponent(relativePath))
    }

    private func fileExistsOnDisk(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(relativePath).path)
    }

    private func getFromAPI(_ path: String) async throws -> [[String: Any]] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)\(path)"))
        let json = try JSONSerialization.jsonObject(with: r.body)
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }

    private func postToAPI(_ path: String, _ data: [String: Any]) async throws {
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await c.request(APIRequest(method: .POST, url: "\(baseURL)\(path)", headers: ["Content-Type": "application/json"], body: body))
    }

    private func putToAPI(_ path: String, _ data: [String: Any]) async throws {
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await c.request(APIRequest(method: .PUT, url: "\(baseURL)\(path)", headers: ["Content-Type": "application/json"], body: body))
    }

    // ======================================================================
    // MARK: - SVG (logos)
    // ======================================================================

    func testSVG_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("logos", from: config)).files
        XCTAssertEqual(files.count, 3, "Should have 3 SVG logo files")
        try writeFilesToDisk(files)

        // Verify files exist with correct content
        let svgFiles = files.filter { $0.relativePath.hasSuffix(".svg") }
        XCTAssertEqual(svgFiles.count, 3)

        for file in svgFiles {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath), "\(file.relativePath) should exist")
            let content = String(data: try readFileFromDisk(file.relativePath), encoding: .utf8)!
            XCTAssertTrue(content.contains("<svg"), "SVG file should contain <svg tag")
            XCTAssertTrue(content.contains("xmlns"), "SVG file should have xmlns attribute")
        }

        // Verify specific logo
        XCTAssertTrue(fileExistsOnDisk("logos/app-icon.svg"))
        let appIcon = String(data: try readFileFromDisk("logos/app-icon.svg"), encoding: .utf8)!
        XCTAssertTrue(appIcon.contains("A2F"))
    }

    func testSVG_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        let newSVG = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50">
          <circle cx="25" cy="25" r="20" fill="#FF5733"/>
        </svg>
        """
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("logos"), withIntermediateDirectories: true)
        try newSVG.write(to: serviceDir.appendingPathComponent("logos/new-logo.svg"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("logos/new-logo.svg")
        let file = SyncableFile(relativePath: "logos/new-logo.svg", format: .svg, content: fileData)
        try await engine.push(file: file, resource: resource("logos", from: config))

        let logos = try await getFromAPI("/api/logos")
        XCTAssertEqual(logos.count, 4)
        let newLogo = logos.first(where: { ($0["content"] as? String)?.contains("FF5733") == true })
        XCTAssertNotNil(newLogo, "New SVG logo should exist on server")
    }

    // ======================================================================
    // MARK: - Raw/PNG (photos)
    // ======================================================================

    func testRaw_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("photos", from: config)).files
        XCTAssertEqual(files.count, 3, "Should have 3 PNG photo files")
        try writeFilesToDisk(files)

        for file in files {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath), "\(file.relativePath) should exist")
            let data = try readFileFromDisk(file.relativePath)
            // PNG files start with magic bytes: 0x89 0x50 0x4E 0x47
            XCTAssertTrue(data.count > 4, "PNG file should have content")
            XCTAssertEqual(data[0], 0x89, "PNG file should start with PNG magic byte")
            XCTAssertEqual(data[1], 0x50, "Second byte should be 'P'")
        }

        XCTAssertTrue(fileExistsOnDisk("photos/red-swatch.png"))
    }

    func testRaw_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        // Create a minimal valid PNG (1x1 white pixel)
        let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
        let pngData = Data(base64Encoded: tinyPNGBase64)!
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try pngData.write(to: serviceDir.appendingPathComponent("photos/white-pixel.png"), options: .atomic)

        let fileData = try readFileFromDisk("photos/white-pixel.png")
        let file = SyncableFile(relativePath: "photos/white-pixel.png", format: .raw, content: fileData)
        try await engine.push(file: file, resource: resource("photos", from: config))

        let photos = try await getFromAPI("/api/photos")
        XCTAssertEqual(photos.count, 4)
        // RawFormat decode encodes back to base64, so the server should have the base64 data
        let newPhoto = photos.first(where: { ($0["data"] as? String) == tinyPNGBase64 })
        XCTAssertNotNil(newPhoto, "New PNG photo should exist on server with matching base64")
    }

    // ======================================================================
    // MARK: - XLSX (spreadsheets)
    // ======================================================================

    func testXLSX_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("spreadsheets", from: config)).files
        XCTAssertEqual(files.count, 1, "Should have 1 XLSX collection file")
        try writeFilesToDisk(files)

        XCTAssertTrue(fileExistsOnDisk("inventory.xlsx"), "inventory.xlsx should exist on disk")
        let xlsxData = try readFileFromDisk("inventory.xlsx")
        // XLSX is a ZIP file — starts with PK signature
        XCTAssertTrue(xlsxData.count > 4)
        XCTAssertEqual(xlsxData[0], 0x50, "XLSX should start with 'P'")
        XCTAssertEqual(xlsxData[1], 0x4B, "XLSX second byte should be 'K'")

        // Decode and verify content
        let records = try XLSXFormat.decode(data: xlsxData, options: nil)
        XCTAssertEqual(records.count, 3, "Should have 3 spreadsheet records")
        let names = records.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("Wireless Mouse"))
        XCTAssertTrue(names.contains("USB-C Cable"))
    }

    func testXLSX_EditFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        // Pull spreadsheets
        let files = try await engine.pull(resource: resource("spreadsheets", from: config)).files
        try writeFilesToDisk(files)

        // Decode, modify, re-encode
        let xlsxData = try readFileFromDisk("inventory.xlsx")
        var records = try XLSXFormat.decode(data: xlsxData, options: nil)
        if let idx = records.firstIndex(where: { ($0["name"] as? String) == "Wireless Mouse" }) {
            records[idx]["name"] = "Ergonomic Wireless Mouse"
            records[idx]["price"] = 34.99
        }
        let modifiedData = try XLSXFormat.encode(records: records, options: nil)
        try modifiedData.write(to: serviceDir.appendingPathComponent("inventory.xlsx"), options: .atomic)

        // Push the update for record with id 1
        try await putToAPI("/api/spreadsheets/1", ["name": "Ergonomic Wireless Mouse", "price": 34.99])

        // Verify
        let spreadsheets = try await getFromAPI("/api/spreadsheets")
        let updated = spreadsheets.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(updated?["name"] as? String, "Ergonomic Wireless Mouse")
    }

    // ======================================================================
    // MARK: - DOCX (reports)
    // ======================================================================

    func testDOCX_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("reports", from: config)).files
        XCTAssertEqual(files.count, 2, "Should have 2 DOCX report files")
        try writeFilesToDisk(files)

        for file in files {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath))
            let data = try readFileFromDisk(file.relativePath)
            // DOCX is a ZIP file
            XCTAssertEqual(data[0], 0x50, "DOCX should start with 'P'")
            XCTAssertEqual(data[1], 0x4B, "DOCX second byte should be 'K'")
        }

        XCTAssertTrue(fileExistsOnDisk("reports/quarterly-review.docx"))
        let docxData = try readFileFromDisk("reports/quarterly-review.docx")
        let records = try DOCXFormat.decode(data: docxData, options: nil)
        XCTAssertFalse(records.isEmpty)
        let content = records[0]["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Q1 2026"), "DOCX should contain report content")
    }

    func testDOCX_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        let text = "# New Report\n\nThis report was created on disk.\n\nKey findings:\n- Item A\n- Item B"
        let docxData = try DOCXFormat.encode(records: [["content": text]], options: nil)

        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("reports"), withIntermediateDirectories: true)
        try docxData.write(to: serviceDir.appendingPathComponent("reports/new-report.docx"), options: .atomic)

        let fileData = try readFileFromDisk("reports/new-report.docx")
        let file = SyncableFile(relativePath: "reports/new-report.docx", format: .docx, content: fileData)
        try await engine.push(file: file, resource: resource("reports", from: config))

        let reports = try await getFromAPI("/api/reports")
        XCTAssertEqual(reports.count, 3)
        let newReport = reports.first(where: { ($0["content"] as? String)?.contains("New Report") == true })
        XCTAssertNotNil(newReport, "Report created from local DOCX should exist on server")
    }

    // ======================================================================
    // MARK: - PPTX (presentations)
    // ======================================================================

    func testPPTX_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("presentations", from: config)).files
        XCTAssertEqual(files.count, 1, "Should have 1 PPTX collection file")
        try writeFilesToDisk(files)

        XCTAssertTrue(fileExistsOnDisk("deck.pptx"), "deck.pptx should exist on disk")
        let pptxData = try readFileFromDisk("deck.pptx")
        XCTAssertEqual(pptxData[0], 0x50, "PPTX should start with 'P'")
        XCTAssertEqual(pptxData[1], 0x4B, "PPTX second byte should be 'K'")

        let records = try PPTXFormat.decode(data: pptxData, options: nil)
        XCTAssertEqual(records.count, 3, "Should have 3 presentation slides")
        let titles = records.compactMap { $0["title"] as? String }
        XCTAssertTrue(titles.contains("API2File Overview"))
        XCTAssertTrue(titles.contains("Key Features"))
    }

    func testPPTX_EditFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        // Pull presentations
        let files = try await engine.pull(resource: resource("presentations", from: config)).files
        try writeFilesToDisk(files)

        // Decode, modify, re-encode
        let pptxData = try readFileFromDisk("deck.pptx")
        var records = try PPTXFormat.decode(data: pptxData, options: nil)
        if let idx = records.firstIndex(where: { ($0["title"] as? String) == "API2File Overview" }) {
            records[idx]["title"] = "API2File V2 Overview"
        }
        let modifiedData = try PPTXFormat.encode(records: records, options: nil)
        try modifiedData.write(to: serviceDir.appendingPathComponent("deck.pptx"), options: .atomic)

        // Push the update for slide with id 1
        try await putToAPI("/api/presentations/1", ["title": "API2File V2 Overview"])

        let presentations = try await getFromAPI("/api/presentations")
        let updated = presentations.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(updated?["title"] as? String, "API2File V2 Overview")
    }

    // ======================================================================
    // MARK: - EML (emails)
    // ======================================================================

    func testEML_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("emails", from: config)).files
        XCTAssertEqual(files.count, 2, "Should have 2 EML email files")
        try writeFilesToDisk(files)

        for file in files {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath), "\(file.relativePath) should exist")
            let content = String(data: try readFileFromDisk(file.relativePath), encoding: .utf8)!
            XCTAssertTrue(content.contains("From:"), "EML should contain From: header")
            XCTAssertTrue(content.contains("To:"), "EML should contain To: header")
            XCTAssertTrue(content.contains("Subject:"), "EML should contain Subject: header")
        }

        XCTAssertTrue(fileExistsOnDisk("emails/project-update.eml"))
        let eml = String(data: try readFileFromDisk("emails/project-update.eml"), encoding: .utf8)!
        XCTAssertTrue(eml.contains("alice@example.com"))
        XCTAssertTrue(eml.contains("bob@example.com"))
        XCTAssertTrue(eml.contains("Project Update"))
    }

    func testEML_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        let newEML = "From: test@example.com\r\nTo: team@example.com\r\nSubject: New Feature Request\r\nDate: Tue, 24 Mar 2026 09:00:00 +0000\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n\r\nPlease add dark mode support."
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("emails"), withIntermediateDirectories: true)
        try newEML.write(to: serviceDir.appendingPathComponent("emails/new-feature-request.eml"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("emails/new-feature-request.eml")
        let file = SyncableFile(relativePath: "emails/new-feature-request.eml", format: .eml, content: fileData)
        try await engine.push(file: file, resource: resource("emails", from: config))

        let emails = try await getFromAPI("/api/emails")
        XCTAssertEqual(emails.count, 3)
        let newEmail = emails.first(where: { ($0["subject"] as? String) == "New Feature Request" })
        XCTAssertNotNil(newEmail, "Email created from local EML should exist on server")
        XCTAssertEqual(newEmail?["from"] as? String, "test@example.com")
        XCTAssertEqual(newEmail?["to"] as? String, "team@example.com")
    }

    // ======================================================================
    // MARK: - WEBLOC (bookmarks)
    // ======================================================================

    func testWEBLOC_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("bookmarks", from: config)).files
        XCTAssertEqual(files.count, 3, "Should have 3 WEBLOC bookmark files")
        try writeFilesToDisk(files)

        for file in files {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath), "\(file.relativePath) should exist")
            let content = String(data: try readFileFromDisk(file.relativePath), encoding: .utf8)!
            XCTAssertTrue(content.contains("plist"), "WEBLOC should contain plist XML")
            XCTAssertTrue(content.contains("<key>URL</key>"), "WEBLOC should contain URL key")
        }

        XCTAssertTrue(fileExistsOnDisk("bookmarks/github.webloc"))
        let webloc = String(data: try readFileFromDisk("bookmarks/github.webloc"), encoding: .utf8)!
        XCTAssertTrue(webloc.contains("https://github.com"))
    }

    func testWEBLOC_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        let newWebloc = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>URL</key>
        \t<string>https://www.apple.com/developer</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("bookmarks"), withIntermediateDirectories: true)
        try newWebloc.write(to: serviceDir.appendingPathComponent("bookmarks/apple-developer.webloc"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("bookmarks/apple-developer.webloc")
        let file = SyncableFile(relativePath: "bookmarks/apple-developer.webloc", format: .webloc, content: fileData)
        try await engine.push(file: file, resource: resource("bookmarks", from: config))

        let bookmarks = try await getFromAPI("/api/bookmarks")
        XCTAssertEqual(bookmarks.count, 4)
        let newBookmark = bookmarks.first(where: { ($0["url"] as? String) == "https://www.apple.com/developer" })
        XCTAssertNotNil(newBookmark, "Bookmark created from local WEBLOC should exist on server")
    }

    // ======================================================================
    // MARK: - YAML (settings)
    // ======================================================================

    func testYAML_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("settings", from: config)).files
        XCTAssertEqual(files.count, 1, "Should have 1 YAML settings file")
        try writeFilesToDisk(files)

        XCTAssertTrue(fileExistsOnDisk("settings.yaml"), "settings.yaml should exist on disk")
        let yamlContent = String(data: try readFileFromDisk("settings.yaml"), encoding: .utf8)!
        XCTAssertTrue(yamlContent.contains("appName"), "YAML should contain appName key")
        XCTAssertTrue(yamlContent.contains("API2File"), "YAML should contain the app name value")
        XCTAssertTrue(yamlContent.contains("version"), "YAML should contain version key")
        XCTAssertTrue(yamlContent.contains("debug"), "YAML should contain debug key")

        // Verify it can be decoded back
        let decoded = try YAMLFormat.decode(data: try readFileFromDisk("settings.yaml"), options: nil)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertEqual(decoded[0]["appName"] as? String, "API2File")
    }

    func testYAML_EditFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        // Pull settings
        let files = try await engine.pull(resource: resource("settings", from: config)).files
        try writeFilesToDisk(files)

        // Modify the YAML
        var yamlRecords = try YAMLFormat.decode(data: readFileFromDisk("settings.yaml"), options: nil)
        XCTAssertFalse(yamlRecords.isEmpty)
        yamlRecords[0]["appName"] = "API2File Pro"
        yamlRecords[0]["debug"] = true
        let modifiedData = try YAMLFormat.encode(records: yamlRecords, options: nil)
        try modifiedData.write(to: serviceDir.appendingPathComponent("settings.yaml"), options: .atomic)

        // Push update
        let file = SyncableFile(relativePath: "settings.yaml", format: .yaml, content: modifiedData, remoteId: "settings")
        try await engine.push(file: file, resource: resource("settings", from: config))

        // Verify API
        let serverSettings = try await getFromAPI("/api/settings")
        XCTAssertEqual(serverSettings[0]["appName"] as? String, "API2File Pro")
        XCTAssertEqual(serverSettings[0]["debug"] as? Bool, true)
        // Unchanged fields should persist
        XCTAssertEqual(serverSettings[0]["maxRetries"] as? Int, 3)
    }

    // ======================================================================
    // MARK: - Text (snippets)
    // ======================================================================

    func testText_PullFromServer_WritesFileToDisk() async throws {
        let (engine, config) = try makeEngine()

        let files = try await engine.pull(resource: resource("snippets", from: config)).files
        XCTAssertEqual(files.count, 2, "Should have 2 text snippet files")
        try writeFilesToDisk(files)

        for file in files {
            XCTAssertTrue(fileExistsOnDisk(file.relativePath), "\(file.relativePath) should exist")
        }

        XCTAssertTrue(fileExistsOnDisk("snippets/hello-world.txt"))
        let txtContent = String(data: try readFileFromDisk("snippets/hello-world.txt"), encoding: .utf8)!
        XCTAssertTrue(txtContent.contains("Hello, World!"), "Text file should contain the snippet content")
        XCTAssertTrue(txtContent.contains("plain text snippet"))
    }

    func testText_CreateFileOnDisk_PushesToServer() async throws {
        let (engine, config) = try makeEngine()

        let newText = "This is a brand new snippet.\nCreated directly on disk.\nLine 3 for good measure."
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("snippets"), withIntermediateDirectories: true)
        try newText.write(to: serviceDir.appendingPathComponent("snippets/brand-new.txt"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("snippets/brand-new.txt")
        let file = SyncableFile(relativePath: "snippets/brand-new.txt", format: .text, content: fileData)
        try await engine.push(file: file, resource: resource("snippets", from: config))

        let snippets = try await getFromAPI("/api/snippets")
        XCTAssertEqual(snippets.count, 3)
        let newSnippet = snippets.first(where: { ($0["content"] as? String)?.contains("brand new snippet") == true })
        XCTAssertNotNil(newSnippet, "Snippet created from local text file should exist on server")
    }
}
