import AppKit

extension Notification.Name {
    static let api2fileOpenURL = Notification.Name("com.api2file.open-url-local")
}

@MainActor
final class API2FileAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().postNotificationName(
            AppState.activateDashboardNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DistributedNotificationCenter.default().postNotificationName(
                AppState.activateDashboardNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("AppDelegate open urls: %@", urls.map(\.absoluteString).joined(separator: ", "))
        for url in urls {
            if url.scheme == "api2file" {
                NotificationCenter.default.post(name: .api2fileOpenURL, object: url)
            } else if url.isFileURL {
                FileEditorWindow.open(fileURL: url)
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        openSupportedFiles(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    private func openSupportedFiles(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            FileEditorWindow.open(fileURL: url)
        }
    }
}
