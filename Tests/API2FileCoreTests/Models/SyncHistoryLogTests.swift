import XCTest
@testable import API2FileCore

final class SyncHistoryLogTests: XCTestCase {

    // MARK: - SyncHistoryLog

    func testAppendInsertsAtFront() {
        var log = SyncHistoryLog()
        let entry1 = makeEntry(summary: "first")
        let entry2 = makeEntry(summary: "second")

        log.append(entry1)
        log.append(entry2)

        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries[0].summary, "second")
        XCTAssertEqual(log.entries[1].summary, "first")
    }

    func testPrunesAt500Entries() {
        var log = SyncHistoryLog()
        for i in 0..<510 {
            log.append(makeEntry(summary: "entry-\(i)"))
        }

        XCTAssertEqual(log.entries.count, 500)
        // Most recent entry should be the last appended
        XCTAssertEqual(log.entries[0].summary, "entry-509")
    }

    func testSaveAndLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncHistoryLogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("sync-history.json")

        var log = SyncHistoryLog()
        let entry = SyncHistoryEntry(
            serviceId: "github",
            serviceName: "GitHub",
            direction: .pull,
            status: .success,
            duration: 1.5,
            files: [
                FileChange(
                    path: "repos/my-project.json",
                    action: .downloaded,
                    recordsCreated: 0,
                    recordsUpdated: 0,
                    recordsDeleted: 0
                )
            ],
            summary: "pulled 1 files"
        )
        log.append(entry)

        try log.save(to: fileURL)
        let loaded = try SyncHistoryLog.load(from: fileURL)

        XCTAssertEqual(loaded.entries.count, 1)
        let loadedEntry = loaded.entries[0]
        XCTAssertEqual(loadedEntry.serviceId, "github")
        XCTAssertEqual(loadedEntry.serviceName, "GitHub")
        XCTAssertEqual(loadedEntry.direction, .pull)
        XCTAssertEqual(loadedEntry.status, .success)
        XCTAssertEqual(loadedEntry.duration, 1.5, accuracy: 0.01)
        XCTAssertEqual(loadedEntry.files.count, 1)
        XCTAssertEqual(loadedEntry.files[0].path, "repos/my-project.json")
        XCTAssertEqual(loadedEntry.files[0].action, .downloaded)
        XCTAssertEqual(loadedEntry.summary, "pulled 1 files")
    }

    func testLoadNonExistentFileThrows() {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try SyncHistoryLog.load(from: bogusURL))
    }

    func testEmptyLogRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncHistoryLogTests-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("sync-history.json")

        let log = SyncHistoryLog()
        try log.save(to: fileURL)
        let loaded = try SyncHistoryLog.load(from: fileURL)

        XCTAssertTrue(loaded.entries.isEmpty)
    }

    // MARK: - SyncHistoryEntry Encoding

    func testAllDirectionsEncodeAndDecode() throws {
        let directions: [SyncDirection] = [.pull, .push]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for direction in directions {
            let data = try encoder.encode(direction)
            let decoded = try decoder.decode(SyncDirection.self, from: data)
            XCTAssertEqual(decoded, direction)
        }
    }

    func testAllOutcomesEncodeAndDecode() throws {
        let outcomes: [SyncOutcome] = [.success, .error, .conflict]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for outcome in outcomes {
            let data = try encoder.encode(outcome)
            let decoded = try decoder.decode(SyncOutcome.self, from: data)
            XCTAssertEqual(decoded, outcome)
        }
    }

    func testAllFileActionsEncodeAndDecode() throws {
        let actions: [FileAction] = [.downloaded, .uploaded, .created, .updated, .deleted, .conflicted, .error]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for action in actions {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(FileAction.self, from: data)
            XCTAssertEqual(decoded, action)
        }
    }

    func testFileChangeWithRecordCounts() throws {
        let change = FileChange(
            path: "boards/tasks.csv",
            action: .uploaded,
            recordsCreated: 2,
            recordsUpdated: 5,
            recordsDeleted: 1,
            errorMessage: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(change)
        let decoded = try JSONDecoder().decode(FileChange.self, from: data)

        XCTAssertEqual(decoded.path, "boards/tasks.csv")
        XCTAssertEqual(decoded.action, .uploaded)
        XCTAssertEqual(decoded.recordsCreated, 2)
        XCTAssertEqual(decoded.recordsUpdated, 5)
        XCTAssertEqual(decoded.recordsDeleted, 1)
        XCTAssertNil(decoded.errorMessage)
    }

    func testFileChangeWithErrorMessage() throws {
        let change = FileChange(
            path: "contacts.vcf",
            action: .error,
            errorMessage: "401 Unauthorized"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(change)
        let decoded = try JSONDecoder().decode(FileChange.self, from: data)

        XCTAssertEqual(decoded.action, .error)
        XCTAssertEqual(decoded.errorMessage, "401 Unauthorized")
        XCTAssertEqual(decoded.recordsCreated, 0)
    }

    func testEntryWithMultipleFiles() throws {
        let entry = SyncHistoryEntry(
            serviceId: "wix",
            serviceName: "Wix",
            direction: .push,
            status: .success,
            duration: 2.3,
            files: [
                FileChange(path: "contacts.csv", action: .uploaded, recordsCreated: 1, recordsUpdated: 3, recordsDeleted: 0),
                FileChange(path: "products.csv", action: .uploaded, recordsCreated: 0, recordsUpdated: 1, recordsDeleted: 2)
            ],
            summary: "pushed 2 files"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncHistoryEntry.self, from: data)

        XCTAssertEqual(decoded.files.count, 2)
        XCTAssertEqual(decoded.files[0].recordsCreated, 1)
        XCTAssertEqual(decoded.files[1].recordsDeleted, 2)
    }

    // MARK: - Helpers

    private func makeEntry(summary: String) -> SyncHistoryEntry {
        SyncHistoryEntry(
            serviceId: "test",
            serviceName: "Test",
            direction: .pull,
            status: .success,
            duration: 0.5,
            files: [],
            summary: summary
        )
    }
}
