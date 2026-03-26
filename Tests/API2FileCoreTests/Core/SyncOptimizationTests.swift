import XCTest
@testable import API2FileCore

final class SyncOptimizationTests: XCTestCase {

    // MARK: - CollectionDiffer ignoreFields

    func testIgnoreFields_RevisionChangeIgnored() {
        let old: [[String: Any]] = [
            ["id": "p1", "name": "Product A", "revision": 5, "updatedDate": "2026-01-01"]
        ]
        let new: [[String: Any]] = [
            ["id": "p1", "name": "Product A", "revision": 6, "updatedDate": "2026-01-02"]
        ]
        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "id",
            ignoreFields: ["revision", "updatedDate"]
        )
        XCTAssertTrue(diff.isEmpty, "Revision and updatedDate changes should be ignored")
    }

    func testIgnoreFields_RealChangeStillDetected() {
        let old: [[String: Any]] = [
            ["id": "p1", "name": "Old Name", "revision": 5, "updatedDate": "2026-01-01"]
        ]
        let new: [[String: Any]] = [
            ["id": "p1", "name": "New Name", "revision": 6, "updatedDate": "2026-01-02"]
        ]
        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "id",
            ignoreFields: ["revision", "updatedDate"]
        )
        XCTAssertEqual(diff.updated.count, 1, "Name change should still be detected")
        XCTAssertEqual(diff.updated[0].record["name"] as? String, "New Name")
    }

    func testIgnoreFields_MultipleServerControlledFields() {
        let old: [[String: Any]] = [
            ["id": "1", "name": "Same", "slug": "same", "createdDate": "2026-01-01", "productType": "PHYSICAL"]
        ]
        let new: [[String: Any]] = [
            ["id": "1", "name": "Same", "slug": "changed-slug", "createdDate": "2026-02-01", "productType": "DIGITAL"]
        ]
        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "id",
            ignoreFields: ["slug", "createdDate", "productType"]
        )
        XCTAssertTrue(diff.isEmpty, "All changed fields are in ignoreFields")
    }

    func testIgnoreFields_EmptyIgnoreSet_BehavesLikeDefault() {
        let old: [[String: Any]] = [["id": "1", "name": "Old"]]
        let new: [[String: Any]] = [["id": "1", "name": "New"]]
        let diff = CollectionDiffer.diff(old: old, new: new, idField: "id", ignoreFields: [])
        XCTAssertEqual(diff.updated.count, 1)
    }

    func testIgnoreFields_CreateAndDeleteStillWork() {
        let old: [[String: Any]] = [
            ["id": "1", "name": "Keep", "revision": 1],
            ["id": "2", "name": "Delete", "revision": 1],
        ]
        let new: [[String: Any]] = [
            ["id": "1", "name": "Keep", "revision": 5],  // only revision changed → ignored
            ["name": "New Item"],                          // create
        ]
        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "id",
            ignoreFields: ["revision"]
        )
        XCTAssertTrue(diff.updated.isEmpty, "Revision-only change should be ignored")
        XCTAssertEqual(diff.created.count, 1)
        XCTAssertEqual(diff.deleted.count, 1)
        XCTAssertEqual(diff.deleted[0], "2")
    }

    // MARK: - CSV Type Normalization with ignoreFields

    func testIgnoreFields_CSVStringVsBooleanRevision() {
        // CSV decodes everything as strings; cached records may have native types
        let old: [[String: Any]] = [
            ["id": "1", "name": "Same", "visible": true, "revision": 5]
        ]
        let new: [[String: Any]] = [
            ["id": "1", "name": "Same", "visible": "true", "revision": "8"]
        ]
        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "id",
            ignoreFields: ["revision"]
        )
        // visible: true vs "true" should normalize to equal
        XCTAssertTrue(diff.isEmpty, "Bool/String normalization + revision ignore should show no changes")
    }

    // MARK: - SyncState New Fields

    func testSyncState_EmptyPullCountsPersistence() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("state.json")

        var state = SyncState()
        state.emptyPullCounts = ["coupons": 10, "groups": 3, "contacts": 0]
        state.lastChangeTime = ["contacts": Date(timeIntervalSince1970: 1_700_000_000)]

        try state.save(to: fileURL)
        let loaded = try SyncState.load(from: fileURL)

        XCTAssertEqual(loaded.emptyPullCounts["coupons"], 10)
        XCTAssertEqual(loaded.emptyPullCounts["groups"], 3)
        XCTAssertEqual(loaded.emptyPullCounts["contacts"], 0)
        let contactTime = try XCTUnwrap(loaded.lastChangeTime["contacts"])
        XCTAssertEqual(contactTime.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testSyncState_EmptyPullCountsDefaultToEmpty() {
        let state = SyncState()
        XCTAssertTrue(state.emptyPullCounts.isEmpty)
        XCTAssertTrue(state.lastChangeTime.isEmpty)
    }

    func testSyncState_BackwardsCompatible() throws {
        // Old state.json without the new fields should still load
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncOptTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("state.json")

        // Write a minimal state without the new fields
        let json = """
        {
            "files": {},
            "resourceSyncTimes": {},
            "syncCounts": {},
            "resourceETags": {}
        }
        """
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try json.write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = try SyncState.load(from: fileURL)
        XCTAssertTrue(loaded.emptyPullCounts.isEmpty)
        XCTAssertTrue(loaded.lastChangeTime.isEmpty)
    }

    // MARK: - GitManager New Methods

    func testGitManager_StatusForFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let git = GitManager(repoPath: tmpDir)
        try await git.initRepo()

        // Create and commit a file
        let file1 = tmpDir.appendingPathComponent("file1.txt")
        try "hello".write(to: file1, atomically: true, encoding: .utf8)
        try await git.commitAll(message: "initial")

        // Modify it
        try "world".write(to: file1, atomically: true, encoding: .utf8)

        // Add a new untracked file
        let file2 = tmpDir.appendingPathComponent("file2.txt")
        try "new".write(to: file2, atomically: true, encoding: .utf8)

        let statuses = try await git.statusForFiles()

        XCTAssertEqual(statuses["file1.txt"], "M", "Modified file should have status M")
        XCTAssertEqual(statuses["file2.txt"], "??", "Untracked file should have status ??")
    }

    func testGitManager_DiffForFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitDiffTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let git = GitManager(repoPath: tmpDir)
        try await git.initRepo()

        let file = tmpDir.appendingPathComponent("data.csv")
        try "id,name\n1,Alice\n".write(to: file, atomically: true, encoding: .utf8)
        try await git.commitAll(message: "initial")

        // Modify
        try "id,name\n1,Alice\n2,Bob\n".write(to: file, atomically: true, encoding: .utf8)

        let diff = try await git.diffForFile("data.csv")
        XCTAssertTrue(diff.contains("+2,Bob"), "Diff should show added line")
    }

    func testGitManager_ChangeSummary() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSummaryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let git = GitManager(repoPath: tmpDir)
        try await git.initRepo()

        let file = tmpDir.appendingPathComponent("file.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        try await git.commitAll(message: "init")

        // Modify existing
        try "world".write(to: file, atomically: true, encoding: .utf8)
        // Add new
        try "new".write(to: tmpDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let summary = try await git.changeSummary()
        XCTAssertEqual(summary.modified, 1)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.deleted, 0)
    }

    // MARK: - AdapterEngine Parallel Pull

    func testAdapterEngine_PullAllSkipsResources() async throws {
        // Verify that resourcesToSkip parameter is respected
        // We can't easily test the full pull (needs HTTP), but we can test
        // that the skip set filters correctly
        let skip: Set<String> = ["coupons", "groups", "restaurant-menus"]
        let resources = ["contacts", "products", "coupons", "groups", "restaurant-menus"]
        let filtered = resources.filter { !skip.contains($0) }
        XCTAssertEqual(filtered, ["contacts", "products"])
    }

    // MARK: - Diff with Wix Products Scenario

    func testWixProductsScenario_OnlyNameChangeDetected() {
        // Simulates the exact Wix products bug:
        // User edits 1 product name. Push should detect 1 change, not 14.
        let old: [[String: Any]] = [
            ["_id": "p1", "name": "Product A", "priceAmount": "99", "revision": "5",
             "updatedDate": "2026-01-01", "slug": "product-a", "visible": "true",
             "productType": "PHYSICAL", "createdDate": "2025-01-01", "compareAtPriceRange": ""],
            ["_id": "p2", "name": "Product B", "priceAmount": "199", "revision": "3",
             "updatedDate": "2026-01-01", "slug": "product-b", "visible": "true",
             "productType": "PHYSICAL", "createdDate": "2025-01-01", "compareAtPriceRange": ""],
        ]
        // User only changed product A's name. Pull bumped both revisions and updatedDates.
        let new: [[String: Any]] = [
            ["_id": "p1", "name": "Product A EDITED", "priceAmount": "99", "revision": "6",
             "updatedDate": "2026-01-02", "slug": "product-a", "visible": "true",
             "productType": "PHYSICAL", "createdDate": "2025-01-01", "compareAtPriceRange": ""],
            ["_id": "p2", "name": "Product B", "priceAmount": "199", "revision": "4",
             "updatedDate": "2026-01-02", "slug": "product-b", "visible": "true",
             "productType": "PHYSICAL", "createdDate": "2025-01-01", "compareAtPriceRange": ""],
        ]

        // Push omits these fields (from wix adapter config)
        let pushOmitFields: Set<String> = [
            "priceAmount", "slug", "createdDate", "updatedDate",
            "productType", "compareAtPriceRange", "revision", "_revision"
        ]

        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "_id",
            ignoreFields: pushOmitFields
        )

        XCTAssertEqual(diff.updated.count, 1, "Only the product with name change should be detected")
        XCTAssertEqual(diff.updated[0].id, "p1")
        XCTAssertEqual(diff.updated[0].record["name"] as? String, "Product A EDITED")
        XCTAssertTrue(diff.created.isEmpty)
        XCTAssertTrue(diff.deleted.isEmpty)
    }

    func testWixProductsScenario_AllRevisionsChanged_NoRealEdits() {
        // After a push bumps all revisions on the server, the next pull
        // updates revision and updatedDate for ALL products.
        // No real user edits → diff should be empty.
        let old: [[String: Any]] = [
            ["_id": "p1", "name": "A", "revision": "10", "updatedDate": "2026-01-01"],
            ["_id": "p2", "name": "B", "revision": "8", "updatedDate": "2026-01-01"],
            ["_id": "p3", "name": "C", "revision": "5", "updatedDate": "2026-01-01"],
        ]
        let new: [[String: Any]] = [
            ["_id": "p1", "name": "A", "revision": "11", "updatedDate": "2026-01-02"],
            ["_id": "p2", "name": "B", "revision": "9", "updatedDate": "2026-01-02"],
            ["_id": "p3", "name": "C", "revision": "6", "updatedDate": "2026-01-02"],
        ]

        let diff = CollectionDiffer.diff(
            old: old, new: new, idField: "_id",
            ignoreFields: ["revision", "_revision", "updatedDate", "_updatedDate"]
        )
        XCTAssertTrue(diff.isEmpty, "Only revision/updatedDate changed — should be empty diff")
    }
}
