import Foundation

/// Persistent sync history for a service — stored in .api2file/sync-history.json
public struct SyncHistoryLog: Codable, Sendable {
    public var entries: [SyncHistoryEntry]

    private static let maxEntries = 500

    public init(entries: [SyncHistoryEntry] = []) {
        self.entries = entries
    }

    /// Append a new entry (newest first) and prune if over limit
    public mutating func append(_ entry: SyncHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> SyncHistoryLog {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncHistoryLog.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
