import Foundation

/// JSON format converter — records as pretty-printed JSON
public enum JSONFormat: FormatConverter {
    public static let format: FileFormat = .json

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        let obj: Any = records.count == 1 ? records[0] : records
        guard JSONSerialization.isValidJSONObject(obj) else {
            throw FormatError.encodingFailed("Data is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if let dict = obj as? [String: Any] {
            return [dict]
        } else if let arr = obj as? [[String: Any]] {
            return arr
        } else {
            throw FormatError.decodingFailed("JSON is not an object or array of objects")
        }
    }
}
