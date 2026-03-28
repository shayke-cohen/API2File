import XCTest
@testable import API2FileCore

final class ResourceBrowserSupportTests: XCTestCase {
    func testDefaultExtensionUsesHumanFriendlyExtensions() {
        XCTAssertEqual(ResourceBrowserSupport.defaultExtension(for: .markdown), "md")
        XCTAssertEqual(ResourceBrowserSupport.defaultExtension(for: .yaml), "yaml")
        XCTAssertEqual(ResourceBrowserSupport.defaultExtension(for: .text), "txt")
        XCTAssertEqual(ResourceBrowserSupport.defaultExtension(for: .json), "json")
    }

    func testDirectoryURLUsesServiceRootForDotDirectory() {
        let serviceRoot = URL(fileURLWithPath: "/tmp/service", isDirectory: true)
        let resource = ResourceConfig(
            name: "notes",
            fileMapping: FileMappingConfig(strategy: .onePerRecord, directory: ".", format: .markdown)
        )

        XCTAssertEqual(ResourceBrowserSupport.directoryURL(for: resource, serviceRoot: serviceRoot).path, serviceRoot.path)
    }

    func testCollectionURLFallsBackToResourceNameAndFormat() {
        let serviceRoot = URL(fileURLWithPath: "/tmp/service", isDirectory: true)
        let resource = ResourceConfig(
            name: "tasks",
            fileMapping: FileMappingConfig(strategy: .collection, directory: ".", format: .csv)
        )

        XCTAssertEqual(ResourceBrowserSupport.collectionURL(for: resource, serviceRoot: serviceRoot).lastPathComponent, "tasks.csv")
    }

    func testCanCreateTextFileRejectsCollectionAndRawResources() {
        let collection = ResourceConfig(
            name: "tasks",
            fileMapping: FileMappingConfig(strategy: .collection, directory: ".", format: .csv)
        )
        let raw = ResourceConfig(
            name: "photos",
            fileMapping: FileMappingConfig(strategy: .onePerRecord, directory: "photos", format: .raw)
        )
        let markdown = ResourceConfig(
            name: "notes",
            fileMapping: FileMappingConfig(strategy: .onePerRecord, directory: "notes", format: .markdown)
        )

        XCTAssertFalse(ResourceBrowserSupport.canCreateTextFile(collection))
        XCTAssertFalse(ResourceBrowserSupport.canCreateTextFile(raw))
        XCTAssertTrue(ResourceBrowserSupport.canCreateTextFile(markdown))
    }

    func testUniqueDestinationURLAddsNumericSuffix() {
        let directory = URL(fileURLWithPath: "/tmp/service", isDirectory: true)
        let existing = Set([
            "/tmp/service/photo.jpg",
            "/tmp/service/photo-2.jpg"
        ])

        let result = ResourceBrowserSupport.uniqueDestinationURL(
            originalName: "photo.jpg",
            directory: directory,
            fileExists: { existing.contains($0.path) }
        )

        XCTAssertEqual(result.lastPathComponent, "photo-3.jpg")
    }

    func testDashboardURLPrefersResourceDashboard() {
        let serviceRoot = URL(fileURLWithPath: "/tmp/service", isDirectory: true)
        let fileURL = serviceRoot.appendingPathComponent("contacts.csv")
        let resource = ResourceConfig(
            name: "contacts",
            fileMapping: FileMappingConfig(strategy: .collection, directory: ".", filename: "contacts.csv", format: .csv),
            dashboardUrl: "https://manage.wix.com/dashboard/site-id/contacts"
        )
        let config = AdapterConfig(
            service: "wix",
            displayName: "Wix",
            version: "1.0",
            auth: AuthConfig(type: .bearer, keychainKey: "test"),
            resources: [resource],
            dashboardUrl: "https://manage.wix.com/dashboard/site-id/home"
        )

        XCTAssertEqual(
            ResourceBrowserSupport.dashboardURL(for: fileURL, serviceConfig: config, serviceRoot: serviceRoot)?.absoluteString,
            "https://manage.wix.com/dashboard/site-id/contacts"
        )
    }

    func testDashboardURLFallsBackToServiceDashboard() {
        let serviceRoot = URL(fileURLWithPath: "/tmp/service", isDirectory: true)
        let fileURL = serviceRoot.appendingPathComponent("notes/readme.md")
        let resource = ResourceConfig(
            name: "notes",
            fileMapping: FileMappingConfig(strategy: .onePerRecord, directory: "notes", format: .markdown)
        )
        let config = AdapterConfig(
            service: "demo",
            displayName: "Demo",
            version: "1.0",
            auth: AuthConfig(type: .bearer, keychainKey: "test"),
            resources: [resource],
            dashboardUrl: "https://example.com/dashboard"
        )

        XCTAssertEqual(
            ResourceBrowserSupport.dashboardURL(for: fileURL, serviceConfig: config, serviceRoot: serviceRoot)?.absoluteString,
            "https://example.com/dashboard"
        )
    }
}
