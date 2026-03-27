import XCTest
@testable import API2FileCore

final class TransformPipelineTests: XCTestCase {

    // MARK: - Pick

    func testPickKeepsOnlySpecifiedFields() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget", "price": 9.99, "_internal": "skip"],
            ["id": 2, "name": "Gadget", "price": 19.99, "_internal": "skip"]
        ]
        let op = TransformOp(op: "pick", fields: ["id", "name", "price"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].keys.sorted(), ["id", "name", "price"])
        XCTAssertEqual(result[0]["name"] as? String, "Widget")
        XCTAssertNil(result[0]["_internal"])
    }

    func testPickWithMissingFieldsIgnoresThem() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "pick", fields: ["id", "nonexistent"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0].keys.sorted(), ["id"])
        XCTAssertNil(result[0]["name"])
    }

    func testPickEmptyFieldsReturnsEmptyRecords() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "pick", fields: [])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertTrue(result[0].isEmpty)
    }

    // MARK: - Omit

    func testOmitRemovesSpecifiedFields() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget", "_internal": "secret", "_debug": true]
        ]
        let op = TransformOp(op: "omit", fields: ["_internal", "_debug"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0].keys.sorted(), ["id", "name"])
        XCTAssertNil(result[0]["_internal"])
        XCTAssertNil(result[0]["_debug"])
    }

    func testOmitWithNonexistentFieldsDoesNothing() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "omit", fields: ["nonexistent"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0].keys.sorted(), ["id", "name"])
    }

    // MARK: - Rename

    func testRenameSimpleField() {
        let data: [[String: Any]] = [
            ["old_name": "Widget", "id": 1]
        ]
        let op = TransformOp(op: "rename", from: "old_name", to: "name")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0]["name"] as? String, "Widget")
        XCTAssertNil(result[0]["old_name"])
        XCTAssertEqual(result[0]["id"] as? Int, 1)
    }

    func testRenameDotPathExtractsNestedValue() {
        let data: [[String: Any]] = [
            ["id": 1, "priceData": ["price": 9.99, "currency": "USD"]]
        ]
        let op = TransformOp(op: "rename", from: "priceData.price", to: "price")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0]["price"] as? Double, 9.99)
        XCTAssertNotNil(result[0]["priceData"]) // parent key preserved for other renames
    }

    func testRenameNonexistentFieldDoesNothing() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "rename", from: "missing", to: "found")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0].keys.sorted(), ["id", "name"])
        XCTAssertNil(result[0]["found"])
    }

    // MARK: - Flatten

    func testFlattenExtractsFieldFromNestedArray() {
        let data: [[String: Any]] = [
            [
                "id": 1,
                "media": [
                    "items": [
                        ["url": "http://img1.jpg", "type": "image"],
                        ["url": "http://img2.jpg", "type": "image"]
                    ]
                ] as [String: Any]
            ]
        ]
        let op = TransformOp(op: "flatten", to: "images", path: "media.items", select: "url")
        let result = TransformPipeline.apply([op], to: data)

        let images = result[0]["images"] as? [Any]
        XCTAssertNotNil(images)
        XCTAssertEqual(images?.count, 2)
        XCTAssertEqual(images?[0] as? String, "http://img1.jpg")
        XCTAssertEqual(images?[1] as? String, "http://img2.jpg")
        XCTAssertNil(result[0]["media"]) // source removed
    }

    func testFlattenWithoutSelectKeepsFullObjects() {
        let data: [[String: Any]] = [
            [
                "id": 1,
                "tags": [
                    ["name": "swift", "count": 5],
                    ["name": "ios", "count": 3]
                ]
            ]
        ]
        let op = TransformOp(op: "flatten", to: "allTags", path: "tags")
        let result = TransformPipeline.apply([op], to: data)

        let allTags = result[0]["allTags"] as? [[String: Any]]
        XCTAssertNotNil(allTags)
        XCTAssertEqual(allTags?.count, 2)
    }

    func testFlattenMissingPathReturnsRecordUnchanged() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "flatten", to: "images", path: "media.items", select: "url")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0]["id"] as? Int, 1)
        XCTAssertEqual(result[0]["name"] as? String, "Widget")
    }

    // MARK: - KeyBy

    func testKeyByConvertsArrayToDict() {
        let data: [[String: Any]] = [
            [
                "id": "item1",
                "column_values": [
                    ["id": "status", "text": "Done"],
                    ["id": "priority", "text": "High"],
                    ["id": "date", "text": "2024-01-15"]
                ]
            ]
        ]
        let op = TransformOp(op: "keyBy", to: "columns", path: "column_values", key: "id", value: "text")
        let result = TransformPipeline.apply([op], to: data)

        let columns = result[0]["columns"] as? [String: Any]
        XCTAssertNotNil(columns)
        XCTAssertEqual(columns?["status"] as? String, "Done")
        XCTAssertEqual(columns?["priority"] as? String, "High")
        XCTAssertEqual(columns?["date"] as? String, "2024-01-15")
        XCTAssertNil(result[0]["column_values"]) // source removed
    }

    func testKeyByMissingPathReturnsRecordUnchanged() {
        let data: [[String: Any]] = [
            ["id": 1]
        ]
        let op = TransformOp(op: "keyBy", to: "columns", path: "missing_path", key: "id", value: "text")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0]["id"] as? Int, 1)
        XCTAssertNil(result[0]["columns"])
    }

    // MARK: - Chaining Multiple Transforms

    func testChainingMultipleTransforms() {
        let data: [[String: Any]] = [
            [
                "id": 1,
                "old_name": "Widget Pro",
                "_internal": "secret",
                "priceData": ["price": 29.99, "currency": "USD"] as [String: Any],
                "media": [
                    "items": [
                        ["url": "http://img.jpg", "type": "image"]
                    ]
                ] as [String: Any]
            ]
        ]

        let transforms: [TransformOp] = [
            TransformOp(op: "omit", fields: ["_internal"]),
            TransformOp(op: "rename", from: "old_name", to: "name"),
            TransformOp(op: "rename", from: "priceData.price", to: "price"),
            TransformOp(op: "flatten", to: "images", path: "media.items", select: "url")
        ]

        let result = TransformPipeline.apply(transforms, to: data)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["id"] as? Int, 1)
        XCTAssertEqual(result[0]["name"] as? String, "Widget Pro")
        XCTAssertEqual(result[0]["price"] as? Double, 29.99)
        XCTAssertNil(result[0]["_internal"])
        XCTAssertNil(result[0]["old_name"])
        XCTAssertNotNil(result[0]["priceData"]) // parent key preserved
        XCTAssertNil(result[0]["media"]) // flatten removes source

        let images = result[0]["images"] as? [Any]
        XCTAssertEqual(images?.count, 1)
        XCTAssertEqual(images?[0] as? String, "http://img.jpg")
    }

    func testApplyEmptyTransformsReturnsDataUnchanged() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let result = TransformPipeline.apply([], to: data)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["id"] as? Int, 1)
        XCTAssertEqual(result[0]["name"] as? String, "Widget")
    }

    func testUnknownOpIsIgnored() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget"]
        ]
        let op = TransformOp(op: "unknown_op", fields: ["id"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result[0]["id"] as? Int, 1)
        XCTAssertEqual(result[0]["name"] as? String, "Widget")
    }

    func testMatchKeepsOnlyMatchingRecords() {
        let data: [[String: Any]] = [
            ["id": 1, "mediaType": "IMAGE"],
            ["id": 2, "mediaType": "VIDEO"],
            ["id": 3, "mediaType": "IMAGE"]
        ]
        let op = TransformOp(op: "match", value: "IMAGE", field: "mediaType")
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.compactMap { $0["id"] as? Int }, [1, 3])
    }

    func testSetSupportsDotPathWritesNestedValues() {
        let data: [[String: Any]] = [
            ["id": 1, "ownerId": "abc-123"]
        ]
        let transforms: [TransformOp] = [
            TransformOp(op: "set", value: "{ownerId}", field: "createdBy.id"),
            TransformOp(op: "set", value: "MEMBER", field: "createdBy.identityType")
        ]
        let result = TransformPipeline.apply(transforms, to: data)

        let createdBy: [String: Any]? = result[0]["createdBy"] as? [String: Any]
        XCTAssertEqual(createdBy?["id"] as? String, "abc-123")
        XCTAssertEqual(createdBy?["identityType"] as? String, "MEMBER")
    }

    func testMultipleRecords() {
        let data: [[String: Any]] = [
            ["id": 1, "name": "Widget", "secret": "x"],
            ["id": 2, "name": "Gadget", "secret": "y"],
            ["id": 3, "name": "Doohickey", "secret": "z"]
        ]
        let op = TransformOp(op: "pick", fields: ["id", "name"])
        let result = TransformPipeline.apply([op], to: data)

        XCTAssertEqual(result.count, 3)
        for record in result {
            XCTAssertEqual(record.keys.sorted(), ["id", "name"])
            XCTAssertNil(record["secret"])
        }
    }
}

