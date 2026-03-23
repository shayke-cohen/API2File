import Foundation

/// WEBLOC format converter — macOS .webloc plist files containing a URL
public enum WeblocFormat: FormatConverter {
    public static let format: FileFormat = .webloc

    private static let defaultURLField = "url"

    public static func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data {
        guard let record = records.first else { return Data() }
        let urlField = options?.fieldMapping?["url"] ?? defaultURLField
        let url = (record[urlField] as? String) ?? ""

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>URL</key>
        \t<string>\(escapeXML(url))</string>
        </dict>
        </plist>
        """

        guard let data = plist.data(using: .utf8) else {
            throw FormatError.encodingFailed("Failed to encode WEBLOC as UTF-8")
        }
        return data
    }

    public static func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FormatError.decodingFailed("WEBLOC is not valid UTF-8")
        }

        let urlField = options?.fieldMapping?["url"] ?? defaultURLField

        // Try to parse using PropertyListSerialization first (handles binary and XML plists)
        if let plistObj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let url = plistObj["URL"] as? String {
            return [[urlField: url]]
        }

        // Fallback: simple XML parsing for the <string> value after <key>URL</key>
        guard let url = extractURLFromPlistXML(text) else {
            throw FormatError.decodingFailed("Could not find URL in WEBLOC plist")
        }

        return [[urlField: url]]
    }

    // MARK: - Helpers

    /// Extract URL string from plist XML by finding the <string> element after <key>URL</key>.
    private static func extractURLFromPlistXML(_ xml: String) -> String? {
        // Find <key>URL</key> then the next <string>...</string>
        guard let keyRange = xml.range(of: "<key>URL</key>") else { return nil }
        let afterKey = xml[keyRange.upperBound...]
        guard let stringStart = afterKey.range(of: "<string>"),
              let stringEnd = afterKey.range(of: "</string>") else { return nil }
        let urlValue = String(afterKey[stringStart.upperBound..<stringEnd.lowerBound])
        return unescapeXML(urlValue)
    }

    /// Escape special XML characters.
    private static func escapeXML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&apos;")
        return result
    }

    /// Unescape XML entities.
    private static func unescapeXML(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        return result
    }
}
