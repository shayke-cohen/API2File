import XCTest
@testable import API2FileiOSApp

final class BrowserFileExplorerSupportTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserFileExplorerSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testTreeGroupsFilesIntoRootAndFolders() throws {
        let rootFile = tempRoot.appendingPathComponent("CLAUDE.md")
        let nestedFile = tempRoot.appendingPathComponent("blog/post.md")
        let deepFile = tempRoot.appendingPathComponent("bookings/appointments.csv")

        try FileManager.default.createDirectory(at: nestedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deepFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("guide".utf8).write(to: rootFile)
        try Data("post".utf8).write(to: nestedFile)
        try Data("id,name\n1,Amit".utf8).write(to: deepFile)

        let items = BrowserFileExplorerSupport.items(
            for: [rootFile, nestedFile, deepFile],
            root: tempRoot
        )
        let tree = BrowserFileExplorerSupport.tree(for: items)

        XCTAssertEqual(tree.files.map(\.relativePath), ["CLAUDE.md"])
        XCTAssertEqual(tree.folders.map(\.relativePath), ["blog", "bookings"])
        XCTAssertEqual(tree.folders.first(where: { $0.relativePath == "blog" })?.files.map(\.relativePath), ["blog/post.md"])
        XCTAssertEqual(tree.folders.first(where: { $0.relativePath == "bookings" })?.files.map(\.relativePath), ["bookings/appointments.csv"])
    }

    func testMetadataReportsFileSizeAndCSVRows() throws {
        let csvURL = tempRoot.appendingPathComponent("contacts.csv")
        try Data("id,name\n1,Amit\n2,Noa\n".utf8).write(to: csvURL)

        let metadata = BrowserFileExplorerSupport.metadata(for: csvURL)

        XCTAssertEqual(metadata.rowCount, 2)
        XCTAssertTrue(metadata.detailDescription.contains("2 rows"))
        XCTAssertFalse(metadata.sizeDescription.isEmpty)
    }

    func testItemsSortGuideAfterRealFiles() throws {
        let guideURL = tempRoot.appendingPathComponent("CLAUDE.md")
        let boardURL = tempRoot.appendingPathComponent("boards/roadmap.csv")

        try FileManager.default.createDirectory(at: boardURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("guide".utf8).write(to: guideURL)
        try Data("id,name\n1,Roadmap".utf8).write(to: boardURL)

        let items = BrowserFileExplorerSupport.items(for: [guideURL, boardURL], root: tempRoot)

        XCTAssertEqual(items.map(\.relativePath), ["boards/roadmap.csv", "CLAUDE.md"])
    }
}
