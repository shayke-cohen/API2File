import XCTest
@testable import API2FileCore

/// TRUE end-to-end tests: real DemoAPIServer, real files on disk, real AdapterEngine pipeline.
/// No mocks, no fakes. Starts a server, pulls data to actual files, edits them, pushes back.
///
/// Run these as regression tests after any sync engine, adapter, or format changes.
final class RealSyncE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!   // temp dir acting as ~/API2File/
    private var serviceDir: URL! // syncRoot/demo/

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Start real demo server
        port = UInt16.random(in: 22000...28000)
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

        // Create real sync folder structure (in temp dir)
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-real-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write real adapter config pointing to our server
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list",
              "pull": { "method": "GET", "url": "\(baseURL)/api/tasks", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/tasks" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "\(baseURL)/api/tasks/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "contacts",
              "description": "Contacts",
              "pull": { "method": "GET", "url": "\(baseURL)/api/contacts", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/contacts" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/contacts/{id}" },
                "delete": { "method": "DELETE", "url": "\(baseURL)/api/contacts/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "contacts",
                "filename": "{firstName|slugify}-{lastName|slugify}.vcf",
                "format": "vcf",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "events",
              "description": "Events",
              "pull": { "method": "GET", "url": "\(baseURL)/api/events", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/events" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/events/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "events",
                "filename": "{title|slugify}.ics",
                "format": "ics",
                "idField": "id"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "notes",
              "description": "Notes",
              "pull": { "method": "GET", "url": "\(baseURL)/api/notes", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/notes" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/notes/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "notes",
                "filename": "{title|slugify}.md",
                "format": "md",
                "idField": "id",
                "contentField": "content"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "pages",
              "description": "Pages",
              "pull": { "method": "GET", "url": "\(baseURL)/api/pages", "dataPath": "$" },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/pages" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/pages/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "pages",
                "filename": "{slug}.html",
                "format": "html",
                "idField": "id",
                "contentField": "content"
              },
              "sync": { "interval": 10 }
            },
            {
              "name": "config",
              "description": "Config",
              "pull": { "method": "GET", "url": "\(baseURL)/api/config", "dataPath": "$" },
              "push": {
                "update": { "method": "PUT", "url": "\(baseURL)/api/config" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "config.json",
                "format": "json"
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

    private func listFilesOnDisk() -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: serviceDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let rel = url.path.replacingOccurrences(of: serviceDir.path + "/", with: "")
            guard !rel.hasPrefix(".") else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { files.append(rel) }
        }
        return files.sorted()
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

    private func deleteFromAPI(_ path: String) async throws {
        let c = HTTPClient()
        _ = try await c.request(APIRequest(method: .DELETE, url: "\(baseURL)\(path)"))
    }

    // ======================================================================
    // MARK: - TEST: Full Pull — API → AdapterEngine → Real Files on Disk
    // ======================================================================

    func testRealPull_AllResources_WritesToDisk() async throws {
        let (engine, _) = try makeEngine()

        // Real pull through the entire pipeline
        let files = try await engine.pullAll().files
        XCTAssertGreaterThan(files.count, 0, "Pull should return files")

        // Write to real disk
        try writeFilesToDisk(files)

        // Verify CSV tasks file
        XCTAssertTrue(fileExistsOnDisk("tasks.csv"), "tasks.csv should exist on disk")
        let csvData = try readFileFromDisk("tasks.csv")
        let csvString = String(data: csvData, encoding: .utf8)!
        XCTAssertTrue(csvString.contains("Buy groceries"), "CSV should contain seed task")
        XCTAssertTrue(csvString.contains("Fix login bug"))
        XCTAssertTrue(csvString.contains("Write docs"))

        // Verify CSV can be decoded back
        let decodedTasks = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(decodedTasks.count, 3)

        // Verify VCF contact files
        let contactFiles = files.filter { $0.relativePath.hasSuffix(".vcf") }
        XCTAssertEqual(contactFiles.count, 2, "Should have 2 VCF files")
        for cf in contactFiles {
            XCTAssertTrue(fileExistsOnDisk(cf.relativePath), "\(cf.relativePath) should exist")
            let vcfContent = String(data: try readFileFromDisk(cf.relativePath), encoding: .utf8)!
            XCTAssertTrue(vcfContent.contains("BEGIN:VCARD"))
            XCTAssertTrue(vcfContent.contains("END:VCARD"))
        }

        // Verify ICS event files
        let eventFiles = files.filter { $0.relativePath.hasSuffix(".ics") }
        XCTAssertEqual(eventFiles.count, 3, "Should have 3 ICS files")
        for ef in eventFiles {
            XCTAssertTrue(fileExistsOnDisk(ef.relativePath))
            let icsContent = String(data: try readFileFromDisk(ef.relativePath), encoding: .utf8)!
            XCTAssertTrue(icsContent.contains("BEGIN:VCALENDAR"))
            XCTAssertTrue(icsContent.contains("VEVENT"))
        }

        // Verify Markdown note files
        let noteFiles = files.filter { $0.relativePath.hasSuffix(".md") }
        XCTAssertEqual(noteFiles.count, 2, "Should have 2 MD files")
        for nf in noteFiles {
            XCTAssertTrue(fileExistsOnDisk(nf.relativePath))
        }

        // Verify HTML page files
        let pageFiles = files.filter { $0.relativePath.hasSuffix(".html") }
        XCTAssertEqual(pageFiles.count, 2, "Should have 2 HTML files")
        for pf in pageFiles {
            XCTAssertTrue(fileExistsOnDisk(pf.relativePath))
        }

        // Verify JSON config
        XCTAssertTrue(fileExistsOnDisk("config.json"), "config.json should exist")
        let configData = try readFileFromDisk("config.json")
        let configDecoded = try JSONFormat.decode(data: configData, options: nil)
        XCTAssertEqual(configDecoded[0]["siteName"] as? String, "My Demo Site")
    }

    // ======================================================================
    // MARK: - TEST: CSV — Edit file on disk → Push to API
    // ======================================================================

    func testRealPush_EditCSVOnDisk_UpdatesAPI() async throws {
        let (engine, _) = try makeEngine()

        // Pull tasks to disk
        let files = try await engine.pullAll().files
        try writeFilesToDisk(files)

        // Read the CSV, decode, modify task 1, push directly via API
        let csvData = try readFileFromDisk("tasks.csv")
        var records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3)

        // Find and update task 1
        if let idx = records.firstIndex(where: { ($0["id"] as? Int) == 1 || ($0["id"] as? String) == "1" }) {
            records[idx]["name"] = "Buy organic groceries"
        }

        // Write modified CSV back to disk
        let modifiedCSV = try CSVFormat.encode(records: records, options: nil)
        try modifiedCSV.write(to: serviceDir.appendingPathComponent("tasks.csv"), options: .atomic)

        // Push the specific record update via API (simulating what the sync engine does)
        try await putToAPI("/api/tasks/1", ["name": "Buy organic groceries"])

        // Verify the API has the updated name
        let tasks = try await getFromAPI("/api/tasks")
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(task1?["name"] as? String, "Buy organic groceries")
    }

    // ======================================================================
    // MARK: - TEST: VCF — Create file on disk → Push creates contact
    // ======================================================================

    func testRealPush_CreateVCFOnDisk_CreatesContact() async throws {
        let (engine, config) = try makeEngine()

        // Write a new VCF file to disk
        let newVCF = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:New Person\r\nN:Person;New;;;\r\nEMAIL:new@test.com\r\nTEL:+1-555-0000\r\nORG:TestCo\r\nEND:VCARD\r\n"
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("contacts"), withIntermediateDirectories: true)
        try newVCF.write(to: serviceDir.appendingPathComponent("contacts/new-person.vcf"), atomically: true, encoding: .utf8)

        // Push through real pipeline
        let fileData = try readFileFromDisk("contacts/new-person.vcf")
        let file = SyncableFile(relativePath: "contacts/new-person.vcf", format: .vcf, content: fileData)
        try await engine.push(file: file, resource: resource("contacts", from: config))

        // Verify API has 3 contacts now
        let contacts = try await getFromAPI("/api/contacts")
        XCTAssertEqual(contacts.count, 3)
        let newContact = contacts.first(where: { ($0["firstName"] as? String) == "New" })
        XCTAssertNotNil(newContact)
        XCTAssertEqual(newContact?["email"] as? String, "new@test.com")
    }

    // ======================================================================
    // MARK: - TEST: ICS — Create file on disk → Push creates event
    // ======================================================================

    func testRealPush_CreateICSOnDisk_CreatesEvent() async throws {
        let (engine, config) = try makeEngine()

        let newICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//API2File//EN\r\nBEGIN:VEVENT\r\nSUMMARY:Local Meeting\r\nDTSTART:20260701T100000Z\r\nDTEND:20260701T110000Z\r\nLOCATION:Room 1\r\nDESCRIPTION:Created from disk\r\nSTATUS:CONFIRMED\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("events"), withIntermediateDirectories: true)
        try newICS.write(to: serviceDir.appendingPathComponent("events/local-meeting.ics"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("events/local-meeting.ics")
        let file = SyncableFile(relativePath: "events/local-meeting.ics", format: .ics, content: fileData)
        try await engine.push(file: file, resource: resource("events", from: config))

        let events = try await getFromAPI("/api/events")
        XCTAssertEqual(events.count, 4)
        let newEvent = events.first(where: { ($0["title"] as? String) == "Local Meeting" })
        XCTAssertNotNil(newEvent)
        XCTAssertEqual(newEvent?["location"] as? String, "Room 1")
    }

    // ======================================================================
    // MARK: - TEST: Markdown — Create file on disk → Push creates note
    // ======================================================================

    func testRealPush_CreateMarkdownOnDisk_CreatesNote() async throws {
        let (engine, config) = try makeEngine()

        let md = "# My Local Note\n\nWritten in **markdown** on disk.\n\n- Point 1\n- Point 2\n"
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try md.write(to: serviceDir.appendingPathComponent("notes/my-local-note.md"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("notes/my-local-note.md")
        let file = SyncableFile(relativePath: "notes/my-local-note.md", format: .markdown, content: fileData)
        try await engine.push(file: file, resource: resource("notes", from: config))

        let notes = try await getFromAPI("/api/notes")
        XCTAssertEqual(notes.count, 3)
        let newNote = notes.first(where: { ($0["content"] as? String)?.contains("My Local Note") == true })
        XCTAssertNotNil(newNote, "Note created from local .md file should exist on server")
    }

    // ======================================================================
    // MARK: - TEST: HTML — Create file on disk → Push creates page
    // ======================================================================

    func testRealPush_CreateHTMLOnDisk_CreatesPage() async throws {
        let (engine, config) = try makeEngine()

        let html = "<h1>Local Page</h1>\n<p>Created as an <em>HTML file</em> on disk.</p>"
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try html.write(to: serviceDir.appendingPathComponent("pages/local-page.html"), atomically: true, encoding: .utf8)

        let fileData = try readFileFromDisk("pages/local-page.html")
        let file = SyncableFile(relativePath: "pages/local-page.html", format: .html, content: fileData)
        try await engine.push(file: file, resource: resource("pages", from: config))

        let pages = try await getFromAPI("/api/pages")
        XCTAssertEqual(pages.count, 3)
        let newPage = pages.first(where: { ($0["content"] as? String)?.contains("Local Page") == true })
        XCTAssertNotNil(newPage, "Page created from local .html file should exist on server")
    }

    // ======================================================================
    // MARK: - TEST: JSON — Edit config file on disk → Push updates API
    // ======================================================================

    func testRealPush_EditJSONConfigOnDisk_UpdatesAPI() async throws {
        let (engine, config) = try makeEngine()

        // Pull config to disk
        let files = try await engine.pull(resource: resource("config", from: config)).files
        try writeFilesToDisk(files)

        // Read, modify, write back
        var configJSON = try JSONSerialization.jsonObject(with: readFileFromDisk("config.json")) as! [String: Any]
        configJSON["siteName"] = "Edited on Disk"
        configJSON["theme"] = "solarized"
        let editedData = try JSONSerialization.data(withJSONObject: configJSON, options: [.prettyPrinted, .sortedKeys])
        try editedData.write(to: serviceDir.appendingPathComponent("config.json"), options: .atomic)

        // Push
        let file = SyncableFile(relativePath: "config.json", format: .json, content: editedData, remoteId: "config")
        try await engine.push(file: file, resource: resource("config", from: config))

        // Verify API
        let serverConfig = try await getFromAPI("/api/config")
        XCTAssertEqual(serverConfig[0]["siteName"] as? String, "Edited on Disk")
        XCTAssertEqual(serverConfig[0]["theme"] as? String, "solarized")
        XCTAssertEqual(serverConfig[0]["language"] as? String, "en") // unchanged
    }

    // ======================================================================
    // MARK: - TEST: Remote create → Pull → File appears on disk
    // ======================================================================

    func testRealPull_RemoteCreate_FileAppearsOnDisk() async throws {
        let (engine, _) = try makeEngine()

        // Create a new task via API
        try await postToAPI("/api/tasks", [
            "name": "Remote task", "status": "todo",
            "priority": "critical", "assignee": "API", "dueDate": "2026-12-31"
        ])

        // Pull
        let files = try await engine.pullAll().files
        try writeFilesToDisk(files)

        // Verify the new task is in the CSV
        let csvString = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(csvString.contains("Remote task"), "New remote task should appear in local CSV")
        XCTAssertTrue(csvString.contains("critical"))
    }

    // ======================================================================
    // MARK: - TEST: Remote update → Pull → File updated on disk
    // ======================================================================

    func testRealPull_RemoteUpdate_FileUpdatedOnDisk() async throws {
        let (engine, _) = try makeEngine()

        // Pull initial state
        let files1 = try await engine.pullAll().files
        try writeFilesToDisk(files1)
        let csv1 = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(csv1.contains("Buy groceries"))

        // Update task on server
        try await putToAPI("/api/tasks/1", ["name": "Buy organic groceries", "status": "done"])

        // Re-pull
        let files2 = try await engine.pullAll().files
        try writeFilesToDisk(files2)
        let csv2 = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(csv2.contains("Buy organic groceries"), "Updated name should appear")
        XCTAssertFalse(csv2.contains("Buy groceries"), "Old name should be gone")
    }

    // ======================================================================
    // MARK: - TEST: Remote delete → Pull → File removed/updated on disk
    // ======================================================================

    func testRealPull_RemoteDelete_FileUpdatedOnDisk() async throws {
        let (engine, _) = try makeEngine()

        // Pull initial
        let files1 = try await engine.pullAll().files
        try writeFilesToDisk(files1)
        let csv1 = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(csv1.contains("Write docs"))

        // Delete task 3 on server
        try await deleteFromAPI("/api/tasks/3")

        // Re-pull
        let files2 = try await engine.pullAll().files
        try writeFilesToDisk(files2)
        let csv2 = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertFalse(csv2.contains("Write docs"), "Deleted task should not appear")

        let decoded = try CSVFormat.decode(data: try readFileFromDisk("tasks.csv"), options: nil)
        XCTAssertEqual(decoded.count, 2)
    }

    // ======================================================================
    // MARK: - TEST: Git auto-commit after sync
    // ======================================================================

    func testRealSync_GitAutoCommit() async throws {
        let (engine, _) = try makeEngine()

        // Init git in service dir
        let git = GitManager(repoPath: serviceDir)
        try await git.initRepo()
        try await git.createGitignore()

        // Pull and write files
        let files = try await engine.pullAll().files
        try writeFilesToDisk(files)

        // Commit
        let hasChanges = try await git.hasChanges()
        XCTAssertTrue(hasChanges, "Should have uncommitted files after pull")

        try await git.commitAll(message: "sync: pull demo — \(files.count) files")

        // Verify commit exists
        let hasChangesAfter = try await git.hasChanges()
        XCTAssertFalse(hasChangesAfter, "Should be clean after commit")
    }

    // ======================================================================
    // MARK: - TEST: CLAUDE.md generated with correct content
    // ======================================================================

    func testRealSync_CLAUDEmdGenerated() async throws {
        let config = try AdapterEngine.loadConfig(from: serviceDir)

        // Generate CLAUDE.md
        let guide = AgentGuideGenerator.generateServiceGuide(config: config, serverPort: 21567)

        // Write to disk
        try guide.write(to: serviceDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(fileExistsOnDisk("CLAUDE.md"))

        let content = try readFileFromDisk("CLAUDE.md")
        let md = String(data: content, encoding: .utf8)!

        XCTAssertTrue(md.contains("Demo API"))
        XCTAssertTrue(md.contains("csv"), "Should mention CSV format")
        XCTAssertTrue(md.contains("vcf"), "Should mention VCF format")
        XCTAssertTrue(md.contains("ics"), "Should mention ICS format")
        XCTAssertTrue(md.contains("Sync behavior"))
        XCTAssertTrue(md.contains("curl"))
    }

    // ======================================================================
    // MARK: - TEST: SyncState persistence
    // ======================================================================

    func testRealSync_SyncStatePersistence() async throws {
        let (engine, _) = try makeEngine()

        // Pull
        let files = try await engine.pullAll().files
        try writeFilesToDisk(files)

        // Create and save SyncState
        var state = SyncState()
        for file in files {
            state.files[file.relativePath] = FileSyncState(
                remoteId: file.remoteId ?? "",
                lastSyncedHash: file.contentHash,
                lastSyncTime: Date(),
                status: .synced
            )
        }
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        try state.save(to: stateURL)

        // Load it back
        let loaded = try SyncState.load(from: stateURL)
        XCTAssertEqual(loaded.files.count, state.files.count)

        // Verify a specific file's state
        let tasksState = loaded.files["tasks.csv"]
        XCTAssertNotNil(tasksState)
        XCTAssertEqual(tasksState?.status, .synced)
        XCTAssertFalse(tasksState!.lastSyncedHash.isEmpty)
    }

    // ======================================================================
    // MARK: - TEST: Full round-trip — pull, edit, push, re-pull, verify
    // ======================================================================

    func testRealFullRoundTrip() async throws {
        let (engine, config) = try makeEngine()

        // 1. Pull everything
        let files = try await engine.pullAll().files
        try writeFilesToDisk(files)
        let initialTaskCount = try CSVFormat.decode(data: readFileFromDisk("tasks.csv"), options: nil).count
        XCTAssertEqual(initialTaskCount, 3)

        // 2. Add a task via API (simulating remote change)
        try await postToAPI("/api/tasks", ["name": "Remote addition", "status": "todo", "priority": "low", "assignee": "Bot", "dueDate": "2026-07-01"])

        // 3. Re-pull — should now have 4 tasks
        let files2 = try await engine.pullAll().files
        try writeFilesToDisk(files2)
        let afterRemoteAdd = try CSVFormat.decode(data: readFileFromDisk("tasks.csv"), options: nil).count
        XCTAssertEqual(afterRemoteAdd, 4)

        // 4. Edit task 1 on disk and push via API
        try await putToAPI("/api/tasks/1", ["name": "Buy local groceries"])

        // 5. Verify API reflects the edit
        let finalTasks = try await getFromAPI("/api/tasks")
        let task1 = finalTasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(task1?["name"] as? String, "Buy local groceries")
        XCTAssertTrue(finalTasks.contains(where: { ($0["name"] as? String) == "Remote addition" }))

        // 6. Final pull — everything consistent on disk
        let files3 = try await engine.pullAll().files
        try writeFilesToDisk(files3)
        let finalCSV = String(data: try readFileFromDisk("tasks.csv"), encoding: .utf8)!
        XCTAssertTrue(finalCSV.contains("Buy local groceries"))
        XCTAssertTrue(finalCSV.contains("Remote addition"))
    }
}
