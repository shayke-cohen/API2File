import Foundation

// MARK: - Log Level

public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info  = "INFO"
    case warn  = "WARN"
    case error = "ERROR"
}

// MARK: - Log Category

public enum LogCategory: String, Sendable {
    case network = "NETWORK"
    case fileOp  = "FILE"
    case sync    = "SYNC"
    case system  = "SYSTEM"
}

// MARK: - ActivityLogger

/// Centralized activity logger. Thread-safe actor that writes timestamped entries to a
/// daily-rotating log file under `{syncFolder}/logs/api2file-YYYY-MM-DD.log`.
///
/// Configure once at startup:
/// ```swift
/// await ActivityLogger.shared.configure(logDirectory: syncFolder.appendingPathComponent("logs"))
/// ```
public actor ActivityLogger {
    public static let shared = ActivityLogger()

    private var logDirectory: URL?
    private var currentLogURL: URL?
    private var currentDateString: String = ""
    private var fileHandle: FileHandle?

    private init() {}

    // MARK: - Setup

    /// Configure the log directory. Creates it if needed. Call once at startup.
    public func configure(logDirectory: URL) {
        self.logDirectory = logDirectory
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        openTodaysFile()
        log(.info, .system, "ActivityLogger configured — logs at \(logDirectory.path)")
    }

    // MARK: - Logging

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        rotateDailyIfNeeded()
        let entry = "[\(timestamp())] [\(level.rawValue)] [\(category.rawValue)] \(message)\n"
        // Mirror to console (visible in Xcode / Console.app)
        print(entry.trimmingCharacters(in: .newlines))
        guard let handle = fileHandle else { return }
        if let data = entry.data(using: .utf8) {
            handle.write(data)
        }
    }

    // MARK: - Accessors

    /// URL of today's log file.
    public func currentLogFileURL() -> URL? { currentLogURL }

    /// URL of the log directory.
    public func logDirectoryURL() -> URL? { logDirectory }

    // MARK: - Private

    private func rotateDailyIfNeeded() {
        let today = dateString(Date())
        guard today != currentDateString else { return }
        openTodaysFile()
    }

    private func openTodaysFile() {
        guard let logDirectory else { return }
        let today = dateString(Date())
        try? fileHandle?.close()
        fileHandle = nil

        let url = logDirectory.appendingPathComponent("api2file-\(today).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            fileHandle = handle
            currentLogURL = url
            currentDateString = today
        }
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Convenience

public extension ActivityLogger {
    func debug(_ category: LogCategory, _ message: String) { log(.debug, category, message) }
    func info(_ category: LogCategory, _ message: String)  { log(.info,  category, message) }
    func warn(_ category: LogCategory, _ message: String)  { log(.warn,  category, message) }
    func error(_ category: LogCategory, _ message: String) { log(.error, category, message) }
}

// MARK: - Byte Size Formatting

extension ActivityLogger {
    static func formatBytes(_ count: Int) -> String {
        if count < 1024 { return "\(count)B" }
        if count < 1024 * 1024 { return String(format: "%.1fKB", Double(count) / 1024) }
        return String(format: "%.1fMB", Double(count) / (1024 * 1024))
    }
}
