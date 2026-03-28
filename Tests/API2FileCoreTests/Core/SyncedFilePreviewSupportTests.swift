import XCTest
@testable import API2FileCore

final class SyncedFilePreviewSupportTests: XCTestCase {
    func testIsUserFacingRelativePathRejectsHiddenAndObjectFiles() {
        XCTAssertTrue(SyncedFilePreviewSupport.isUserFacingRelativePath("tasks.csv"))
        XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath(".api2file/state.json"))
        XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath("notes/.objects/item.json"))
        XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath(".tasks.objects.json"))
        XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath("tasks/task.conflict.csv"))
    }

    func testDefaultPreviewCandidatePrefersMostRecentlyModifiedUserFacingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = root.appendingPathComponent("notes.md")
        let newer = root.appendingPathComponent("tasks.csv")
        let hidden = root.appendingPathComponent(".api2file/state.json")

        try "older".write(to: older, atomically: true, encoding: .utf8)
        try "newer".write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: hidden.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}".write(to: hidden, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )

        XCTAssertEqual(
            SyncedFilePreviewSupport.defaultPreviewCandidate(in: root)?.lastPathComponent,
            "tasks.csv"
        )
    }

    func testKindClassificationCoversFinderFacingFormats() {
        XCTAssertEqual(
            SyncedFilePreviewSupport.kind(for: URL(fileURLWithPath: "/tmp/tasks.csv")),
            .csv
        )
        XCTAssertEqual(
            SyncedFilePreviewSupport.kind(for: URL(fileURLWithPath: "/tmp/notes.md")),
            .markdown
        )
        XCTAssertEqual(
            SyncedFilePreviewSupport.kind(for: URL(fileURLWithPath: "/tmp/report.pdf")),
            .pdf
        )
        XCTAssertEqual(
            SyncedFilePreviewSupport.kind(for: URL(fileURLWithPath: "/tmp/deck.pptx")),
            .office
        )
    }
}