// MARK: - TemplateEngine Tests

final class TemplateEngineTests: XCTestCase {

    func testSimpleFieldSubstitution() {
        let template = "Hello, {name}!"
        let data: [String: Any] = ["name": "World"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Hello, World!")
    }

    func testMultipleFieldSubstitutions() {
        let template = "{greeting}, {name}! You have {count} items."
        let data: [String: Any] = ["greeting": "Hi", "name": "Alice", "count": 5]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Hi, Alice! You have 5 items.")
    }

    func testMissingFieldRendersEmpty() {
        let template = "Hello, {name}!"
        let data: [String: Any] = [:]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Hello, !")
    }

    func testNoPlaceholders() {
        let template = "Just plain text."
        let data: [String: Any] = ["name": "World"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Just plain text.")
    }

    func testSlugifyFilter() {
        let template = "{name|slugify}"
        let data: [String: Any] = ["name": "Hello World & Friends!"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "hello-world-friends")
    }

    func testSlugifyWithSpecialChars() {
        let template = "{title|slugify}"
        let data: [String: Any] = ["title": "My Blog Post: A New Beginning"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "my-blog-post-a-new-beginning")
    }

    func testLowerFilter() {
        let template = "{name|lower}"
        let data: [String: Any] = ["name": "HELLO"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "hello")
    }

    func testUpperFilter() {
        let template = "{name|upper}"
        let data: [String: Any] = ["name": "hello"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "HELLO")
    }

    func testDefaultFilterWithMissingField() {
        let template = "{status|default:unknown}"
        let data: [String: Any] = [:]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "unknown")
    }

    func testDefaultFilterWithPresentField() {
        let template = "{status|default:unknown}"
        let data: [String: Any] = ["status": "active"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "active")
    }

    func testDotPathInTemplate() {
        let template = "{user.name} ({user.email})"
        let data: [String: Any] = [
            "user": ["name": "Alice", "email": "alice@example.com"] as [String: Any]
        ]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Alice (alice@example.com)")
    }

    func testNumericValues() {
        let template = "Price: ${price}"
        let data: [String: Any] = ["price": 29.99]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Price: $29.99")
    }

    func testIntegerValues() {
        let template = "Count: {count}"
        let data: [String: Any] = ["count": 42]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Count: 42")
    }

    func testBoolValues() {
        let template = "Active: {active}"
        let data: [String: Any] = ["active": true]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "Active: true")
    }

