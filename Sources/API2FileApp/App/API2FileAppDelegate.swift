import AppKit

final class API2FileAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        openSupportedFiles(urls)
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
