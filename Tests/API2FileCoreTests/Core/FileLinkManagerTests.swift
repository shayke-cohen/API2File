import XCTest
@testable import API2FileCore

final class FileLinkManagerTests: XCTestCase {

    func testLinksFileURLUsesAPI2FileDirectory() {
        let serviceDir = URL(fileURLWithPath: "/tmp/api2file-test-service")
        let url = FileLinkManager.linksFileURL(in: serviceDir)
        XCTAssertEqual(url.path, "/tmp/api2file-test-service/.api2file/file-links.json")
    }

    func testSaveAndLoadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let entry = FileLinkEntry(
            resourceName: "blog-posts",
            mappingStrategy: .onePerRecord,
            remoteId: "post-123",
            userPath: "blog/post.md",
            canonicalPath: "blog/.objects/post.json",
            derivedPaths: ["blog/.preview/post.html"]
        )
        try FileLinkManager.save(FileLinkIndex(links: [entry]), to: tempDir)

        let loaded = try FileLinkManager.load(from: tempDir)
        XCTAssertEqual(loaded.links, [entry])
    }

    func testUpsertMatchesExistingEntryByRemoteIdAndUpdatesPaths() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileLinkManager.upsert(
            FileLinkEntry(
                resourceName: "blog-posts",
                mappingStrategy: .onePerRecord,
                remoteId: "post-123",
                userPath: "blog/old-slug.md",
                canonicalPath: "blog/.objects/old-slug.json"
            ),
            in: tempDir
        )

        try FileLinkManager.upsert(
            FileLinkEntry(
                resourceName: "blog-posts",
                mappingStrategy: .onePerRecord,
                remoteId: "post-123",
                userPath: "blog/new-slug.md",
                canonicalPath: "blog/.objects/new-slug.json",
                derivedPaths: ["blog/.preview/new-slug.html"]
            ),
            in: tempDir
        )

        let loaded = try FileLinkManager.load(from: tempDir)
        XCTAssertEqual(loaded.links.count, 1)
        XCTAssertEqual(loaded.links[0].userPath, "blog/new-slug.md")
        XCTAssertEqual(loaded.links[0].canonicalPath, "blog/.objects/new-slug.json")
        XCTAssertEqual(loaded.links[0].derivedPaths, ["blog/.preview/new-slug.html"])
    }

    func testRemoveLinksDeletesMatchingUserCanonicalAndDerivedPaths() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileLinkManager.save(
            FileLinkIndex(links: [
                FileLinkEntry(
                    resourceName: "blog-posts",
                    mappingStrategy: .onePerRecord,
                    remoteId: "post-123",
                    userPath: "blog/post.md",
                    canonicalPath: "blog/.objects/post.json",
                    derivedPaths: ["blog/.preview/post.html"]
                ),
                FileLinkEntry(
                    resourceName: "contacts",
                    mappingStrategy: .collection,
                    remoteId: nil,
                    userPath: "contacts.csv",
                    canonicalPath: ".contacts.objects.json"
                ),
            ]),
            to: tempDir
        )

        try FileLinkManager.removeLinks(referencingAny: ["blog/.objects/post.json"], in: tempDir)

        let loaded = try FileLinkManager.load(from: tempDir)
        XCTAssertEqual(loaded.links.count, 1)
        XCTAssertEqual(loaded.links[0].resourceName, "contacts")
    }
}
