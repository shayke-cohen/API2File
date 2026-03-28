import Foundation

/// ZIP archive helper using system /usr/bin/zip and /usr/bin/unzip.
/// Zero external dependencies — uses only macOS built-in tools.
enum ZIPHelper {

    /// Create a ZIP archive from a dictionary of relative paths → file contents.
    static func createZIP(files: [String: Data]) throws -> Data {
        #if os(macOS)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-zip-\(UUID().uuidString)")
        let contentDir = tempDir.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write all files to content subdirectory
        for (path, content) in files {
            let fileURL = contentDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL)
        }

        // Create ZIP using /usr/bin/zip — zip "." to avoid argument count limits
        let zipPath = tempDir.appendingPathComponent("output.zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", zipPath.path, "."]
        process.currentDirectoryURL = contentDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FormatError.encodingFailed("zip command failed with status \(process.terminationStatus)")
        }

        return try Data(contentsOf: zipPath)
        #else
        throw FormatError.encodingFailed("ZIP creation is only available on macOS in the current build.")
        #endif
    }

    /// Extract a ZIP archive to a dictionary of relative paths → file contents.
    static func extractZIP(data: Data) throws -> [String: Data] {
        #if os(macOS)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write ZIP data to temp file
        let zipPath = tempDir.appendingPathComponent("archive.zip")
        try data.write(to: zipPath)

        // Extract using /usr/bin/unzip
        let outputDir = tempDir.appendingPathComponent("contents")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", zipPath.path, "-d", outputDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw FormatError.decodingFailed("unzip command failed with status \(process.terminationStatus)")
        }

        // Read all extracted files into dictionary
        var result: [String: Data] = [:]
        let resolvedOutputDir = outputDir.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: [.isRegularFileKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let resolvedFile = fileURL.resolvingSymlinksInPath().path
            let relativePath = resolvedFile.replacingOccurrences(of: resolvedOutputDir + "/", with: "")
            result[relativePath] = try Data(contentsOf: fileURL)
        }

        return result
        #else
        throw FormatError.decodingFailed("ZIP extraction is only available on macOS in the current build.")
        #endif
    }
}
