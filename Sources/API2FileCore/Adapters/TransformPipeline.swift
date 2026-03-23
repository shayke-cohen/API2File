import Foundation

// MARK: - JSONPath

/// Extracts values from nested data structures using simple JSONPath expressions.
///
/// Supported syntax:
/// - `$.data.boards` — traverse nested dictionaries
/// - `$.items[0].name` — array index access
/// - `$.data.boards[*]` — wildcard (returns all elements of an array)
public struct JSONPath {

    /// Extract a value from a nested data structure using a dot-path expression.
    /// - Parameters:
    ///   - path: A JSONPath-like string (e.g. `$.data.boards[0].name`)
    ///   - data: The root object (dictionary, array, or primitive)
    /// - Returns: The extracted value, or `nil` if the path doesn't resolve.
    public static func extract(_ path: String, from data: Any) -> Any? {
        let normalized = path.hasPrefix("$") ? String(path.dropFirst()) : path
        let tokens = tokenize(normalized)
        return resolve(tokens: tokens, in: data)
    }

    // MARK: - Private helpers

    /// Tokenize a path like `.data.boards[0].name` into components.
    private static func tokenize(_ path: String) -> [Token] {
        var tokens: [Token] = []
        var current = path[path.startIndex...]

        while !current.isEmpty {
            // Skip leading dots
            if current.first == "." {
                current = current.dropFirst()
                continue
            }

            // Check for bracket notation
            if current.first == "[" {
                if let closeBracket = current.firstIndex(of: "]") {
                    let inside = current[current.index(after: current.startIndex)..<closeBracket]
                    if inside == "*" {
                        tokens.append(.wildcard)
                    } else if let index = Int(inside) {
                        tokens.append(.index(index))
                    }
                    current = current[current.index(after: closeBracket)...]
                } else {
                    break
                }
                continue
            }

            // Read a key segment until we hit `.` or `[` or end
            var keyEnd = current.startIndex
            while keyEnd < current.endIndex && current[keyEnd] != "." && current[keyEnd] != "[" {
                keyEnd = current.index(after: keyEnd)
            }
            let key = String(current[current.startIndex..<keyEnd])
            if !key.isEmpty {
                tokens.append(.key(key))
            }
            current = current[keyEnd...]
        }
        return tokens
    }

    private enum Token {
        case key(String)
        case index(Int)
        case wildcard
    }

    private static func resolve(tokens: [Token], in data: Any) -> Any? {
        guard !tokens.isEmpty else { return data }

        var remaining = tokens
        let token = remaining.removeFirst()

        switch token {
        case .key(let key):
            guard let dict = data as? [String: Any], let next = dict[key] else { return nil }
            return resolve(tokens: remaining, in: next)

        case .index(let idx):
            guard let arr = data as? [Any], idx >= 0, idx < arr.count else { return nil }
            return resolve(tokens: remaining, in: arr[idx])

        case .wildcard:
            guard let arr = data as? [Any] else { return nil }
            if remaining.isEmpty {
                return arr
            }
            return arr.compactMap { resolve(tokens: remaining, in: $0) }
        }
    }
}

// MARK: - TemplateEngine

/// Renders mustache-style templates by replacing `{fieldName}` placeholders with values.
///
/// Supports filters via pipe syntax:
/// - `{name|slugify}` — lowercase, replace spaces/special chars with hyphens
/// - `{name|lower}` — lowercase
/// - `{name|upper}` — uppercase
/// - `{field|default:fallback}` — use fallback if field is nil or empty
public struct TemplateEngine {

    /// Render a template string, substituting `{field}` and `{field|filter}` placeholders.
    /// - Parameters:
    ///   - template: The template string with `{...}` placeholders
    ///   - data: Dictionary of values to substitute
    /// - Returns: The rendered string
    public static func render(_ template: String, with data: [String: Any]) -> String {
        var result = ""
        var current = template.startIndex

        while current < template.endIndex {
            // Find next opening brace
            guard let openBrace = template[current...].firstIndex(of: "{") else {
                result += template[current...]
                break
            }

            // Append text before the brace
            result += template[current..<openBrace]

            // Find matching close brace
            guard let closeBrace = template[template.index(after: openBrace)...].firstIndex(of: "}") else {
                result += template[openBrace...]
                break
            }

            let expression = String(template[template.index(after: openBrace)..<closeBrace])
            result += evaluateExpression(expression, with: data)
            current = template.index(after: closeBrace)
        }

        return result
    }

    // MARK: - Private helpers

    private static func evaluateExpression(_ expression: String, with data: [String: Any]) -> String {
        let parts = expression.split(separator: "|", maxSplits: 1)
        let fieldName = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let rawValue = resolveField(fieldName, in: data)

        if parts.count > 1 {
            let filterExpr = String(parts[1]).trimmingCharacters(in: .whitespaces)
            return applyFilter(filterExpr, to: rawValue)
        }

        return stringify(rawValue)
    }