    func testFileNameTemplate() {
        let template = "{id}-{name|slugify}.md"
        let data: [String: Any] = ["id": 42, "name": "My Great Post"]
        let result = TemplateEngine.render(template, with: data)
        XCTAssertEqual(result, "42-my-great-post.md")
    }
}

// MARK: - JSONPath Tests

final class JSONPathTests: XCTestCase {

    func testSimpleDictAccess() {
        let data: [String: Any] = ["name": "Alice", "age": 30]
        let result = JSONPath.extract("$.name", from: data)
        XCTAssertEqual(result as? String, "Alice")
    }

    func testNestedDictAccess() {
        let data: [String: Any] = [
            "data": [
                "boards": [
                    ["id": 1, "name": "Board 1"],
                    ["id": 2, "name": "Board 2"]
                ]
            ] as [String: Any]
        ]
        let result = JSONPath.extract("$.data.boards", from: data)
        let boards = result as? [[String: Any]]
        XCTAssertNotNil(boards)
        XCTAssertEqual(boards?.count, 2)
    }

    func testArrayIndexAccess() {
        let data: [String: Any] = [
            "items": [
                ["name": "First"],
                ["name": "Second"],
                ["name": "Third"]
            ]
        ]
        let result = JSONPath.extract("$.items[0].name", from: data)
        XCTAssertEqual(result as? String, "First")
    }

