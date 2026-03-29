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
    public var deleteFromAPI: Bool
    public var enableSnapshots: Bool

    public init(
        syncFolder: String = "~/API2File-Data",
        gitAutoCommit: Bool = true,
        commitMessageFormat: String = "sync: {service} — {summary}",
        defaultSyncInterval: Int = 60,
        showNotifications: Bool = true,
        finderBadges: Bool = true,
        serverPort: Int = 21567,
        launchAtLogin: Bool = false,
        deleteFromAPI: Bool = false,
        enableSnapshots: Bool = true
    ) {
        self.syncFolder = syncFolder
        self.gitAutoCommit = gitAutoCommit
        self.commitMessageFormat = commitMessageFormat
        self.defaultSyncInterval = defaultSyncInterval
        self.showNotifications = showNotifications
        self.finderBadges = finderBadges
        self.serverPort = serverPort
        self.launchAtLogin = launchAtLogin
        self.deleteFromAPI = deleteFromAPI
        self.enableSnapshots = enableSnapshots
    }

    /// Resolve the sync folder path, expanding ~ to home directory
    public var resolvedSyncFolder: URL {
        resolvedSyncFolder(using: .current)
    }

    public func resolvedSyncFolder(using locations: StorageLocations) -> URL {
        let homePath = locations.homeDirectory.path
        let path = syncFolder.replacingOccurrences(of: "~", with: homePath)
        return URL(fileURLWithPath: path)
    }

    // MARK: - Persistence

    public static func load(from url: URL) throws -> GlobalConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GlobalConfig.self, from: data)
    }

    public static func loadOrDefault(syncFolder: URL, defaultConfig: @autoclosure () -> GlobalConfig = GlobalConfig()) -> GlobalConfig {
        let configURL = syncFolder.appendingPathComponent(".api2file.json")
        return (try? load(from: configURL)) ?? defaultConfig()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
