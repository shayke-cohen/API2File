import XCTest
import UserNotifications
@testable import API2FileCore

final class NotificationManagerTests: XCTestCase {

    // MARK: - General Notification Content

    func testGeneralNotificationContent() {
        let content = NotificationManager.buildGeneralContent(
            title: "Test Title",
            body: "Test body message"
        )

        XCTAssertEqual(content.title, "Test Title")
        XCTAssertEqual(content.body, "Test body message")
        XCTAssertEqual(content.categoryIdentifier, "GENERAL")
        XCTAssertNotNil(content.sound)
    }

    func testGeneralNotificationContentWithActionURL() {
        let url = URL(string: "https://example.com/action")!
        let content = NotificationManager.buildGeneralContent(
            title: "Action",
            body: "Click to open",
            actionURL: url
        )

        XCTAssertEqual(content.title, "Action")
        XCTAssertEqual(content.body, "Click to open")
        let actionURL = content.userInfo["actionURL"] as? String
        XCTAssertEqual(actionURL, "https://example.com/action")
    }

    func testGeneralNotificationContentWithoutActionURL() {
        let content = NotificationManager.buildGeneralContent(
            title: "No Action",
            body: "Just info"
        )

        XCTAssertNil(content.userInfo["actionURL"])
    }

    // MARK: - Conflict Notification Content

    func testConflictNotificationIncludesFileName() {
        let content = NotificationManager.buildConflictContent(
            service: "Notion",
            file: "notes/meeting.md"
        )

        XCTAssertEqual(content.title, "Sync Conflict — Notion")
        XCTAssertTrue(content.body.contains("notes/meeting.md"),
                       "Conflict notification body should include the file name")
        XCTAssertEqual(content.categoryIdentifier, "SYNC_CONFLICT")

        let service = content.userInfo["service"] as? String
        XCTAssertEqual(service, "Notion")

        let file = content.userInfo["file"] as? String
        XCTAssertEqual(file, "notes/meeting.md")
    }

    func testConflictNotificationBodyFormat() {
        let content = NotificationManager.buildConflictContent(
            service: "GitHub",
            file: "README.md"
        )

        XCTAssertEqual(content.body, "Conflict detected in file: README.md")
    }

    // MARK: - Error Notification Content

    func testErrorNotificationIncludesErrorMessage() {
        let content = NotificationManager.buildErrorContent(
            service: "Airtable",
            message: "Rate limit exceeded (429)"
        )

        XCTAssertEqual(content.title, "Sync Error — Airtable")
        XCTAssertEqual(content.body, "Rate limit exceeded (429)")
        XCTAssertEqual(content.categoryIdentifier, "SYNC_ERROR")

        let service = content.userInfo["service"] as? String
        XCTAssertEqual(service, "Airtable")

        let errorMsg = content.userInfo["error"] as? String
        XCTAssertEqual(errorMsg, "Rate limit exceeded (429)")
    }

    func testErrorNotificationWithNetworkError() {
        let content = NotificationManager.buildErrorContent(
            service: "Dropbox",
            message: "Network connection lost"
        )

        XCTAssertTrue(content.body.contains("Network connection lost"))
        XCTAssertEqual(content.title, "Sync Error — Dropbox")
    }

    // MARK: - Connected Notification Content

    func testConnectedNotificationSingleFile() {
        let content = NotificationManager.buildConnectedContent(
            service: "Google Sheets",
            fileCount: 1
        )

        XCTAssertEqual(content.title, "Connected — Google Sheets")
        XCTAssertEqual(content.body, "Successfully connected. 1 file synced.")
        XCTAssertEqual(content.categoryIdentifier, "CONNECTED")

        let service = content.userInfo["service"] as? String
        XCTAssertEqual(service, "Google Sheets")

        let fileCount = content.userInfo["fileCount"] as? Int
        XCTAssertEqual(fileCount, 1)
    }

    func testConnectedNotificationMultipleFiles() {
        let content = NotificationManager.buildConnectedContent(
            service: "Notion",
            fileCount: 42
        )

        XCTAssertEqual(content.body, "Successfully connected. 42 files synced.")
    }

    func testConnectedNotificationZeroFiles() {
        let content = NotificationManager.buildConnectedContent(
            service: "Trello",
            fileCount: 0
        )

        XCTAssertEqual(content.body, "Successfully connected. 0 files synced.")
    }
}
