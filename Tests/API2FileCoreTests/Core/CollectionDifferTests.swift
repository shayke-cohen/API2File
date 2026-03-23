import XCTest
@testable import API2FileCore

final class CollectionDifferTests: XCTestCase {

    // MARK: - No Changes

    func testIdenticalRecords_NoChanges() {
        let records: [[String: Any]] = [
            ["id": 1, "name": "Alice", "email": "alice@test.com"],
            ["id": 2, "name": "Bob", "email": "bob@test.com"],
        ]
        let diff = CollectionDiffer.diff(old: records, new: records, idField: "id")
        XCTAssertTrue(diff.isEmpty)
        XCTAssertEqual(diff.summary, "no changes")
    }

    func testEmptyToEmpty_NoChanges() {
        let diff = CollectionDiffer.diff(old: [], new: [], idField: "id")
        XCTAssertTrue(diff.isEmpty)
    }

    // MARK: - Creates

    func testNewRecordWithNoId_DetectedAsCreate() {
        let old: [[String: Any]] = [["id": 1, "name": "Alice"]]
        let new: [[String: Any]] = [["id": 1, "name": "Alice"], ["name": "Bob"]]  // no id = new
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.created[0]["name"] as? String, "Bob")
        XCTAssertTrue(diff.updated.isEmpty)
        XCTAssertTrue(diff.deleted.isEmpty)
    }

    func testNewRecordWithUnknownId_DetectedAsCreate() {
        let old: [[String: Any]] = [["id": 1, "name": "Alice"]]
        let new: [[String: Any]] = [["id": 1, "name": "Alice"], ["id": 99, "name": "New"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.created[0]["name"] as? String, "New")
    }

    func testMultipleCreates() {
        let old: [[String: Any]] = []
        let new: [[String: Any]] = [["name": "A"], ["name": "B"], ["name": "C"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.created.count, 3)
    }

    // MARK: - Updates

    func testFieldChanged_DetectedAsUpdate() {
        let old: [[String: Any]] = [["id": 1, "name": "Alice", "status": "active"]]
        let new: [[String: Any]] = [["id": 1, "name": "Alice", "status": "inactive"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertTrue(diff.created.isEmpty)
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "1")
        XCTAssertEqual(diff.updated[0].record["status"] as? String, "inactive")
        XCTAssertTrue(diff.deleted.isEmpty)
    }

    func testMultipleFieldsChanged() {
        let old: [[String: Any]] = [["id": 1, "name": "Old", "email": "old@test.com"]]
        let new: [[String: Any]] = [["id": 1, "name": "New", "email": "new@test.com"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.updated.count, 1)
    }

    func testNoFieldChanged_NotDetectedAsUpdate() {
        let old: [[String: Any]] = [["id": 1, "name": "Same"]]
        let new: [[String: Any]] = [["id": 1, "name": "Same"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertTrue(diff.isEmpty)
    }

    // MARK: - Deletes

    func testRecordRemoved_DetectedAsDelete() {
        let old: [[String: Any]] = [
            ["id": 1, "name": "Alice"],
            ["id": 2, "name": "Bob"],
        ]
        let new: [[String: Any]] = [["id": 1, "name": "Alice"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertTrue(diff.created.isEmpty)
        XCTAssertTrue(diff.updated.isEmpty)
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.deleted[0], "2")
    }

    func testAllDeleted() {
        let old: [[String: Any]] = [["id": 1, "name": "A"], ["id": 2, "name": "B"]]
        let new: [[String: Any]] = []
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.deleted.count, 2)
    }

    // MARK: - Mixed Operations

    func testCreateUpdateDelete_Together() {
        let old: [[String: Any]] = [
            ["id": 1, "name": "Keep", "status": "active"],
            ["id": 2, "name": "Change", "status": "active"],
            ["id": 3, "name": "Remove", "status": "active"],
        ]
        let new: [[String: Any]] = [
            ["id": 1, "name": "Keep", "status": "active"],      // unchanged
            ["id": 2, "name": "Changed", "status": "inactive"],  // updated
            ["name": "Brand New"],                                 // created (no id)
        ]
        // id: 3 is missing = deleted

        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.created[0]["name"] as? String, "Brand New")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "2")
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.deleted[0], "3")
    }

    // MARK: - String vs Int IDs

    func testStringIds() {
        let old: [[String: Any]] = [["id": "abc", "name": "Old"]]
        let new: [[String: Any]] = [["id": "abc", "name": "New"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "abc")
    }

    func testIntIdMatchesStringId() {
        // CSV decodes "1" as Int, but old record might have String "1"
        let old: [[String: Any]] = [["id": "1", "name": "Old"]]
        let new: [[String: Any]] = [["id": 1, "name": "New"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertEqual(diff.updated.count, 1) // Should match despite type difference
    }

    // MARK: - Custom ID Field

    func testCustomIdField() {
        let old: [[String: Any]] = [["taskId": "t1", "name": "Old"]]
        let new: [[String: Any]] = [["taskId": "t1", "name": "New"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "taskId")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "t1")
    }

    // MARK: - CSV Round-Trip Scenario

    func testCSVEditScenario() throws {
        // Simulate: pull CSV, user edits one row, adds one row, deletes one row
        let originalRecords: [[String: Any]] = [
            ["id": 1, "name": "Buy groceries", "status": "todo"],
            ["id": 2, "name": "Fix bug", "status": "in-progress"],
            ["id": 3, "name": "Write docs", "status": "done"],
        ]

        // User edited the CSV:
        let editedRecords: [[String: Any]] = [
            ["id": 1, "name": "Buy organic groceries", "status": "done"],  // updated name + status
            ["id": 2, "name": "Fix bug", "status": "in-progress"],        // unchanged
            // id: 3 deleted
            ["name": "New task", "status": "todo"],                         // new (no id)
        ]

        let diff = CollectionDiffer.diff(old: originalRecords, new: editedRecords, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.created[0]["name"] as? String, "New task")
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "1")
        XCTAssertEqual(diff.updated[0].record["name"] as? String, "Buy organic groceries")
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.deleted[0], "3")
    }

    // MARK: - JSON Array Scenario

    func testJSONArrayEditScenario() throws {
        let original: [[String: Any]] = [
            ["id": "srv-1", "name": "auth-service", "status": "healthy"],
            ["id": "srv-2", "name": "payment-api", "status": "degraded"],
        ]
        let edited: [[String: Any]] = [
            ["id": "srv-1", "name": "auth-service", "status": "healthy"],  // unchanged
            ["id": "srv-2", "name": "payment-api", "status": "healthy"],   // status fixed
            ["id": "srv-3", "name": "new-service", "status": "healthy"],   // new with id
        ]

        let diff = CollectionDiffer.diff(old: original, new: edited, idField: "id")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.updated.count, 1)
        XCTAssertEqual(diff.updated[0].id, "srv-2")
        XCTAssertTrue(diff.deleted.isEmpty)
    }

    // MARK: - Summary

    func testSummaryFormatting() {
        let old: [[String: Any]] = [["id": 1, "x": "a"], ["id": 2, "x": "b"]]
        let new: [[String: Any]] = [["id": 1, "x": "changed"], ["x": "new"]]  // 1 updated, 1 created, 1 deleted
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id")
        XCTAssertTrue(diff.summary.contains("created"))
        XCTAssertTrue(diff.summary.contains("updated"))
        XCTAssertTrue(diff.summary.contains("deleted"))
    }
}
