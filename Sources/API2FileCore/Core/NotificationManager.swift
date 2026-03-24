import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

// MARK: - NotificationManager

/// Manages macOS user notifications for sync events, conflicts, errors, and connection status.
/// Uses UNUserNotificationCenter for actionable notifications.
public final class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {

    /// Shared singleton instance.
    public static let shared = NotificationManager()

    /// Whether notifications are available (requires proper app bundle)
    private let isAvailable: Bool

    private var center: UNUserNotificationCenter? {
        guard isAvailable else { return nil }
        return UNUserNotificationCenter.current()
    }

    // MARK: - Category Identifiers

    private enum Category {
        static let syncConflict = "SYNC_CONFLICT"
        static let syncError = "SYNC_ERROR"
        static let connected = "CONNECTED"
        static let general = "GENERAL"
    }

    // MARK: - Init

    override init() {
        // Check if we have a proper app bundle (UNUserNotificationCenter crashes without one)
        self.isAvailable = Bundle.main.bundleIdentifier != nil
        super.init()
        if isAvailable {
            center?.delegate = self
            registerCategories()
        }
    }

    // MARK: - Public API

    /// Request notification permission from the user.
    public func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[NotificationManager] Permission error: \(error.localizedDescription)")
            } else if !granted {
                print("[NotificationManager] Notification permission denied.")
            }
        }
    }

    /// Send a general notification.
    /// - Parameters:
    ///   - title: The notification title.
    ///   - body: The notification body text.
    ///   - actionURL: Optional URL to open when the notification is tapped.
    public func notify(title: String, body: String, actionURL: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Category.general

        if let actionURL {
            content.userInfo["actionURL"] = actionURL.absoluteString
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center?.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify about a sync conflict.
    /// - Parameters:
    ///   - service: The name of the service where the conflict occurred.
    ///   - file: The file path or name that has a conflict.
    public func notifyConflict(service: String, file: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sync Conflict — \(service)"
        content.body = "Conflict detected in file: \(file)"
        content.sound = .default
        content.categoryIdentifier = Category.syncConflict
        content.userInfo["service"] = service
        content.userInfo["file"] = file

        let request = UNNotificationRequest(
            identifier: "conflict-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center?.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to deliver conflict notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify about a sync error.
    /// - Parameters:
    ///   - service: The name of the service that encountered the error.
    ///   - message: The error message.
    public func notifyError(service: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sync Error — \(service)"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Category.syncError
        content.userInfo["service"] = service
        content.userInfo["error"] = message

        let request = UNNotificationRequest(
            identifier: "error-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center?.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to deliver error notification: \(error.localizedDescription)")
            }
        }
    }

    /// Notify about a successful connection.
    /// - Parameters:
    ///   - service: The name of the service that was connected.
    ///   - fileCount: The number of files synced.
    public func notifyConnected(service: String, fileCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Connected — \(service)"
        content.body = "Successfully connected. \(fileCount) file\(fileCount == 1 ? "" : "s") synced."
        content.sound = .default
        content.categoryIdentifier = Category.connected
        content.userInfo["service"] = service
        content.userInfo["fileCount"] = fileCount

        let request = UNNotificationRequest(
            identifier: "connected-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center?.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to deliver connected notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification actions when the app is in the foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle notification tap / action.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        if let urlString = userInfo["actionURL"] as? String,
           let url = URL(string: urlString) {
            #if canImport(AppKit)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
            #endif
        }

        completionHandler()
    }

    // MARK: - Private

    /// Register notification categories with actions.
    private func registerCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW_ACTION",
            title: "View",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: [.destructive]
        )

        let conflictCategory = UNNotificationCategory(
            identifier: Category.syncConflict,
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let errorCategory = UNNotificationCategory(
            identifier: Category.syncError,
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let connectedCategory = UNNotificationCategory(
            identifier: Category.connected,
            actions: [dismissAction],
            intentIdentifiers: [],
            options: []
        )
        let generalCategory = UNNotificationCategory(
            identifier: Category.general,
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        center?.setNotificationCategories([
            conflictCategory,
            errorCategory,
            connectedCategory,
            generalCategory,
        ])
    }
}

// MARK: - Notification Content Builder (for testing)

/// Utility to build notification content without sending. Useful for unit tests.
extension NotificationManager {

    /// Build a conflict notification content object without delivering it.
    public static func buildConflictContent(service: String, file: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Sync Conflict — \(service)"
        content.body = "Conflict detected in file: \(file)"
        content.sound = .default
        content.categoryIdentifier = Category.syncConflict
        content.userInfo["service"] = service
        content.userInfo["file"] = file
        return content
    }

    /// Build an error notification content object without delivering it.
    public static func buildErrorContent(service: String, message: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Sync Error — \(service)"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Category.syncError
        content.userInfo["service"] = service
        content.userInfo["error"] = message
        return content
    }

    /// Build a connected notification content object without delivering it.
    public static func buildConnectedContent(service: String, fileCount: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Connected — \(service)"
        content.body = "Successfully connected. \(fileCount) file\(fileCount == 1 ? "" : "s") synced."
        content.sound = .default
        content.categoryIdentifier = Category.connected
        content.userInfo["service"] = service
        content.userInfo["fileCount"] = fileCount
        return content
    }

    /// Build a general notification content object without delivering it.
    public static func buildGeneralContent(title: String, body: String, actionURL: URL? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Category.general
        if let actionURL {
            content.userInfo["actionURL"] = actionURL.absoluteString
        }
        return content
    }
}
