import Foundation

/// Persistent sync state for a service — stored in .api2file/state.json
public struct SyncState: Codable, Sendable {
    public var files: [String: FileSyncState]
    /// Last full sync time per resource name — used to compute updatedSince for incremental pulls
    public var resourceSyncTimes: [String: Date]
    /// Count of sync intervals since last full sync per resource name
    public var syncCounts: [String: Int]
    /// ETag per resource name — used for HTTP conditional requests (If-None-Match / 304)
    public var resourceETags: [String: String]
    /// Consecutive empty pull count per resource — used for skip-empty backoff
    public var emptyPullCounts: [String: Int]
    /// Last time a resource had actual data changes — used for adaptive intervals
    public var lastChangeTime: [String: Date]

    public init(
        files: [String: FileSyncState] = [:],
        resourceSyncTimes: [String: Date] = [:],
        syncCounts: [String: Int] = [:],
        resourceETags: [String: String] = [:],
        emptyPullCounts: [String: Int] = [:],
        lastChangeTime: [String: Date] = [:]
    ) {
        self.files = files
        self.resourceSyncTimes = resourceSyncTimes
        self.syncCounts = syncCounts
        self.resourceETags = resourceETags
        self.emptyPullCounts = emptyPullCounts
        self.lastChangeTime = lastChangeTime
    }

    // MARK: - Decodable (backwards-compatible)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([String: FileSyncState].self, forKey: .files)
        resourceSyncTimes = try container.decodeIfPresent([String: Date].self, forKey: .resourceSyncTimes) ?? [:]
        syncCounts = try container.decodeIfPresent([String: Int].self, forKey: .syncCounts) ?? [:]
        resourceETags = try container.decodeIfPresent([String: String].self, forKey: .resourceETags) ?? [:]
        emptyPullCounts = try container.decodeIfPresent([String: Int].self, forKey: .emptyPullCounts) ?? [:]
        lastChangeTime = try container.decodeIfPresent([String: Date].self, forKey: .lastChangeTime) ?? [:]
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
    /// If true, this file is excluded from sync in both directions (default: nil = not excluded)
    public var excluded: Bool?

    public init(remoteId: String, lastSyncedHash: String, lastRemoteETag: String? = nil, lastSyncTime: Date = Date(), status: SyncStatus = .synced, excluded: Bool? = nil) {
        self.remoteId = remoteId
        self.lastSyncedHash = lastSyncedHash
        self.lastRemoteETag = lastRemoteETag
        self.lastSyncTime = lastSyncTime
        self.status = status
        self.excluded = excluded
    }
}
