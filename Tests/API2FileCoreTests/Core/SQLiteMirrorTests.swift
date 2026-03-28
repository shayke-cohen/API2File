import XCTest
@testable import API2FileCore

final class SQLiteMirrorTests: XCTestCase {
    private var tempDir: URL!
    private var serviceDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteMirrorTests-\(UUID().uuidString)")
        serviceDir = tempDir.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent(".api2file"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        serviceDir = nil
        try super.tearDownWithError()
    }

    func testRefreshCreatesQueryableTablesWithMetadata() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()

        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        let list = try parseObject(SQLiteMirror.listTablesJSON(in: serviceDir))
        let tables = list["tables"] as? [[String: Any]]
        XCTAssertEqual(tables?.count, 2)
        XCTAssertEqual(Set(tables?.compactMap { $0["table_name"] as? String } ?? []), ["tasks", "blog_posts"])

        let describe = try parseObject(SQLiteMirror.describeTableJSON("blog_posts", in: serviceDir))
        XCTAssertEqual(describe["resourceName"] as? String, "blog-posts")
        XCTAssertEqual(describe["rowCount"] as? Int, 1)
        let columns = describe["columns"] as? [[String: Any]]
        let columnNames = Set(columns?.compactMap { $0["name"] as? String } ?? [])
        XCTAssertTrue(columnNames.contains("_json_payload"))
        XCTAssertTrue(columnNames.contains("_projection_path"))
        XCTAssertTrue(columnNames.contains("slug"))
        XCTAssertTrue(columnNames.contains("published"))

