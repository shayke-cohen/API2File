import Cocoa
import FinderSync

/// Finder Sync Extension for API2File
/// Shows badge overlays on synced files in ~/API2File/
class API2FileFinder: FIFinderSync {

    let syncFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("API2File")

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
        // Check for .conflict file
        let conflictPath = conflictFilePath(for: url)
        if FileManager.default.fileExists(atPath: conflictPath.path) {
            return "conflict"
        }

        // Read sync state from .api2file/state.json
        guard let serviceId = extractServiceId(from: url) else { return "" }
        let stateURL = syncFolderURL
            .appendingPathComponent(serviceId)
            .appendingPathComponent(".api2file/state.json")

        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncStateCompact.self, from: data) else {
            return ""
        }

        // Get relative path within service
        let servicePath = syncFolderURL.appendingPathComponent(serviceId).path
        let relativePath = String(url.path.dropFirst(servicePath.count + 1))

        if let fileState = state.files[relativePath] {
            return fileState.status
        }

        return "synced" // Default to synced if file exists but not in state
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
}

// Compact state model for Finder extension (avoids importing full API2FileCore)
private struct SyncStateCompact: Codable {
    let files: [String: FileStateCompact]
}

private struct FileStateCompact: Codable {
    let status: String
}
