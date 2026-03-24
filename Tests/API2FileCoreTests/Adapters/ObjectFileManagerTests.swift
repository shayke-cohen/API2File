import XCTest
@testable import API2FileCore

final class ObjectFileManagerTests: XCTestCase {

    // MARK: - Path Computation — Collection Strategy

    func testCollectionObjectFilePath() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forCollectionFile: "tasks.csv"),
            ".tasks.objects.json"
        )
    }

    func testCollectionObjectFilePathWithDirectory() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forCollectionFile: "boards/marketing.csv"),
            "boards/.marketing.objects.json"
        )
    }

    func testCollectionObjectFilePathNestedDirectory() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forCollectionFile: "data/exports/items.json"),
            "data/exports/.items.objects.json"
        )
    }

    // MARK: - Path Computation — One-per-record Strategy

    func testRecordObjectFilePath() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forRecordFile: "contacts/john-doe.vcf"),
            "contacts/.objects/john-doe.json"
        )
    }

    func testRecordObjectFilePathNestedDirectory() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forRecordFile: "data/people/alice.vcf"),
            "data/people/.objects/alice.json"
        )
    }

    func testRecordObjectFilePathRootLevel() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forRecordFile: "readme.md"),
            ".objects/readme.json"
        )
    }

    // MARK: - Strategy Dispatch

    func testObjectFilePathByStrategy() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forUserFile: "tasks.csv", strategy: .collection),
            ".tasks.objects.json"
        )
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forUserFile: "contacts/alice.vcf", strategy: .onePerRecord),
            "contacts/.objects/alice.json"
        )
    }

    // MARK: - isObjectFile

    func testIsObjectFileForCollectionObject() {
        XCTAssertTrue(ObjectFileManager.isObjectFile(".tasks.objects.json"))
        XCTAssertTrue(ObjectFileManager.isObjectFile("boards/.marketing.objects.json"))
    }

    func testIsObjectFileForRecordObject() {
        XCTAssertTrue(ObjectFileManager.isObjectFile("contacts/.objects/alice.json"))
        XCTAssertTrue(ObjectFileManager.isObjectFile("data/people/.objects/bob.json"))
    }

    func testIsObjectFileForNormalFiles() {
        XCTAssertFalse(ObjectFileManager.isObjectFile("tasks.csv"))
        XCTAssertFalse(ObjectFileManager.isObjectFile("contacts/alice.vcf"))
        XCTAssertFalse(ObjectFileManager.isObjectFile(".gitignore"))
        XCTAssertFalse(ObjectFileManager.isObjectFile(".api2file/state.json"))
    }

    // MARK: - Reverse Path (object → user)

    func testUserFilePathFromCollectionObject() {
        let userPath = ObjectFileManager.userFilePath(
            forObjectFile: ".tasks.objects.json",
            strategy: .collection,
            format: .csv
        )
        XCTAssertEqual(userPath, "tasks.csv")
    }

    func testUserFilePathFromCollectionObjectWithDir() {
        let userPath = ObjectFileManager.userFilePath(
            forObjectFile: "boards/.marketing.objects.json",
            strategy: .collection,
            format: .csv
        )
        XCTAssertEqual(userPath, "boards/marketing.csv")
    }

    func testUserFilePathFromRecordObject() {
        let userPath = ObjectFileManager.userFilePath(
            forObjectFile: "contacts/.objects/alice.json",
            strategy: .onePerRecord,
            format: .vcf
        )
        XCTAssertEqual(userPath, "contacts/alice.vcf")
    }

    func testUserFilePathReturnsNilForNonObjectFile() {
        let userPath = ObjectFileManager.userFilePath(
            forObjectFile: "tasks.csv",
            strategy: .collection,
            format: .csv
        )
        XCTAssertNil(userPath)
    }

    // MARK: - Read / Write (Disk I/O)

    func testWriteAndReadCollectionObjectFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent(".tasks.objects.json")
        let records: [[String: Any]] = [
            ["id": "1", "name": "Task A", "done": false],
            ["id": "2", "name": "Task B", "done": true]
        ]

        try ObjectFileManager.writeCollectionObjectFile(records: records, to: url)
        let readBack = try ObjectFileManager.readCollectionObjectFile(from: url)

        XCTAssertEqual(readBack.count, 2)
        XCTAssertEqual(readBack[0]["id"] as? String, "1")
        XCTAssertEqual(readBack[1]["name"] as? String, "Task B")
    }

    func testWriteAndReadRecordObjectFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("alice.json")
        let record: [String: Any] = ["id": "1", "name": "Alice", "email": "alice@example.com"]

        try ObjectFileManager.writeRecordObjectFile(record: record, to: url)
        let readBack = try ObjectFileManager.readRecordObjectFile(from: url)

        XCTAssertEqual(readBack["id"] as? String, "1")
        XCTAssertEqual(readBack["name"] as? String, "Alice")
        XCTAssertEqual(readBack["email"] as? String, "alice@example.com")
    }

    // MARK: - PushMode

    func testEffectivePushModeExplicit() {
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, pushMode: .readOnly)
        XCTAssertEqual(mapping.effectivePushMode, .readOnly)
    }

    func testEffectivePushModeReadOnlyFlag() {
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, readOnly: true)
        XCTAssertEqual(mapping.effectivePushMode, .readOnly)
    }

    func testEffectivePushModeAutoReverseWithTransforms() {
        let transforms = TransformConfig(pull: [TransformOp(op: "omit", fields: ["internal"])])
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, idField: "id", transforms: transforms)
        XCTAssertEqual(mapping.effectivePushMode, .autoReverse)
    }

    func testEffectivePushModeReadOnlyWhenNoIdField() {
        let transforms = TransformConfig(pull: [TransformOp(op: "omit", fields: ["internal"])])
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, transforms: transforms)
        XCTAssertEqual(mapping.effectivePushMode, .readOnly)
    }

    func testEffectivePushModePassthroughWhenNoTransforms() {
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, idField: "id")
        XCTAssertEqual(mapping.effectivePushMode, .passthrough)
    }

    // MARK: - Edge-case Tests

    func testCollectionObjectFilePathMultipleDots() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forCollectionFile: "data.backup.csv"),
            ".data.backup.objects.json"
        )
    }

    func testMirrorStrategyUsesCollectionPath() {
        let mirrorPath = ObjectFileManager.objectFilePath(forUserFile: "tasks.csv", strategy: .mirror)
        let collectionPath = ObjectFileManager.objectFilePath(forUserFile: "tasks.csv", strategy: .collection)
        XCTAssertEqual(mirrorPath, collectionPath)
    }

    func testIsObjectFileInsideNestedObjectsDir() {
        XCTAssertTrue(ObjectFileManager.isObjectFile("a/b/c/.objects/d.json"))
    }

    func testIsObjectFileNotForDotApiFile() {
        XCTAssertFalse(ObjectFileManager.isObjectFile(".api2file/something.json"))
    }

    func testUserFilePathFromRecordObjectWithNestedDir() {
        let userPath = ObjectFileManager.userFilePath(
            forObjectFile: "data/people/.objects/bob.json",
            strategy: .onePerRecord,
            format: .vcf
        )
        XCTAssertEqual(userPath, "data/people/bob.vcf")
    }

    func testWriteCollectionObjectFileCreatesParentDirs() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nested = tempDir.appendingPathComponent("a/b/c/.items.objects.json")
        let records: [[String: Any]] = [["id": "1", "title": "Hello"]]

        try ObjectFileManager.writeCollectionObjectFile(records: records, to: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        let readBack = try ObjectFileManager.readCollectionObjectFile(from: nested)
        XCTAssertEqual(readBack.count, 1)
        XCTAssertEqual(readBack[0]["id"] as? String, "1")
    }

    func testWriteRecordObjectFileCreatesObjectsDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let objectFile = tempDir.appendingPathComponent("contacts/.objects/alice.json")
        let record: [String: Any] = ["id": "a1", "name": "Alice"]

        try ObjectFileManager.writeRecordObjectFile(record: record, to: objectFile)

        XCTAssertTrue(FileManager.default.fileExists(atPath: objectFile.path))
        let readBack = try ObjectFileManager.readRecordObjectFile(from: objectFile)
        XCTAssertEqual(readBack["name"] as? String, "Alice")
    }

    func testReadCollectionObjectFileThrowsOnInvalidJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent(".items.objects.json")
        // Write a JSON object (dict) instead of the expected array
        let dictData = try JSONSerialization.data(withJSONObject: ["key": "value"])
        try dictData.write(to: url)

        XCTAssertThrowsError(try ObjectFileManager.readCollectionObjectFile(from: url)) { error in
            guard let objError = error as? ObjectFileError else {
                XCTFail("Expected ObjectFileError, got \(type(of: error))")
                return
            }
            if case .invalidFormat(let msg) = objError {
                XCTAssertTrue(msg.contains("array"), "Error message should mention array, got: \(msg)")
            } else {
                XCTFail("Expected .invalidFormat, got \(objError)")
            }
        }
    }

    func testReadRecordObjectFileThrowsOnArray() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("record.json")
        // Write a JSON array instead of the expected object
        let arrayData = try JSONSerialization.data(withJSONObject: [["id": "1"]])
        try arrayData.write(to: url)

        XCTAssertThrowsError(try ObjectFileManager.readRecordObjectFile(from: url)) { error in
            guard let objError = error as? ObjectFileError else {
                XCTFail("Expected ObjectFileError, got \(type(of: error))")
                return
            }
            if case .invalidFormat(let msg) = objError {
                XCTAssertTrue(msg.contains("object"), "Error message should mention object, got: \(msg)")
            } else {
                XCTFail("Expected .invalidFormat, got \(objError)")
            }
        }
    }

    func testWriteAndReadPreservesNumericTypes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent(".numbers.objects.json")
        let records: [[String: Any]] = [
            ["count": 42, "price": 19.99, "label": "item"]
        ]

        try ObjectFileManager.writeCollectionObjectFile(records: records, to: url)
        let readBack = try ObjectFileManager.readCollectionObjectFile(from: url)

        XCTAssertEqual(readBack.count, 1)
        // NSNumber from JSONSerialization — verify numeric values survive round-trip
        XCTAssertEqual(readBack[0]["count"] as? Int, 42)
        let price = try XCTUnwrap(readBack[0]["price"] as? Double)
        XCTAssertEqual(price, 19.99, accuracy: 0.001)
        XCTAssertEqual(readBack[0]["label"] as? String, "item")
    }

    func testWriteAndReadPreservesNestedObjects() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("nested.json")
        let record: [String: Any] = [
            "id": "x1",
            "address": ["street": "123 Main", "city": "Springfield"],
            "tags": ["urgent", "review"]
        ]

        try ObjectFileManager.writeRecordObjectFile(record: record, to: url)
        let readBack = try ObjectFileManager.readRecordObjectFile(from: url)

        XCTAssertEqual(readBack["id"] as? String, "x1")
        let address = readBack["address"] as? [String: Any]
        XCTAssertEqual(address?["street"] as? String, "123 Main")
        XCTAssertEqual(address?["city"] as? String, "Springfield")
        let tags = readBack["tags"] as? [String]
        XCTAssertEqual(tags, ["urgent", "review"])
    }

    func testEffectivePushModeExplicitOverridesAutoDetect() {
        let transforms = TransformConfig(pull: [TransformOp(op: "omit", fields: ["secret"])])
        // Even with transforms + idField (which would auto-detect as .autoReverse),
        // an explicit .custom overrides
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, idField: "id", transforms: transforms, pushMode: .custom)
        XCTAssertEqual(mapping.effectivePushMode, .custom)
    }

    func testEffectivePushModeExplicitAutoReverseWithoutTransforms() {
        // Explicit auto-reverse even without transforms
        let mapping = FileMappingConfig(strategy: .collection, directory: ".", format: .csv, pushMode: .autoReverse)
        XCTAssertEqual(mapping.effectivePushMode, .autoReverse)
    }

    func testCollectionObjectFilePathNoExtension() {
        XCTAssertEqual(
            ObjectFileManager.objectFilePath(forCollectionFile: "Makefile"),
            ".Makefile.objects.json"
        )
    }
}
