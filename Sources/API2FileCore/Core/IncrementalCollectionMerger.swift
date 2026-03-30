import Foundation

struct IncrementalCollectionMergeResult {
    let rawRecords: [[String: Any]]
    let transformedRecords: [[String: Any]]
    let content: Data

    var contentHash: String {
        content.sha256Hex
    }
}

enum IncrementalCollectionMerger {

    static func merge(
        existingRaw: [[String: Any]],
        existingTransformed: [[String: Any]],
        newRaw: [[String: Any]],
        resource: ResourceConfig
    ) throws -> IncrementalCollectionMergeResult {
        let idField = resource.fileMapping.idField ?? "id"
        let pullTransforms = resource.fileMapping.transforms?.pull ?? []
        let transformedNew = pullTransforms.isEmpty ? newRaw : TransformPipeline.apply(pullTransforms, to: newRaw)

        let mergedRaw = mergeRecords(
            existing: existingRaw,
            new: newRaw,
            idFields: rawIdFields(for: resource)
        )
        let mergedTransformed = mergeRecords(
            existing: existingTransformed,
            new: transformedNew,
            idField: idField
        )
        let content = try FormatConverterFactory.encode(
            records: mergedTransformed,
            format: resource.fileMapping.format,
            options: resource.fileMapping.effectiveFormatOptions
        )

        return IncrementalCollectionMergeResult(
            rawRecords: mergedRaw,
            transformedRecords: mergedTransformed,
            content: content
        )
    }

    static func rawIdField(for resource: ResourceConfig) -> String {
        let idField = resource.fileMapping.idField ?? "id"
        let pullTransforms = resource.fileMapping.transforms?.pull ?? []

        if let renamedIdField = pullTransforms.first(where: { $0.op == "rename" && $0.to == idField })?.from,
           !renamedIdField.isEmpty {
            return renamedIdField
        }

        return idField
    }

    static func rawIdFields(for resource: ResourceConfig) -> [String] {
        let primary = rawIdField(for: resource)
        let transformed = resource.fileMapping.idField ?? "id"
        return primary == transformed ? [primary] : [primary, transformed]
    }

    static func mergeRecords(
        existing: [[String: Any]],
        new: [[String: Any]],
        idField: String
    ) -> [[String: Any]] {
        mergeRecords(existing: existing, new: new, idFields: [idField])
    }

    static func mergeRecords(
        existing: [[String: Any]],
        new: [[String: Any]],
        idFields: [String]
    ) -> [[String: Any]] {
        var merged = deduplicate(records: existing, idFields: idFields)

        for record in new {
            guard let newId = stringifyId(firstValue(at: idFields, in: record)) else {
                merged.append(record)
                continue
            }

            if let index = merged.firstIndex(where: { stringifyId(firstValue(at: idFields, in: $0)) == newId }) {
                merged[index] = record
            } else {
                merged.append(record)
            }
        }

        return deduplicate(records: merged, idFields: idFields)
    }

    private static func deduplicate(records: [[String: Any]], idFields: [String]) -> [[String: Any]] {
        var deduped: [[String: Any]] = []
        var indexesById: [String: Int] = [:]

        for record in records {
            guard let id = stringifyId(firstValue(at: idFields, in: record)) else {
                deduped.append(record)
                continue
            }

            if let existingIndex = indexesById[id] {
                deduped[existingIndex] = record
            } else {
                indexesById[id] = deduped.count
                deduped.append(record)
            }
        }

        return deduped
    }

    private static func firstValue(at fieldPaths: [String], in record: [String: Any]) -> Any? {
        for fieldPath in fieldPaths {
            if let value = value(at: fieldPath, in: record) {
                return value
            }
        }
        return nil
    }

    private static func value(at fieldPath: String, in record: [String: Any]) -> Any? {
        guard fieldPath.contains(".") else {
            return record[fieldPath]
        }

        let components = fieldPath.split(separator: ".").map(String.init)
        var current: Any = record

        for component in components {
            guard let dict = current as? [String: Any],
                  let next = dict[component] else {
                return nil
            }
            current = next
        }

        return current
    }

    private static func stringifyId(_ value: Any?) -> String? {
        guard let value else { return nil }

        switch value {
        case let string as String:
            return string.isEmpty ? nil : string
        case let int as Int:
            return "\(int)"
        case let double as Double:
            if double == double.rounded(), double < 1e15 {
                return "\(Int(double))"
            }
            return "\(double)"
        default:
            return "\(value)"
        }
    }
}
