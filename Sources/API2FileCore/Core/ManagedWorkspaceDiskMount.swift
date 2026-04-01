#if os(macOS)
import Foundation
import OSLog

/// Manages the lifecycle of a raw disk image used to activate the A2File FSKit filesystem extension.
///
/// The approach: create a small raw disk image with A2File magic bytes at offset 0.
/// When attached via hdiutil, DiskArbitration probes it, the FSKit extension recognises the magic
/// and returns `.usable`, triggering auto-mount via fskit_agent (user context).
///
/// This works around Apple bug FB17772372 where fskitd (root context) doesn't see user-installed
/// FSKit extensions, so `mount -F -t a2fmount` fails. Probe goes through fskit_agent and works.
public actor ManagedWorkspaceDiskMount {
    private let logger = Logger(subsystem: "com.shayco.api2file.dev", category: "DiskMount")

    /// "A2FILE\x00\x00" — identifies a managed workspace disk image to the FSKit extension
    public static let diskMagic: [UInt8] = [0x41, 0x32, 0x46, 0x49, 0x4C, 0x45, 0x00, 0x00]

    /// 64 MB raw image — large enough for DiskArbitration to treat as a real disk
    private static let imageSizeBytes: Int = 64 * 1024 * 1024

    private let diskImageURL: URL

    public init(storageLocations: StorageLocations) {
        self.diskImageURL = storageLocations.applicationSupportDirectory
            .appendingPathComponent("API2File", isDirectory: true)
            .appendingPathComponent("ManagedWorkspace", isDirectory: true)
            .appendingPathComponent("workspace.img")
    }

    // MARK: - Public interface

    /// Creates the disk image (if absent or corrupted) and attaches it so DiskArbitration can probe it.
    /// Returns the BSD device path (e.g. "/dev/disk7") on success.
    @discardableResult
    public func attach() async throws -> String {
        try ensureDiskImage()
        return try await attachImage()
    }

    /// Detaches the disk image by BSD device name.
    public func detach(device: String) async throws {
        let result = try await run("/usr/bin/hdiutil", ["detach", device, "-quiet"])
        logger.notice("detach \(device) exit=\(result.exitCode)")
    }

    /// Detaches all currently attached disk images that match our image file path.
    public func detachAll() async throws {
        let hdiInfo = try await run("/usr/bin/hdiutil", ["info"])
        let lines = hdiInfo.output.components(separatedBy: "\n")
        var imageSection = false
        var currentImagePath = ""
        for line in lines {
            if line.hasPrefix("image-path") {
                currentImagePath = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                imageSection = currentImagePath == diskImageURL.path
            }
            if imageSection, line.contains("/dev/disk") {
                let parts = line.components(separatedBy: "\t").filter { $0.hasPrefix("/dev/disk") }
                if let device = parts.first {
                    try await detach(device: device.trimmingCharacters(in: .whitespaces))
                }
            }
        }
    }

    // MARK: - Disk image management

    private func ensureDiskImage() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: diskImageURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: diskImageURL.path) {
            if try hasMagicBytes() { return }
            logger.notice("Disk image exists but lacks magic — recreating")
            try fm.removeItem(at: diskImageURL)
        }

        logger.notice("Creating disk image at \(self.diskImageURL.path, privacy: .public)")
        try createDiskImage()
    }

    private func hasMagicBytes() throws -> Bool {
        let handle = try FileHandle(forReadingFrom: diskImageURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8) ?? Data()
        return data.count == 8 && [UInt8](data) == Self.diskMagic
    }

    private func createDiskImage() throws {
        let size = Self.imageSizeBytes

        // Create a sparse file by seeking to end and writing one null byte
        guard FileManager.default.createFile(atPath: diskImageURL.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let handle = try FileHandle(forWritingTo: diskImageURL)
        defer { try? handle.close() }

        // Write magic at offset 0
        try handle.write(contentsOf: Data(Self.diskMagic))

        // Extend to full size (sparse where supported by the filesystem)
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([0x00]))

        logger.notice("Created \(size / (1024*1024)) MB disk image with A2File magic")
    }

    // MARK: - hdiutil attach

    private func attachImage() async throws -> String {
        logger.notice("Attaching disk image \(self.diskImageURL.path, privacy: .public)")
        let result = try await run("/usr/bin/hdiutil", [
            "attach",
            "-imagekey", "diskimage-class=CRawDiskImage",
            diskImageURL.path
        ])
        guard result.exitCode == 0 else {
            throw MountError.hdiutilFailed(result.output)
        }
        // hdiutil output: "/dev/disk7\t\t\t\n/dev/disk7s1\t...\n..."
        // We want the first /dev/diskN line
        let device = result.output
            .components(separatedBy: "\n")
            .compactMap { line -> String? in
                let col = line.components(separatedBy: "\t").first?.trimmingCharacters(in: .whitespaces) ?? ""
                return col.hasPrefix("/dev/disk") ? col : nil
            }
            .first
        guard let device else {
            throw MountError.noDeviceFound(result.output)
        }
        logger.notice("Attached as \(device, privacy: .public)")
        return device
    }

    // MARK: - Process helper

    private struct RunResult {
        let exitCode: Int32
        let output: String
    }

    private func run(_ path: String, _ args: [String]) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            process.terminationHandler = { proc in
                let outData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let combined = (String(data: outData, encoding: .utf8) ?? "") +
                               (String(data: errData, encoding: .utf8) ?? "")
                continuation.resume(returning: RunResult(exitCode: proc.terminationStatus, output: combined))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Error

    public enum MountError: Error, LocalizedError {
        case hdiutilFailed(String)
        case noDeviceFound(String)

        public var errorDescription: String? {
            switch self {
            case .hdiutilFailed(let out): "hdiutil failed: \(out)"
            case .noDeviceFound(let out): "No /dev/diskN found in hdiutil output: \(out)"
            }
        }
    }
}
#endif
