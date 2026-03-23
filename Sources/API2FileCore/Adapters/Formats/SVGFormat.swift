import Foundation

/// SVG format converter — stores/reads a content field as raw SVG (XML text passthrough)
public enum SVGFormat: FormatConverter {
    public static let format: FileFormat = .svg

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        let svg = (record[contentField] as? String) ?? ""
        guard let data = svg.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode SVG as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let svg = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("SVG is not valid UTF-8")
        }
        let contentField = options?.fieldMapping?["content"] ?? "content"
        return [[contentField: svg]]
    }
}
