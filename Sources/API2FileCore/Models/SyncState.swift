import Foundation

/// Persistent sync state for a service — stored in .api2file/state.json
public struct SyncState: Codable, Sendable {
    public var files: [String: FileSyncState]

    public init(files: [String: FileSyncState] = [:]) {
        self.files = files
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> SyncState {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Sync state for an individual file
public struct FileSyncState: Codable, Sendable {
    public var remoteId: String
    public var lastSyncedHash: String
    public var lastRemoteETag: String?
    public var lastSyncTime: Date
    public var status: SyncStatus

    public init(remoteId: String, lastSyncedHash: String, lastRemoteETag: String? = nil, lastSyncTime: Date = Date(), status: SyncStatus = .synced) {
        self.remoteId = remoteId
        self.lastSyncedHash = lastSyncedHash
        self.lastRemoteETag = lastRemoteETag
        self.lastSyncTime = lastSyncTime
        self.status = status
    }
}
