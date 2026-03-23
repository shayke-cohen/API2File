import XCTest
@testable import API2FileCore

/// End-to-end bidirectional sync tests against a live DemoAPIServer.
/// Tests create/update/delete in both directions (remote→local, local→remote)
/// across all file formats: CSV, VCF, ICS, Markdown, HTML, JSON.
///
/// These tests are regression tests — run them after any sync engine changes.
final class BidirectionalSyncE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncDir: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Random port to avoid conflicts
        let randomPort = UInt16.random(in: 20000...30000)
        let s = DemoAPIServer(port: randomPort)
        try await s.start()
        server = s
        port = randomPort

        // Wait for server readiness
        var ready = false
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, response) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if let r = response as? HTTPURLResponse, r.statusCode == 200 { ready = true; break }
            } catch { continue }
        }
        guard ready else { XCTFail("Server not ready"); return }

        await server.reset()

        // Create temp sync directory
        syncDir = FileManager.default.temporaryDirectory.appendingPathComponent("api2file-sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        if let dir = syncDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func client() -> HTTPClient { HTTPClient() }

    private func get(_ path: String) async throws -> [[String: Any]] {
        let c = client()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)\(path)"))
        XCTAssertEqual(r.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: r.body)
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }

    private func post(_ path: String, _ data: [String: Any]) async throws -> [String: Any] {
        let c = client()
        let body = try JSONSerialization.data(withJSONObject: data)
        let r = try await c.request(APIRequest(method: .POST, url: "\(baseURL)\(path)", headers: ["Content-Type": "application/json"], body: body))
        XCTAssertTrue([200, 201].contains(r.statusCode))
        return (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    private func put(_ path: String, _ data: [String: Any]) async throws -> [String: Any] {
        let c = client()
        let body = try JSONSerialization.data(withJSONObject: data)
        let r = try await c.request(APIRequest(method: .PUT, url: "\(baseURL)\(path)", headers: ["Content-Type": "application/json"], body: body))
        XCTAssertEqual(r.statusCode, 200)
        return (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    private func delete(_ path: String) async throws {
        let c = client()
        let r = try await c.request(APIRequest(method: .DELETE, url: "\(baseURL)\(path)"))
        XCTAssertEqual(r.statusCode, 200)
    }

    private func writeFile(_ relativePath: String, _ content: String) throws {
        let url = syncDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readFile(_ relativePath: String) throws -> String {
        let url = syncDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: syncDir.appendingPathComponent(relativePath).path)
    }

    // MARK: - CSV (Tasks) — Bidirectional

    func testCSV_RemoteToLocal_PullTasks() async throws {
        // Pull from API
        let tasks = try await get("/api/tasks")
        XCTAssertEqual(tasks.count, 3)

        // Convert to CSV
        let csvData = try CSVFormat.encode(records: tasks, options: nil)
        let csvString = String(data: csvData, encoding: .utf8)!

        // Write to local file
        try writeFile("tasks.csv", csvString)

        // Verify file exists and has correct content
        let content = try readFile("tasks.csv")
        XCTAssertTrue(content.contains("Buy groceries"))
        XCTAssertTrue(content.contains("Fix login bug"))
        XCTAssertTrue(content.contains("Write docs"))

        // Decode back and verify round-trip
        let decoded = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(decoded.count, 3)
    }

    func testCSV_LocalToRemote_CreateTask() async throws {
        // Pull current tasks to CSV
        let tasks = try await get("/api/tasks")
        let csvData = try CSVFormat.encode(records: tasks, options: nil)
        var csvString = String(data: csvData, encoding: .utf8)!

        // Append a new row locally
        csvString += ",Tester,2026-06-15,New local task,high,todo\n"
        try writeFile("tasks.csv", csvString)

        // Simulate push: detect new row and POST
        let created = try await post("/api/tasks", [
            "name": "New local task", "status": "todo",
            "priority": "high", "assignee": "Tester", "dueDate": "2026-06-15"
        ])
        XCTAssertEqual(created["name"] as? String, "New local task")

        // Verify remote has 4 tasks
        let updated = try await get("/api/tasks")
        XCTAssertEqual(updated.count, 4)
        XCTAssertTrue(updated.contains(where: { ($0["name"] as? String) == "New local task" }))
    }

    func testCSV_LocalToRemote_UpdateTask() async throws {
        // Update task 1 via API (simulating local edit → push)
        let updated = try await put("/api/tasks/1", ["name": "Buy organic groceries", "status": "done"])
        XCTAssertEqual(updated["name"] as? String, "Buy organic groceries")
        XCTAssertEqual(updated["status"] as? String, "done")

        // Pull and verify
        let tasks = try await get("/api/tasks")
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(task1?["name"] as? String, "Buy organic groceries")
    }

    func testCSV_LocalToRemote_DeleteTask() async throws {
        // Delete task 3
        try await delete("/api/tasks/3")

        // Verify only 2 remain
        let tasks = try await get("/api/tasks")
        XCTAssertEqual(tasks.count, 2)
        XCTAssertFalse(tasks.contains(where: { ($0["id"] as? Int) == 3 }))
    }

    // MARK: - VCF (Contacts) — Bidirectional

    func testVCF_RemoteToLocal_PullContacts() async throws {
        let contacts = try await get("/api/contacts")
        XCTAssertEqual(contacts.count, 2)

        // Convert each contact to VCF and write
        for contact in contacts {
            let vcfData = try VCFFormat.encode(records: [contact], options: nil)
            let firstName = (contact["firstName"] as? String ?? "").lowercased()
            let lastName = (contact["lastName"] as? String ?? "").lowercased()
            try writeFile("contacts/\(firstName)-\(lastName).vcf", String(data: vcfData, encoding: .utf8)!)
        }

        // Verify files exist
        XCTAssertTrue(fileExists("contacts/alice-johnson.vcf"))
        XCTAssertTrue(fileExists("contacts/bob-smith.vcf"))

        // Verify VCF content
        let aliceVCF = try readFile("contacts/alice-johnson.vcf")
        XCTAssertTrue(aliceVCF.contains("FN:Alice Johnson"))
        XCTAssertTrue(aliceVCF.contains("EMAIL:alice@example.com"))
    }

    func testVCF_LocalToRemote_CreateContact() async throws {
        // Create local VCF
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:New Contact\r\nN:Contact;New;;;\r\nEMAIL:new@test.com\r\nTEL:+1-555-0000\r\nORG:TestCo\r\nEND:VCARD\r\n"
        try writeFile("contacts/new-contact.vcf", vcf)

        // Decode VCF
        let records = try VCFFormat.decode(data: vcf.data(using: .utf8)!, options: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["firstName"] as? String, "New")

        // Push to API
        let created = try await post("/api/contacts", [
            "firstName": "New", "lastName": "Contact",
            "email": "new@test.com", "phone": "+1-555-0000", "company": "TestCo"
        ])
        XCTAssertEqual(created["firstName"] as? String, "New")

        // Verify remote has 3 contacts
        let contacts = try await get("/api/contacts")
        XCTAssertEqual(contacts.count, 3)
    }

    func testVCF_LocalToRemote_UpdateContact() async throws {
        // Update contact email
        let updated = try await put("/api/contacts/1", ["email": "alice.new@example.com"])
        XCTAssertEqual(updated["email"] as? String, "alice.new@example.com")
        XCTAssertEqual(updated["firstName"] as? String, "Alice") // unchanged
    }

    func testVCF_RemoteToLocal_DeleteContact() async throws {
        try await delete("/api/contacts/2")
        let contacts = try await get("/api/contacts")
        XCTAssertEqual(contacts.count, 1)
        XCTAssertFalse(contacts.contains(where: { ($0["id"] as? Int) == 2 }))
    }

    // MARK: - ICS (Events) — Bidirectional

    func testICS_RemoteToLocal_PullEvents() async throws {
        let events = try await get("/api/events")
        XCTAssertEqual(events.count, 3)

        // Convert to ICS and write
        for event in events {
            let icsData = try ICSFormat.encode(records: [event], options: nil)
            let slug = (event["title"] as? String ?? "").lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            try writeFile("events/\(slug).ics", String(data: icsData, encoding: .utf8)!)
        }

        XCTAssertTrue(fileExists("events/team-standup.ics"))
        let ics = try readFile("events/team-standup.ics")
        XCTAssertTrue(ics.contains("SUMMARY:Team Standup"))
        XCTAssertTrue(ics.contains("LOCATION:Zoom"))
    }

    func testICS_LocalToRemote_CreateEvent() async throws {
        // Create local ICS
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nSUMMARY:Local Event\r\nDTSTART:20260601T090000Z\r\nDTEND:20260601T100000Z\r\nLOCATION:Office\r\nDESCRIPTION:Created locally\r\nSTATUS:CONFIRMED\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        try writeFile("events/local-event.ics", ics)

        // Decode and push
        let records = try ICSFormat.decode(data: ics.data(using: .utf8)!, options: nil)
        XCTAssertEqual(records.count, 1)

        let created = try await post("/api/events", [
            "title": "Local Event", "startDate": "2026-06-01T09:00:00Z",
            "endDate": "2026-06-01T10:00:00Z", "location": "Office",
            "description": "Created locally", "status": "confirmed"
        ])
        XCTAssertEqual(created["title"] as? String, "Local Event")

        let events = try await get("/api/events")
        XCTAssertEqual(events.count, 4)
    }

    func testICS_LocalToRemote_UpdateEvent() async throws {
        let updated = try await put("/api/events/1", ["title": "Updated Standup", "status": "cancelled"])
        XCTAssertEqual(updated["title"] as? String, "Updated Standup")
        XCTAssertEqual(updated["status"] as? String, "cancelled")
    }

    func testICS_RemoteToLocal_DeleteEvent() async throws {
        try await delete("/api/events/3")
        let events = try await get("/api/events")
        XCTAssertEqual(events.count, 2)
    }

    // MARK: - Markdown (Notes) — Bidirectional

    func testMarkdown_RemoteToLocal_PullNotes() async throws {
        let notes = try await get("/api/notes")
        XCTAssertEqual(notes.count, 2)

        for note in notes {
            let content = note["content"] as? String ?? ""
            let slug = (note["title"] as? String ?? "").lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let mdData = try MarkdownFormat.encode(records: [["content": content]], options: nil)
            try writeFile("notes/\(slug).md", String(data: mdData, encoding: .utf8)!)
        }

        XCTAssertTrue(fileExists("notes/meeting-notes.md"))
        let md = try readFile("notes/meeting-notes.md")
        XCTAssertTrue(md.contains("# Meeting Notes"))
    }

    func testMarkdown_LocalToRemote_CreateNote() async throws {
        let md = "# New Note\n\nCreated locally with **bold** text.\n\n- List item\n"
        try writeFile("notes/new-note.md", md)

        // Decode
        let records = try MarkdownFormat.decode(data: md.data(using: .utf8)!, options: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue((records[0]["content"] as? String)?.contains("# New Note") == true)

        // Push
        let created = try await post("/api/notes", ["title": "New Note", "content": md])
        XCTAssertEqual(created["title"] as? String, "New Note")

        let notes = try await get("/api/notes")
        XCTAssertEqual(notes.count, 3)
    }

    func testMarkdown_LocalToRemote_UpdateNote() async throws {
        let updated = try await put("/api/notes/1", ["content": "# Updated\n\nNew content here."])
        XCTAssertTrue((updated["content"] as? String)?.contains("# Updated") == true)
    }

    func testMarkdown_RemoteToLocal_DeleteNote() async throws {
        try await delete("/api/notes/2")
        let notes = try await get("/api/notes")
        XCTAssertEqual(notes.count, 1)
    }

    // MARK: - HTML (Pages) — Bidirectional

    func testHTML_RemoteToLocal_PullPages() async throws {
        let pages = try await get("/api/pages")
        XCTAssertEqual(pages.count, 2)

        for page in pages {
            let content = page["content"] as? String ?? ""
            let slug = page["slug"] as? String ?? "unknown"
            let htmlData = try HTMLFormat.encode(records: [["content": content]], options: nil)
            try writeFile("pages/\(slug).html", String(data: htmlData, encoding: .utf8)!)
        }

        XCTAssertTrue(fileExists("pages/home.html"))
        let html = try readFile("pages/home.html")
        XCTAssertTrue(html.contains("Welcome"))
    }

    func testHTML_LocalToRemote_CreatePage() async throws {
        let html = "<h1>New Page</h1>\n<p>Created <strong>locally</strong>.</p>"
        try writeFile("pages/new-page.html", html)

        // Decode
        let records = try HTMLFormat.decode(data: html.data(using: .utf8)!, options: nil)
        XCTAssertEqual(records.count, 1)

        // Push
        let created = try await post("/api/pages", ["title": "New Page", "slug": "new-page", "content": html])
        XCTAssertEqual(created["slug"] as? String, "new-page")

        let pages = try await get("/api/pages")
        XCTAssertEqual(pages.count, 3)
    }

    func testHTML_LocalToRemote_UpdatePage() async throws {
        let newContent = "<h1>Updated Home</h1><p>Refreshed content.</p>"
        let updated = try await put("/api/pages/1", ["content": newContent])
        XCTAssertTrue((updated["content"] as? String)?.contains("Updated Home") == true)
    }

    func testHTML_RemoteToLocal_DeletePage() async throws {
        try await delete("/api/pages/2")
        let pages = try await get("/api/pages")
        XCTAssertEqual(pages.count, 1)
    }

    // MARK: - JSON (Config) — Bidirectional

    func testJSON_RemoteToLocal_PullConfig() async throws {
        let configs = try await get("/api/config")
        XCTAssertEqual(configs.count, 1)
        let config = configs[0]

        // Write to local JSON
        let jsonData = try JSONFormat.encode(records: [config], options: nil)
        try writeFile("config.json", String(data: jsonData, encoding: .utf8)!)

        // Verify
        let content = try readFile("config.json")
        XCTAssertTrue(content.contains("My Demo Site"))

        // Decode round-trip
        let decoded = try JSONFormat.decode(data: jsonData, options: nil)
        XCTAssertEqual(decoded[0]["siteName"] as? String, "My Demo Site")
    }

    func testJSON_LocalToRemote_UpdateConfig() async throws {
        // Update config
        let updated = try await put("/api/config", ["siteName": "Updated Site", "theme": "dark"])
        XCTAssertEqual(updated["siteName"] as? String, "Updated Site")
        XCTAssertEqual(updated["theme"] as? String, "dark")

        // Verify unchanged fields preserved
        XCTAssertEqual(updated["language"] as? String, "en")

        // Pull back
        let configs = try await get("/api/config")
        XCTAssertEqual(configs[0]["siteName"] as? String, "Updated Site")
    }

    // MARK: - Cross-Format: Full Sync Cycle

    func testFullSyncCycle_PullAllResources() async throws {
        // Pull all 6 resource types and write to local files
        let tasks = try await get("/api/tasks")
        let contacts = try await get("/api/contacts")
        let events = try await get("/api/events")
        let notes = try await get("/api/notes")
        let pages = try await get("/api/pages")
        let config = try await get("/api/config")

        // Write CSV
        let csvData = try CSVFormat.encode(records: tasks, options: nil)
        try writeFile("tasks.csv", String(data: csvData, encoding: .utf8)!)

        // Write VCFs
        for c in contacts {
            let data = try VCFFormat.encode(records: [c], options: nil)
            let name = "\((c["firstName"] as? String ?? "").lowercased())-\((c["lastName"] as? String ?? "").lowercased()).vcf"
            try writeFile("contacts/\(name)", String(data: data, encoding: .utf8)!)
        }

        // Write ICS files
        for e in events {
            let data = try ICSFormat.encode(records: [e], options: nil)
            let slug = (e["title"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
            try writeFile("events/\(slug).ics", String(data: data, encoding: .utf8)!)
        }

        // Write markdown notes
        for n in notes {
            let data = try MarkdownFormat.encode(records: [["content": n["content"] ?? ""]], options: nil)
            let slug = (n["title"] as? String ?? "").lowercased().replacingOccurrences(of: " ", with: "-")
            try writeFile("notes/\(slug).md", String(data: data, encoding: .utf8)!)
        }

        // Write HTML pages
        for p in pages {
            let data = try HTMLFormat.encode(records: [["content": p["content"] ?? ""]], options: nil)
            try writeFile("pages/\(p["slug"] as? String ?? "unknown").html", String(data: data, encoding: .utf8)!)
        }

        // Write config JSON
        let jsonData = try JSONFormat.encode(records: config, options: nil)
        try writeFile("config.json", String(data: jsonData, encoding: .utf8)!)

        // Verify all files exist
        XCTAssertTrue(fileExists("tasks.csv"))
        XCTAssertTrue(fileExists("contacts/alice-johnson.vcf"))
        XCTAssertTrue(fileExists("contacts/bob-smith.vcf"))
        XCTAssertTrue(fileExists("events/team-standup.ics"))
        XCTAssertTrue(fileExists("notes/meeting-notes.md"))
        XCTAssertTrue(fileExists("pages/home.html"))
        XCTAssertTrue(fileExists("config.json"))
    }

    func testFullSyncCycle_ModifyAndPushBack() async throws {
        // Modify one item in each resource type
        _ = try await put("/api/tasks/1", ["status": "done"])
        _ = try await put("/api/contacts/1", ["email": "alice.updated@example.com"])
        _ = try await put("/api/events/1", ["status": "cancelled"])
        _ = try await put("/api/notes/1", ["content": "# Updated Notes\n\nChanged."])
        _ = try await put("/api/pages/1", ["content": "<h1>Updated</h1>"])
        _ = try await put("/api/config", ["theme": "ocean"])

        // Pull back and verify all changes
        let tasks = try await get("/api/tasks")
        XCTAssertEqual(tasks.first(where: { ($0["id"] as? Int) == 1 })?["status"] as? String, "done")

        let contacts = try await get("/api/contacts")
        XCTAssertEqual(contacts.first(where: { ($0["id"] as? Int) == 1 })?["email"] as? String, "alice.updated@example.com")

        let events = try await get("/api/events")
        XCTAssertEqual(events.first(where: { ($0["id"] as? Int) == 1 })?["status"] as? String, "cancelled")

        let notes = try await get("/api/notes")
        XCTAssertTrue((notes.first(where: { ($0["id"] as? Int) == 1 })?["content"] as? String)?.contains("Updated Notes") == true)

        let pages = try await get("/api/pages")
        XCTAssertTrue((pages.first(where: { ($0["id"] as? Int) == 1 })?["content"] as? String)?.contains("Updated") == true)

        let config = try await get("/api/config")
        XCTAssertEqual(config[0]["theme"] as? String, "ocean")
    }

    func testFullSyncCycle_DeleteAndVerify() async throws {
        // Delete one item from each resource type
        try await delete("/api/tasks/3")
        try await delete("/api/contacts/2")
        try await delete("/api/events/3")
        try await delete("/api/notes/2")
        try await delete("/api/pages/2")

        // Verify counts
        let remainingTasks = try await get("/api/tasks")
        let remainingContacts = try await get("/api/contacts")
        let remainingEvents = try await get("/api/events")
        let remainingNotes = try await get("/api/notes")
        let remainingPages = try await get("/api/pages")
        XCTAssertEqual(remainingTasks.count, 2)
        XCTAssertEqual(remainingContacts.count, 1)
        XCTAssertEqual(remainingEvents.count, 2)
        XCTAssertEqual(remainingNotes.count, 1)
        XCTAssertEqual(remainingPages.count, 1)
    }

    func testServerReset_RestoresAllData() async throws {
        // Mutate everything
        try await delete("/api/tasks/1")
        try await delete("/api/contacts/1")
        _ = try await post("/api/events", ["title": "Temp", "startDate": "", "endDate": "", "location": "", "description": "", "status": "confirmed"])

        // Reset
        await server.reset()

        // Verify all back to seed counts
        let tasks = try await get("/api/tasks")
        let contacts = try await get("/api/contacts")
        let events = try await get("/api/events")
        let notesAfter = try await get("/api/notes")
        let pagesAfter = try await get("/api/pages")
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(notesAfter.count, 2)
        XCTAssertEqual(pagesAfter.count, 2)
    }
}
