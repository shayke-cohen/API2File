import Foundation

/// Global API2File configuration — stored in ~/API2File/.api2file.json
public struct GlobalConfig: Codable, Sendable {
    public var syncFolder: String
    public var managedWorkspaceFolder: String
    public var gitAutoCommit: Bool
    public var commitMessageFormat: String
    public var defaultSyncInterval: Int
    public var showNotifications: Bool
    public var finderBadges: Bool
    public var serverPort: Int
    public var launchAtLogin: Bool
    public var deleteFromAPI: Bool
    public var enableSnapshots: Bool
    public var generateCompanionFiles: Bool

    public init(
        syncFolder: String = "~/API2File-Data",
        managedWorkspaceFolder: String = "~/API2File-Workspace",
        gitAutoCommit: Bool = true,
        commitMessageFormat: String = "sync: {service} — {summary}",
        defaultSyncInterval: Int = 60,
        showNotifications: Bool = true,
        finderBadges: Bool = true,
        serverPort: Int = 21567,
        launchAtLogin: Bool = false,
        deleteFromAPI: Bool = false,
        enableSnapshots: Bool = true,
        generateCompanionFiles: Bool = false
    ) {
        self.syncFolder = syncFolder
        self.managedWorkspaceFolder = managedWorkspaceFolder
        self.gitAutoCommit = gitAutoCommit
        self.commitMessageFormat = commitMessageFormat
        self.defaultSyncInterval = defaultSyncInterval
        self.showNotifications = showNotifications
        self.finderBadges = finderBadges
        self.serverPort = serverPort
        self.launchAtLogin = launchAtLogin
        self.deleteFromAPI = deleteFromAPI
        self.enableSnapshots = enableSnapshots
        self.generateCompanionFiles = generateCompanionFiles
    }

    private enum CodingKeys: String, CodingKey {
        case syncFolder
        case managedWorkspaceFolder
        case gitAutoCommit
        case commitMessageFormat
        case defaultSyncInterval
        case showNotifications
        case finderBadges
        case serverPort
        case launchAtLogin
        case deleteFromAPI
        case enableSnapshots
        case generateCompanionFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        syncFolder = try container.decodeIfPresent(String.self, forKey: .syncFolder) ?? "~/API2File-Data"
        managedWorkspaceFolder = try container.decodeIfPresent(String.self, forKey: .managedWorkspaceFolder) ?? "~/API2File-Workspace"
        gitAutoCommit = try container.decodeIfPresent(Bool.self, forKey: .gitAutoCommit) ?? true
        commitMessageFormat = try container.decodeIfPresent(String.self, forKey: .commitMessageFormat) ?? "sync: {service} — {summary}"
        defaultSyncInterval = try container.decodeIfPresent(Int.self, forKey: .defaultSyncInterval) ?? 60
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
        finderBadges = try container.decodeIfPresent(Bool.self, forKey: .finderBadges) ?? true
        serverPort = try container.decodeIfPresent(Int.self, forKey: .serverPort) ?? 21567
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        deleteFromAPI = try container.decodeIfPresent(Bool.self, forKey: .deleteFromAPI) ?? false
        enableSnapshots = try container.decodeIfPresent(Bool.self, forKey: .enableSnapshots) ?? true
        generateCompanionFiles = try container.decodeIfPresent(Bool.self, forKey: .generateCompanionFiles) ?? false
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

    public var resolvedManagedWorkspaceFolder: URL {
        resolvedManagedWorkspaceFolder(using: .current)
    }

    public func resolvedManagedWorkspaceFolder(using locations: StorageLocations) -> URL {
        let homePath = locations.homeDirectory.path
        let path = managedWorkspaceFolder.replacingOccurrences(of: "~", with: homePath)
        return URL(fileURLWithPath: path)
    }

    public func resolvedServiceRoot(
        serviceId: String,
        storageMode: ServiceStorageMode,
        using locations: StorageLocations
    ) -> URL {
        switch storageMode {
        case .plainSync:
            return resolvedSyncFolder(using: locations).appendingPathComponent(serviceId, isDirectory: true)
        case .managedWorkspace:
            return resolvedManagedWorkspaceFolder(using: locations).appendingPathComponent(serviceId, isDirectory: true)
        }
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
