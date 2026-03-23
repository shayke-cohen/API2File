import Foundation

/// Global API2File configuration — stored in ~/API2File/.api2file.json
public struct GlobalConfig: Codable, Sendable {
    public var syncFolder: String
    public var gitAutoCommit: Bool
    public var commitMessageFormat: String
    public var defaultSyncInterval: Int
    public var showNotifications: Bool
    public var finderBadges: Bool
    public var serverPort: Int
    public var launchAtLogin: Bool

    public init(
        syncFolder: String = "~/API2File",
        gitAutoCommit: Bool = true,
        commitMessageFormat: String = "sync: {service} — {summary}",
        defaultSyncInterval: Int = 60,
        showNotifications: Bool = true,
        finderBadges: Bool = true,
        serverPort: Int = 21567,
        launchAtLogin: Bool = false
    ) {
        self.syncFolder = syncFolder
        self.gitAutoCommit = gitAutoCommit
        self.commitMessageFormat = commitMessageFormat
        self.defaultSyncInterval = defaultSyncInterval
        self.showNotifications = showNotifications
        self.finderBadges = finderBadges
        self.serverPort = serverPort
        self.launchAtLogin = launchAtLogin
    }

    /// Resolve the sync folder path, expanding ~ to home directory
    public var resolvedSyncFolder: URL {
        let path = syncFolder.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
        return URL(fileURLWithPath: path)
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> GlobalConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GlobalConfig.self, from: data)
    }

    public static func loadOrDefault(syncFolder: URL) -> GlobalConfig {
        let configURL = syncFolder.appendingPathComponent(".api2file.json")
        return (try? load(from: configURL)) ?? GlobalConfig()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
