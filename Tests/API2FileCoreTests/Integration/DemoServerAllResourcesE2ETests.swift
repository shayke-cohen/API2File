import XCTest
@testable import API2FileCore

final class DemoServerAllResourcesE2ETests: XCTestCase {

    // MARK: - Properties

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        let randomPort = UInt16.random(in: 19000...29999)
        let candidate_server = DemoAPIServer(port: randomPort)
        try await candidate_server.start()
        server = candidate_server
        port = randomPort

        // Wait for server to bind and verify it's ready with retry
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

        // Reset to clean seed state
        await server.reset()
    }

    override func tearDown() async throws {
        if let server {
            await server.stop()
        }
        server = nil
        port = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() -> HTTPClient {
        HTTPClient()
    }

    private func getList(_ client: HTTPClient, resource: String) async throws -> [[String: Any]] {
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/\(resource)")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let items = json as? [[String: Any]] else {
            XCTFail("Expected array of \(resource)")
            return []
        }
        return items
    }

    private func getItem(_ client: HTTPClient, resource: String, id: Int) async throws -> [String: Any] {
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/\(resource)/\(id)")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let item = json as? [String: Any] else {
            XCTFail("Expected \(resource) dictionary")
            return [:]
        }
        return item
    }

    private func createItem(_ client: HTTPClient, resource: String, payload: [String: Any]) async throws -> APIResponse {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            method: .POST,
            url: "\(baseURL)/api/\(resource)",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        return try await client.request(request)
    }

    private func updateItem(_ client: HTTPClient, resource: String, id: Int, payload: [String: Any]) async throws -> APIResponse {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/\(resource)/\(id)",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        return try await client.request(request)
    }

    private func deleteItem(_ client: HTTPClient, resource: String, id: Int) async throws -> APIResponse {
        let request = APIRequest(
            method: .DELETE,
            url: "\(baseURL)/api/\(resource)/\(id)"
        )
        return try await client.request(request)
    }

    private func getConfig(_ client: HTTPClient) async throws -> [String: Any] {
        let request = APIRequest(method: .GET, url: "\(baseURL)/api/config")
        let response = try await client.request(request)
        XCTAssertEqual(response.statusCode, 200)
        let json = try JSONSerialization.jsonObject(with: response.body)
        guard let config = json as? [String: Any] else {
            XCTFail("Expected config dictionary")
            return [:]
        }
        return config
    }

    private func updateConfig(_ client: HTTPClient, payload: [String: Any]) async throws -> APIResponse {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = APIRequest(
            method: .PUT,
            url: "\(baseURL)/api/config",
            headers: ["Content-Type": "application/json"],
            body: body
        )
        return try await client.request(request)
    }

    // MARK: - Contacts Tests

    func testListContacts() async throws {
        let client = makeClient()
        let contacts = try await getList(client, resource: "contacts")

        XCTAssertEqual(contacts.count, 2, "Should have 2 seed contacts")

        let contact1 = contacts.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(contact1)
        XCTAssertEqual(contact1?["firstName"] as? String, "Alice")
        XCTAssertEqual(contact1?["lastName"] as? String, "Johnson")
        XCTAssertEqual(contact1?["email"] as? String, "alice@example.com")
        XCTAssertEqual(contact1?["phone"] as? String, "+1-555-0101")
        XCTAssertEqual(contact1?["company"] as? String, "Acme Corp")

        let contact2 = contacts.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(contact2)
        XCTAssertEqual(contact2?["firstName"] as? String, "Bob")
        XCTAssertEqual(contact2?["lastName"] as? String, "Smith")
        XCTAssertEqual(contact2?["email"] as? String, "bob@example.com")
        XCTAssertEqual(contact2?["phone"] as? String, "+1-555-0102")
        XCTAssertEqual(contact2?["company"] as? String, "Globex Inc")
    }

    func testCreateContact() async throws {
        let client = makeClient()

        let newContact: [String: Any] = [
            "firstName": "Charlie",
            "lastName": "Brown",
            "email": "charlie@example.com",
            "phone": "+1-555-0103",
            "company": "Peanuts Inc"
        ]
        let createResponse = try await createItem(client, resource: "contacts", payload: newContact)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertNotNil(created)
        XCTAssertEqual(created?["firstName"] as? String, "Charlie")
        XCTAssertEqual(created?["lastName"] as? String, "Brown")
        XCTAssertEqual(created?["email"] as? String, "charlie@example.com")

        let contacts = try await getList(client, resource: "contacts")
        XCTAssertEqual(contacts.count, 3, "Should have 3 contacts after creating one")
    }

    func testUpdateContact() async throws {
        let client = makeClient()

        let updateResponse = try await updateItem(client, resource: "contacts", id: 1, payload: ["email": "alice.new@example.com"])
        XCTAssertEqual(updateResponse.statusCode, 200)

        let contact = try await getItem(client, resource: "contacts", id: 1)
        XCTAssertEqual(contact["email"] as? String, "alice.new@example.com")
        // Other fields remain unchanged
        XCTAssertEqual(contact["firstName"] as? String, "Alice")
        XCTAssertEqual(contact["lastName"] as? String, "Johnson")
        XCTAssertEqual(contact["phone"] as? String, "+1-555-0101")
        XCTAssertEqual(contact["company"] as? String, "Acme Corp")
    }

    func testDeleteContact() async throws {
        let client = makeClient()

        let deleteResponse = try await deleteItem(client, resource: "contacts", id: 2)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let contacts = try await getList(client, resource: "contacts")
        XCTAssertEqual(contacts.count, 1, "Should have 1 contact after deleting one")

        let deleted = contacts.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNil(deleted, "Contact 2 should have been deleted")

        let remaining = contacts.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(remaining, "Contact 1 should still exist")
    }

    // MARK: - Events Tests

    func testListEvents() async throws {
        let client = makeClient()
        let events = try await getList(client, resource: "events")

        XCTAssertEqual(events.count, 3, "Should have 3 seed events")

        let event1 = events.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(event1)
        XCTAssertEqual(event1?["title"] as? String, "Team Standup")
        XCTAssertEqual(event1?["startDate"] as? String, "2026-03-24T09:00:00Z")
        XCTAssertEqual(event1?["endDate"] as? String, "2026-03-24T09:15:00Z")
        XCTAssertEqual(event1?["location"] as? String, "Zoom")
        XCTAssertEqual(event1?["description"] as? String, "Daily sync with the engineering team")
        XCTAssertEqual(event1?["status"] as? String, "confirmed")

        let event2 = events.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(event2)
        XCTAssertEqual(event2?["title"] as? String, "Product Launch")
        XCTAssertEqual(event2?["status"] as? String, "tentative")
        XCTAssertEqual(event2?["location"] as? String, "Main Conference Room")

        let event3 = events.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNotNil(event3)
        XCTAssertEqual(event3?["title"] as? String, "Design Review")
        XCTAssertEqual(event3?["status"] as? String, "confirmed")
        XCTAssertEqual(event3?["location"] as? String, "Room 42")
    }

    func testCreateEvent() async throws {
        let client = makeClient()

        let newEvent: [String: Any] = [
            "title": "Sprint Retrospective",
            "startDate": "2026-03-27T15:00:00Z",
            "endDate": "2026-03-27T16:00:00Z",
            "location": "Room 101",
            "description": "End of sprint retro",
            "status": "confirmed"
        ]
        let createResponse = try await createItem(client, resource: "events", payload: newEvent)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertNotNil(created)
        XCTAssertEqual(created?["title"] as? String, "Sprint Retrospective")
        XCTAssertEqual(created?["location"] as? String, "Room 101")

        let events = try await getList(client, resource: "events")
        XCTAssertEqual(events.count, 4, "Should have 4 events after creating one")
    }

    func testUpdateEvent() async throws {
        let client = makeClient()

        let updateResponse = try await updateItem(client, resource: "events", id: 2, payload: [
            "title": "Product Launch v2",
            "status": "confirmed"
        ])
        XCTAssertEqual(updateResponse.statusCode, 200)

        let event = try await getItem(client, resource: "events", id: 2)
        XCTAssertEqual(event["title"] as? String, "Product Launch v2")
        XCTAssertEqual(event["status"] as? String, "confirmed")
        // Other fields remain unchanged
        XCTAssertEqual(event["location"] as? String, "Main Conference Room")
        XCTAssertEqual(event["startDate"] as? String, "2026-04-15T14:00:00Z")
    }

    func testDeleteEvent() async throws {
        let client = makeClient()

        let deleteResponse = try await deleteItem(client, resource: "events", id: 3)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let events = try await getList(client, resource: "events")
        XCTAssertEqual(events.count, 2, "Should have 2 events after deleting one")

        let deleted = events.first(where: { ($0["id"] as? Int) == 3 })
        XCTAssertNil(deleted, "Event 3 should have been deleted")

        let remaining1 = events.first(where: { ($0["id"] as? Int) == 1 })
        let remaining2 = events.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(remaining1)
        XCTAssertNotNil(remaining2)
    }

    // MARK: - Notes Tests

    func testListNotes() async throws {
        let client = makeClient()
        let notes = try await getList(client, resource: "notes")

        XCTAssertEqual(notes.count, 2, "Should have 2 seed notes")

        let note1 = notes.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(note1)
        XCTAssertEqual(note1?["title"] as? String, "Meeting Notes")
        let content1 = note1?["content"] as? String ?? ""
        XCTAssertTrue(content1.contains("# Meeting Notes"), "Note 1 should contain markdown heading")
        XCTAssertTrue(content1.contains("## Attendees"), "Note 1 should contain Attendees section")
        XCTAssertTrue(content1.contains("- Alice"), "Note 1 should list Alice as attendee")

        let note2 = notes.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(note2)
        XCTAssertEqual(note2?["title"] as? String, "Ideas")
        let content2 = note2?["content"] as? String ?? ""
        XCTAssertTrue(content2.contains("dark mode"), "Note 2 should mention dark mode")
    }

    func testCreateNote() async throws {
        let client = makeClient()

        let markdownContent = "# Architecture Decision\n\n## Context\nWe need to choose a database.\n\n## Decision\nUse **SQLite** for local storage.\n\n- Fast\n- Reliable\n- Zero config"
        let newNote: [String: Any] = [
            "title": "ADR-001",
            "content": markdownContent
        ]
        let createResponse = try await createItem(client, resource: "notes", payload: newNote)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertNotNil(created)
        XCTAssertEqual(created?["title"] as? String, "ADR-001")
        let createdContent = created?["content"] as? String ?? ""
        XCTAssertTrue(createdContent.contains("# Architecture Decision"))
        XCTAssertTrue(createdContent.contains("**SQLite**"))

        let notes = try await getList(client, resource: "notes")
        XCTAssertEqual(notes.count, 3, "Should have 3 notes after creating one")
    }

    func testUpdateNote() async throws {
        let client = makeClient()

        let updatedContent = "# Meeting Notes\n\n## Updated\nNew content after review."
        let updateResponse = try await updateItem(client, resource: "notes", id: 1, payload: [
            "content": updatedContent
        ])
        XCTAssertEqual(updateResponse.statusCode, 200)

        let note = try await getItem(client, resource: "notes", id: 1)
        XCTAssertEqual(note["content"] as? String, updatedContent)
        // Title remains unchanged
        XCTAssertEqual(note["title"] as? String, "Meeting Notes")
    }

    func testDeleteNote() async throws {
        let client = makeClient()

        let deleteResponse = try await deleteItem(client, resource: "notes", id: 2)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let notes = try await getList(client, resource: "notes")
        XCTAssertEqual(notes.count, 1, "Should have 1 note after deleting one")

        let deleted = notes.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNil(deleted, "Note 2 should have been deleted")

        let remaining = notes.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(remaining, "Note 1 should still exist")
    }

    // MARK: - Pages Tests

    func testListPages() async throws {
        let client = makeClient()
        let pages = try await getList(client, resource: "pages")

        XCTAssertEqual(pages.count, 2, "Should have 2 seed pages")

        let page1 = pages.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(page1)
        XCTAssertEqual(page1?["title"] as? String, "Home")
        XCTAssertEqual(page1?["slug"] as? String, "home")
        let html1 = page1?["content"] as? String ?? ""
        XCTAssertTrue(html1.contains("<h1>Welcome</h1>"), "Page 1 should contain HTML heading")
        XCTAssertTrue(html1.contains("<a href=\"/about\">"), "Page 1 should contain About link")

        let page2 = pages.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(page2)
        XCTAssertEqual(page2?["title"] as? String, "About")
        XCTAssertEqual(page2?["slug"] as? String, "about")
        let html2 = page2?["content"] as? String ?? ""
        XCTAssertTrue(html2.contains("<h1>About Us</h1>"), "Page 2 should contain About heading")
        XCTAssertTrue(html2.contains("<strong>small team</strong>"), "Page 2 should contain bold text")
    }

    func testCreatePage() async throws {
        let client = makeClient()

        let htmlContent = "<h1>Contact Us</h1>\n<p>Reach us at <a href=\"mailto:hello@example.com\">hello@example.com</a></p>"
        let newPage: [String: Any] = [
            "title": "Contact",
            "slug": "contact",
            "content": htmlContent
        ]
        let createResponse = try await createItem(client, resource: "pages", payload: newPage)
        XCTAssertEqual(createResponse.statusCode, 201)

        let created = try JSONSerialization.jsonObject(with: createResponse.body) as? [String: Any]
        XCTAssertNotNil(created)
        XCTAssertEqual(created?["title"] as? String, "Contact")
        XCTAssertEqual(created?["slug"] as? String, "contact")
        let createdContent = created?["content"] as? String ?? ""
        XCTAssertTrue(createdContent.contains("<h1>Contact Us</h1>"))

        let pages = try await getList(client, resource: "pages")
        XCTAssertEqual(pages.count, 3, "Should have 3 pages after creating one")
    }

    func testUpdatePage() async throws {
        let client = makeClient()

        let updatedContent = "<h1>Welcome to Our Site</h1>\n<p>Redesigned home page.</p>"
        let updateResponse = try await updateItem(client, resource: "pages", id: 1, payload: [
            "content": updatedContent
        ])
        XCTAssertEqual(updateResponse.statusCode, 200)

        let page = try await getItem(client, resource: "pages", id: 1)
        XCTAssertEqual(page["content"] as? String, updatedContent)
        // Title and slug remain unchanged
        XCTAssertEqual(page["title"] as? String, "Home")
        XCTAssertEqual(page["slug"] as? String, "home")
    }

    func testDeletePage() async throws {
        let client = makeClient()

        let deleteResponse = try await deleteItem(client, resource: "pages", id: 1)
        XCTAssertEqual(deleteResponse.statusCode, 200)

        let pages = try await getList(client, resource: "pages")
        XCTAssertEqual(pages.count, 1, "Should have 1 page after deleting one")

        let deleted = pages.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNil(deleted, "Page 1 should have been deleted")

        let remaining = pages.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(remaining, "Page 2 should still exist")
    }

    // MARK: - Config Tests

    func testGetConfig() async throws {
        let client = makeClient()
        let config = try await getConfig(client)

        XCTAssertEqual(config["siteName"] as? String, "My Demo Site")
        XCTAssertEqual(config["theme"] as? String, "light")
        XCTAssertEqual(config["language"] as? String, "en")
        XCTAssertEqual(config["timezone"] as? String, "America/New_York")
        XCTAssertEqual(config["notifications"] as? Bool, true)
    }

    func testUpdateConfig() async throws {
        let client = makeClient()

        let updateResponse = try await updateConfig(client, payload: [
            "theme": "dark",
            "siteName": "My Updated Site"
        ])
        XCTAssertEqual(updateResponse.statusCode, 200)

        let config = try await getConfig(client)
        XCTAssertEqual(config["theme"] as? String, "dark")
        XCTAssertEqual(config["siteName"] as? String, "My Updated Site")
        // Other fields remain unchanged
        XCTAssertEqual(config["language"] as? String, "en")
        XCTAssertEqual(config["timezone"] as? String, "America/New_York")
        XCTAssertEqual(config["notifications"] as? Bool, true)
    }

    // MARK: - Cross-resource Tests

    func testResetRestoresAllResources() async throws {
        let client = makeClient()

        // Mutate contacts: create one
        let _ = try await createItem(client, resource: "contacts", payload: [
            "firstName": "Temp", "lastName": "User", "email": "temp@test.com", "phone": "", "company": ""
        ])
        var contacts = try await getList(client, resource: "contacts")
        XCTAssertEqual(contacts.count, 3, "Should have 3 contacts after creating one")

        // Mutate events: delete one
        let _ = try await deleteItem(client, resource: "events", id: 1)
        var events = try await getList(client, resource: "events")
        XCTAssertEqual(events.count, 2, "Should have 2 events after deleting one")

        // Mutate notes: create one
        let _ = try await createItem(client, resource: "notes", payload: [
            "title": "Temp Note", "content": "Temporary"
        ])
        var notes = try await getList(client, resource: "notes")
        XCTAssertEqual(notes.count, 3, "Should have 3 notes after creating one")

        // Mutate pages: delete one
        let _ = try await deleteItem(client, resource: "pages", id: 2)
        var pages = try await getList(client, resource: "pages")
        XCTAssertEqual(pages.count, 1, "Should have 1 page after deleting one")

        // Mutate config
        let _ = try await updateConfig(client, payload: ["theme": "dark", "siteName": "Changed"])
        var config = try await getConfig(client)
        XCTAssertEqual(config["theme"] as? String, "dark")

        // Mutate tasks: create one, delete one
        let _ = try await createItem(client, resource: "tasks", payload: [
            "name": "Temp Task", "status": "todo", "priority": "low", "assignee": "", "dueDate": ""
        ])
        let _ = try await deleteItem(client, resource: "tasks", id: 1)
        var tasks = try await getList(client, resource: "tasks")
        XCTAssertEqual(tasks.count, 3, "Should have 3 tasks (3 seed - 1 deleted + 1 created)")

        // Reset
        await server.reset()

        // Verify all resources restored to seed counts
        tasks = try await getList(client, resource: "tasks")
        XCTAssertEqual(tasks.count, 3, "Tasks should be back to 3 seed items after reset")
        let task1 = tasks.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(task1, "Task 1 should be restored")
        XCTAssertEqual(task1?["name"] as? String, "Buy groceries")

        contacts = try await getList(client, resource: "contacts")
        XCTAssertEqual(contacts.count, 2, "Contacts should be back to 2 seed items after reset")

        events = try await getList(client, resource: "events")
        XCTAssertEqual(events.count, 3, "Events should be back to 3 seed items after reset")
        let event1 = events.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertNotNil(event1, "Event 1 should be restored")

        notes = try await getList(client, resource: "notes")
        XCTAssertEqual(notes.count, 2, "Notes should be back to 2 seed items after reset")

        pages = try await getList(client, resource: "pages")
        XCTAssertEqual(pages.count, 2, "Pages should be back to 2 seed items after reset")
        let page2 = pages.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertNotNil(page2, "Page 2 should be restored")

        config = try await getConfig(client)
        XCTAssertEqual(config["theme"] as? String, "light", "Config theme should be restored to light")
        XCTAssertEqual(config["siteName"] as? String, "My Demo Site", "Config siteName should be restored")
    }

    func testAllEndpointsExist() async throws {
        let client = makeClient()

        let endpoints = ["tasks", "contacts", "events", "notes", "pages", "config"]
        for endpoint in endpoints {
            let request = APIRequest(method: .GET, url: "\(baseURL)/api/\(endpoint)")
            let response = try await client.request(request)
            XCTAssertEqual(response.statusCode, 200, "GET /api/\(endpoint) should return 200")

            // Verify the response body is valid JSON
            let json = try JSONSerialization.jsonObject(with: response.body)
            if endpoint == "config" {
                XCTAssertTrue(json is [String: Any], "/api/config should return a JSON object")
            } else {
                XCTAssertTrue(json is [[String: Any]], "/api/\(endpoint) should return a JSON array")
            }
        }
    }
}
