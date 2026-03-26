import Foundation

/// Diffs two versions of a collection (array of records) to determine
/// which records were created, updated, or deleted.
///
/// Used when a collection-strategy file (CSV, JSON array, XLSX, YAML)
/// is edited locally and needs to be pushed back to the API.
public enum CollectionDiffer {

    /// Result of diffing old vs new records
    public struct DiffResult: Sendable {
        /// New records (no matching ID in old set)
        public let created: [[String: Any]]
        /// Records whose content changed (same ID, different fields)
        public let updated: [(id: String, record: [String: Any])]
        /// IDs of records that existed before but are gone now
        public let deleted: [String]

        public var isEmpty: Bool {
            created.isEmpty && updated.isEmpty && deleted.isEmpty
        }

        public var summary: String {
            var parts: [String] = []
            if !created.isEmpty { parts.append("\(created.count) created") }
            if !updated.isEmpty { parts.append("\(updated.count) updated") }
            if !deleted.isEmpty { parts.append("\(deleted.count) deleted") }
            return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
        }
    }

    /// Diff old records against new records using the given ID field.
    ///
    /// - Parameters:
    ///   - oldRecords: Previously synced records (from last pull or state)
    ///   - newRecords: Current records (decoded from the edited local file)
    ///   - idField: The field name that uniquely identifies records (e.g., "id", "_id")
    /// - Returns: A DiffResult with created, updated, and deleted records
    public static func diff(
        old oldRecords: [[String: Any]],
        new newRecords: [[String: Any]],
        idField: String = "id",
        ignoreFields: Set<String> = []
    ) -> DiffResult {
        // Fields to ignore in comparison: id fields + server-controlled fields
        let skipFields = Set([idField, "_id"]).union(ignoreFields)

        // Build lookup of old records by ID
        var oldById: [String: [String: Any]] = [:]
        for record in oldRecords {
            if let id = stringId(record[idField]) {
                oldById[id] = record
            }
        }

        // Build lookup of new records by ID
        var newById: [String: [String: Any]] = [:]
        var created: [[String: Any]] = []

        for record in newRecords {
            if let id = stringId(record[idField]), !id.isEmpty {
                newById[id] = record
            } else {
                // No ID = new record
                created.append(record)
            }
        }

        // Find updated records (same ID, different content)
        var updated: [(id: String, record: [String: Any])] = []
        for (id, newRecord) in newById {
            if let oldRecord = oldById[id] {
                if !recordsEqual(oldRecord, newRecord, ignoringFields: skipFields) {
                    updated.append((id: id, record: newRecord))
                }
            } else {
                // ID exists in new but not in old — treat as created
                created.append(newRecord)
            }
        }

        // Find deleted records (in old but not in new)
        var deleted: [String] = []
        for id in oldById.keys {
            if newById[id] == nil {
                deleted.append(id)
            }
        }

        return DiffResult(created: created, updated: updated, deleted: deleted)
    }

    // MARK: - Helpers

    /// Convert any ID value to a string for comparison
    private static func stringId(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let i as Int: return "\(i)"
        case let d as Double: return d == Double(Int(d)) ? "\(Int(d))" : "\(d)"
        default: return "\(value)"
        }
    }

    /// Compare two records for equality, ignoring specified fields
    private static func recordsEqual(_ a: [String: Any], _ b: [String: Any], ignoringFields: Set<String>) -> Bool {
        let keysA = Set(a.keys).subtracting(ignoringFields)
        let keysB = Set(b.keys).subtracting(ignoringFields)

        guard keysA == keysB else { return false }

        for key in keysA {
            if !valuesEqual(a[key], b[key]) {
                return false
            }
        }
        return true
    }

    /// Compare two values for equality
    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        // Both nil
        if a == nil && b == nil { return true }
        guard let a = a, let b = b else { return false }

        // Normalize to strings for comparison (handles Int vs String "1", etc.)
        let strA = normalizeValue(a)
        let strB = normalizeValue(b)
        return strA == strB
    }

    /// Normalize a value to a canonical string form for comparison
    private static func normalizeValue(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let i as Int: return "\(i)"
        case let d as Double:
            if d == Double(Int(d)) { return "\(Int(d))" }
            return "\(d)"
        case let b as Bool: return b ? "true" : "false"
        case let arr as [Any]: return arr.map { normalizeValue($0) }.joined(separator: ",")
        case let dict as [String: Any]:
            return dict.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\(normalizeValue($0.value))" }.joined(separator: "&")
        default: return "\(value)"
        }
    }
}
