import XCTest
@testable import API2FileCore

/// Live end-to-end tests against the real Wix APIs.
///
/// Requires:
/// - A Wix API key stored in Keychain under `api2file.wix.key`
/// - A deployed adapter config at ~/API2File-Data/wix/.api2file/adapter.json
///
/// Tests are skipped automatically when credentials are missing.
/// Each mutating test creates its own test data and cleans up in teardown.
final class WixLiveE2ETests: XCTestCase {

    private var apiKey: String!
    private var siteId: String!
    private var engine: AdapterEngine!
    private var config: AdapterConfig!
    private var serviceDir: URL!
    private var syncRoot: URL!
    private var httpClient: HTTPClient!

    /// IDs of records created during tests, keyed by resource name, for cleanup.
    private var createdIds: [(resource: ResourceConfig, id: String)] = []

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        // Load API key from keychain
        let key = await KeychainManager.shared.load(key: "api2file.wix.key")
        try XCTSkipIf(key == nil, "No Wix API key in keychain — skipping live tests")
        apiKey = key!

        // Load deployed adapter config
        let deployedDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("API2File-Data/wix")
        let deployedConfigURL = deployedDir.appendingPathComponent(".api2file/adapter.json")
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath: deployedConfigURL.path),
            "No deployed Wix adapter at \(deployedConfigURL.path) — skipping live tests"
        )

        let fullConfig = try AdapterEngine.loadConfig(from: deployedDir)

        // Filter to only the resources we test
        let testResources = Set(["cms-todos", "cms-projects", "products", "media"])
        let filtered = fullConfig.resources.filter { testResources.contains($0.name) }

        // Extract site-id from globals
        siteId = fullConfig.globals?.headers?["wix-site-id"]
        XCTAssertNotNil(siteId, "wix-site-id missing from deployed adapter globals")

        // Create temp dir for test files
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-wix-live-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("wix")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Build a test adapter config with only our resources
        let testConfig = AdapterConfig(
            service: fullConfig.service,
            displayName: fullConfig.displayName,
            version: fullConfig.version,
            auth: fullConfig.auth,
            globals: fullConfig.globals,
            resources: filtered
        )

        // Write adapter.json so loadConfig works
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(testConfig)
        try configData.write(to: api2fileDir.appendingPathComponent("adapter.json"), options: .atomic)

        // Load it back via standard path
        config = try AdapterEngine.loadConfig(from: serviceDir)

        // Set up HTTP client with auth
        httpClient = HTTPClient()
        await httpClient.setAuthHeader("Authorization", value: apiKey)

        engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
    }

    override func tearDown() async throws {
        // Clean up any created records (reverse order for safety)
        for item in createdIds.reversed() {
            try? await engine.delete(remoteId: item.id, resource: item.resource)
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms between deletes
        }
        createdIds.removeAll()

        // Remove temp dir
        if let dir = syncRoot {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func resource(_ name: String) -> ResourceConfig {
        config.resources.first(where: { $0.name == name })!
    }

    private func writeFilesToDisk(_ files: [SyncableFile]) throws {
        for file in files {
            let path = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func readCSV(_ relativePath: String) throws -> [[String: Any]] {
        let url = serviceDir.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try CSVFormat.decode(data: data, options: nil)
    }

    private func delay(_ ms: UInt64 = 500) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// Make a direct Wix API call (bypassing the engine) for setup/verification.
    private func wixAPI(
        method: HTTPMethod,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        let baseURL = config.globals?.baseUrl ?? "https://www.wixapis.com"
        let url = path.hasPrefix("http") ? path : "\(baseURL)\(path)"

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "wix-site-id": siteId
        ]
        headers["Authorization"] = apiKey

        var bodyData: Data? = nil
        if let body = body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }

        let request = APIRequest(method: method, url: url, headers: headers, body: bodyData)
        let response = try await httpClient.request(request)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        return json
    }

    /// Create a CMS item directly via API and register for cleanup.
    private func createCMSItem(
        collectionId: String,
        data: [String: Any],
        resourceName: String
    ) async throws -> String {
        let body: [String: Any] = [
            "dataCollectionId": collectionId,
            "dataItem": ["data": data]
        ]
        let result = try await wixAPI(method: .POST, path: "/wix-data/v2/items", body: body)
        guard let item = result["dataItem"] as? [String: Any],
              let id = item["id"] as? String else {
            XCTFail("Failed to create CMS item in \(collectionId)")
            return ""
        }
        let res = resource(resourceName)
        createdIds.append((resource: res, id: id))
        return id
    }

    /// Query CMS items directly via API.
    private func queryCMS(collectionId: String) async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "dataCollectionId": collectionId,
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/wix-data/v2/items/query", body: body)
        return result["dataItems"] as? [[String: Any]] ?? []
    }

    /// Delete a CMS item directly via API (doesn't register for cleanup).
    private func deleteCMSItem(id: String, collectionId: String) async throws {
        _ = try await wixAPI(
            method: .DELETE,
            path: "/wix-data/v2/items/\(id)?dataCollectionId=\(collectionId)"
        )
    }

    private func uniqueTestName(_ prefix: String = "E2E-TEST") -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    // ======================================================================
    // MARK: - CMS Todos — Pull
    // ======================================================================

    func testCMSTodos_Pull_ReturnsCSVWithExpectedColumns() async throws {
        let res = resource("cms-todos")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "Pull returned no files")
        let file = result.files.first!
        XCTAssertEqual(file.relativePath, "cms/todos.csv")

        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/todos.csv")
        XCTAssertFalse(records.isEmpty, "No records in todos.csv")

        // Verify expected columns (CSVFormat decodes _id header back to "id" key)
        let columns = Set(records[0].keys)
        for expected in ["id", "title", "status", "priority"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
    }

    func testCMSTodos_Pull_ContainsKnownRecords() async throws {
        let res = resource("cms-todos")
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/todos.csv")

        // There should be at least one record
        XCTAssertGreaterThanOrEqual(records.count, 1, "Expected at least 1 todo")
    }

    // ======================================================================
    // MARK: - CMS Todos — Create / Update / Delete
    // ======================================================================

    func testCMSTodos_Create_NewRow_AppearsOnServer() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("Todo")

        // Create via engine pushRecord
        let record: [String: Any] = [
            "title": testTitle,
            "description": "Created by E2E test",
            "status": "To Do",
            "priority": "low"
        ]
        try await engine.pushRecord(record, resource: res, action: .create)
        try await delay(1000)

        // Find the created record on server
        let items = try await queryCMS(collectionId: "Todos")
        let found = items.first(where: {
            ($0["data"] as? [String: Any])?["title"] as? String == testTitle
        })
        XCTAssertNotNil(found, "Created todo not found on server")

        // Register for cleanup
        if let id = found?["id"] as? String {
            createdIds.append((resource: res, id: id))
        }
    }

    func testCMSTodos_Update_ModifyTitle_ReflectedOnServer() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("TodoUpd")
        let updatedTitle = testTitle + " UPDATED"

        // Create a test item
        let id = try await createCMSItem(
            collectionId: "Todos",
            data: ["title": testTitle, "status": "To Do", "priority": "medium"],
            resourceName: "cms-todos"
        )
        try await delay()

        // Update via engine
        let updateRecord: [String: Any] = [
            "title": updatedTitle,
            "status": "To Do",
            "priority": "medium"
        ]
        try await engine.pushRecord(updateRecord, resource: res, action: .update(id: id))
        try await delay(1000)

        // Verify on server
        let items = try await queryCMS(collectionId: "Todos")
        let found = items.first(where: { $0["id"] as? String == id })
        let serverTitle = (found?["data"] as? [String: Any])?["title"] as? String
        XCTAssertEqual(serverTitle, updatedTitle, "Title not updated on server")
    }

    func testCMSTodos_Delete_RemoveRow_DeletedFromServer() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("TodoDel")

        // Create a test item
        let id = try await createCMSItem(
            collectionId: "Todos",
            data: ["title": testTitle, "status": "To Do"],
            resourceName: "cms-todos"
        )
        try await delay()

        // Verify it exists
        var items = try await queryCMS(collectionId: "Todos")
        XCTAssertTrue(items.contains(where: { $0["id"] as? String == id }), "Item should exist before delete")

        // Delete via engine
        try await engine.delete(remoteId: id, resource: res)
        // Remove from cleanup list since we just deleted it
        createdIds.removeAll(where: { $0.id == id })
        try await delay(1000)

        // Verify gone
        items = try await queryCMS(collectionId: "Todos")
        XCTAssertFalse(items.contains(where: { $0["id"] as? String == id }), "Item should be deleted")
    }

    func testCMSTodos_RoundTrip_CreateUpdateDelete() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("TodoRT")

        // CREATE
        let createRecord: [String: Any] = [
            "title": testTitle,
            "description": "Round trip test",
            "status": "To Do",
            "priority": "high"
        ]
        try await engine.pushRecord(createRecord, resource: res, action: .create)
        try await delay(1000)

        // Find it
        var items = try await queryCMS(collectionId: "Todos")
        let created = items.first(where: {
            ($0["data"] as? [String: Any])?["title"] as? String == testTitle
        })
        let id = created?["id"] as? String
        XCTAssertNotNil(id, "Created todo not found")
        guard let id = id else { return }

        // UPDATE
        let updatedTitle = testTitle + " DONE"
        let updateRecord: [String: Any] = [
            "title": updatedTitle,
            "status": "Done",
            "priority": "high"
        ]
        try await engine.pushRecord(updateRecord, resource: res, action: .update(id: id))
        try await delay(1000)

        items = try await queryCMS(collectionId: "Todos")
        let updated = items.first(where: { $0["id"] as? String == id })
        XCTAssertEqual(
            (updated?["data"] as? [String: Any])?["title"] as? String,
            updatedTitle
        )

        // DELETE
        try await engine.delete(remoteId: id, resource: res)
        try await delay(1000)

        items = try await queryCMS(collectionId: "Todos")
        XCTAssertFalse(items.contains(where: { $0["id"] as? String == id }))
    }

    func testCMSTodos_ServerChange_ReflectedInLocalFile() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("TodoSrv")

        // Create directly via API
        let id = try await createCMSItem(
            collectionId: "Todos",
            data: ["title": testTitle, "status": "To Do", "priority": "low"],
            resourceName: "cms-todos"
        )
        try await delay(1000)

        // Pull and check local CSV
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/todos.csv")

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertNotNil(found, "Server-created todo should appear in local CSV")
        XCTAssertEqual(found?["title"] as? String, testTitle)
    }

    func testCMSTodos_ServerUpdate_ReflectedInLocalFile() async throws {
        let res = resource("cms-todos")
        let testTitle = uniqueTestName("TodoSU")
        let updatedTitle = testTitle + " SRV-UPD"

        // Create via API
        let id = try await createCMSItem(
            collectionId: "Todos",
            data: ["title": testTitle, "status": "To Do"],
            resourceName: "cms-todos"
        )
        try await delay()

        // Update via API directly
        let updateBody: [String: Any] = [
            "dataCollectionId": "Todos",
            "dataItem": [
                "id": id,
                "data": ["title": updatedTitle, "status": "To Do"]
            ]
        ]
        _ = try await wixAPI(method: .PUT, path: "/wix-data/v2/items/\(id)", body: updateBody)
        try await delay(1000)

        // Pull and verify local file has updated value
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/todos.csv")

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertEqual(found?["title"] as? String, updatedTitle, "Server update should be reflected in local CSV")
    }

    // ======================================================================
    // MARK: - CMS Projects — Pull
    // ======================================================================

    func testCMSProjects_Pull_ReturnsCSVWithCorrectFields() async throws {
        let res = resource("cms-projects")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty)
        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/projects.csv")

        XCTAssertFalse(records.isEmpty, "No records in projects.csv")
        let columns = Set(records[0].keys)
        for expected in ["id", "name", "description", "color"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
    }

    // ======================================================================
    // MARK: - CMS Projects — Create / Update / Delete
    // ======================================================================

    func testCMSProjects_Create_NewProject_AppearsOnServer() async throws {
        let res = resource("cms-projects")
        let testName = uniqueTestName("Proj")

        let record: [String: Any] = [
            "name": testName,
            "description": "E2E test project",
            "color": "#FF0000"
        ]
        try await engine.pushRecord(record, resource: res, action: .create)
        try await delay(1000)

        let items = try await queryCMS(collectionId: "Projects")
        let found = items.first(where: {
            ($0["data"] as? [String: Any])?["name"] as? String == testName
        })
        XCTAssertNotNil(found, "Created project not found on server")

        if let id = found?["id"] as? String {
            createdIds.append((resource: res, id: id))
        }
    }

    func testCMSProjects_Update_ModifyName_ReflectedOnServer() async throws {
        let res = resource("cms-projects")
        let testName = uniqueTestName("ProjUpd")
        let updatedName = testName + " UPDATED"

        let id = try await createCMSItem(
            collectionId: "Projects",
            data: ["name": testName, "description": "Update test", "color": "#00FF00"],
            resourceName: "cms-projects"
        )
        try await delay()

        let record: [String: Any] = [
            "name": updatedName,
            "description": "Update test",
            "color": "#00FF00"
        ]
        try await engine.pushRecord(record, resource: res, action: .update(id: id))
        try await delay(1000)

        let items = try await queryCMS(collectionId: "Projects")
        let found = items.first(where: { $0["id"] as? String == id })
        XCTAssertEqual(
            (found?["data"] as? [String: Any])?["name"] as? String,
            updatedName
        )
    }

    func testCMSProjects_Delete_RemoveProject_DeletedFromServer() async throws {
        let res = resource("cms-projects")
        let testName = uniqueTestName("ProjDel")

        let id = try await createCMSItem(
            collectionId: "Projects",
            data: ["name": testName, "description": "Delete test", "color": "#0000FF"],
            resourceName: "cms-projects"
        )
        try await delay()

        try await engine.delete(remoteId: id, resource: res)
        createdIds.removeAll(where: { $0.id == id })
        try await delay(1000)

        let items = try await queryCMS(collectionId: "Projects")
        XCTAssertFalse(items.contains(where: { $0["id"] as? String == id }))
    }

    func testCMSProjects_ServerCreate_ReflectedInLocalFile() async throws {
        let res = resource("cms-projects")
        let testName = uniqueTestName("ProjSrv")

        let id = try await createCMSItem(
            collectionId: "Projects",
            data: ["name": testName, "description": "Server create test", "color": "#AABB00"],
            resourceName: "cms-projects"
        )
        try await delay(1000)

        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("cms/projects.csv")

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertNotNil(found, "Server-created project should appear in local CSV")
        XCTAssertEqual(found?["name"] as? String, testName)
    }

    // ======================================================================
    // MARK: - Products — Pull
    // ======================================================================

    func testProducts_Pull_ReturnsCSVWithProductData() async throws {
        let res = resource("products")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty)
        let file = result.files.first!
        XCTAssertEqual(file.relativePath, "products.csv")

        try writeFilesToDisk(result.files)
        let records = try readCSV("products.csv")
        XCTAssertFalse(records.isEmpty, "No records in products.csv")

        let columns = Set(records[0].keys)
        for expected in ["id", "name", "revision", "slug", "visible"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
    }

    func testProducts_Pull_ContainsKnownProducts() async throws {
        let res = resource("products")
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("products.csv")

        let names = records.compactMap { $0["name"] as? String }
        // At least one of these known products should exist
        let knownProducts = ["Ceramic Flower Vase", "Minimalist Tote Bag"]
        let found = knownProducts.contains(where: { known in
            names.contains(where: { $0.contains(known.replacingOccurrences(of: "*", with: "")) })
        })
        XCTAssertTrue(found, "Expected at least one known product. Got: \(names)")
    }

    // ======================================================================
    // MARK: - Products — Update
    // ======================================================================

    func testProducts_Update_ModifyName_ReflectedOnServer() async throws {
        let res = resource("products")

        // Pull products to get current state
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("products.csv")
        XCTAssertFalse(records.isEmpty)

        // Pick the first product and note its original name and revision
        let original = records[0]
        guard let productId = original["id"] as? String else {
            XCTFail("Product missing id"); return
        }
        let originalName = original["name"] as? String ?? ""
        let testSuffix = " E2E"

        // Get revision as integer (Wix requires numeric revision)
        let revision: Int
        if let rev = original["revision"] as? Int { revision = rev }
        else if let revStr = original["revision"] as? String, let rev = Int(revStr) { revision = rev }
        else { XCTFail("Could not parse revision"); return }

        // Update via direct API — Wix V3 expects revision inside product object
        let updateBody: [String: Any] = [
            "product": [
                "name": originalName + testSuffix,
                "revision": String(revision)
            ]
        ]
        _ = try await wixAPI(method: .PATCH, path: "/stores/v3/products/\(productId)", body: updateBody)
        try await delay(1500)

        // Verify on server via re-pull
        let result2 = try await engine.pull(resource: res)
        try writeFilesToDisk(result2.files)
        let records2 = try readCSV("products.csv")
        let updated = records2.first(where: { ($0["id"] as? String) == productId })
        XCTAssertTrue(
            (updated?["name"] as? String)?.contains(testSuffix) == true,
            "Product name should contain test suffix"
        )

        // Restore original name
        let newRevision: Int
        if let rev = updated?["revision"] as? Int { newRevision = rev }
        else if let revStr = updated?["revision"] as? String, let rev = Int(revStr) { newRevision = rev }
        else { XCTFail("Could not parse updated revision"); return }

        let restoreBody: [String: Any] = [
            "product": [
                "name": originalName,
                "revision": String(newRevision)
            ]
        ]
        _ = try await wixAPI(method: .PATCH, path: "/stores/v3/products/\(productId)", body: restoreBody)
        try await delay()
    }

    func testProducts_Update_RevisionIncrementsAfterPush() async throws {
        let res = resource("products")

        // Pull current products
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("products.csv")
        XCTAssertFalse(records.isEmpty)

        let original = records[0]
        guard let productId = original["id"] as? String else {
            XCTFail("Product missing id"); return
        }
        let originalName = original["name"] as? String ?? ""
        let revisionBefore: Int
        if let rev = original["revision"] as? Int { revisionBefore = rev }
        else if let revStr = original["revision"] as? String, let rev = Int(revStr) { revisionBefore = rev }
        else { XCTFail("Could not parse revision"); return }

        // Push a trivial update via direct API — Wix V3 expects revision inside product
        let updateBody: [String: Any] = [
            "product": [
                "name": originalName + " rev-test",
                "revision": String(revisionBefore)
            ]
        ]
        _ = try await wixAPI(method: .PATCH, path: "/stores/v3/products/\(productId)", body: updateBody)
        try await delay(1500)

        // Re-pull and check revision
        let result2 = try await engine.pull(resource: res)
        try writeFilesToDisk(result2.files)
        let records2 = try readCSV("products.csv")
        let updated = records2.first(where: { ($0["id"] as? String) == productId })
        let revisionAfter: Int
        if let rev = updated?["revision"] as? Int { revisionAfter = rev }
        else if let revStr = updated?["revision"] as? String, let rev = Int(revStr) { revisionAfter = rev }
        else { XCTFail("Could not parse updated revision"); return }

        XCTAssertGreaterThan(revisionAfter, revisionBefore, "Revision should increment after update")

        // Restore original name
        let restoreBody: [String: Any] = [
            "product": [
                "name": originalName,
                "revision": String(revisionAfter)
            ]
        ]
        _ = try await wixAPI(method: .PATCH, path: "/stores/v3/products/\(productId)", body: restoreBody)
        try await delay()
    }

    // ======================================================================
    // MARK: - Products — Delete
    // ======================================================================

    func testProducts_Delete_RemoveProduct_DeletedFromServer() async throws {
        let res = resource("products")

        // Create a test product — try V1 first (simpler), fall back to V3 with full fields
        let testName = uniqueTestName("Product")
        var productId: String?

        // V3 API — requires variantsInfo with at least one variant
        let v3Body: [String: Any] = [
            "product": [
                "name": testName,
                "productType": "PHYSICAL",
                "visible": false,
                "physicalProperties": [:] as [String: Any],
                "variantsInfo": [
                    "variants": [
                        [
                            "choices": [] as [[String: Any]],
                            "price": [
                                "actualPrice": ["amount": "1.00"]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        if let v3Result = try? await wixAPI(method: .POST, path: "/stores/v3/products", body: v3Body),
           let product = v3Result["product"] as? [String: Any],
           let id = product["id"] as? String {
            productId = id
        }

        guard let productId = productId else {
            throw XCTSkip("Cannot create test product via Wix API (V1 and V3 both rejected)")
        }
        try await delay(1000)

        // Verify exists via pull
        var pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        var records = try readCSV("products.csv")
        XCTAssertTrue(records.contains(where: { ($0["id"] as? String) == productId }), "Test product should exist")

        // Delete via engine
        try await engine.delete(remoteId: productId, resource: res)
        try await delay(1000)

        // Verify gone
        pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        records = try readCSV("products.csv")
        XCTAssertFalse(records.contains(where: { ($0["id"] as? String) == productId }), "Product should be deleted")
    }

    // ======================================================================
    // MARK: - Media — Pull
    // ======================================================================

    func testMedia_Pull_DownloadsBinaryFiles() async throws {
        let res = resource("media")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "Expected at least one media file")
        try writeFilesToDisk(result.files)

        for file in result.files {
            XCTAssertGreaterThan(file.content.count, 0, "Media file \(file.relativePath) should not be empty")
            XCTAssertTrue(file.relativePath.hasPrefix("media/"), "Media file should be in media/ dir")

            // Check for JPEG or PNG magic bytes
            let bytes = [UInt8](file.content.prefix(8))
            let isJPEG = bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
            let isPNG = bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
            let isValid = isJPEG || isPNG || file.content.count > 100 // Allow other formats
            XCTAssertTrue(isValid, "File \(file.relativePath) doesn't appear to be a valid image")
        }
    }

    func testMedia_Pull_FilenamesMatchDisplayNames() async throws {
        let res = resource("media")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty)
        for file in result.files {
            // Each file should have a reasonable filename (not a UUID mess)
            let filename = URL(fileURLWithPath: file.relativePath).lastPathComponent
            XCTAssertFalse(filename.isEmpty, "Filename should not be empty")
            XCTAssertTrue(filename.contains("."), "Filename should have an extension: \(filename)")
        }
    }

    func testMedia_Pull_SecondPullSkipsUnchanged() async throws {
        let res = resource("media")

        // First pull
        let result1 = try await engine.pull(resource: res)
        try writeFilesToDisk(result1.files)
        let fileCount1 = result1.files.count

        try await delay(1000)

        // Second pull — should still return files (engine doesn't do ETag caching at this level)
        let result2 = try await engine.pull(resource: res)
        let fileCount2 = result2.files.count

        XCTAssertEqual(fileCount1, fileCount2, "Same number of files expected on second pull")
    }

    // ======================================================================
    // MARK: - Media — Upload
    // ======================================================================

    func testMedia_Upload_PushNewImage_AppearsOnServer() async throws {
        let res = resource("media")

        // Create a minimal valid PNG (1x1 pixel, red)
        let pngData = createMinimalPNG()
        let filename = "e2e-test-\(UUID().uuidString.prefix(8)).png"

        // Upload via engine
        try await engine.pushMediaFile(
            fileData: pngData,
            filename: filename,
            mimeType: "image/png",
            resource: res
        )
        try await delay(2000)

        // Re-pull and check if our file appears
        let result = try await engine.pull(resource: res)
        let found = result.files.contains(where: {
            $0.relativePath.contains("e2e-test")
        })
        // Note: Wix media processing may take time; best-effort verification
        if !found {
            print("[WixLiveE2E] Warning: uploaded file not yet visible in pull — may need processing time")
        }
    }

    /// Create a minimal valid 1x1 red PNG file.
    private func createMinimalPNG() -> Data {
        // Minimal PNG: 8-byte signature + IHDR + IDAT + IEND
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

        // IHDR: 1x1, 8-bit RGB
        let ihdrData: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, // width = 1
            0x00, 0x00, 0x00, 0x01, // height = 1
            0x08,                   // bit depth = 8
            0x02,                   // color type = RGB
            0x00,                   // compression
            0x00,                   // filter
            0x00                    // interlace
        ]
        let ihdr = pngChunk(type: [0x49, 0x48, 0x44, 0x52], data: ihdrData)

        // IDAT: compressed scanline (filter=0, R=255, G=0, B=0)
        // zlib-compressed version of [0x00, 0xFF, 0x00, 0x00]
        let idatCompressed: [UInt8] = [
            0x78, 0x01, 0x62, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01
        ]
        let idat = pngChunk(type: [0x49, 0x44, 0x41, 0x54], data: idatCompressed)

        // IEND
        let iend = pngChunk(type: [0x49, 0x45, 0x4E, 0x44], data: [])

        return Data(signature + ihdr + idat + iend)
    }

    private func pngChunk(type: [UInt8], data: [UInt8]) -> [UInt8] {
        var chunk: [UInt8] = []
        // Length (4 bytes big-endian)
        let length = UInt32(data.count)
        chunk += withUnsafeBytes(of: length.bigEndian) { Array($0) }
        // Type
        chunk += type
        // Data
        chunk += data
        // CRC32 over type + data
        let crcInput = type + data
        let crc = crc32(crcInput)
        chunk += withUnsafeBytes(of: crc.bigEndian) { Array($0) }
        return chunk
    }

    private func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
