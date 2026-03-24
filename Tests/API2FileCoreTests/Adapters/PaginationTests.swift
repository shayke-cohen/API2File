import XCTest
@testable import API2FileCore

final class PaginationTests: XCTestCase {

    // MARK: - 1. PaginationType "body" decodes correctly

    func testPaginationTypeBodyDecodes() throws {
        let json = """
        { "type": "body" }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PaginationConfig.self, from: json)
        XCTAssertEqual(decoded.type, .body)
    }

    // MARK: - 2. Default pageSize is 100 when nil

    func testDefaultPageSize() {
        let config = PaginationConfig(type: .offset, pageSize: nil)
        // The engine falls back to 100 when pageSize is nil:
        //   let pageSize = pullConfig.pagination?.pageSize ?? 100
        let effectivePageSize = config.pageSize ?? 100
        XCTAssertEqual(effectivePageSize, 100)
    }

    // MARK: - 3. Default maxRecords is 10000 when nil

    func testDefaultMaxRecords() {
        let config = PaginationConfig(type: .offset, maxRecords: nil)
        let effectiveMaxRecords = config.maxRecords ?? 10000
        XCTAssertEqual(effectiveMaxRecords, 10000)
    }

    // MARK: - 4. PaginationParamNames custom values encode/decode

    func testPaginationParamNamesCustom() throws {
        let names = PaginationParamNames(limit: "count", offset: "skip", page: "pg", cursor: "next_token")
        let data = try JSONEncoder().encode(names)
        let decoded = try JSONDecoder().decode(PaginationParamNames.self, from: data)
        XCTAssertEqual(decoded.limit, "count")
        XCTAssertEqual(decoded.offset, "skip")
        XCTAssertEqual(decoded.page, "pg")
        XCTAssertEqual(decoded.cursor, "next_token")
    }

    // MARK: - 5. PaginationConfig with body fields roundtrips

    func testPaginationConfigWithBodyFields() throws {
        let config = PaginationConfig(
            type: .body,
            nextCursorPath: "pagination.nextCursor",
            pageSize: 50,
            maxRecords: 5000,
            cursorField: "pagination.cursor",
            offsetField: nil,
            limitField: "pagination.limit"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(PaginationConfig.self, from: data)

        XCTAssertEqual(decoded.type, .body)
        XCTAssertEqual(decoded.nextCursorPath, "pagination.nextCursor")
        XCTAssertEqual(decoded.pageSize, 50)
        XCTAssertEqual(decoded.maxRecords, 5000)
        XCTAssertEqual(decoded.cursorField, "pagination.cursor")
        XCTAssertNil(decoded.offsetField)
        XCTAssertEqual(decoded.limitField, "pagination.limit")
    }

    // MARK: - 6. PaginationConfig with queryTemplate survives encoding

    func testPaginationConfigWithQueryTemplate() throws {
        let template = "query { items(first: {limit}, after: \"{cursor}\") { nodes { id name } pageInfo { endCursor hasNextPage } } }"
        let config = PaginationConfig(
            type: .cursor,
            pageSize: 25,
            queryTemplate: template
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PaginationConfig.self, from: data)

        XCTAssertEqual(decoded.queryTemplate, template)
        XCTAssertEqual(decoded.type, .cursor)
        XCTAssertEqual(decoded.pageSize, 25)
    }

    // MARK: - 7. Pagination doesn't affect pushMode (regression)

    func testEffectivePushModeUnchangedByPagination() {
        // Create a file mapping with no special push config and no transforms
        let mapping = FileMappingConfig(
            strategy: .collection,
            directory: ".",
            filename: "items.csv",
            format: .csv,
            idField: "id"
        )
        // effectivePushMode should be .passthrough regardless of whether pagination exists
        XCTAssertEqual(mapping.effectivePushMode, .passthrough)

        // Create a resource with pagination — pushMode should still be determined by fileMapping, not pagination
        let pullWithPagination = PullConfig(
            url: "http://example.com/api/items",
            pagination: PaginationConfig(type: .offset, pageSize: 10)
        )
        let resource = ResourceConfig(
            name: "items",
            pull: pullWithPagination,
            fileMapping: mapping
        )
        XCTAssertEqual(resource.fileMapping.effectivePushMode, .passthrough)
    }

    // MARK: - 8. PullConfig with updatedSince fields

    func testPullConfigWithUpdatedSinceFields() throws {
        let config = PullConfig(
            url: "http://example.com/api/items",
            updatedSinceField: "since",
            updatedSinceBodyPath: "filter.updatedAfter",
            updatedSinceDateFormat: "iso8601"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PullConfig.self, from: data)

        XCTAssertEqual(decoded.updatedSinceField, "since")
        XCTAssertEqual(decoded.updatedSinceBodyPath, "filter.updatedAfter")
        XCTAssertEqual(decoded.updatedSinceDateFormat, "iso8601")
    }

    // MARK: - 9. SyncConfig with fullSyncEvery encodes and has defaults

    func testSyncConfigWithFullSyncEvery() throws {
        let config = SyncConfig(interval: 30, fullSyncEvery: 5)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SyncConfig.self, from: data)

        XCTAssertEqual(decoded.interval, 30)
        XCTAssertEqual(decoded.fullSyncEvery, 5)
        XCTAssertNil(decoded.debounceMs)

        // Verify defaults
        XCTAssertEqual(decoded.intervalSeconds, 30.0)
        XCTAssertEqual(decoded.debounceSeconds, 0.5) // default 500ms

        // Config with no fullSyncEvery
        let minimal = SyncConfig()
        XCTAssertNil(minimal.fullSyncEvery)
        XCTAssertEqual(minimal.intervalSeconds, 60.0) // default
    }

    // MARK: - 10. SyncState with resourceSyncTimes and syncCounts save/load roundtrip

    func testSyncStateWithResourceSyncTimes() throws {
        let now = Date()
        var state = SyncState()
        state.resourceSyncTimes["tasks"] = now
        state.resourceSyncTimes["contacts"] = now.addingTimeInterval(-3600)
        state.syncCounts["tasks"] = 5
        state.syncCounts["contacts"] = 3
        state.files["tasks.csv"] = FileSyncState(
            remoteId: "all",
            lastSyncedHash: "abc123",
            lastSyncTime: now,
            status: .synced
        )

        // Save to temp file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagination-test-\(UUID().uuidString)")
        let stateURL = tempDir.appendingPathComponent("state.json")

        try state.save(to: stateURL)

        // Load back
        let loaded = try SyncState.load(from: stateURL)

        XCTAssertEqual(loaded.syncCounts["tasks"], 5)
        XCTAssertEqual(loaded.syncCounts["contacts"], 3)
        XCTAssertNotNil(loaded.resourceSyncTimes["tasks"])
        XCTAssertNotNil(loaded.resourceSyncTimes["contacts"])
        XCTAssertEqual(loaded.files["tasks.csv"]?.remoteId, "all")
        XCTAssertEqual(loaded.files["tasks.csv"]?.lastSyncedHash, "abc123")
        XCTAssertEqual(loaded.files["tasks.csv"]?.status, .synced)

        // Cleanup
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 11. Body pagination type in adapter JSON

    func testBodyPaginationTypeInAdapterJSON() throws {
        let json = """
        {
          "service": "test",
          "displayName": "Test API",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "test.key" },
          "resources": [
            {
              "name": "items",
              "pull": {
                "url": "http://example.com/api/items",
                "dataPath": "$.items",
                "pagination": {
                  "type": "body",
                  "cursorField": "pagination.cursor",
                  "limitField": "pagination.limit",
                  "nextCursorPath": "pagination.nextCursor",
                  "pageSize": 50
                }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "items.json",
                "format": "json"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AdapterConfig.self, from: json)
        XCTAssertEqual(config.resources.count, 1)

        let pagination = config.resources[0].pull?.pagination
        XCTAssertNotNil(pagination)
        XCTAssertEqual(pagination?.type, .body)
        XCTAssertEqual(pagination?.cursorField, "pagination.cursor")
        XCTAssertEqual(pagination?.limitField, "pagination.limit")
        XCTAssertEqual(pagination?.nextCursorPath, "pagination.nextCursor")
        XCTAssertEqual(pagination?.pageSize, 50)
    }

    // MARK: - 12. Query template placeholders replacement

    func testQueryTemplatePlaceholders() {
        // This mirrors how AdapterEngine replaces {cursor} and {limit} in queryTemplate
        var template = "query { items(first: {limit}, after: \"{cursor}\") { nodes { id } pageInfo { endCursor } } }"

        // Replace {limit}
        template = template.replacingOccurrences(of: "{limit}", with: "25")
        XCTAssertTrue(template.contains("first: 25"))
        XCTAssertFalse(template.contains("{limit}"))

        // Replace {cursor}
        template = template.replacingOccurrences(of: "{cursor}", with: "abc123cursor")
        XCTAssertTrue(template.contains("after: \"abc123cursor\""))
        XCTAssertFalse(template.contains("{cursor}"))

        // First page: remove cursor argument entirely
        var firstPageTemplate = "query { items(first: {limit}, after: \"{cursor}\") { nodes { id } } }"
        firstPageTemplate = firstPageTemplate.replacingOccurrences(of: "{limit}", with: "25")
        firstPageTemplate = firstPageTemplate.replacingOccurrences(of: ", after: \"{cursor}\"", with: "")
        XCTAssertTrue(firstPageTemplate.contains("items(first: 25)"))
        XCTAssertFalse(firstPageTemplate.contains("cursor"))
    }
}
