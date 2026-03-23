import Foundation

/// Plain text format converter — stores content field as plain text
public enum TextFormat: FormatConverter {
    public static let format: FileFormat = .text

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let text = (record[contentField] as? String) ?? ""
        guard let data = text.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode text as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("Text is not valid UTF-8")
        }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        return [[contentField: text]]
    }
}
