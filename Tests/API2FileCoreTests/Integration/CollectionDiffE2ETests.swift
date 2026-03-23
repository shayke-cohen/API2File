import XCTest
@testable import API2FileCore

/// E2E tests for collection-strategy smart diffing with a live DemoAPIServer.
/// Verifies that editing a CSV/JSON collection file only pushes the changed records,
/// not the entire file.
final class CollectionDiffE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }

    override func setUp() async throws {
        try await super.setUp()
        port = UInt16.random(in: 22000...28000)
        server = DemoAPIServer(port: port)
        try await server.start()
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch { continue }
        }
        await server.reset()
    }

    override func tearDown() async throws {
        await server?.stop()
        try await super.tearDown()
    }

    private func getTasks() async throws -> [[String: Any]] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)/api/tasks"))
        return (try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]]) ?? []
    }

    private func getContacts() async throws -> [[String: Any]] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)/api/contacts"))
        return (try JSONSerialization.jsonObject(with: r.body) as? [[String: Any]]) ?? []
    }

    private func getConfig() async throws -> [String: Any] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)/api/config"))
        return (try JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
    }

    // MARK: - CSV Diff Tests

    func testCSVDiff_UpdateOneRow_OnlyThatRowPushes() async throws {
        // Pull original tasks
        let original = try await getTasks()
        XCTAssertEqual(original.count, 3)

        // Simulate user editing one row in the CSV
        var edited = original
        if let idx = edited.firstIndex(where: { ($0["id"] as? Int) == 1 }) {
            edited[idx]["name"] = "Buy organic groceries"
            edited[idx]["status"] = "done"
        }

        // Diff
        let diff = CollectionDiffer.diff(old: original, new: edited, idField: "id")
        XCTAssertEqual(diff.created.count, 0, "No new rows")
        XCTAssertEqual(diff.updated.count, 1, "Only 1 row changed")
        XCTAssertEqual(diff.deleted.count, 0, "No rows deleted")
        XCTAssertEqual(diff.updated[0].id, "1")
        XCTAssertEqual(diff.updated[0].record["name"] as? String, "Buy organic groceries")

        // Push the update via API
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: diff.updated[0].record)
        _ = try await c.request(APIRequest(method: .PUT, url: "\(baseURL)/api/tasks/\(diff.updated[0].id)", headers: ["Content-Type": "application/json"], body: body))

        // Verify only task 1 changed, others untouched
        let after = try await getTasks()
        XCTAssertEqual(after.count, 3)
        let task1 = after.first(where: { ($0["id"] as? Int) == 1 })
        XCTAssertEqual(task1?["name"] as? String, "Buy organic groceries")
        let task2 = after.first(where: { ($0["id"] as? Int) == 2 })
        XCTAssertEqual(task2?["name"] as? String, "Fix login bug") // unchanged
    }

    func testCSVDiff_AddRow_DetectedAsCreate() async throws {
        let original = try await getTasks()

        // User adds a row (no id)
        var edited = original
        edited.append(["name": "New task", "status": "todo", "priority": "high", "assignee": "Test", "dueDate": "2026-12-31"])

        let diff = CollectionDiffer.diff(old: original, new: edited, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.updated.count, 0)
        XCTAssertEqual(diff.deleted.count, 0)

        // Push create
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: diff.created[0])
        _ = try await c.request(APIRequest(method: .POST, url: "\(baseURL)/api/tasks", headers: ["Content-Type": "application/json"], body: body))

        let after = try await getTasks()
        XCTAssertEqual(after.count, 4)
        XCTAssertTrue(after.contains(where: { ($0["name"] as? String) == "New task" }))
    }

    func testCSVDiff_DeleteRow_DetectedAsDelete() async throws {
        let original = try await getTasks()

        // User deletes task 3
        let edited = original.filter { ($0["id"] as? Int) != 3 }

        let diff = CollectionDiffer.diff(old: original, new: edited, idField: "id")
        XCTAssertEqual(diff.created.count, 0)
        XCTAssertEqual(diff.updated.count, 0)
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.deleted[0], "3")

        // Push delete
        let c = HTTPClient()
        _ = try await c.request(APIRequest(method: .DELETE, url: "\(baseURL)/api/tasks/\(diff.deleted[0])"))

        let after = try await getTasks()
        XCTAssertEqual(after.count, 2)
    }

    func testCSVDiff_MixedOperations() async throws {
        let original = try await getTasks()

        // Edit row 1, add new row, delete row 3
        var edited = original.filter { ($0["id"] as? Int) != 3 }
        if let idx = edited.firstIndex(where: { ($0["id"] as? Int) == 1 }) {
            edited[idx]["status"] = "done"
        }
        edited.append(["name": "Added", "status": "todo", "priority": "low", "assignee": "Bot"])

        let diff = CollectionDiffer.diff(old: original, new: edited, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.summary.contains("1 created"), true)
        XCTAssertEqual(diff.summary.contains("1 updated"), true)
        XCTAssertEqual(diff.summary.contains("1 deleted"), true)
    }

    // MARK: - CSV Round-Trip with Actual Encoding

    func testCSVRoundTrip_EncodeEditDecode_DiffWorks() async throws {
        let original = try await getTasks()

        // Encode to CSV
        let csvData = try CSVFormat.encode(records: original, options: nil)
        var csvString = String(data: csvData, encoding: .utf8)!

        // Edit the CSV text (change "Buy groceries" → "Buy local food")
        csvString = csvString.replacingOccurrences(of: "Buy groceries", with: "Buy local food")

        // Decode back
        let decoded = try CSVFormat.decode(data: csvString.data(using: .utf8)!, options: nil)

        // Diff
        let diff = CollectionDiffer.diff(old: original, new: decoded, idField: "id")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].record["name"] as? String, "Buy local food")
    }

    // MARK: - JSON Array Diff

    func testJSONArrayDiff_EditConfig_DiffDetectsChange() async throws {
        let original = try await getConfig()

        var edited = original
        edited["theme"] = "dark"
        edited["siteName"] = "Updated Site"

        // For single-object JSON, diff as arrays of 1
        let diff = CollectionDiffer.diff(old: [original], new: [edited], idField: "siteName")
        // This is a special case — single object collections are always "updated"
        // since the "id" is the siteName which changed, it'll appear as create + delete
        // For config objects, the push should just PUT the whole thing
        // This test validates the differ handles it
        XCTAssertFalse(diff.isEmpty, "Should detect config changes")
    }

    // MARK: - No-Op Diff (file saved without changes)

    func testCSVDiff_SaveWithoutChanges_NoDiff() async throws {
        let original = try await getTasks()

        // Encode to CSV and decode back (round-trip without edits)
        let csvData = try CSVFormat.encode(records: original, options: nil)
        let decoded = try CSVFormat.decode(data: csvData, options: nil)

        let diff = CollectionDiffer.diff(old: original, new: decoded, idField: "id")
        XCTAssertTrue(diff.isEmpty, "No changes should produce empty diff")
    }
}
