import XCTest
@testable import API2FileCore

final class ManagedWorkspaceFileSystemStoreTests: XCTestCase {
    func testCloseRejectsInvalidWriteAndLeavesAcceptedFileUntouched() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedWorkspaceFileSystemStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot.appendingPathComponent("demo", isDirectory: true), withIntermediateDirectories: true)
        let targetURL = workspaceRoot.appendingPathComponent("demo/tasks.csv")
        let original = "_id,name\n1,Buy groceries\n"
        try Data(original.utf8).write(to: targetURL, options: .atomic)

        let commitClient = TestManagedWorkspaceCommitClient(root: workspaceRoot)
        commitClient.rejectWith = NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [
            NSLocalizedDescriptionKey: "Managed file schema mismatch — missing columns: priority"
        ])
        let store = ManagedWorkspaceFileSystemStore(
            workspaceRoot: workspaceRoot,
            commitClient: commitClient,
            sourceApplication: "Tests"
        )

        try await store.openFile(at: "demo/tasks.csv", modes: [.write])
        _ = try await store.writeFile(
            at: "demo/tasks.csv",
            offset: 0,
            contents: Data("_id,name,status\n1,Buy groceries,todo\n".utf8)
        )

        do {
            try await store.closeFile(at: "demo/tasks.csv", keeping: [])
            XCTFail("Expected close to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("schema mismatch"))
        }

        let restored = try String(contentsOf: targetURL)
        XCTAssertEqual(restored, original)
    }

    func testRenameFromTemporaryFileCommitsToDestinationPath() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedWorkspaceFileSystemStoreRenameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot.appendingPathComponent("demo", isDirectory: true), withIntermediateDirectories: true)
        let targetURL = workspaceRoot.appendingPathComponent("demo/tasks.csv")
        try Data("_id,name\n1,Buy groceries\n".utf8).write(to: targetURL, options: .atomic)

        let commitClient = TestManagedWorkspaceCommitClient(root: workspaceRoot)
        let store = ManagedWorkspaceFileSystemStore(
            workspaceRoot: workspaceRoot,
            commitClient: commitClient,
            sourceApplication: "Tests"
        )

        _ = try await store.createFile(at: "demo/.tasks.csv.tmp")
        try await store.openFile(at: "demo/.tasks.csv.tmp", modes: [.write])
        _ = try await store.writeFile(
            at: "demo/.tasks.csv.tmp",
            offset: 0,
            contents: Data("_id,name\n1,Updated from temp\n".utf8)
        )
        try await store.closeFile(at: "demo/.tasks.csv.tmp", keeping: [])
        try await store.renameItem(from: "demo/.tasks.csv.tmp", to: "demo/tasks.csv")

        let committed = try String(contentsOf: targetURL)
        XCTAssertEqual(committed, "_id,name\n1,Updated from temp\n")
        XCTAssertEqual(commitClient.commits.last?.relativePath, "demo/tasks.csv")
    }
}

private final class TestManagedWorkspaceCommitClient: ManagedWorkspaceMountCommitClient, @unchecked Sendable {
    let root: URL
    var rejectWith: Error?
    var commits: [(relativePath: String, data: Data)] = []

    init(root: URL) {
        self.root = root
    }

    func commit(relativePath: String, data: Data, sourceApplication: String?) async throws {
        if let rejectWith {
            throw rejectWith
        }
        commits.append((relativePath, data))
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func remove(relativePath: String, sourceApplication: String?) async throws {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
