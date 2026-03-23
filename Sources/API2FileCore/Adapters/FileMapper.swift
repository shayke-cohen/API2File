import Foundation

/// Utility for mapping API records to file paths and performing file I/O.
public enum FileMapper {

    // MARK: - File path generation

    /// Generates a relative file path for a record based on the file mapping config.
    /// Uses TemplateEngine to resolve filename templates like `{name|slugify}.json`.
    /// - Parameters:
    ///   - record: The API record as a dictionary
    ///   - config: The file mapping configuration
    /// - Returns: A relative file path string (e.g. "boards/marketing.json")
    public static func filePath(for record: [String: Any], config: FileMappingConfig) -> String {
        let directory = config.directory

        // Determine the filename
        let filename: String
        if let template = config.filename {
            filename = TemplateEngine.render(template, with: record)
        } else {
            // Fallback: use the ID field or "untitled"
            let idField = config.idField ?? "id"
            let idValue = stringValue(record[idField]) ?? "untitled"
            let ext = fileExtension(for: config.format)
            filename = "\(idValue).\(ext)"
        }

        // Combine directory and filename
        if directory.isEmpty || directory == "." {
            return filename
        }
        return "\(directory)/\(filename)"
    }

    // MARK: - File I/O

    /// Writes an array of SyncableFile objects to disk under the given directory.
    /// Creates intermediate directories as needed.
    /// - Parameters:
    ///   - files: The files to write
    ///   - directory: The root directory to write into
    public static func writeFiles(_ files: [SyncableFile], to directory: URL) throws {
        let fm = FileManager.default
        for file in files {
            let fileURL = directory.appendingPathComponent(file.relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try file.content.write(to: fileURL, options: .atomic)
        }
    }

    /// Reads a file from disk and returns its raw data.
    /// - Parameters:
    ///   - path: The full URL to the file
    ///   - format: The expected file format (for future validation)
    /// - Returns: The file content as Data
    public static func readFile(at path: URL, format: FileFormat) throws -> Data {
        return try Data(contentsOf: path)
    }

    // MARK: - Private helpers

    /// Returns the conventional file extension for a FileFormat.
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

    /// Safely convert any value to a string, or return nil.
    private static func stringValue(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case let s as String: return s
        case let n as Int: return "\(n)"
        case let n as Double:
            if n == n.rounded() && n < 1e15 { return "\(Int(n))" }
            return "\(n)"
        default: return "\(value)"
        }
    }
}
