import Cocoa
import FinderSync

/// Finder Sync Extension for API2File
/// Shows badge overlays on synced files in ~/API2File/
class API2FileFinder: FIFinderSync {

    let syncFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("API2File")

    /// Shared UserDefaults via App Group for cross-process badge state communication.
    /// The main app writes badge states here; the Finder extension reads them.
    private let sharedDefaults = UserDefaults(suiteName: "group.com.api2file")

    /// Key prefix for badge state entries in shared UserDefaults.
    private static let badgeKeyPrefix = "badge."

    override init() {
        super.init()

        // Watch the sync folder
        FIFinderSyncController.default().directoryURLs = [syncFolderURL]

        // Register badge images
        let syncedImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Synced")!
        let syncingImage = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.circle.fill", accessibilityDescription: "Syncing")!
        let conflictImage = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Conflict")!
        let errorImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Error")!

        FIFinderSyncController.default().setBadgeImage(syncedImage, label: "Synced", forBadgeIdentifier: "synced")
        FIFinderSyncController.default().setBadgeImage(syncingImage, label: "Syncing", forBadgeIdentifier: "syncing")
        FIFinderSyncController.default().setBadgeImage(conflictImage, label: "Conflict", forBadgeIdentifier: "conflict")
        FIFinderSyncController.default().setBadgeImage(errorImage, label: "Error", forBadgeIdentifier: "error")
    }

    // MARK: - Primary Finder Sync Protocol

    override func beginObservingDirectory(at url: URL) {
        // Called when the user navigates to a watched directory
    }

    override func endObservingDirectory(at url: URL) {
        // Called when the user navigates away
    }

    override func requestBadgeIdentifier(for url: URL) {
        // Determine the sync status of this file
        let status = lookupSyncStatus(for: url)
        FIFinderSyncController.default().setBadgeIdentifier(status, for: url)
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "API2File")

        let syncItem = NSMenuItem(title: "Force Sync", action: #selector(forceSyncAction(_:)), keyEquivalent: "")
        syncItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(syncItem)

        let viewItem = NSMenuItem(title: "View on Server", action: #selector(viewOnServerAction(_:)), keyEquivalent: "")
        viewItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(viewItem)

        // Add conflict resolution if there's a .conflict file
        if let targetURL = FIFinderSyncController.default().targetedURL(),
           hasConflict(at: targetURL) {
            menu.addItem(NSMenuItem.separator())
            let resolveItem = NSMenuItem(title: "View Conflict", action: #selector(viewConflictAction(_:)), keyEquivalent: "")
            resolveItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(resolveItem)
        }

        return menu
    }

    // MARK: - Actions

    @objc func forceSyncAction(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }

        // Extract service ID from path
        guard let serviceId = extractServiceId(from: items[0]) else { return }

        // Trigger sync via the Control API
        Task {
            let url = URL(string: "http://localhost:21567/api/services/\(serviceId)/sync")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    @objc func viewOnServerAction(_ sender: AnyObject?) {
        // TODO: Open the corresponding page on the cloud service
    }

    @objc func viewConflictAction(_ sender: AnyObject?) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), let url = items.first else { return }

        // Find the .conflict file and open both in FileMerge or side-by-side
        let conflictPath = conflictFilePath(for: url)
        if FileManager.default.fileExists(atPath: conflictPath.path) {
            NSWorkspace.shared.open(conflictPath)
        }
    }

    // MARK: - Helpers

    private func lookupSyncStatus(for url: URL) -> String {
        // Check for .conflict file first
        let conflictPath = conflictFilePath(for: url)
        if FileManager.default.fileExists(atPath: conflictPath.path) {
            return "conflict"
        }

        // Build a relative path key from the sync folder root
        let syncPath = syncFolderURL.path
        guard url.path.hasPrefix(syncPath) else { return "" }
        let relativePath = String(url.path.dropFirst(syncPath.count + 1))

        // Read badge state from shared App Group UserDefaults
        let key = Self.badgeKeyPrefix + relativePath
        if let status = sharedDefaults?.string(forKey: key), !status.isEmpty {
            return status
        }

        // Fallback: check if the file exists in the sync folder at all
        if FileManager.default.fileExists(atPath: url.path) {
            return "synced"
        }

        return ""
    }

    private func extractServiceId(from url: URL) -> String? {
        let syncPath = syncFolderURL.path
        guard url.path.hasPrefix(syncPath) else { return nil }
        let relative = String(url.path.dropFirst(syncPath.count + 1))
        return relative.split(separator: "/").first.map(String.init)
    }

    private func hasConflict(at url: URL) -> Bool {
        let conflictPath = conflictFilePath(for: url)
        return FileManager.default.fileExists(atPath: conflictPath.path)
    }

    private func conflictFilePath(for url: URL) -> URL {
        let ext = url.pathExtension
        let nameWithoutExt = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        return dir.appendingPathComponent("\(nameWithoutExt).conflict.\(ext)")
    }

    // MARK: - Public API for Main App

    /// Convenience method for the main app to write badge state into shared UserDefaults.
    /// Call from the main app process to update badge overlays visible in Finder.
    ///
    /// - Parameters:
    ///   - status: Badge identifier ("synced", "syncing", "conflict", "error", or "" to clear)
    ///   - relativePath: File path relative to the ~/API2File/ sync folder
    static func setBadgeState(_ status: String, forRelativePath relativePath: String) {
        guard let defaults = UserDefaults(suiteName: "group.com.api2file") else { return }
        let key = badgeKeyPrefix + relativePath
        if status.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(status, forKey: key)
        }
    }

    /// Convenience method to read the current badge state for a file.
    ///
    /// - Parameter relativePath: File path relative to the ~/API2File/ sync folder
    /// - Returns: Badge identifier string, or nil if not set
    static func badgeState(forRelativePath relativePath: String) -> String? {
        guard let defaults = UserDefaults(suiteName: "group.com.api2file") else { return nil }
        let key = badgeKeyPrefix + relativePath
        return defaults.string(forKey: key)
    }
}
