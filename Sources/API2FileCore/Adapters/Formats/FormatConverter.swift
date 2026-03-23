import Foundation

/// Protocol for bidirectional conversion between API data (dictionaries) and file formats
public protocol FormatConverter: Sendable {
    /// The file format this converter handles
    static var format: FileFormat { get }

    /// Convert API records to file data
    /// - Parameters:
    ///   - records: Array of dictionaries from the API
    ///   - options: Format-specific options from the adapter config
    /// - Returns: File content as Data
    static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data

    /// Convert file data back to API records
    /// - Parameters:
    ///   - data: Raw file content
    ///   - options: Format-specific options from the adapter config
    /// - Returns: Array of dictionaries for the API
    static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]]
}

/// Errors during format conversion
public enum FormatError: Error, LocalizedError {
    case invalidData(String)
    case unsupportedFormat(FileFormat)
    case encodingFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData(let msg): return "Invalid data: \(msg)"
        case .unsupportedFormat(let fmt): return "Unsupported format: \(fmt.rawValue)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Decoding failed: \(msg)"
        }
    }
}

/// Factory for getting the right converter for a format
public enum FormatConverterFactory {
    public static func converter(for format: FileFormat) throws -> FormatConverter.Type {
        switch format {
        case .json: return JSONFormat.self
        case .csv: return CSVFormat.self
        case .html: return HTMLFormat.self
        case .markdown: return MarkdownFormat.self
        case .yaml: return YAMLFormat.self
        case .text: return TextFormat.self
        case .raw: return RawFormat.self
        case .ics: return ICSFormat.self
        case .vcf: return VCFFormat.self
        case .eml: return EMLFormat.self
        case .svg: return SVGFormat.self
        case .webloc: return WeblocFormat.self
        default:
            throw FormatError.unsupportedFormat(format)
        }
    }

    public static func encode(records: [[String: Any]], format: FileFormat, options: FormatOptions? = nil) throws -> Data {
        let converter = try converter(for: format)
        return try converter.encode(records: records, options: options)
    }

    public static func decode(data: Data, format: FileFormat, options: FormatOptions? = nil) throws -> [[String: Any]] {
        let converter = try converter(for: format)
        return try converter.decode(data: data, options: options)
    }
}
