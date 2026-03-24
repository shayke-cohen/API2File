import XCTest
@testable import API2FileCore

/// E2E tests for pagination: real DemoAPIServer, real files on disk, real AdapterEngine pipeline.
/// Verifies that offset pagination correctly fetches all pages, respects maxRecords limits,
/// and works alongside non-paginated resources.
final class PaginationE2ETests: XCTestCase {

    private var server: DemoAPIServer!
    private var port: UInt16!
    private var baseURL: String { "http://localhost:\(port!)" }
    private var syncRoot: URL!
    private var serviceDir: URL!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        // Start real demo server on random port
        port = UInt16.random(in: 22000...28000)
        server = DemoAPIServer(port: port)
        try await server.start()

        // Wait for readiness
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 300_000_000)
            do {
                let (_, r) = try await URLSession.shared.data(from: URL(string: "\(baseURL)/api/tasks")!)
                if (r as? HTTPURLResponse)?.statusCode == 200 { break }
            } catch { continue }
        }
        await server.reset()

        // Create real sync folder structure (in temp dir)
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-pagination-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("demo")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Write adapter config with paginated tasks (pageSize=2) and non-paginated contacts
        let adapterConfig = """
        {
          "service": "demo",
          "displayName": "Demo API (Pagination)",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.pagination.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "description": "Task list with offset pagination",
              "pull": {
                "method": "GET",
                "url": "\(baseURL)/api/tasks",
                "dataPath": "$",
                "pagination": {
                  "type": "offset",
                  "pageSize": 2
                }
              },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/tasks" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/tasks/{id}" },
                "delete": { "method": "DELETE", "url": "\(baseURL)/api/tasks/{id}" }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id"
              }
            },
            {
              "name": "contacts",
              "description": "Contacts without pagination",
              "pull": {
                "method": "GET",
                "url": "\(baseURL)/api/contacts",
                "dataPath": "$"
              },
              "push": {
                "create": { "method": "POST", "url": "\(baseURL)/api/contacts" },
                "update": { "method": "PUT", "url": "\(baseURL)/api/contacts/{id}" }
              },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "contacts",
                "filename": "{firstName|slugify}-{lastName|slugify}.vcf",
                "format": "vcf",
                "idField": "id"
              }
            }
          ]
        }
        """
        try adapterConfig.write(to: api2fileDir.appendingPathComponent("adapter.json"), atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        await server?.stop()
        if let dir = syncRoot { try? FileManager.default.removeItem(at: dir) }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeEngine() throws -> (AdapterEngine, AdapterConfig) {
        let config = try AdapterEngine.loadConfig(from: serviceDir)
        let httpClient = HTTPClient()
        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        return (engine, config)
    }

    private func resource(_ name: String, from config: AdapterConfig) -> ResourceConfig {
        config.resources.first(where: { $0.name == name })!
    }

    private func writeFilesToDisk(_ files: [SyncableFile]) throws {
        for file in files {
            let path = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func readFileFromDisk(_ relativePath: String) throws -> Data {
        try Data(contentsOf: serviceDir.appendingPathComponent(relativePath))
    }

    private func fileExistsOnDisk(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(relativePath).path)
    }

    private func getFromAPI(_ path: String) async throws -> [[String: Any]] {
        let c = HTTPClient()
        let r = try await c.request(APIRequest(method: .GET, url: "\(baseURL)\(path)"))
        let json = try JSONSerialization.jsonObject(with: r.body)
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] { return [dict] }
        return []
    }

    private func postToAPI(_ path: String, _ data: [String: Any]) async throws {
        let c = HTTPClient()
        let body = try JSONSerialization.data(withJSONObject: data)
        _ = try await c.request(APIRequest(method: .POST, url: "\(baseURL)\(path)", headers: ["Content-Type": "application/json"], body: body))
    }

    /// Build an engine with a custom adapter config that overrides the one on disk.
    private func makeEngineWithConfig(_ adapterJSON: String) throws -> (AdapterEngine, AdapterConfig) {
        let data = adapterJSON.data(using: .utf8)!
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let httpClient = HTTPClient()
        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        return (engine, config)
    }

    // ======================================================================
    // MARK: - TEST 1: Paginated pull fetches all pages
    // ======================================================================

    func testPaginatedPullFetchesAllPages() async throws {
        let (engine, config) = try makeEngine()

        // DemoAPIServer seeds 3 tasks. With pageSize=2, the engine must make 2 requests:
        // - offset=0 returns 2 tasks
        // - offset=2 returns 1 task (less than pageSize, so pagination stops)
        let result = try await engine.pull(resource: resource("tasks", from: config))
        let files = result.files

        XCTAssertEqual(files.count, 1, "Collection mapping should produce 1 file")

        // Decode the CSV to verify all 3 tasks arrived
        let csvData = files[0].content
        let records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3, "All 3 seed tasks should be fetched across 2 pages")

        // Verify specific task names from seed data
        let names = records.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("Buy groceries"))
        XCTAssertTrue(names.contains("Fix login bug"))
        XCTAssertTrue(names.contains("Write docs"))
    }

    // ======================================================================
    // MARK: - TEST 2: Paginated pull writes correct files to disk
    // ======================================================================

    func testPaginatedPullWritesCorrectFiles() async throws {
        let (engine, config) = try makeEngine()

        let result = try await engine.pull(resource: resource("tasks", from: config))
        try writeFilesToDisk(result.files)

        // Verify file exists on disk
        XCTAssertTrue(fileExistsOnDisk("tasks.csv"), "tasks.csv should be written to disk")

        // Read back and verify all 3 rows
        let csvData = try readFileFromDisk("tasks.csv")
        let csvString = String(data: csvData, encoding: .utf8)!
        XCTAssertTrue(csvString.contains("Buy groceries"))
        XCTAssertTrue(csvString.contains("Fix login bug"))
        XCTAssertTrue(csvString.contains("Write docs"))

        let records = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(records.count, 3, "CSV file should have all 3 task rows")
    }

    // ======================================================================
    // MARK: - TEST 3: maxRecords limit stops pagination early
    // ======================================================================

    func testMaxRecordsLimitStopsPagination() async throws {
        // Create a custom config with maxRecords=2 and pageSize=1
        // This means the engine will fetch page by page (1 record each)
        // and stop after 2 records total, even though 3 exist.
        let adapterJSON = """
        {
          "service": "demo",
          "displayName": "Demo API (MaxRecords)",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.pagination.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "pull": {
                "method": "GET",
                "url": "\(baseURL)/api/tasks",
                "dataPath": "$",
                "pagination": {
                  "type": "offset",
                  "pageSize": 1,
                  "maxRecords": 2
                }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id"
              }
            }
          ]
        }
        """

        let (engine, config) = try makeEngineWithConfig(adapterJSON)
        let result = try await engine.pull(resource: resource("tasks", from: config))
        let files = result.files

        XCTAssertEqual(files.count, 1)

        let records = try CSVFormat.decode(data: files[0].content, options: nil)
        XCTAssertEqual(records.count, 2, "maxRecords=2 should cap at 2 records even though 3 exist on server")
    }

    // ======================================================================
    // MARK: - TEST 4: Non-paginated resource still works
    // ======================================================================

    func testNonPaginatedResourceStillWorks() async throws {
        let (engine, config) = try makeEngine()

        // Contacts have no pagination config — should return all in one shot
        let result = try await engine.pull(resource: resource("contacts", from: config))
        let files = result.files

        // DemoAPIServer seeds 2 contacts (one-per-record strategy → 2 VCF files)
        XCTAssertEqual(files.count, 2, "Should have 2 VCF contact files without pagination")

        for file in files {
            let content = String(data: file.content, encoding: .utf8)!
            XCTAssertTrue(content.contains("BEGIN:VCARD"), "Each file should be valid VCF")
            XCTAssertTrue(content.contains("END:VCARD"))
        }
    }

    // ======================================================================
    // MARK: - TEST 5: Paginated pull populates rawRecordsByFile
    // ======================================================================

    func testPaginatedPullWithRawRecords() async throws {
        let (engine, config) = try makeEngine()

        let result = try await engine.pull(resource: resource("tasks", from: config))

        // rawRecordsByFile should have an entry for tasks.csv with all 3 raw records
        XCTAssertFalse(result.rawRecordsByFile.isEmpty, "rawRecordsByFile should not be empty")

        let tasksRaw = result.rawRecordsByFile["tasks.csv"]
        XCTAssertNotNil(tasksRaw, "Should have raw records keyed by tasks.csv")
        XCTAssertEqual(tasksRaw?.count, 3, "All 3 raw records should be present across paginated pages")

        // Verify raw records contain expected fields
        let ids = tasksRaw?.compactMap { $0["id"] }
        XCTAssertEqual(ids?.count, 3, "Each raw record should have an id")
    }

    // ======================================================================
    // MARK: - TEST 6: Pagination with small dataset (count < pageSize)
    // ======================================================================

    func testPaginationWithSmallDataset() async throws {
        let (_, _) = try makeEngine()

        // Add 1 more task via API — now 4 total (3 seed + 1 new)
        try await postToAPI("/api/tasks", [
            "name": "New task via API",
            "status": "todo",
            "priority": "low",
            "assignee": "Test",
            "dueDate": "2026-12-31"
        ])

        // Create a config with pageSize=10 — all 4 tasks fit in one page
        let adapterJSON = """
        {
          "service": "demo",
          "displayName": "Demo API (Large Page)",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "api2file.demo.pagination.test" },
          "globals": { "baseUrl": "\(baseURL)" },
          "resources": [
            {
              "name": "tasks",
              "pull": {
                "method": "GET",
                "url": "\(baseURL)/api/tasks",
                "dataPath": "$",
                "pagination": {
                  "type": "offset",
                  "pageSize": 10
                }
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "tasks.csv",
                "format": "csv",
                "idField": "id"
              }
            }
          ]
        }
        """

        let (bigPageEngine, bigPageConfig) = try makeEngineWithConfig(adapterJSON)
        let result = try await bigPageEngine.pull(resource: resource("tasks", from: bigPageConfig))
        let files = result.files

        XCTAssertEqual(files.count, 1)

        let records = try CSVFormat.decode(data: files[0].content, options: nil)
        XCTAssertEqual(records.count, 4, "Should get all 4 tasks (3 seed + 1 new) in a single page")

        let names = records.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("New task via API"), "New task should be included")
        XCTAssertTrue(names.contains("Buy groceries"), "Seed tasks should still be present")
    }
}
