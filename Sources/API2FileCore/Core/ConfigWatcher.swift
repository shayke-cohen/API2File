import Foundation
import CoreServices

/// Watches .api2file/ directories for adapter.json changes.
/// When a config file is modified, calls the handler with the service ID.
public final class ConfigWatcher: @unchecked Sendable {
    public typealias ReloadHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "com.api2file.configwatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var handler: ReloadHandler?
    private var debounceWorkItem: DispatchWorkItem?

    /// Debounce interval — wait for editor to finish writing
    private static let debounceInterval: TimeInterval = 1.0

    public init() {}

    deinit { stop() }

    /// Start watching .api2file/ directories for adapter.json changes.
    /// - Parameters:
    ///   - directories: Paths to .api2file/ directories (e.g., ~/API2File/demo/.api2file)
    ///   - handler: Called with the service ID when its adapter.json changes
    public func start(directories: [String], handler: @escaping ReloadHandler) {
        stop()
        guard !directories.isEmpty else { return }

        self.handler = handler

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = directories as CFArray

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            configWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
            )
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        handler = nil
    }

    fileprivate func handleEvent(path: String) {
        // Only react to adapter.json changes
        guard path.hasSuffix("adapter.json") else { return }

        // Extract service ID: .../~/API2File/{serviceId}/.api2file/adapter.json
        let components = path.split(separator: "/")
        guard components.count >= 3 else { return }
        // The service ID is 2 levels up from adapter.json (above .api2file/)
        let api2fileIdx = components.lastIndex(of: ".api2file")
        guard let idx = api2fileIdx, idx > 0 else { return }
        let serviceId = String(components[idx - 1])

        // Debounce — editors may write multiple times
        debounceWorkItem?.cancel()
        let handler = self.handler
        let work = DispatchWorkItem {
            handler?(serviceId)
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }
}

// MARK: - FSEvents Callback

private func configWatcherCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<ConfigWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let cfArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    for i in 0..<numEvents {
        let rawFlags = flags[i]
        let isModified = rawFlags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        let isCreated = rawFlags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        let isRenamed = rawFlags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0

        if isModified || isCreated || isRenamed {
            watcher.handleEvent(path: cfArray[i])
        }
    }
}
