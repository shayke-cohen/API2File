import Foundation

/// Raw format converter — binary passthrough (images, PDFs, etc.)
/// Stores/reads raw bytes via a "data" field containing base64
public enum RawFormat: FormatConverter {
    public static let format: FileFormat = .raw

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        // If there's a "data" field with base64, decode it
        if let base64 = record["data"] as? String,
           let data = Data(base64Encoded: base64) {
            return data
        }
        // If there's raw Data, pass through
        if let data = record["data"] as? Data {
            return data
        }
        throw FormatError.encodingFailed("Raw format requires a 'data' field with base64 content")
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        return [["data": data.base64EncodedString()]]
    }
}
