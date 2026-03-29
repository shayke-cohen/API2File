import XCTest
@testable import API2FileCore

#if os(macOS)
final class FinderBadgeSupportTests: XCTestCase {
    func testWixPathsResolveToWixBadgeIdentifiers() {
        XCTAssertEqual(
            FinderBadgeSupport.badgeIdentifier(for: "synced", relativePath: "wix/contacts.csv"),
            "wix-synced"
        )
        XCTAssertEqual(
            FinderBadgeSupport.badgeIdentifier(for: "error", relativePath: "wix/blog/homepage.md"),
            "wix-error"
        )
    }

    func testNonWixPathsKeepGenericBadgeIdentifiers() {
        XCTAssertEqual(
            FinderBadgeSupport.badgeIdentifier(for: "syncing", relativePath: "github/issues.csv"),
            "syncing"
        )
    }

    func testRelativePathNormalizesAndValidatesSyncRoot() {
        let syncRoot = URL(fileURLWithPath: "/tmp/API2File-Data", isDirectory: true)
        let fileURL = URL(fileURLWithPath: "/tmp/API2File-Data/wix/blog/homepage.md")
        let outsideURL = URL(fileURLWithPath: "/tmp/other/file.md")

        XCTAssertEqual(
            FinderBadgeSupport.relativePath(for: fileURL, syncRootURL: syncRoot),
            "wix/blog/homepage.md"
        )
        XCTAssertNil(FinderBadgeSupport.relativePath(for: outsideURL, syncRootURL: syncRoot))
    }

    func testClearBadgeStatesRemovesOnlyBadgeKeys() {
        guard let defaults = UserDefaults(suiteName: "tests.api2file.finder-badges.\(UUID().uuidString)") else {
            XCTFail("Expected isolated user defaults suite")
            return
        }

        defaults.set("value", forKey: "keep.me")
        FinderBadgeSupport.setBadgeState("synced", forRelativePath: "wix", in: defaults)
        FinderBadgeSupport.setBadgeState("error", forRelativePath: "wix/contacts.csv", in: defaults)

        FinderBadgeSupport.clearBadgeStates(in: defaults)

        XCTAssertNil(defaults.string(forKey: FinderBadgeSupport.badgeKey(forRelativePath: "wix")))
        XCTAssertNil(defaults.string(forKey: FinderBadgeSupport.badgeKey(forRelativePath: "wix/contacts.csv")))
        XCTAssertEqual(defaults.string(forKey: "keep.me"), "value")
    }

    func testServiceConfigRoundTripsViaSharedDefaults() {
        guard let defaults = UserDefaults(suiteName: "tests.api2file.finder-config.\(UUID().uuidString)") else {
            XCTFail("Expected isolated user defaults suite")
            return
        }

        let resource = ResourceConfig(
            name: "contacts",
            fileMapping: FileMappingConfig(strategy: .collection, directory: ".", filename: "contacts.csv", format: .csv),
            dashboardUrl: "https://manage.wix.com/dashboard/site-id/contacts"
        )
        let config = AdapterConfig(
            service: "wix",
            displayName: "Wix",
            version: "1.0",
            auth: AuthConfig(type: .apiKey, keychainKey: "api2file.wix.key"),
            resources: [resource],
            dashboardUrl: "https://manage.wix.com/dashboard/site-id/home"
        )

        FinderBadgeSupport.setServiceConfig(config, forServiceId: "wix", in: defaults)

        XCTAssertEqual(
            FinderBadgeSupport.serviceConfig(forServiceId: "wix", in: defaults)?.resources.first?.dashboardUrl,
            "https://manage.wix.com/dashboard/site-id/contacts"
        )
    }

    func testCustomWixInstanceUsesWixBadgeIdentifiersWhenConfigIsStored() {
        guard let defaults = UserDefaults(suiteName: "tests.api2file.finder-wix-instance.\(UUID().uuidString)") else {
            XCTFail("Expected isolated user defaults suite")
            return
        }

        let config = AdapterConfig(
            service: "wix",
            displayName: "Wix",
            version: "1.0",
            auth: AuthConfig(type: .apiKey, keychainKey: "api2file.wix-client-a.key"),
            resources: []
        )

        FinderBadgeSupport.setServiceConfig(config, forServiceId: "wix-client-a", in: defaults)

        XCTAssertEqual(
            FinderBadgeSupport.badgeIdentifier(for: "syncing", relativePath: "wix-client-a/blog/post.md", defaults: defaults),
            "wix-syncing"
        )
    }
}
#endif
