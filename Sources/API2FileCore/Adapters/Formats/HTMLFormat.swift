import Foundation

/// HTML format converter — stores/reads a content field as raw HTML
public enum HTMLFormat: FormatConverter {
    public static let format: FileFormat = .html

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let html = (record[contentField] as? String) ?? ""
        guard let data = html.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode HTML as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let html = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("HTML is not valid UTF-8")
        }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        return [[contentField: html]]
    }
}
