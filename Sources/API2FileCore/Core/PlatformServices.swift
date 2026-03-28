import Foundation

/// Platform-specific services that the sync engine depends on.
public struct PlatformServices: @unchecked Sendable {
    public let storageLocations: StorageLocations
    public let adapterStore: AdapterStore
    public let keychainManager: KeychainManager
    public let notificationManager: NotificationManager
    public let fileWatcher: FileWatcher
    public let configWatcher: ConfigWatcher
    public let versionControlFactory: VersionControlBackendFactory

    public init(
        storageLocations: StorageLocations = .current,
        adapterStore: AdapterStore? = nil,
        keychainManager: KeychainManager = .shared,
        notificationManager: NotificationManager = .shared,
        fileWatcher: FileWatcher = FileWatcher(),
        configWatcher: ConfigWatcher = ConfigWatcher(),
        versionControlFactory: VersionControlBackendFactory = .current
    ) {
        let store = adapterStore ?? AdapterStore(storageLocations: storageLocations)
        self.storageLocations = storageLocations
        self.adapterStore = store
        self.keychainManager = keychainManager
        self.notificationManager = notificationManager
        self.fileWatcher = fileWatcher
        self.configWatcher = configWatcher
        self.versionControlFactory = versionControlFactory
    }

    public static var current: PlatformServices {
        PlatformServices()
    }

    public static var iOSApp: PlatformServices {
        let storage = StorageLocations.current
        return PlatformServices(
            storageLocations: storage,
            adapterStore: AdapterStore(storageLocations: storage),
            versionControlFactory: .embedded
        )
    }
}
