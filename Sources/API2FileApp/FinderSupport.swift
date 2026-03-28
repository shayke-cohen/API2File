import AppKit
import Foundation

@MainActor
enum FinderSupport {
    static func openInFinder(_ url: URL) {
        let targetURL = url.standardizedFileURL
        let values = try? targetURL.resourceValues(forKeys: [.isDirectoryKey])

        if values?.isDirectory == true {
            if let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
                NSWorkspace.shared.open(
                    [targetURL],
                    withApplicationAt: finderURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: targetURL.path)
            }
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }
}