    /// Resolve a potentially dot-notated field name from a dictionary.
    private static func resolveField(_ field: String, in data: [String: Any]) -> Any? {
        // Try direct lookup first
        if let value = data[field] {
            return value
        }
        // Try dot-path traversal
        let components = field.split(separator: ".").map(String.init)
        var current: Any = data
        for component in components {
            if let dict = current as? [String: Any], let next = dict[component] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    private static func applyFilter(_ filter: String, to value: Any?) -> String {
        switch filter {
        case "lower":
            return stringify(value).lowercased()
        case "upper":
            return stringify(value).uppercased()
        case "slugify":
            return slugify(stringify(value))
        default:
            // Check for default:fallback
            if filter.hasPrefix("default:") {
                let fallback = String(filter.dropFirst("default:".count))
                let str = stringify(value)
                return str.isEmpty ? fallback : str
            }
            // Unknown filter — return value as-is
            return stringify(value)
        }
    }

    private static func slugify(_ input: String) -> String {
        let lowered = input.lowercased()
        var result = ""
        for char in lowered {
            if char.isLetter || char.isNumber {
                result.append(char)
            } else if char == " " || char == "_" || char == "." || char == "/" {
                // Replace separators/special chars with hyphen, avoiding consecutive hyphens
                if !result.isEmpty && result.last != "-" {
                    result.append("-")
                }
            } else {
                // Other special characters: replace with hyphen
                if !result.isEmpty && result.last != "-" {
                    result.append("-")
                }
            }
        }
        // Trim trailing hyphens
        while result.last == "-" {
            result.removeLast()
        }
        return result
    }

    /// Convert any value to a string representation.
    private static func stringify(_ value: Any?) -> String {
        guard let value = value else { return "" }
        switch value {
        case let s as String: return s
        case let n as Int: return "\(n)"
        case let n as Double:
            if n == n.rounded() && n < 1e15 {
                return "\(Int(n))"
            }
            return "\(n)"
        case let b as Bool: return b ? "true" : "false"
        default: return "\(value)"
        }
    }
}

// MARK: - TransformPipeline

/// Applies a sequence of transform operations to arrays of records.
///
/// Each `TransformOp` specifies an `op` type and relevant parameters:
/// - `pick` — keep only specified fields
/// - `omit` — remove specified fields
/// - `rename` — rename a field (supports dot-path for nested extraction)
/// - `flatten` — extract a field from nested array elements into a flat array
/// - `keyBy` — convert an array of key-value objects into a dictionary
public struct TransformPipeline {

    /// Apply a sequence of transforms to an array of records.
    /// - Parameters:
    ///   - transforms: Ordered list of transform operations
    ///   - data: Input records
    /// - Returns: Transformed records
    public static func apply(_ transforms: [TransformOp], to data: [[String: Any]]) -> [[String: Any]] {
        var records = data
        for transform in transforms {
            records = applyOp(transform, to: records)
        }
        return records
    }

    // MARK: - Private dispatch

    private static func applyOp(_ op: TransformOp, to records: [[String: Any]]) -> [[String: Any]] {
        switch op.op {
        case "pick":
            return records.map { pick(fields: op.fields ?? [], from: $0) }
        case "omit":
            return records.map { omit(fields: op.fields ?? [], from: $0) }
        case "rename":
            guard let from = op.from, let to = op.to else { return records }
            return records.map { rename(from: from, to: to, in: $0) }
        case "flatten":
            guard let path = op.path, let to = op.to else { return records }
            return records.map { flatten(path: path, to: to, select: op.select, in: $0) }
        case "keyBy":
            guard let path = op.path, let key = op.key, let value = op.value, let to = op.to else { return records }
            return records.map { keyBy(path: path, key: key, value: value, to: to, in: $0) }
        default:
            return records
        }
    }

    // MARK: - Pick

    private static func pick(fields: [String], from record: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for field in fields {
            if let value = record[field] {
                result[field] = value
            }
        }
        return result
    }

    // MARK: - Omit

    private static func omit(fields: [String], from record: [String: Any]) -> [String: Any] {
        var result = record
        for field in fields {
            result.removeValue(forKey: field)
        }
        return result
    }

    // MARK: - Rename

    private static func rename(from: String, to: String, in record: [String: Any]) -> [String: Any] {
        var result = record

        if from.contains(".") {
            // Dot-path: extract nested value
            let value = resolveDotPath(from, in: record)
            if let value = value {
                result[to] = value
            }
            // Don't remove the source key — other renames may need it.
            // Use "omit" explicitly to clean up parent keys after all renames.
        } else {
            // Simple rename
            if let value = result.removeValue(forKey: from) {
                result[to] = value
            }
        }

        return result
    }

    // MARK: - Flatten

    private static func flatten(path: String, to: String, select: String?, in record: [String: Any]) -> [String: Any] {
        var result = record

        guard let nested = resolveDotPath(path, in: record) else { return result }
        guard let arr = nested as? [[String: Any]] else { return result }

        if let selectField = select {
            let values = arr.compactMap { $0[selectField] }
            result[to] = values
        } else {
            result[to] = arr
        }

        // Remove the top-level source key
        let topKey = String(path.split(separator: ".").first ?? "")
        if !topKey.isEmpty && topKey != to {
            result.removeValue(forKey: topKey)
        }

        return result
    }

    // MARK: - KeyBy

    private static func keyBy(path: String, key: String, value: String, to: String, in record: [String: Any]) -> [String: Any] {
        var result = record

        guard let nested = resolveDotPath(path, in: record) else { return result }
        guard let arr = nested as? [[String: Any]] else { return result }

        var dict: [String: Any] = [:]
        for item in arr {
            if let k = item[key] as? String {
                dict[k] = item[value] as Any
            }
        }

        result[to] = dict

        // Remove the top-level source key
        let topKey = String(path.split(separator: ".").first ?? "")
        if !topKey.isEmpty && topKey != to {
            result.removeValue(forKey: topKey)
        }

        return result
    }

    // MARK: - Dot-path resolution

    /// Resolve a dot-path like "priceData.price" from a nested dictionary.
    private static func resolveDotPath(_ path: String, in record: [String: Any]) -> Any? {
        let components = path.split(separator: ".").map(String.init)
        var current: Any = record
        for component in components {
            if let dict = current as? [String: Any], let next = dict[component] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }
}