    func testArrayIndexAccessLastElement() {
        let data: [String: Any] = [
            "items": [
                ["name": "First"],
                ["name": "Second"],
                ["name": "Third"]
            ]
        ]
        let result = JSONPath.extract("$.items[2].name", from: data)
        XCTAssertEqual(result as? String, "Third")
    }

    func testWildcardAccess() {
        let data: [String: Any] = [
            "data": [
                "boards": [
                    ["id": 1, "name": "Board 1"],
                    ["id": 2, "name": "Board 2"]
                ]
            ] as [String: Any]
        ]
        let result = JSONPath.extract("$.data.boards[*]", from: data)
        let boards = result as? [[String: Any]]
        XCTAssertNotNil(boards)
        XCTAssertEqual(boards?.count, 2)
    }

    func testWildcardWithFieldAccess() {
        let data: [String: Any] = [
            "users": [
                ["name": "Alice"],
                ["name": "Bob"],
                ["name": "Charlie"]
            ]
        ]
        let result = JSONPath.extract("$.users[*].name", from: data)
        let names = result as? [String]
        XCTAssertNotNil(names)
        XCTAssertEqual(names, ["Alice", "Bob", "Charlie"])
    }

    func testMissingPathReturnsNil() {
        let data: [String: Any] = ["name": "Alice"]
        let result = JSONPath.extract("$.missing.path", from: data)
        XCTAssertNil(result)
    }

    func testOutOfBoundsIndexReturnsNil() {
        let data: [String: Any] = [
            "items": [["name": "Only"]]
        ]
        let result = JSONPath.extract("$.items[5].name", from: data)
        XCTAssertNil(result)
    }

    func testRootDollarOnly() {
        let data: [String: Any] = ["key": "value"]
        let result = JSONPath.extract("$", from: data)
        let dict = result as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["key"] as? String, "value")
    }

    func testDeeplyNestedPath() {
        let data: [String: Any] = [
            "level1": [
                "level2": [
                    "level3": [
                        "value": "deep"
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any]
        ]
        let result = JSONPath.extract("$.level1.level2.level3.value", from: data)
        XCTAssertEqual(result as? String, "deep")
    }

    func testArrayAtRoot() {
        let data: [Any] = [
            ["name": "First"],
            ["name": "Second"]
        ]
        let result = JSONPath.extract("$[0].name", from: data)
        XCTAssertEqual(result as? String, "First")
    }

    func testPathWithoutDollarPrefix() {
        let data: [String: Any] = ["name": "Alice"]
        let result = JSONPath.extract("name", from: data)
        XCTAssertEqual(result as? String, "Alice")
    }
}
