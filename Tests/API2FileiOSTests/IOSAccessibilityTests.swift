import XCTest
@testable import API2FileiOSApp

final class IOSAccessibilityTests: XCTestCase {
    func testSlugNormalizesPunctuationAndWhitespace() {
        XCTAssertEqual(IOSAccessibility.slug("Blog Posts / Drafts"), "blog-posts-drafts")
    }

    func testSlugFallsBackWhenStringHasNoAlphanumerics() {
        XCTAssertEqual(IOSAccessibility.slug("   ---   "), "item")
    }

    func testIdentifierJoinsSluggedParts() {
        XCTAssertEqual(
            IOSAccessibility.id("Browser", "My Service", "Recent Files"),
            "browser.my-service.recent-files"
        )
    }

    func testRootTabsExposeStableIdentifiers() {
        XCTAssertEqual(IOSRootTab.services.accessibilityID, "tab.services")
        XCTAssertEqual(IOSRootTab.browser.accessibilityID, "tab.browser")
        XCTAssertEqual(IOSRootTab.dataExplorer.accessibilityID, "tab.data")
        XCTAssertEqual(IOSRootTab.activity.accessibilityID, "tab.activity")
        XCTAssertEqual(IOSRootTab.settings.accessibilityID, "tab.settings")
    }

    func testRootTabsExposeExpectedTitles() {
        XCTAssertEqual(IOSRootTab.services.title, "Services")
        XCTAssertEqual(IOSRootTab.browser.title, "Files")
        XCTAssertEqual(IOSRootTab.dataExplorer.title, "Data")
        XCTAssertEqual(IOSRootTab.activity.title, "Activity")
        XCTAssertEqual(IOSRootTab.settings.title, "Settings")
    }

    func testScreenIdentifiersRemainStable() {
        XCTAssertEqual(IOSScreenID.services, "screen.services")
        XCTAssertEqual(IOSScreenID.browser, "screen.files")
        XCTAssertEqual(IOSScreenID.dataExplorer, "screen.data-explorer")
        XCTAssertEqual(IOSScreenID.activity, "screen.activity")
        XCTAssertEqual(IOSScreenID.settings, "screen.settings")
        XCTAssertEqual(IOSScreenID.addService, "screen.add-service")
        XCTAssertEqual(IOSScreenID.fileDetail, "screen.file-detail")
    }

    func testLaunchValuesMapLegacyAndNewTabNames() {
        XCTAssertEqual(IOSRootTab.launchValue("browser"), .browser)
        XCTAssertEqual(IOSRootTab.launchValue("files"), .browser)
        XCTAssertEqual(IOSRootTab.launchValue("file-explorer"), .browser)
        XCTAssertEqual(IOSRootTab.launchValue("data"), .dataExplorer)
        XCTAssertEqual(IOSRootTab.launchValue("data-explorer"), .dataExplorer)
    }
}
