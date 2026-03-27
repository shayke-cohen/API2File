import XCTest
@testable import API2FileCore

final class IncrementalCollectionMergerTests: XCTestCase {

    func testRawIdFieldUsesRenameSourceForIncrementalRawMerge() {
        let resource = ResourceConfig(
            name: "crm-tasks",
            fileMapping: FileMappingConfig(
                strategy: .collection,
                directory: ".",
                filename: "crm-tasks.csv",
                format: .csv,
                idField: "id",
                transforms: TransformConfig(
                    pull: [
                        TransformOp(op: "rename", from: "taskId", to: "id")
                    ]
                )
            )
        )

        XCTAssertEqual(IncrementalCollectionMerger.rawIdField(for: resource), "taskId")
    }

    func testMergeRecordsDeduplicatesExistingRecordsByRawTaskId() {
        let existing: [[String: Any]] = [
            ["taskId": "t1", "title": "First copy", "version": 1],
            ["taskId": "t1", "title": "Second copy", "version": 2],
            ["taskId": "t2", "title": "Keep me", "version": 1],
        ]
        let incoming: [[String: Any]] = [
            ["taskId": "t1", "title": "Latest from API", "version": 3]
        ]

        let merged = IncrementalCollectionMerger.mergeRecords(
            existing: existing,
            new: incoming,
            idField: "taskId"
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0]["taskId"] as? String, "t1")
        XCTAssertEqual(merged[0]["title"] as? String, "Latest from API")
        XCTAssertEqual(merged[1]["taskId"] as? String, "t2")
    }

    func testMergeBuildsMergedContentUsingRawAndTransformedIdSpaces() throws {
        let resource = ResourceConfig(
            name: "crm-tasks",
            fileMapping: FileMappingConfig(
                strategy: .collection,
                directory: ".",
                filename: "crm-tasks.csv",
                format: .csv,
                idField: "id",
                transforms: TransformConfig(
                    pull: [
                        TransformOp(op: "rename", from: "taskId", to: "id"),
                        TransformOp(op: "omit", fields: ["labels"])
                    ]
                )
            )
        )

        let existingRaw: [[String: Any]] = [
            ["taskId": "t1", "title": "Original title", "version": 1, "labels": ["a"]],
            ["taskId": "t1", "title": "Duplicate title", "version": 2, "labels": ["b"]],
        ]
        let existingTransformed: [[String: Any]] = [
            ["id": "t1", "title": "Original title", "version": 1],
            ["id": "t1", "title": "Duplicate title", "version": 2],
        ]
        let newRaw: [[String: Any]] = [
            ["taskId": "t1", "title": "Updated title", "version": 3, "labels": ["c"]]
        ]

        let result = try IncrementalCollectionMerger.merge(
            existingRaw: existingRaw,
            existingTransformed: existingTransformed,
            newRaw: newRaw,
            resource: resource
        )

        XCTAssertEqual(result.rawRecords.count, 1)
        XCTAssertEqual(result.transformedRecords.count, 1)
        XCTAssertEqual(result.rawRecords[0]["taskId"] as? String, "t1")
        XCTAssertEqual(result.rawRecords[0]["version"] as? Int, 3)
        XCTAssertEqual(result.transformedRecords[0]["id"] as? String, "t1")
        XCTAssertEqual(result.transformedRecords[0]["title"] as? String, "Updated title")
        XCTAssertFalse(result.contentHash.isEmpty)

        let decoded = try CSVFormat.decode(data: result.content, options: nil)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0]["id"] as? String, "t1")
        XCTAssertEqual(decoded[0]["title"] as? String, "Updated title")
    }

    func testMergeCleansLegacyMixedRawAndTransformedObjectRecords() throws {
        let resource = ResourceConfig(
            name: "crm-tasks",
            fileMapping: FileMappingConfig(
                strategy: .collection,
                directory: ".",
                filename: "crm-tasks.csv",
                format: .csv,
                idField: "id",
                transforms: TransformConfig(
                    pull: [
                        TransformOp(op: "rename", from: "taskId", to: "id")
                    ]
                )
            )
        )

        let existingRaw: [[String: Any]] = [
            ["id": "t1", "title": "Legacy transformed object", "version": 1],
            ["taskId": "t1", "title": "Legacy raw object", "version": 2],
        ]
        let existingTransformed: [[String: Any]] = [
            ["id": "t1", "title": "Legacy transformed object", "version": 1]
        ]
        let newRaw: [[String: Any]] = [
            ["taskId": "t1", "title": "Fresh API title", "version": 3]
        ]

        let result = try IncrementalCollectionMerger.merge(
            existingRaw: existingRaw,
            existingTransformed: existingTransformed,
            newRaw: newRaw,
            resource: resource
        )

        XCTAssertEqual(result.rawRecords.count, 1)
        XCTAssertEqual(result.rawRecords[0]["taskId"] as? String, "t1")
        XCTAssertEqual(result.rawRecords[0]["title"] as? String, "Fresh API title")
    }
}
