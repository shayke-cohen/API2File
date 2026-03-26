import Foundation
import Combine

/// Lightweight file watcher for editor windows.
/// Publishes on the main thread when the watched file changes on disk.
@MainActor
final class FileWatcherHelper: ObservableObject {
    @Published var lastModified: Date = Date()

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        startWatching()
    }

    deinit {
        stopWatching()
    }

    func startWatching() {
        stopWatching()
        descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.lastModified = Date()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    nonisolated func stopWatching() {
        // Cancel must happen from any isolation context
        MainActor.assumeIsolated {
            source?.cancel()
            source = nil
        }
    }

    /// Read the current file content as a string.
    func readContent() -> String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Write content back to the file.
    func writeContent(_ text: String) throws {
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
