import Foundation

/// Represents an inverse transform operation derived from a pull transform.
public enum InverseOp {
    /// Reverse of `rename(from, to)` — rename `to` back to `from`
    case rename(from: String, to: String)
    /// Reverse of `omit(fields)` — restore fields from raw record
    case restoreOmitted(fields: [String])
    /// Reverse of `pick(fields)` — restore non-picked fields from raw record
    case restoreNonPicked(fields: [String])
    /// Reverse of `flatten(path, to, select)` — re-nest flat value back into original path
    case unflatten(originalPath: String, flatKey: String, select: String?)
    /// Reverse of `keyBy(path, key, value, to)` — convert dict back to array
    case unkeyBy(originalPath: String, flatKey: String, keyField: String, valueField: String)
}

/// Computes and applies inverse transforms to support bidirectional push.
///
/// Given a set of pull transforms (API → file), this pipeline computes the inverse
/// operations needed to transform user-edited records back into the raw API shape.
/// It merges user edits with the cached raw record to produce a complete API payload.
public struct InverseTransformPipeline {

    /// Compute inverse operations from pull transforms.
    /// Returns the inverse ops in reverse order (last pull transform is first to invert).
    public static func computeInverse(of pullTransforms: [TransformOp]) -> [InverseOp] {
        var inverseOps: [InverseOp] = []

        // Process in reverse order — last applied pull transform is first to undo
        for transform in pullTransforms.reversed() {
            switch transform.op {
            case "rename":
                if let from = transform.from, let to = transform.to {
                    // Reverse: rename `to` back to `from`
                    inverseOps.append(.rename(from: to, to: from))
                }
            case "omit":
                if let fields = transform.fields {
                    inverseOps.append(.restoreOmitted(fields: fields))
                }
            case "pick":
                if let fields = transform.fields {
                    inverseOps.append(.restoreNonPicked(fields: fields))
                }
            case "flatten":
                if let path = transform.path, let to = transform.to {
                    inverseOps.append(.unflatten(originalPath: path, flatKey: to, select: transform.select))
                }
            case "keyBy":
                if let path = transform.path, let key = transform.key,
                   let value = transform.value, let to = transform.to {
                    inverseOps.append(.unkeyBy(originalPath: path, flatKey: to, keyField: key, valueField: value))
                }
            default:
                break
            }
        }

        return inverseOps
    }

    /// Apply inverse transforms to merge a user-edited record with a raw cached record.
    ///
    /// - Parameters:
    ///   - inverseOps: The inverse operations to apply
    ///   - editedRecord: The record as decoded from the user-edited file
    ///   - rawRecord: The original raw API record from the object file
    /// - Returns: A merged record in the raw API shape, ready to push
    public static func apply(
        inverseOps: [InverseOp],
        editedRecord: [String: Any],
        rawRecord: [String: Any]
    ) -> [String: Any] {
        // Start with the raw record as the base (preserves all API fields)
        var result = rawRecord
        // Track which fields in the edited record have been "consumed" by inverse ops
        var editedCopy = editedRecord

        for op in inverseOps {
            switch op {
            case .rename(let from, let to):
                applyInverseRename(from: from, to: to, edited: &editedCopy, result: &result)
            case .restoreOmitted(let fields):
                applyInverseOmit(fields: fields, result: &result, rawRecord: rawRecord)
            case .restoreNonPicked(let pickedFields):
                applyInversePick(pickedFields: pickedFields, edited: &editedCopy, result: &result, rawRecord: rawRecord)
            case .unflatten(let originalPath, let flatKey, let select):
                applyInverseFlatten(originalPath: originalPath, flatKey: flatKey, select: select, edited: &editedCopy, result: &result, rawRecord: rawRecord)
            case .unkeyBy(let originalPath, let flatKey, let keyField, let valueField):
                applyInverseKeyBy(originalPath: originalPath, flatKey: flatKey, keyField: keyField, valueField: valueField, edited: &editedCopy, result: &result)
            }
        }

        // Apply remaining edited fields that weren't consumed by inverse ops
        // These are fields that exist in both the file and API without transformation
        for (key, value) in editedCopy {
            result[key] = value
        }

        return result
    }

