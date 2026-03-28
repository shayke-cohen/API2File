import XCTest
@testable import API2FileCore

final class SyncStateTests: XCTestCase {

    // MARK: - SyncState

    func testSaveAndLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncStateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("state.json")

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var state = SyncState()
        state.files["notes/hello.md"] = FileSyncState(
            remoteId: "r-001",
            lastSyncedHash: "aabbccdd",
            lastRemoteETag: "W/\"etag1\"",
            lastSyncTime: date,
            status: .synced
        )

        try state.save(to: fileURL)
        let loaded = try SyncState.load(from: fileURL)

        XCTAssertEqual(loaded.files.count, 1)
        let file = try XCTUnwrap(loaded.files["notes/hello.md"])
        XCTAssertEqual(file.remoteId, "r-001")
        XCTAssertEqual(file.lastSyncedHash, "aabbccdd")
        XCTAssertEqual(file.lastRemoteETag, "W/\"etag1\"")
        XCTAssertEqual(file.lastSyncTime.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(file.status, .synced)
    }

    func testLoadNonExistentFileThrows() {
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        XCTAssertThrowsError(try SyncState.load(from: bogusURL))
    }

    func testFileSyncStateStoresAllFields() {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let fs = FileSyncState(
            remoteId: "id-42",
            lastSyncedHash: "0123456789abcdef",
            lastRemoteETag: "\"strong-etag\"",
            lastSyncTime: date,
            status: .conflict
        )

        XCTAssertEqual(fs.remoteId, "id-42")
        XCTAssertEqual(fs.lastSyncedHash, "0123456789abcdef")
        XCTAssertEqual(fs.lastRemoteETag, "\"strong-etag\"")
        XCTAssertEqual(fs.lastSyncTime, date)
        XCTAssertEqual(fs.status, .conflict)
    }

    func testMultipleFilesInState() throws {
        var state = SyncState()
        state.files["a.json"] = FileSyncState(remoteId: "1", lastSyncedHash: "h1", status: .synced)
        state.files["b.csv"] = FileSyncState(remoteId: "2", lastSyncedHash: "h2", status: .modified)
        state.files["c.md"] = FileSyncState(remoteId: "3", lastSyncedHash: "h3", status: .error)

        XCTAssertEqual(state.files.count, 3)
        XCTAssertEqual(state.files["a.json"]?.remoteId, "1")
        XCTAssertEqual(state.files["b.csv"]?.status, .modified)
        XCTAssertEqual(state.files["c.md"]?.status, .error)

        // Round-trip through JSON
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SyncState.self, from: data)
        XCTAssertEqual(decoded.files.count, 3)
        XCTAssertEqual(decoded.files["a.json"]?.lastSyncedHash, "h1")
        XCTAssertEqual(decoded.files["b.csv"]?.lastSyncedHash, "h2")
        XCTAssertEqual(decoded.files["c.md"]?.lastSyncedHash, "h3")
    }
}

// MARK: - GlobalConfig Tests

final class GlobalConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = GlobalConfig()
        XCTAssertEqual(config.syncFolder, "~/API2File-Data")
        XCTAssertTrue(config.gitAutoCommit)
        XCTAssertEqual(config.commitMessageFormat, "sync: {service} — {summary}")
        XCTAssertEqual(config.defaultSyncInterval, 60)
        XCTAssertTrue(config.showNotifications)
        XCTAssertTrue(config.finderBadges)
        XCTAssertEqual(config.serverPort, 21567)
        XCTAssertFalse(config.launchAtLogin)
    }

    func testSaveAndLoadRoundTrip() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalConfigTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let fileURL = tmpDir.appendingPathComponent("config.json")

        let config = GlobalConfig(
            syncFolder: "/custom/path",
            gitAutoCommit: false,
            commitMessageFormat: "custom: {summary}",
            defaultSyncInterval: 120,
            showNotifications: false,
            finderBadges: false,
            serverPort: 9999,
            launchAtLogin: true
        )

        try config.save(to: fileURL)
        let loaded = try GlobalConfig.load(from: fileURL)

        XCTAssertEqual(loaded.syncFolder, "/custom/path")
        XCTAssertFalse(loaded.gitAutoCommit)
        XCTAssertEqual(loaded.commitMessageFormat, "custom: {summary}")
        XCTAssertEqual(loaded.defaultSyncInterval, 120)
        XCTAssertFalse(loaded.showNotifications)
        XCTAssertFalse(loaded.finderBadges)
        XCTAssertEqual(loaded.serverPort, 9999)
        XCTAssertTrue(loaded.launchAtLogin)
    }

    func testLoadOrDefaultReturnsDefaultsWhenFileDoesNotExist() {
        let bogusDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-dir-\(UUID().uuidString)")
        let config = GlobalConfig.loadOrDefault(syncFolder: bogusDir)

        // Should return defaults since the file doesn't exist
        XCTAssertEqual(config.syncFolder, "~/API2File-Data")
        XCTAssertTrue(config.gitAutoCommit)
        XCTAssertEqual(config.defaultSyncInterval, 60)
    }

    func testResolvedSyncFolderExpandsTilde() {
        let config = GlobalConfig(syncFolder: "~/API2File-Data")
        let resolved = config.resolvedSyncFolder

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(resolved.path.hasPrefix(home), "Resolved path should start with home directory")
        XCTAssertTrue(resolved.path.hasSuffix("API2File-Data"), "Resolved path should end with API2File-Data")
        XCTAssertFalse(resolved.path.contains("~"), "Resolved path should not contain tilde")
    }

    func testResolvedSyncFolderAbsolutePathUnchanged() {
        let config = GlobalConfig(syncFolder: "/tmp/my-sync")
        let resolved = config.resolvedSyncFolder
        XCTAssertEqual(resolved.path, "/tmp/my-sync")
    }

    func testResolvedSyncFolderUsesInjectedStorageLocations() {
        let locations = StorageLocations(
            homeDirectory: URL(fileURLWithPath: "/sandbox/home", isDirectory: true),
            syncRootDirectory: URL(fileURLWithPath: "/sandbox/Documents/API2File-Data", isDirectory: true),
            adaptersDirectory: URL(fileURLWithPath: "/sandbox/Library/API2File/Adapters", isDirectory: true),
            applicationSupportDirectory: URL(fileURLWithPath: "/sandbox/Library/Application Support", isDirectory: true)
        )
        let config = GlobalConfig(syncFolder: "~/API2File-Data")
        let resolved = config.resolvedSyncFolder(using: locations)

        XCTAssertEqual(resolved.path, "/sandbox/home/API2File-Data")
    }
}

