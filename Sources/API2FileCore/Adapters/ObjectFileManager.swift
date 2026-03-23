import Foundation

/// Manages hidden object files that store raw API records alongside user-facing files.
///
/// Object files serve two purposes:
/// 1. Raw record store for reverse-transform support on push
/// 2. Agent-editable interface — agents edit structured JSON, system regenerates user files
///
/// Layout:
/// - Collection strategy: `.{filename-without-ext}.objects.json` in same directory
/// - One-per-record strategy: `.objects/{record-filename-without-ext}.json` subdirectory
public enum ObjectFileManager {

    // MARK: - Path Computation

    /// Compute the object file path for a collection-strategy user file.
    /// Example: `tasks.csv` → `.tasks.objects.json`
    public static func objectFilePath(forCollectionFile userFilePath: String) -> String {
        let url = URL(fileURLWithPath: userFilePath)
        let directory = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let objectFileName = ".\(stem).objects.json"

        if directory == "." || directory == "/" || directory.isEmpty {
            return objectFileName
        }
        // Normalize: remove leading "./" if present
        let normalizedDir = directory.hasPrefix("./") ? String(directory.dropFirst(2)) : directory
        if normalizedDir.isEmpty || normalizedDir == "." {
            return objectFileName
        }
        return "\(normalizedDir)/\(objectFileName)"
    }

    /// Compute the object file path for a one-per-record user file.
    /// Example: `contacts/john-doe.vcf` → `contacts/.objects/john-doe.json`
    public static func objectFilePath(forRecordFile userFilePath: String) -> String {
        let url = URL(fileURLWithPath: userFilePath)
        let directory = url.deletingLastPathComponent().path
        let stem = url.deletingPathExtension().lastPathComponent
        let objectFileName = "\(stem).json"

        if directory == "." || directory == "/" || directory.isEmpty {
            return ".objects/\(objectFileName)"
        }
        let normalizedDir = directory.hasPrefix("./") ? String(directory.dropFirst(2)) : directory
        if normalizedDir.isEmpty || normalizedDir == "." {
            return ".objects/\(objectFileName)"
        }
        return "\(normalizedDir)/.objects/\(objectFileName)"
    }

    /// Compute the object file path based on the mapping strategy.
    public static func objectFilePath(forUserFile userFilePath: String, strategy: MappingStrategy) -> String {
        switch strategy {
        case .collection:
            return objectFilePath(forCollectionFile: userFilePath)
        case .onePerRecord:
            return objectFilePath(forRecordFile: userFilePath)
        case .mirror:
            // Mirror strategy: treat like collection
            return objectFilePath(forCollectionFile: userFilePath)
        }
    }

    /// Check if a given path is an object file (hidden `.objects.json` or inside `.objects/`).
    public static func isObjectFile(_ path: String) -> Bool {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        if filename.hasPrefix(".") && filename.hasSuffix(".objects.json") {
            return true
        }
        // Check if inside a .objects/ directory
        return path.contains("/.objects/")
    }

    /// Derive the user file path from an object file path.
    /// Returns nil if the path is not a recognized object file.
    public static func userFilePath(forObjectFile objectPath: String, strategy: MappingStrategy, format: FileFormat) -> String? {
        switch strategy {
        case .collection, .mirror:
            return userFilePathForCollectionObject(objectPath, format: format)
        case .onePerRecord:
            return userFilePathForRecordObject(objectPath, format: format)
        }
    }

    // MARK: - Read / Write

    /// Write raw records as a collection object file (JSON array).
    public static func writeCollectionObjectFile(
        records: [[String: Any]],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Write a single raw record as a one-per-record object file (JSON object).
    public static func writeRecordObjectFile(
        record: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Read a collection object file (JSON array of records).
    public static func readCollectionObjectFile(from url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ObjectFileError.invalidFormat("Expected JSON array in \(url.lastPathComponent)")
        }
        return array
    }

    /// Read a single record object file (JSON object).
    public static func readRecordObjectFile(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ObjectFileError.invalidFormat("Expected JSON object in \(url.lastPathComponent)")
        }
        return dict
    }

    // MARK: - Private Helpers

    private static func userFilePathForCollectionObject(_ objectPath: String, format: FileFormat) -> String? {
        let url = URL(fileURLWithPath: objectPath)
        let filename = url.lastPathComponent
        // Must match pattern: .{stem}.objects.json
        guard filename.hasPrefix(".") && filename.hasSuffix(".objects.json") else { return nil }
        let stem = String(filename.dropFirst().dropLast(".objects.json".count))
        guard !stem.isEmpty else { return nil }

        let ext = fileExtension(for: format)
        let userFilename = "\(stem).\(ext)"
        let directory = url.deletingLastPathComponent().path
        let normalizedDir = directory.hasPrefix("./") ? String(directory.dropFirst(2)) : directory
        if normalizedDir.isEmpty || normalizedDir == "." || normalizedDir == "/" {
            return userFilename
        }
        return "\(normalizedDir)/\(userFilename)"
    }

    private static func userFilePathForRecordObject(_ objectPath: String, format: FileFormat) -> String? {
        // Must be inside a .objects/ directory
        guard objectPath.contains("/.objects/") else { return nil }
        let url = URL(fileURLWithPath: objectPath)
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }

        let ext = fileExtension(for: format)
        let userFilename = "\(stem).\(ext)"

        // Remove .objects/ from the path
        let parentOfObjects = url.deletingLastPathComponent().deletingLastPathComponent().path
        let normalizedDir = parentOfObjects.hasPrefix("./") ? String(parentOfObjects.dropFirst(2)) : parentOfObjects
        if normalizedDir.isEmpty || normalizedDir == "." || normalizedDir == "/" {
            return userFilename
        }
        return "\(normalizedDir)/\(userFilename)"
    }

    private static func fileExtension(for format: FileFormat) -> String {
        switch format {
        case .json: return "json"
        case .csv: return "csv"
        case .html: return "html"
        case .markdown: return "md"
        case .yaml: return "yaml"
        case .text: return "txt"
        case .raw: return "bin"
        case .ics: return "ics"
        case .vcf: return "vcf"
        case .eml: return "eml"
        case .svg: return "svg"
        case .webloc: return "webloc"
        case .xlsx: return "xlsx"
        case .docx: return "docx"
        case .pptx: return "pptx"
        }
    }
}

// MARK: - Errors

public enum ObjectFileError: Error, LocalizedError {
    case invalidFormat(String)
    case objectFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Object file format error: \(msg)"
        case .objectFileNotFound(let path): return "Object file not found: \(path)"
        }
    }
}
