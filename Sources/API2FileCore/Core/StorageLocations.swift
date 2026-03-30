import Foundation
#if os(macOS)
import Darwin
#endif

/// Filesystem locations used by API2File on the current platform.
public struct StorageLocations: Sendable {
    public let homeDirectory: URL
    public let syncRootDirectory: URL
    public let managedWorkspaceDirectory: URL
    public let adaptersDirectory: URL
    public let applicationSupportDirectory: URL

    public init(
        homeDirectory: URL,
        syncRootDirectory: URL,
        managedWorkspaceDirectory: URL? = nil,
        adaptersDirectory: URL,
        applicationSupportDirectory: URL
    ) {
        self.homeDirectory = homeDirectory
        self.syncRootDirectory = syncRootDirectory
        self.managedWorkspaceDirectory = managedWorkspaceDirectory
            ?? homeDirectory.appendingPathComponent("API2File-Workspace", isDirectory: true)
        self.adaptersDirectory = adaptersDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public static var current: StorageLocations {
        let fm = FileManager.default
        let home = currentUserHomeDirectory()

        #if os(iOS)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? home
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home
        let syncRoot = documents.appendingPathComponent("API2File-Data", isDirectory: true)
        let workspaceRoot = documents.appendingPathComponent("API2File-Workspace", isDirectory: true)
        let adapters = appSupport
            .appendingPathComponent("API2File", isDirectory: true)
            .appendingPathComponent("Adapters", isDirectory: true)
        return StorageLocations(
            homeDirectory: home,
            syncRootDirectory: syncRoot,
            managedWorkspaceDirectory: workspaceRoot,
            adaptersDirectory: adapters,
            applicationSupportDirectory: appSupport
        )
        #else
        let syncRoot = home.appendingPathComponent("API2File-Data", isDirectory: true)
        let workspaceRoot = home.appendingPathComponent("API2File-Workspace", isDirectory: true)
        let adapters = home
            .appendingPathComponent(".api2file", isDirectory: true)
            .appendingPathComponent("adapters", isDirectory: true)
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? home
        return StorageLocations(
            homeDirectory: home,
            syncRootDirectory: syncRoot,
            managedWorkspaceDirectory: workspaceRoot,
            adaptersDirectory: adapters,
            applicationSupportDirectory: appSupport
        )
        #endif
    }

    static func currentUserHomeDirectory(
        environmentHome: String? = ProcessInfo.processInfo.environment["HOME"],
        posixHomeDirectory: String? = Self.posixHomeDirectoryPath()
    ) -> URL {
        #if os(macOS)
        if let posixHomeDirectory, posixHomeDirectory.hasPrefix("/") {
            return URL(fileURLWithPath: posixHomeDirectory, isDirectory: true)
        }
        #endif

        if let environmentHome, environmentHome.hasPrefix("/") {
            return URL(fileURLWithPath: environmentHome, isDirectory: true)
        }

        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    #if os(macOS)
    private static func posixHomeDirectoryPath() -> String? {
        guard let pwd = getpwuid(getuid()),
              let home = pwd.pointee.pw_dir else {
            return nil
        }
        return String(cString: home)
    }
    #else
    private static func posixHomeDirectoryPath() -> String? {
        nil
    }
    #endif
}