        let indexNames = Set(try SQLiteMirror.indexNamesForTesting(table: "tasks", in: serviceDir))
        XCTAssertTrue(indexNames.contains("idx_tasks_remote_id"))
        XCTAssertTrue(indexNames.contains("idx_tasks_projection_path"))
        XCTAssertTrue(indexNames.contains("idx_tasks_object_path"))
    }

    func testQueryReturnsRowsAndSearchFindsPayloadMatches() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()
        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        let queryResult = try parseObject(
            SQLiteMirror.queryJSON(
                "SELECT _remote_id, title, points, active FROM tasks ORDER BY points DESC",
                in: serviceDir
            )
        )
        XCTAssertEqual(queryResult["rowCount"] as? Int, 2)
        let rows = queryResult["rows"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["_remote_id"] as? String, "2")
        XCTAssertEqual(rows?.first?["title"] as? String, "Beta")
        XCTAssertEqual(rows?.first?["points"] as? Int, 8)
        XCTAssertEqual(rows?.first?["active"] as? Int, 0)

        let searchResult = try parseObject(SQLiteMirror.searchJSON(text: "Launch", resources: ["blog-posts"], in: serviceDir))
        XCTAssertEqual(searchResult["rowCount"] as? Int, 1)
        let searchRows = searchResult["rows"] as? [[String: Any]]
        XCTAssertEqual(searchRows?.first?["_table_name"] as? String, "blog_posts")
        XCTAssertEqual(searchRows?.first?["title"] as? String, "Launch Notes")
    }

    func testQueryRejectsMutatingSQL() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()
        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        XCTAssertThrowsError(try SQLiteMirror.queryJSON("UPDATE tasks SET title = 'nope'", in: serviceDir)) { error in
            guard let mirrorError = error as? SQLiteMirror.MirrorError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .invalidQuery(let message) = mirrorError else {
                return XCTFail("Expected invalidQuery, got \(mirrorError)")
            }
            XCTAssertTrue(message.contains("read-only") || message.contains("SELECT-style"))
        }
    }

    func testGetRecordAndOpenRecordFileReturnPathsAndContent() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()
        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        let recordResult = try parseObject(
            SQLiteMirror.getRecordJSON(resource: "blog-posts", recordId: "post_1", in: serviceDir)
        )
        XCTAssertEqual(recordResult["resourceName"] as? String, "blog-posts")
        XCTAssertEqual(recordResult["table"] as? String, "blog_posts")
        XCTAssertEqual(recordResult["recordId"] as? String, "post_1")
        XCTAssertEqual(recordResult["canonicalPath"] as? String, "blog/.objects/launch.json")
        XCTAssertEqual(recordResult["projectionPath"] as? String, "blog/launch.md")
        let record = recordResult["record"] as? [String: Any]
        XCTAssertEqual(record?["title"] as? String, "Launch Notes")

        let canonicalResult = try parseObject(
            SQLiteMirror.openRecordFileJSON(
                resource: "blog-posts",
                recordId: "post_1",
                surface: .canonical,
                in: serviceDir
            )
        )
        XCTAssertEqual(canonicalResult["surface"] as? String, "canonical")
        XCTAssertEqual(canonicalResult["relativePath"] as? String, "blog/.objects/launch.json")
        XCTAssertEqual(canonicalResult["contentEncoding"] as? String, "utf8")
        XCTAssertTrue((canonicalResult["content"] as? String)?.contains("Launch Notes") == true)

        let projectionResult = try parseObject(
            SQLiteMirror.openRecordFileJSON(
                resource: "blog-posts",
                recordId: "post_1",
                surface: .projection,
                in: serviceDir
            )
        )
        XCTAssertEqual(projectionResult["surface"] as? String, "projection")
        XCTAssertEqual(projectionResult["relativePath"] as? String, "blog/launch.md")
        XCTAssertEqual(projectionResult["contentEncoding"] as? String, "utf8")
        XCTAssertTrue((projectionResult["content"] as? String)?.contains("# Launch Notes") == true)
    }

    func testGetRecordFailsForUnknownResourceAndMissingRecord() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()
        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        XCTAssertThrowsError(
            try SQLiteMirror.getRecordJSON(resource: "missing-resource", recordId: "post_1", in: serviceDir)
        ) { error in
            guard let mirrorError = error as? SQLiteMirror.MirrorError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .invalidQuery(let message) = mirrorError else {
                return XCTFail("Expected invalidQuery, got \(mirrorError)")
            }
            XCTAssertTrue(message.contains("Unknown table"))
        }

        XCTAssertThrowsError(
            try SQLiteMirror.getRecordJSON(resource: "blog-posts", recordId: "missing", in: serviceDir)
        ) { error in
            guard let mirrorError = error as? SQLiteMirror.MirrorError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .notFound(let message) = mirrorError else {
                return XCTFail("Expected notFound, got \(mirrorError)")
            }
            XCTAssertTrue(message.contains("No record with id 'missing'"))
        }
    }

    func testOpenRecordFileFailsWhenProjectionFileIsMissing() throws {
        let config = makeConfig()
        let state = try seedCanonicalFiles()
        try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)

        try FileManager.default.removeItem(at: serviceDir.appendingPathComponent("blog/launch.md"))

        XCTAssertThrowsError(
            try SQLiteMirror.openRecordFileJSON(
                resource: "blog-posts",
                recordId: "post_1",
                surface: .projection,
                in: serviceDir
            )
        ) { error in
            guard let mirrorError = error as? SQLiteMirror.MirrorError else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .notFound(let message) = mirrorError else {
                return XCTFail("Expected notFound, got \(mirrorError)")
            }
            XCTAssertTrue(message.contains("blog/launch.md"))
        }
    }

    private func makeConfig() -> AdapterConfig {
        AdapterConfig(
            service: "demo",
            displayName: "Demo",
            version: "1.0",
            auth: AuthConfig(type: .bearer, keychainKey: "api2file.demo.sqlite-test"),
            resources: [
                ResourceConfig(
                    name: "tasks",
                    fileMapping: FileMappingConfig(
                        strategy: .collection,
                        directory: ".",
                        filename: "tasks.csv",
                        format: .csv,
                        idField: "id"
                    )
                ),
                ResourceConfig(
                    name: "blog-posts",
                    fileMapping: FileMappingConfig(
                        strategy: .onePerRecord,
                        directory: "blog",
                        filename: "{slug}.md",
                        format: .markdown,
                        idField: "id"
                    )
                )
            ]
        )
    }

    private func seedCanonicalFiles() throws -> SyncState {
        let tasksObjectURL = serviceDir.appendingPathComponent(".tasks.objects.json")
        try ObjectFileManager.writeCollectionObjectFile(records: [
            ["id": 1, "title": "Alpha", "points": 3, "active": true, "details": ["owner": "maya"]],
            ["id": 2, "title": "Beta", "points": 8, "active": false]
        ], to: tasksObjectURL)

        let blogObjectURL = serviceDir.appendingPathComponent("blog/.objects/launch.json")
        try ObjectFileManager.writeRecordObjectFile(
            record: [
                "id": "post_1",
                "slug": "launch",
                "title": "Launch Notes",
                "published": true,
                "body": "SQLite mirror ready"
            ],
            to: blogObjectURL
        )

        try "id,title,points,active\n1,Alpha,3,true\n2,Beta,8,false\n".write(
            to: serviceDir.appendingPathComponent("tasks.csv"),
            atomically: true,
            encoding: .utf8
        )
        try "# Launch Notes\n\nSQLite mirror ready\n".write(
            to: serviceDir.appendingPathComponent("blog/launch.md"),
            atomically: true,
            encoding: .utf8
        )

        try FileLinkManager.save(
            FileLinkIndex(links: [
                FileLinkEntry(
                    resourceName: "tasks",
                    mappingStrategy: .collection,
                    remoteId: "collection",
                    userPath: "tasks.csv",
                    canonicalPath: ".tasks.objects.json"
                ),
                FileLinkEntry(
                    resourceName: "blog-posts",
                    mappingStrategy: .onePerRecord,
                    remoteId: "post_1",
                    userPath: "blog/launch.md",
                    canonicalPath: "blog/.objects/launch.json"
                )
            ]),
            to: serviceDir
        )

        return SyncState(
            files: [
                "tasks.csv": FileSyncState(
                    remoteId: "collection",
                    lastSyncedHash: "tasks-hash",
                    lastSyncTime: Date(timeIntervalSince1970: 1_710_000_000),
                    status: .synced
                ),
                "blog/launch.md": FileSyncState(
                    remoteId: "post_1",
                    lastSyncedHash: "blog-hash",
                    lastSyncTime: Date(timeIntervalSince1970: 1_710_000_100),
                    status: .synced
                )
            ]
        )
    }

    private func parseObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "SQLiteMirrorTests", code: 1)
        }
        return dictionary
    }
}
