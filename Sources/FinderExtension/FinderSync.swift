import Cocoa
import FinderSync
import API2FileCore

/// Finder Sync Extension for API2File.
/// Shows sync-status overlays, including Wix-branded variants for the Wix service.
final class FinderSync: FIFinderSync {
    private let sharedDefaults = FinderBadgeSupport.sharedDefaults()
    private let controlServerBaseURL = "http://127.0.0.1:21567"
    private let fallbackSyncFolderURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("API2File-Data", isDirectory: true)
    private var securityScopedSyncFolderURL: URL?

    override init() {
        super.init()

        NSLog("FinderSync init bundle=%@", Bundle.main.bundlePath)
        refreshSyncFolderAccess()
        registerBadgeImages()
        refreshObservedDirectories()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sharedStateDidChange),
            name: FinderBadgeSupport.refreshNotificationName,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        releaseSyncFolderAccess()
    }

    private var syncFolderURL: URL {
        securityScopedSyncFolderURL ?? FinderBadgeSupport.syncRootURL(in: sharedDefaults, fallback: fallbackSyncFolderURL)
    }

    // MARK: - Primary Finder Sync Protocol

    override func beginObservingDirectory(at url: URL) {
        NSLog("FinderSync beginObservingDirectory %@", url.path)
    }

    override func endObservingDirectory(at url: URL) {
        NSLog("FinderSync endObservingDirectory %@", url.path)
    }

    override func requestBadgeIdentifier(for url: URL) {
        let badgeIdentifier = lookupBadgeIdentifier(for: url)
        NSLog("FinderSync requestBadgeIdentifier %@ -> %@", url.path, badgeIdentifier)
        FIFinderSyncController.default().setBadgeIdentifier(badgeIdentifier, for: url)
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let title = menuTitle()
        NSLog("FinderSync menu requested kind=%ld title=%@", menuKind.rawValue, title)
        let menu = NSMenu(title: title)

        let syncItem = NSMenuItem(title: "Force Sync", action: #selector(forceSyncAction(_:)), keyEquivalent: "")
        syncItem.target = self
        syncItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(syncItem)

        let viewItem = NSMenuItem(title: "View on Server", action: #selector(viewOnServerAction(_:)), keyEquivalent: "")
        viewItem.target = self
        viewItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(viewItem)

        if let targetURL = FIFinderSyncController.default().targetedURL(),
           hasConflict(at: targetURL) {
            menu.addItem(NSMenuItem.separator())
            let resolveItem = NSMenuItem(title: "View Conflict", action: #selector(viewConflictAction(_:)), keyEquivalent: "")
            resolveItem.target = self
            resolveItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            menu.addItem(resolveItem)
        }

        return menu
    }

    // MARK: - Actions

    @objc func forceSyncAction(_ sender: AnyObject?) {
        NSLog("FinderSync forceSyncAction fired")
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else {
            NSLog("FinderSync forceSyncAction missing selected items")
            return
        }
        guard let serviceId = extractServiceId(from: items[0]) else {
            NSLog("FinderSync forceSyncAction could not resolve service id for %@", items[0].path)
            return
        }

        Task {
            let url = URL(string: "\(controlServerBaseURL)/api/services/\(serviceId)/sync")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            NSLog("FinderSync forceSyncAction POST %@", url.absoluteString)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                NSLog("FinderSync forceSyncAction response status=%ld body=%@", statusCode, body)
            } catch {
                NSLog("FinderSync forceSyncAction failed for %@: %@", url.absoluteString, error.localizedDescription)
            }
        }
    }

    @objc func viewOnServerAction(_ sender: AnyObject?) {
        NSLog("FinderSync viewOnServerAction fired")
        guard let targetURL = currentTargetURL(),
              let serviceId = extractServiceId(from: targetURL) else { return }

        let serviceRoot = syncFolderURL.appendingPathComponent(serviceId, isDirectory: true)
        guard let config = serviceConfig(for: serviceId, serviceRoot: serviceRoot),
              let dashboardURL = ResourceBrowserSupport.dashboardURL(for: targetURL, serviceConfig: config, serviceRoot: serviceRoot) else {
            NSLog("FinderSync viewOnServerAction missing dashboard target for %@", targetURL.path)
            return
        }

        NSLog("FinderSync viewOnServerAction opening %@ for %@", dashboardURL.absoluteString, targetURL.path)
        openURLInBrowser(dashboardURL)
    }

    @objc func viewConflictAction(_ sender: AnyObject?) {
        NSLog("FinderSync viewConflictAction fired")
        guard let items = FIFinderSyncController.default().selectedItemURLs(),
              let url = items.first else { return }

        let conflictPath = conflictFilePath(for: url)
        if FileManager.default.fileExists(atPath: conflictPath.path) {
            NSWorkspace.shared.open(conflictPath)
        }
    }

    // MARK: - Shared State

    @objc private func sharedStateDidChange() {
        NSLog("FinderSync sharedStateDidChange")
        refreshSyncFolderAccess()
        refreshObservedDirectories()
        refreshKnownBadges()
    }

    private func refreshObservedDirectories() {
        NSLog("FinderSync observing %@", syncFolderURL.path)
        FIFinderSyncController.default().directoryURLs = [syncFolderURL]
    }

    private func refreshSyncFolderAccess() {
        releaseSyncFolderAccess()

        guard let bookmarkData = FinderBadgeSupport.syncRootBookmarkData(in: sharedDefaults) else {
            return
        }

        var isStale = false
        guard let bookmarkedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            NSLog("FinderSync failed resolving sync-root bookmark")
            return
        }

        if bookmarkedURL.startAccessingSecurityScopedResource() {
            securityScopedSyncFolderURL = bookmarkedURL
            NSLog("FinderSync started security-scoped access for %@ stale=%@", bookmarkedURL.path, isStale ? "yes" : "no")
        } else {
            NSLog("FinderSync could not start security-scoped access for %@", bookmarkedURL.path)
        }
    }

    private func releaseSyncFolderAccess() {
        guard let securityScopedSyncFolderURL else { return }
        securityScopedSyncFolderURL.stopAccessingSecurityScopedResource()
        self.securityScopedSyncFolderURL = nil
    }

    private func refreshKnownBadges() {
        if let targetedURL = FIFinderSyncController.default().targetedURL() {
            requestBadgeIdentifier(for: targetedURL)
        }

        for url in FIFinderSyncController.default().selectedItemURLs() ?? [] {
            requestBadgeIdentifier(for: url)
        }
    }

    // MARK: - Helpers

    private func lookupBadgeIdentifier(for url: URL) -> String {
        guard FinderBadgeSupport.badgesEnabled(in: sharedDefaults) else { return "" }

        if hasConflict(at: url),
           let relativePath = FinderBadgeSupport.relativePath(for: url, syncRootURL: syncFolderURL) {
            return FinderBadgeSupport.badgeIdentifier(for: "conflict", relativePath: relativePath)
        }

        guard let relativePath = FinderBadgeSupport.relativePath(for: url, syncRootURL: syncFolderURL) else {
            return ""
        }

        if let storedStatus = FinderBadgeSupport.badgeState(forRelativePath: relativePath, in: sharedDefaults) {
            return FinderBadgeSupport.badgeIdentifier(for: storedStatus, relativePath: relativePath)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return FinderBadgeSupport.badgeIdentifier(for: "synced", relativePath: relativePath)
        }

        return ""
    }

    private func extractServiceId(from url: URL) -> String? {
        guard let relativePath = FinderBadgeSupport.relativePath(for: url, syncRootURL: syncFolderURL) else {
            return nil
        }
        return FinderBadgeSupport.serviceId(forRelativePath: relativePath)
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

    private func menuTitle() -> String {
        guard let targetURL = currentTargetURL(),
              let serviceId = extractServiceId(from: targetURL) else {
            return "API2File"
        }

        if serviceId == "wix" {
            return "API2File - Wix"
        }
        return "API2File"
    }

    private func openURLInBrowser(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let chromeURL = workspace.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.open([url], withApplicationAt: chromeURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("FinderSync failed opening Chrome for %@: %@", url.absoluteString, error.localizedDescription)
                    let fallbackConfiguration = NSWorkspace.OpenConfiguration()
                    workspace.open(url, configuration: fallbackConfiguration) { _, fallbackError in
                        if let fallbackError {
                            NSLog("FinderSync failed opening default browser for %@: %@", url.absoluteString, fallbackError.localizedDescription)
                        } else {
                            NSLog("FinderSync opened default browser for %@", url.absoluteString)
                        }
                    }
                } else {
                    NSLog("FinderSync opened Chrome for %@", url.absoluteString)
                }
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        workspace.open(url, configuration: configuration) { _, error in
            if let error {
                NSLog("FinderSync failed opening default browser for %@: %@", url.absoluteString, error.localizedDescription)
            } else {
                NSLog("FinderSync opened default browser for %@", url.absoluteString)
            }
        }
    }

    private func currentTargetURL() -> URL? {
        if let selected = FIFinderSyncController.default().selectedItemURLs()?.first {
            return selected
        }
        return FIFinderSyncController.default().targetedURL()
    }

    private func serviceConfig(for serviceId: String, serviceRoot: URL) -> AdapterConfig? {
        if let sharedConfig = FinderBadgeSupport.serviceConfig(forServiceId: serviceId, in: sharedDefaults) {
            return sharedConfig
        }

        let adapterURL = serviceRoot
            .appendingPathComponent(".api2file", isDirectory: true)
            .appendingPathComponent("adapter.json", isDirectory: false)

        guard let data = try? Data(contentsOf: adapterURL) else {
            NSLog("FinderSync serviceConfig could not read %@", adapterURL.path)
            return nil
        }

        guard let config = try? JSONDecoder().decode(AdapterConfig.self, from: data) else {
            NSLog("FinderSync serviceConfig could not decode %@", adapterURL.path)
            return nil
        }

        return config
    }

    // MARK: - Badge Images

    private func registerBadgeImages() {
        registerGenericBadgeImage(symbolName: "checkmark.circle.fill", label: "Synced", identifier: "synced")
        registerGenericBadgeImage(symbolName: "arrow.triangle.2.circlepath.circle.fill", label: "Syncing", identifier: "syncing")
        registerGenericBadgeImage(symbolName: "exclamationmark.triangle.fill", label: "Conflict", identifier: "conflict")
        registerGenericBadgeImage(symbolName: "xmark.circle.fill", label: "Error", identifier: "error")

        registerWixBadgeImage(status: "synced", label: "Wix Synced", identifier: "wix-synced")
        registerWixBadgeImage(status: "syncing", label: "Wix Syncing", identifier: "wix-syncing")
        registerWixBadgeImage(status: "conflict", label: "Wix Conflict", identifier: "wix-conflict")
        registerWixBadgeImage(status: "error", label: "Wix Error", identifier: "wix-error")
    }

    private func registerGenericBadgeImage(symbolName: String, label: String, identifier: String) {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label) else { return }
        FIFinderSyncController.default().setBadgeImage(image, label: label, forBadgeIdentifier: identifier)
    }

    private func registerWixBadgeImage(status: String, label: String, identifier: String) {
        let image = NSImage(size: NSSize(width: 44, height: 44))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: 44, height: 44)
        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.07, green: 0.43, blue: 1.0, alpha: 1.0).setFill()
        background.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .black),
            .foregroundColor: NSColor.white
        ]
        let wixLetter = NSAttributedString(string: "W", attributes: attributes)
        let wixSize = wixLetter.size()
        wixLetter.draw(at: NSPoint(x: (rect.width - wixSize.width) / 2 - 1, y: 10))

        let statusRect = NSRect(x: 25, y: 3, width: 16, height: 16)
        let statusPath = NSBezierPath(ovalIn: statusRect)
        statusColor(for: status).setFill()
        statusPath.fill()

        let statusAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let statusGlyph = NSAttributedString(string: statusGlyph(for: status), attributes: statusAttributes)
        let statusSize = statusGlyph.size()
        statusGlyph.draw(at: NSPoint(
            x: statusRect.origin.x + (statusRect.width - statusSize.width) / 2,
            y: statusRect.origin.y + (statusRect.height - statusSize.height) / 2 - 1
        ))

        image.unlockFocus()
        FIFinderSyncController.default().setBadgeImage(image, label: label, forBadgeIdentifier: identifier)
    }

    private func statusColor(for status: String) -> NSColor {
        switch status {
        case "synced":
            return NSColor(calibratedRed: 0.12, green: 0.62, blue: 0.41, alpha: 1)
        case "syncing":
            return NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.92, alpha: 1)
        case "conflict":
            return NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.02, alpha: 1)
        case "error":
            return NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.18, alpha: 1)
        default:
            return NSColor.secondaryLabelColor
        }
    }

    private func statusGlyph(for status: String) -> String {
        switch status {
        case "synced":
            return "✓"
        case "syncing":
            return "↻"
        case "conflict":
            return "!"
        case "error":
            return "×"
        default:
            return ""
        }
    }
}
