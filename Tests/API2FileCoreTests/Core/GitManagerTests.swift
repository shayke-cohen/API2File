import XCTest
@testable import API2FileCore

final class GitManagerTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!
    private var manager: GitManager!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = GitManager(repoPath: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - initRepo

    func testInitRepoCreatesGitDirectory() async throws {
        let gitDir = tempDir.appendingPathComponent(".git")
        XCTAssertFalse(FileManager.default.fileExists(atPath: gitDir.path))

        try await manager.initRepo()

        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDir.path))
    }

    func testInitRepoIsIdempotent() async throws {
        try await manager.initRepo()
        // Calling again should not throw
        try await manager.initRepo()

        let gitDir = tempDir.appendingPathComponent(".git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDir.path))
    }

    // MARK: - createGitignore

    func testCreateGitignoreWritesCorrectContent() async throws {
        try await manager.initRepo()
        try await manager.createGitignore()

        let gitignorePath = tempDir.appendingPathComponent(".gitignore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitignorePath.path))

        let content = try String(contentsOf: gitignorePath, encoding: .utf8)
        XCTAssertEqual(content, ".api2file/\n")
    }

    func testCreateGitignoreDoesNotOverwrite() async throws {
        try await manager.initRepo()

        // Write a custom gitignore first
        let gitignorePath = tempDir.appendingPathComponent(".gitignore")
        try "node_modules/\n".write(to: gitignorePath, atomically: true, encoding: .utf8)

        // createGitignore should not overwrite the existing file
        try await manager.createGitignore()

        let content = try String(contentsOf: gitignorePath, encoding: .utf8)
        XCTAssertEqual(content, "node_modules/\n")
    }

    // MARK: - commitAll

    func testCommitAllCreatesCommit() async throws {
        try await manager.initRepo()

        // Configure git user for the test repo
        try configureGitUser()

        // Create a file to commit
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: filePath, atomically: true, encoding: .utf8)

        try await manager.commitAll(message: "Initial commit")

        // Verify a commit was created by checking git log
        let log = try runGitCommand(["log", "--oneline", "-1"])
        XCTAssertTrue(log.contains("Initial commit"))
    }

    // MARK: - hasChanges

    func testHasChangesDetectsModifications() async throws {
        try await manager.initRepo()
        try configureGitUser()

        // Create and commit a file
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "original".write(to: filePath, atomically: true, encoding: .utf8)
        try await manager.commitAll(message: "Initial commit")

        // No changes initially after commit
        let cleanResult = try await manager.hasChanges()
        XCTAssertFalse(cleanResult)

        // Modify the file
        try "modified".write(to: filePath, atomically: true, encoding: .utf8)

        // Now should detect changes
        let dirtyResult = try await manager.hasChanges()
        XCTAssertTrue(dirtyResult)
    }

    func testHasChangesDetectsNewFiles() async throws {
        try await manager.initRepo()
        try configureGitUser()

        // Create and commit a file
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)
        try await manager.commitAll(message: "Initial commit")

        // Add a new file
        let newFile = tempDir.appendingPathComponent("new.txt")
        try "new content".write(to: newFile, atomically: true, encoding: .utf8)

        let result = try await manager.hasChanges()
        XCTAssertTrue(result)
    }

    // MARK: - fileHashAtHead

    func testFileHashAtHeadReturnsHashForCommittedFile() async throws {
        try await manager.initRepo()
        try configureGitUser()

        let filePath = tempDir.appendingPathComponent("test.txt")
        try "Hello, World!".write(to: filePath, atomically: true, encoding: .utf8)
        try await manager.commitAll(message: "Add test file")

        let hash = try await manager.fileHashAtHead("test.txt")
        XCTAssertNotNil(hash)
        XCTAssertFalse(hash!.isEmpty)
        // SHA-256 hex string should be 64 characters
        XCTAssertEqual(hash!.count, 64)
    }

    func testFileHashAtHeadReturnsNilForMissingFile() async throws {
        try await manager.initRepo()
        try configureGitUser()

        // Create a commit so HEAD exists
        let filePath = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)
        try await manager.commitAll(message: "Initial commit")

        let hash = try await manager.fileHashAtHead("nonexistent.txt")
        XCTAssertNil(hash)
    }

    func testFileHashAtHeadReturnsNilWhenNoCommits() async throws {
        try await manager.initRepo()

        let hash = try await manager.fileHashAtHead("test.txt")
        XCTAssertNil(hash)
    }

    func testEmbeddedBackendCreatesSnapshotMetadata() async throws {
        let embedded = GitManager(repoPath: tempDir, backendFactory: .embedded)
        try await embedded.initRepo()
        try await embedded.createGitignore()

        let filePath = tempDir.appendingPathComponent("embedded.txt")
        try "one".write(to: filePath, atomically: true, encoding: .utf8)
        try await embedded.commitAll(message: "Initial snapshot")

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(".api2file-git/manifest.json").path))
    }

    // MARK: - Test Helpers

    private func configureGitUser() throws {
        _ = try runGitCommand(["config", "user.email", "test@api2file.dev"])
        _ = try runGitCommand(["config", "user.name", "Test User"])
    }

    @discardableResult
    private func runGitCommand(_ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = tempDir
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
