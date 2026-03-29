import XCTest
import CommonCrypto
@testable import API2FileCore

final class FullSyncCycleTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullSyncCycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Initial Setup Creates Correct Folder Structure

    func testInitialSetupCreatesCorrectFolderStructure() async throws {
        // Create .api2file directory with adapter.json
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let configJSON = """
        {
            "service": "test-service",
            "displayName": "Test Service",
            "version": "1.0",
            "auth": { "type": "bearer", "keychainKey": "test-key" },
            "resources": [
                {
                    "name": "items",
                    "pull": { "url": "https://api.example.com/items" },
                    "fileMapping": {
                        "strategy": "collection",
                        "directory": "items",
                        "format": "json"
                    }
                }
            ]
        }
        """
        try configJSON.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )

        // Initialize git
        let git = GitManager(repoPath: tempDir)
        try await git.initRepo()
        try await git.createGitignore()

        // Verify .git/ exists
        let gitDir = tempDir.appendingPathComponent(".git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDir.path))

        // Verify .gitignore exists and has correct content
        let gitignorePath = tempDir.appendingPathComponent(".gitignore")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitignorePath.path))
        let gitignoreContent = try String(contentsOf: gitignorePath, encoding: .utf8)
        XCTAssertTrue(gitignoreContent.contains(".api2file/"))

        // Verify .api2file/ exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: api2fileDir.path))

        // Verify adapter.json can be loaded
        let config = try AdapterEngine.loadConfig(from: tempDir)
        XCTAssertEqual(config.service, "test-service")
    }

    // MARK: - Pull Writes Files and Commits to Git

    func testPullWritesFilesAndCommitsToGit() async throws {
        // Initialize git
        let git = GitManager(repoPath: tempDir)
        try await git.initRepo()
        try configureGitUser(at: tempDir)

        // Create SyncableFiles (simulating what AdapterEngine.pull would produce)
        let records: [[String: Any]] = [
            ["id": 1, "name": "Widget", "price": 9.99],
            ["id": 2, "name": "Gadget", "price": 19.99]
        ]
        let csvData = try FormatConverterFactory.encode(records: records, format: .csv)

        let files = [
            SyncableFile(
                relativePath: "products/catalog.csv",
                format: .csv,
                content: csvData,
                remoteId: nil
            )
        ]

        // Write files using FileMapper
        try FileMapper.writeFiles(files, to: tempDir)

        // Update SyncState
        let stateURL = tempDir.appendingPathComponent(".api2file/state.json")
        var state = SyncState()
        state.files["products/catalog.csv"] = FileSyncState(
            remoteId: "catalog",
            lastSyncedHash: files[0].contentHash,
            lastSyncTime: Date(),
            status: .synced
        )
        try state.save(to: stateURL)

        // Commit
        try await git.commitAll(message: "sync: pull products")

        // Verify git log shows the commit
        let log = try runGitCommand(["log", "--oneline", "-1"], at: tempDir)
        XCTAssertTrue(log.contains("sync: pull products"))

        // Verify files exist on disk with correct content
        let catalogPath = tempDir.appendingPathComponent("products/catalog.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogPath.path))

        let content = try String(contentsOf: catalogPath, encoding: .utf8)
        XCTAssertTrue(content.contains("Widget"))
        XCTAssertTrue(content.contains("Gadget"))
        XCTAssertTrue(content.contains("9.99"))
        XCTAssertTrue(content.contains("19.99"))
    }

    // MARK: - Conflict Detection

    func testConflictDetection() throws {
        // Write a file
        let filePath = tempDir.appendingPathComponent("data/items.json")
        let originalContent = Data("{\"id\": 1, \"name\": \"Original\"}".utf8)
        let files = [
            SyncableFile(
                relativePath: "data/items.json",
                format: .json,
                content: originalContent
            )
        ]
        try FileMapper.writeFiles(files, to: tempDir)

        // Save its hash in SyncState
        let originalHash = originalContent.sha256Hex
        var state = SyncState()
        state.files["data/items.json"] = FileSyncState(
            remoteId: "1",
            lastSyncedHash: originalHash,
            lastSyncTime: Date(),
            status: .synced
        )

        // Modify the file content (simulating a local user edit)
        let modifiedContent = Data("{\"id\": 1, \"name\": \"Modified\"}".utf8)
        try modifiedContent.write(to: filePath, options: .atomic)

        // Read the file back and compute its current hash
        let currentData = try Data(contentsOf: filePath)
        let currentHash = currentData.sha256Hex

        // Verify conflict: current hash differs from synced hash
        XCTAssertNotEqual(currentHash, state.files["data/items.json"]?.lastSyncedHash)

        // Verify the original hash was correct
        XCTAssertEqual(originalHash, originalContent.sha256Hex)
        XCTAssertNotEqual(originalHash, modifiedContent.sha256Hex)
    }

    // MARK: - CLAUDE.md Generation in Full Context

    func testClaudeMDGenerationInFullContext() throws {
        // Create a service dir with adapter.json
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let configJSON = """
        {
            "service": "monday",
            "displayName": "Monday.com",
            "version": "1.0",
            "auth": { "type": "bearer", "keychainKey": "monday-key" },
            "resources": [
                {
                    "name": "boards",
                    "description": "Monday.com boards",
                    "pull": { "url": "https://api.monday.com/boards" },
                    "fileMapping": {
                        "strategy": "one-per-record",
                        "directory": "boards",
                        "filename": "{name|slugify}.csv",
                        "format": "csv",
                        "idField": "id",
                        "readOnly": false
                    },
                    "sync": {
                        "interval": 90
                    }
                }
            ]
        }
        """
        try configJSON.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )

        let config = try AdapterEngine.loadConfig(from: tempDir)

        // Generate service CLAUDE.md
        let guide = AgentGuideGenerator.generateServiceGuide(
            serviceId: "monday",
            config: config,
            serverPort: 7422
        )

        // Verify it contains resource info
        XCTAssertTrue(guide.contains("Monday.com"))
        XCTAssertTrue(guide.contains("boards/"))
        XCTAssertTrue(guide.contains("csv"))

        // Verify it contains format details
        XCTAssertTrue(guide.contains("File format"))
        XCTAssertTrue(guide.contains("csv"))

        // Verify sync interval
        XCTAssertTrue(guide.contains("90"))

        // Verify it contains strategy info
        XCTAssertTrue(guide.contains("one-per-record"))

        // Verify control API section
        XCTAssertTrue(guide.contains("7422"))
        XCTAssertTrue(guide.contains("monday"))

        // Verify constraints section exists
        XCTAssertTrue(guide.contains("Constraints"))
        XCTAssertTrue(guide.contains(".api2file/"))
    }

    func testClaudeMDRootGuideGeneration() throws {
        let config = AdapterConfig(
            service: "notion",
            displayName: "Notion",
            version: "1.0",
            auth: AuthConfig(type: .bearer, keychainKey: "notion-key"),
            resources: [
                ResourceConfig(
                    name: "pages",
                    fileMapping: FileMappingConfig(
                        strategy: .onePerRecord,
                        directory: "pages",
                        format: .markdown
                    )
                )
            ]
        )

        let rootGuide = AgentGuideGenerator.generateRootGuide(
            services: [("notion", config)],
            serverPort: 7422
        )

        XCTAssertTrue(rootGuide.contains("API2File"))
        XCTAssertTrue(rootGuide.contains("notion"))
        XCTAssertTrue(rootGuide.contains("Notion"))
        XCTAssertTrue(rootGuide.contains("md"))
        XCTAssertTrue(rootGuide.contains("7422"))
    }

    // MARK: - SyncState Persistence Across Cycles

    func testSyncStatePersistenceAcrossCycles() throws {
        let stateURL = tempDir.appendingPathComponent(".api2file/state.json")

        // Create SyncState with multiple files
        let now = Date()
        var state = SyncState()
        state.files["boards/marketing.csv"] = FileSyncState(
            remoteId: "board-1",
            lastSyncedHash: "abc123def456",
            lastRemoteETag: "etag-1",
            lastSyncTime: now,
            status: .synced
        )
        state.files["boards/engineering.csv"] = FileSyncState(
            remoteId: "board-2",
            lastSyncedHash: "789xyz000111",
            lastRemoteETag: "etag-2",
            lastSyncTime: now,
            status: .synced
        )
        state.files["docs/readme.md"] = FileSyncState(
            remoteId: "doc-1",
            lastSyncedHash: "hash999",
            lastSyncTime: now,
            status: .modified
        )

        // Save to disk
        try state.save(to: stateURL)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        // Load it back
        let loaded = try SyncState.load(from: stateURL)

        // Verify all fields match
        XCTAssertEqual(loaded.files.count, 3)
        XCTAssertEqual(loaded.files["boards/marketing.csv"]?.remoteId, "board-1")
        XCTAssertEqual(loaded.files["boards/marketing.csv"]?.lastSyncedHash, "abc123def456")
        XCTAssertEqual(loaded.files["boards/marketing.csv"]?.lastRemoteETag, "etag-1")
        XCTAssertEqual(loaded.files["boards/marketing.csv"]?.status, .synced)

        XCTAssertEqual(loaded.files["boards/engineering.csv"]?.remoteId, "board-2")
        XCTAssertEqual(loaded.files["boards/engineering.csv"]?.lastSyncedHash, "789xyz000111")

        XCTAssertEqual(loaded.files["docs/readme.md"]?.remoteId, "doc-1")
        XCTAssertEqual(loaded.files["docs/readme.md"]?.status, .modified)

        // Modify a file's status
        var updatedState = loaded
        updatedState.files["boards/marketing.csv"]?.status = .conflict
        updatedState.files["boards/marketing.csv"]?.lastSyncedHash = "newhash999"

        // Save and reload again
        try updatedState.save(to: stateURL)
        let reloaded = try SyncState.load(from: stateURL)

        // Verify the modification persisted
        XCTAssertEqual(reloaded.files["boards/marketing.csv"]?.status, .conflict)
        XCTAssertEqual(reloaded.files["boards/marketing.csv"]?.lastSyncedHash, "newhash999")
        // Other files unchanged
        XCTAssertEqual(reloaded.files["boards/engineering.csv"]?.status, .synced)
        XCTAssertEqual(reloaded.files["docs/readme.md"]?.status, .modified)
    }

    func testSyncStateEmptyPersistence() throws {
        let stateURL = tempDir.appendingPathComponent(".api2file/state.json")

        // Empty state
        let state = SyncState()
        try state.save(to: stateURL)

        let loaded = try SyncState.load(from: stateURL)
        XCTAssertTrue(loaded.files.isEmpty)
    }

    // MARK: - Git Tracks Sync History

    func testGitTracksSyncHistory() async throws {
        // Initialize git
        let git = GitManager(repoPath: tempDir)
        try await git.initRepo()
        try configureGitUser(at: tempDir)

        // Write a file and commit as "sync: pull"
        let filePath = tempDir.appendingPathComponent("items/data.csv")
        let dir = tempDir.appendingPathComponent("items")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "id,name\n1,Alpha\n".write(to: filePath, atomically: true, encoding: .utf8)

        try await git.commitAll(message: "sync: pull items from API")

        // Modify the file and commit as "sync: push"
        try "id,name\n1,Alpha Updated\n".write(to: filePath, atomically: true, encoding: .utf8)

        try await git.commitAll(message: "sync: push local changes")

        // Verify git log shows both commits in correct order
        let log = try runGitCommand(["log", "--oneline"], at: tempDir)
        let lines = log.split(separator: "\n")

        XCTAssertGreaterThanOrEqual(lines.count, 2)
        // Most recent commit first
        XCTAssertTrue(String(lines[0]).contains("sync: push local changes"))
        XCTAssertTrue(String(lines[1]).contains("sync: pull items from API"))
    }

    func testGitTracksMultipleFileChanges() async throws {
        let git = GitManager(repoPath: tempDir)
        try await git.initRepo()
        try configureGitUser(at: tempDir)

        // First sync: write two files
        let files1 = [
            SyncableFile(
                relativePath: "boards/alpha.json",
                format: .json,
                content: Data("{\"id\": 1, \"name\": \"Alpha\"}".utf8)
            ),
            SyncableFile(
                relativePath: "boards/beta.json",
                format: .json,
                content: Data("{\"id\": 2, \"name\": \"Beta\"}".utf8)
            )
        ]
        try FileMapper.writeFiles(files1, to: tempDir)
        try await git.commitAll(message: "sync: pull 2 boards")

        // Second sync: modify one file, add another
        let files2 = [
            SyncableFile(
                relativePath: "boards/alpha.json",
                format: .json,
                content: Data("{\"id\": 1, \"name\": \"Alpha Updated\"}".utf8)
            ),
            SyncableFile(
                relativePath: "boards/gamma.json",
                format: .json,
                content: Data("{\"id\": 3, \"name\": \"Gamma\"}".utf8)
            )
        ]
        try FileMapper.writeFiles(files2, to: tempDir)
        try await git.commitAll(message: "sync: pull updated boards")

        // Verify both commits exist
        let log = try runGitCommand(["log", "--oneline"], at: tempDir)
        XCTAssertTrue(log.contains("sync: pull 2 boards"))
        XCTAssertTrue(log.contains("sync: pull updated boards"))

        // Verify file content is up to date
        let alphaData = try Data(contentsOf: tempDir.appendingPathComponent("boards/alpha.json"))
        let alphaStr = String(data: alphaData, encoding: .utf8)!
        XCTAssertTrue(alphaStr.contains("Alpha Updated"))

        // Verify gamma exists
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            tempDir.appendingPathComponent("boards/gamma.json").path))

        // Verify no uncommitted changes remain
        let hasChanges = try await git.hasChanges()
        XCTAssertFalse(hasChanges)
    }

    // MARK: - Test Helpers

    private func configureGitUser(at dir: URL) throws {
        _ = try runGitCommand(["config", "user.email", "test@api2file.dev"], at: dir)
        _ = try runGitCommand(["config", "user.name", "Test User"], at: dir)
    }

    @discardableResult
    private func runGitCommand(_ arguments: [String], at dir: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