// MARK: - SyncableFile Tests

final class SyncableFileTests: XCTestCase {

    func testContentHashProducesConsistentSHA256HexString() {
        let content = "Hello, world!".data(using: .utf8)!
        let file = SyncableFile(relativePath: "test.txt", format: .text, content: content)
        let hash1 = file.contentHash
        let hash2 = file.contentHash

        // SHA256 produces a 64-character hex string
        XCTAssertEqual(hash1.count, 64)
        XCTAssertEqual(hash1, hash2, "Same content should produce the same hash")

        // Verify it's valid hex
        let hexCharSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hash1.unicodeScalars.allSatisfy { hexCharSet.contains($0) },
                      "Hash should only contain hex characters")
    }

    func testDifferentContentProducesDifferentHashes() {
        let file1 = SyncableFile(relativePath: "a.txt", format: .text, content: "alpha".data(using: .utf8)!)
        let file2 = SyncableFile(relativePath: "b.txt", format: .text, content: "beta".data(using: .utf8)!)

        XCTAssertNotEqual(file1.contentHash, file2.contentHash)
    }

    func testSameContentProducesSameHash() {
        let content = "identical content".data(using: .utf8)!
        let file1 = SyncableFile(relativePath: "one.txt", format: .text, content: content)
        let file2 = SyncableFile(relativePath: "two.json", format: .json, content: content)

        XCTAssertEqual(file1.contentHash, file2.contentHash,
                       "Files with different paths but same content should have the same hash")
    }
}

// MARK: - SyncStatus Tests

final class SyncStatusTests: XCTestCase {

    func testAllSyncStatusCasesEncodeAndDecode() throws {
        let allCases: [SyncStatus] = [.synced, .syncing, .modified, .conflict, .error]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(SyncStatus.self, from: data)
            XCTAssertEqual(decoded, status, "Round-trip failed for SyncStatus.\(status)")
        }
    }

    func testSyncStatusRawValues() {
        XCTAssertEqual(SyncStatus.synced.rawValue, "synced")
        XCTAssertEqual(SyncStatus.syncing.rawValue, "syncing")
        XCTAssertEqual(SyncStatus.modified.rawValue, "modified")
        XCTAssertEqual(SyncStatus.conflict.rawValue, "conflict")
        XCTAssertEqual(SyncStatus.error.rawValue, "error")
    }

    func testAllServiceStatusCasesEncodeAndDecode() throws {
        let allCases: [ServiceStatus] = [.connected, .syncing, .paused, .error, .disconnected]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for status in allCases {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(ServiceStatus.self, from: data)
            XCTAssertEqual(decoded, status, "Round-trip failed for ServiceStatus.\(status)")
        }
    }

    func testServiceStatusRawValues() {
        XCTAssertEqual(ServiceStatus.connected.rawValue, "connected")
        XCTAssertEqual(ServiceStatus.syncing.rawValue, "syncing")
        XCTAssertEqual(ServiceStatus.paused.rawValue, "paused")
        XCTAssertEqual(ServiceStatus.error.rawValue, "error")
        XCTAssertEqual(ServiceStatus.disconnected.rawValue, "disconnected")
    }
}
