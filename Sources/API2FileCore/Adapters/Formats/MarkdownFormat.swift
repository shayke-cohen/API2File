import Foundation

/// Markdown format converter — stores content field as markdown text
public enum MarkdownFormat: FormatConverter {
    public static let format: FileFormat = .markdown

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let md = (record[contentField] as? String) ?? ""
        guard let data = md.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode Markdown as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let md = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("Markdown is not valid UTF-8")
        }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        return [[contentField: md]]
    }
}
