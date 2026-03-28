import Foundation
#if os(macOS)
import CoreServices
#endif

// MARK: - FileWatcher

/// Watches directories for file changes using FSEvents.
public final class FileWatcher: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable ([FileChange]) -> Void

    // MARK: - FileChange

    public struct FileChange: Sendable {
        public let path: String
        public let flags: ChangeFlags

        public init(path: String, flags: ChangeFlags) {
            self.path = path
            self.flags = flags
        }
    }

    // MARK: - ChangeFlags

    public struct ChangeFlags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let created  = ChangeFlags(rawValue: 1 << 0)
        public static let modified = ChangeFlags(rawValue: 1 << 1)
        public static let removed  = ChangeFlags(rawValue: 1 << 2)
        public static let renamed  = ChangeFlags(rawValue: 1 << 3)
    }

    // MARK: - Private State

    private let queue = DispatchQueue(label: "com.api2file.filewatcher", qos: .utility)
    private let isEnabled: Bool
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif
    private var handler: ChangeHandler?

    /// Accumulated changes during the debounce window.
    private let pendingLock = NSLock()
    private var pendingChanges: [FileChange] = []
    private var debounceWorkItem: DispatchWorkItem?

    /// Directories to ignore.
    static let ignoredComponents: Set<String> = [".api2file", ".git"]

    /// Debounce interval in seconds.
    private static let debounceInterval: TimeInterval = 0.5

    // MARK: - Init / Deinit

    public init(enabled: Bool = true) {
        self.isEnabled = enabled
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start watching the given directories for file-level changes.
    /// The handler is called on a background queue with batched changes after a 500ms debounce window.
    public func start(directories: [String], handler: @escaping ChangeHandler) {
        guard isEnabled else {
            self.handler = handler
            return
        }
        #if os(macOS)
        stop()

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
            fileWatcherFSEventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0, // latency — we handle debouncing ourselves
            UInt32(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        #else
        self.handler = handler
        #endif
    }

    /// Stop watching and clean up the FSEvents stream.
    public func stop() {
        #if os(macOS)
        if let stream = self.stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        #endif

        pendingLock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingChanges.removeAll()
        pendingLock.unlock()

        handler = nil
    }

    // MARK: - Debouncing

    fileprivate func enqueueChanges(_ changes: [FileChange]) {
        pendingLock.lock()
        pendingChanges.append(contentsOf: changes)

        // Cancel existing debounce timer and create a new one
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingChanges()
        }
        debounceWorkItem = workItem
        pendingLock.unlock()

        queue.asyncAfter(
            deadline: .now() + Self.debounceInterval,
            execute: workItem
        )
    }

    private func flushPendingChanges() {
        pendingLock.lock()
        let changes = pendingChanges
        pendingChanges.removeAll()
        pendingLock.unlock()

        guard !changes.isEmpty, let handler = self.handler else { return }
        handler(changes)
    }
}

// MARK: - FSEvents Callback (file-level)

#if os(macOS)

/// File-level callback function for FSEvents — avoids the "covariant Self" issue
/// that arises when storing a closure referencing `Self` as a static property.
private func fileWatcherFSEventCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let cfArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
        return
    }

    let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)

    var changes: [FileWatcher.FileChange] = []

    for i in 0..<numEvents {
        let path = cfArray[i]

        // Filter out ignored directories
        let components = path.split(separator: "/")
        if components.contains(where: { FileWatcher.ignoredComponents.contains(String($0)) }) {
            continue
        }

        let rawFlags = flags[i]
        let changeFlags = mapFSEventFlags(rawFlags)

        if !changeFlags.isEmpty {
            changes.append(FileWatcher.FileChange(path: path, flags: changeFlags))
        }
    }

    if !changes.isEmpty {
        watcher.enqueueChanges(changes)
    }
}

/// Maps raw FSEvent flags to our ChangeFlags option set.
private func mapFSEventFlags(_ raw: FSEventStreamEventFlags) -> FileWatcher.ChangeFlags {
    var result = FileWatcher.ChangeFlags()

    if raw & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
        result.insert(.created)
    }
    if raw & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
        result.insert(.modified)
    }
    if raw & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
        result.insert(.removed)
    }
    if raw & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
        result.insert(.renamed)
    }

    return result
}
#endif