    /// Apply inverse transforms without a raw record (for new records).
    /// Only applies mechanical inversions (rename, unkeyBy). Omit/pick are no-ops.
    public static func applyMechanical(
        inverseOps: [InverseOp],
        editedRecord: [String: Any]
    ) -> [String: Any] {
        var result = editedRecord

        for op in inverseOps {
            switch op {
            case .rename(let from, let to):
                // Rename field back — use setNestedValue whenever `to` has a dot-path
                if let value = result.removeValue(forKey: from) {
                    if to.contains(".") {
                        setNestedValue(value, atPath: to, in: &result)
                    } else {
                        result[to] = value
                    }
                }
            case .unkeyBy(let originalPath, let flatKey, let keyField, let valueField):
                // Convert dict back to array
                if let dict = result.removeValue(forKey: flatKey) as? [String: Any] {
                    let array = dict.map { (k, v) -> [String: Any] in
                        [keyField: k, valueField: v]
                    }
                    let topKey = String(originalPath.split(separator: ".").first ?? Substring(originalPath))
                    result[topKey] = array
                }
            case .unflatten(let originalPath, let flatKey, _):
                // Without raw record, best effort: move flat value to top-level key
                if let value = result.removeValue(forKey: flatKey) {
                    let topKey = String(originalPath.split(separator: ".").first ?? Substring(originalPath))
                    result[topKey] = value
                }
            case .restoreOmitted, .restoreNonPicked:
                // Can't restore without raw record — skip
                break
            }
        }

        return result
    }

    // MARK: - Private Inverse Operation Implementations

    private static func applyInverseRename(
        from: String, to: String,
        edited: inout [String: Any], result: inout [String: Any]
    ) {
        // `from` is the field name in the edited file, `to` is where it goes in the raw record
        if let value = edited.removeValue(forKey: from) {
            if to.contains(".") {
                setNestedValue(value, atPath: to, in: &result)
            } else {
                result[to] = value
            }
        }
    }

    private static func applyInverseOmit(
        fields: [String],
        result: inout [String: Any],
        rawRecord: [String: Any]
    ) {
        // Restore omitted fields from the raw record
        for field in fields {
            if let value = rawRecord[field] {
                result[field] = value
            }
        }
    }

    private static func applyInversePick(
        pickedFields: [String],
        edited: inout [String: Any],
        result: inout [String: Any],
        rawRecord: [String: Any]
    ) {
        // User can only see picked fields. Restore everything else from raw.
        // First, overlay user's edits for the picked fields
        for field in pickedFields {
            if let value = edited.removeValue(forKey: field) {
                result[field] = value
            }
        }
        // Non-picked fields are already in result (from rawRecord base)
    }

    private static func applyInverseFlatten(
        originalPath: String, flatKey: String, select: String?,
        edited: inout [String: Any],
        result: inout [String: Any],
        rawRecord: [String: Any]
    ) {
        guard let flatValue = edited.removeValue(forKey: flatKey) else { return }

        // Get the original nested structure from raw record
        let topKey = String(originalPath.split(separator: ".").first ?? Substring(originalPath))

        if let selectField = select {
            // flatten with select: the flat value is an array of selected field values
            // Merge back into the original array items
            if let flatArray = flatValue as? [Any],
               let originalNested = resolveNestedValue(atPath: originalPath, in: rawRecord) as? [[String: Any]] {
                var updatedArray = originalNested
                for (index, newValue) in flatArray.enumerated() where index < updatedArray.count {
                    updatedArray[index][selectField] = newValue
                }
                setNestedValue(updatedArray, atPath: originalPath, in: &result)
            } else {
                // Fallback: just put it back
                setNestedValue(flatValue, atPath: originalPath, in: &result)
            }
        } else {
            // flatten without select: the flat value replaces the nested structure
            setNestedValue(flatValue, atPath: originalPath, in: &result)
        }

        // Remove the flat key from result if it was placed there
        if flatKey != topKey {
            result.removeValue(forKey: flatKey)
        }
    }

    private static func applyInverseKeyBy(
        originalPath: String, flatKey: String,
        keyField: String, valueField: String,
        edited: inout [String: Any],
        result: inout [String: Any]
    ) {
        guard let dict = edited.removeValue(forKey: flatKey) as? [String: Any] else { return }

        // Convert dict back to array of {key, value} objects
        let array: [[String: Any]] = dict.map { (k, v) in
            [keyField: k, valueField: v]
        }

        let topKey = String(originalPath.split(separator: ".").first ?? Substring(originalPath))
        setNestedValue(array, atPath: originalPath, in: &result)

        // Remove the flat key from result
        if flatKey != topKey {
            result.removeValue(forKey: flatKey)
        }
    }

    // MARK: - Nested Value Helpers

    /// Set a value at a dot-separated path in a nested dictionary.
    private static func setNestedValue(_ value: Any, atPath path: String, in dict: inout [String: Any]) {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return }

        if components.count == 1 {
            dict[components[0]] = value
            return
        }

        // Build nested structure
        let topKey = components[0]
        var nested = dict[topKey] as? [String: Any] ?? [:]
        let remainingPath = components.dropFirst().joined(separator: ".")
        setNestedValue(value, atPath: remainingPath, in: &nested)
        dict[topKey] = nested
    }

    /// Resolve a value at a dot-separated path in a nested dictionary.
    private static func resolveNestedValue(atPath path: String, in dict: [String: Any]) -> Any? {
        let components = path.split(separator: ".").map(String.init)
        var current: Any = dict
        for component in components {
            guard let d = current as? [String: Any], let next = d[component] else { return nil }
            current = next
        }
        return current
    }
}
