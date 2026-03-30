import XCTest
@testable import API2FileCore

final class AdapterEngineIntegrationTests: XCTestCase {

    private final class RequestCapture: @unchecked Sendable {
        var request: URLRequest?
    }

    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }

        return data
    }

    // MARK: - Properties

    private var tempDir: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdapterEngineIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - loadConfig

    func testLoadConfigFromAdapterJSON() throws {
        // Create a valid adapter.json inside .api2file/
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let configJSON = """
        {
            "service": "test-api",
            "displayName": "Test API",
            "version": "1.0",
            "auth": {
                "type": "bearer",
                "keychainKey": "test-api-key"
            },
            "globals": {
                "baseUrl": "https://api.example.com",
                "headers": {
                    "X-Custom": "value"
                }
            },
            "resources": [
                {
                    "name": "items",
                    "description": "Test items",
                    "pull": {
                        "url": "{baseUrl}/items",
                        "dataPath": "$.data.items"
                    },
                    "fileMapping": {
                        "strategy": "collection",
                        "directory": "items",
                        "filename": "all-items.csv",
                        "format": "csv"
                    },
                    "sync": {
                        "interval": 120
                    }
                }
            ]
        }
        """
        try configJSON.write(
            to: api2fileDir.appendingPathComponent("adapter.json"),
            atomically: true,
            encoding: .utf8
        )

        let config = try AdapterEngine.loadConfig(from: tempDir)

        XCTAssertEqual(config.service, "test-api")
        XCTAssertEqual(config.displayName, "Test API")
        XCTAssertEqual(config.version, "1.0")
        XCTAssertEqual(config.auth.type, .bearer)
        XCTAssertEqual(config.auth.keychainKey, "test-api-key")
        XCTAssertEqual(config.globals?.baseUrl, "https://api.example.com")
        XCTAssertEqual(config.globals?.headers?["X-Custom"], "value")
        XCTAssertEqual(config.resources.count, 1)
        XCTAssertEqual(config.resources[0].name, "items")
        XCTAssertEqual(config.resources[0].fileMapping.strategy, .collection)
        XCTAssertEqual(config.resources[0].fileMapping.format, .csv)
        XCTAssertEqual(config.resources[0].fileMapping.directory, "items")
        XCTAssertEqual(config.resources[0].fileMapping.filename, "all-items.csv")
        XCTAssertEqual(config.resources[0].sync?.interval, 120)
    }

    func testLoadConfigThrowsWhenMissing() {
        XCTAssertThrowsError(try AdapterEngine.loadConfig(from: tempDir)) { error in
            guard let adapterError = error as? AdapterError else {
                XCTFail("Expected AdapterError, got \(type(of: error))")
                return
            }
            if case .configNotFound = adapterError {
                // Expected
            } else {
                XCTFail("Expected configNotFound, got \(adapterError)")
            }
        }
    }

    // MARK: - Full Pull Pipeline (transform + format chain)

    func testPullPipeline_JSONPathExtraction_TransformPipeline_FormatConversion() throws {
        // Simulate a raw API response
        let apiResponse: [String: Any] = [
            "data": [
                "items": [
                    ["id": 1, "old_name": "Widget", "price": 9.99, "_internal": "skip"],
                    ["id": 2, "old_name": "Gadget", "price": 19.99, "_internal": "skip"]
                ]
            ] as [String: Any]
        ]

        // Step 1: JSONPath extraction (simulates pull.dataPath = "$.data.items")
        let extracted = JSONPath.extract("$.data.items", from: apiResponse)
        let records = extracted as! [[String: Any]]
        XCTAssertEqual(records.count, 2)

        // Step 2: Transform pipeline (omit internal fields, rename old_name to name)
        let transforms: [TransformOp] = [
            TransformOp(op: "omit", fields: ["_internal"]),
            TransformOp(op: "rename", from: "old_name", to: "name")
        ]
        let transformed = TransformPipeline.apply(transforms, to: records)

        XCTAssertEqual(transformed.count, 2)
        XCTAssertNil(transformed[0]["_internal"])
        XCTAssertNil(transformed[0]["old_name"])
        XCTAssertEqual(transformed[0]["name"] as? String, "Widget")
        XCTAssertEqual(transformed[0]["price"] as? Double, 9.99)

        // Step 3: Format conversion to CSV
        let csvData = try FormatConverterFactory.encode(records: transformed, format: .csv)
        let csvString = String(data: csvData, encoding: .utf8)!
        XCTAssertTrue(csvString.contains("_id"))
        XCTAssertTrue(csvString.contains("name"))
        XCTAssertTrue(csvString.contains("price"))
        XCTAssertTrue(csvString.contains("Widget"))
        XCTAssertTrue(csvString.contains("Gadget"))

        // Step 4: Create SyncableFile
        let syncableFile = SyncableFile(
            relativePath: "items/all-items.csv",
            format: .csv,
            content: csvData,
            remoteId: nil,
            readOnly: false
        )

        XCTAssertEqual(syncableFile.relativePath, "items/all-items.csv")
        XCTAssertEqual(syncableFile.format, .csv)
        XCTAssertFalse(syncableFile.readOnly)
        XCTAssertFalse(syncableFile.contentHash.isEmpty)
        // SHA256 hex is 64 chars
        XCTAssertEqual(syncableFile.contentHash.count, 64)
    }

    func testPullPipeline_JSONFormat_OnePerRecord() throws {
        // Simulate extracted records
        let records: [[String: Any]] = [
            ["id": 101, "title": "My Blog Post", "body": "Hello world"],
            ["id": 102, "title": "Another Post", "body": "More content"]
        ]

        // Transform: pick only id and title
        let transforms: [TransformOp] = [
            TransformOp(op: "pick", fields: ["id", "title"])
        ]
        let transformed = TransformPipeline.apply(transforms, to: records)

        // Format each as JSON (one-per-record)
        for record in transformed {
            let jsonData = try FormatConverterFactory.encode(records: [record], format: .json)
            let decoded = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]
            XCTAssertNotNil(decoded["id"])
            XCTAssertNotNil(decoded["title"])
            XCTAssertNil(decoded["body"])
        }
    }

    // MARK: - Full Push Pipeline (file content -> format decode -> transforms -> API JSON)

    func testPushPipeline_CSVDecode_TransformToAPIJSON() throws {
        // Create a CSV file content (simulating what a user edited)
        let csvContent = "_id,name,price,status\n1,Widget,9.99,active\n2,Gadget,19.99,inactive\n"
        let csvData = Data(csvContent.utf8)

        // Step 1: Decode CSV back to records
        let records = try FormatConverterFactory.decode(data: csvData, format: .csv)

        XCTAssertEqual(records.count, 2)
        // CSV decoder converts _id back to "id"
        XCTAssertEqual(records[0]["id"] as? Int, 1)
        XCTAssertEqual(records[0]["name"] as? String, "Widget")
        XCTAssertEqual(records[0]["price"] as? Double, 9.99)
        XCTAssertEqual(records[0]["status"] as? String, "active")

        // Step 2: Apply push transforms (e.g., omit status, rename name to title)
        let pushTransforms: [TransformOp] = [
            TransformOp(op: "omit", fields: ["status"]),
            TransformOp(op: "rename", from: "name", to: "title")
        ]
        let transformed = TransformPipeline.apply(pushTransforms, to: records)

        XCTAssertEqual(transformed.count, 2)
        XCTAssertEqual(transformed[0]["title"] as? String, "Widget")
        XCTAssertNil(transformed[0]["name"])
        XCTAssertNil(transformed[0]["status"])
        XCTAssertEqual(transformed[0]["id"] as? Int, 1)
        XCTAssertEqual(transformed[0]["price"] as? Double, 9.99)

        // Step 3: Verify records are ready for API serialization
        for record in transformed {
            let jsonData = try JSONSerialization.data(withJSONObject: record)
            XCTAssertFalse(jsonData.isEmpty)
        }
    }

    func testWixProductsUpdate_RevisionStaysInsideProductWrapper() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "products" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        try await engine.pushRecord(
            [
                "id": "product-123",
                "name": "Updated Name",
                "revision": "237"
            ],
            resource: resource,
            action: .update(id: "product-123")
        )

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://www.wixapis.com/stores/v3/products/product-123")

        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let product = try XCTUnwrap(json["product"] as? [String: Any])

        XCTAssertEqual(product["name"] as? String, "Updated Name")
        XCTAssertEqual(product["revision"] as? String, "237")
        XCTAssertNil(json["revision"], "Wix V3 expects revision nested inside product, not hoisted to the root body")
    }

    func testWixContactsCreateBuildsInfoBodyFromHumanFields() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"contact":{"id":"contact-123"}}"#.utf8))
        }

        let createdId = try await engine.pushRecord(
            [
                "first": "Codex",
                "last": "Agent",
                "primaryEmail": "codex@example.com"
            ],
            resource: resource,
            action: .create
        )

        XCTAssertEqual(createdId, "contact-123")

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.wixapis.com/contacts/v4/contacts")

        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        let name = try XCTUnwrap(info["name"] as? [String: Any])
        let emails = try XCTUnwrap(info["emails"] as? [String: Any])
        let items = try XCTUnwrap(emails["items"] as? [[String: Any]])

        XCTAssertEqual(name["first"] as? String, "Codex")
        XCTAssertEqual(name["last"] as? String, "Agent")
        XCTAssertEqual(items.first?["email"] as? String, "codex@example.com")
        XCTAssertNil(json["revision"], "Contact create should not send revision at the root")
    }

    func testWixContactsUpdateKeepsRevisionAtRootAndInfoNested() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        try await engine.pushRecord(
            [
                "id": "contact-123",
                "revision": 7,
                "info": [
                    "name": [
                        "first": "CodexUpdated",
                        "last": "Agent"
                    ]
                ],
                "primaryEmail": "codex@example.com"
            ],
            resource: resource,
            action: .update(id: "contact-123")
        )

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.absoluteString, "https://www.wixapis.com/contacts/v4/contacts/contact-123")

        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        let name = try XCTUnwrap(info["name"] as? [String: Any])

        XCTAssertEqual(json["revision"] as? Int, 7)
        XCTAssertEqual(name["first"] as? String, "CodexUpdated")
        XCTAssertEqual(name["last"] as? String, "Agent")
        XCTAssertNil(info["revision"], "Contact update should keep revision at the root, not nested inside info")
    }

    func testWixContactsUpdatePromotesEditedDisplayNameWhenRawNameWasNotChanged() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        try await engine.pushRecord(
            [
                "id": "contact-123",
                "revision": 8,
                "info": [
                    "name": [
                        "first": "Codex",
                        "last": "Contact"
                    ],
                    "extendedFields": [
                        "items": [
                            "contacts": [
                                "displayByFirstName": "Sarah Mitchell"
                            ]
                        ]
                    ]
                ]
            ],
            resource: resource,
            action: .update(id: "contact-123")
        )

        let request = try XCTUnwrap(capture.request)
        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        let name = try XCTUnwrap(info["name"] as? [String: Any])

        XCTAssertEqual(name["first"] as? String, "Sarah")
        XCTAssertEqual(name["last"] as? String, "Mitchell")
    }

    func testWixContactsUpdateIgnoresRawExtendedFieldsAndParsesJSONEmailCell() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "contacts" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        try await engine.pushRecord(
            [
                "id": "contact-123",
                "revision": 4,
                "primaryEmail": #"{"subscriptionStatus":"NOT_SET","deliverabilityStatus":"NOT_SET","email":"codex@example.com"}"#,
                "info": [
                    "emails": [
                        "items": [
                            [
                                "email": "codex@example.com",
                                "id": "email-1",
                                "primary": true,
                                "tag": "UNTAGGED"
                            ]
                        ]
                    ],
                    "extendedFields": [
                        "items": [
                            "contacts.displayByFirstName": "codex@example.com"
                        ]
                    ]
                ]
            ],
            resource: resource,
            action: .update(id: "contact-123")
        )

        let request = try XCTUnwrap(capture.request)
        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        let emails = try XCTUnwrap(info["emails"] as? [String: Any])
        let items = try XCTUnwrap(emails["items"] as? [[String: Any]])

        XCTAssertEqual(items.first?["email"] as? String, "codex@example.com")
        XCTAssertNil(info["extendedFields"], "Human contact updates should not push raw extended fields back to Wix")
    }

    func testWixCMSItemCreateBuildsDataCollectionBodyFromHumanRecord() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let collections = try XCTUnwrap(config.resources.first(where: { $0.name == "collections" }))
        let resource = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"dataItem":{"id":"todo-123"}}"#.utf8))
        }

        let createdId = try await engine.pushRecord(
            [
                "dataCollectionId": "Todos",
                "title": "Codex Todo",
                "status": "To Do"
            ],
            resource: resource,
            action: .create
        )

        XCTAssertEqual(createdId, "todo-123")

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.wixapis.com/wix-data/v2/items")

        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["dataCollectionId"] as? String, "Todos")
        let dataItem = try XCTUnwrap(json["dataItem"] as? [String: Any])
        XCTAssertNil(dataItem["id"], "Create should not force an id into the CMS dataItem payload")
        let itemData = try XCTUnwrap(dataItem["data"] as? [String: Any])
        XCTAssertEqual(itemData["title"] as? String, "Codex Todo")
        XCTAssertEqual(itemData["status"] as? String, "To Do")
    }

    func testWixCMSItemUpdateBuildsDataCollectionBodyFromHumanRecord() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let collections = try XCTUnwrap(config.resources.first(where: { $0.name == "collections" }))
        let resource = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        try await engine.pushRecord(
            [
                "id": "todo-123",
                "dataCollectionId": "Todos",
                "title": "Codex Todo Updated",
                "status": "Done"
            ],
            resource: resource,
            action: .update(id: "todo-123")
        )

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://www.wixapis.com/wix-data/v2/items/todo-123")

        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["dataCollectionId"] as? String, "Todos")
        let dataItem = try XCTUnwrap(json["dataItem"] as? [String: Any])
        XCTAssertEqual(dataItem["id"] as? String, "todo-123")
        let itemData = try XCTUnwrap(dataItem["data"] as? [String: Any])
        XCTAssertEqual(itemData["title"] as? String, "Codex Todo Updated")
        XCTAssertEqual(itemData["status"] as? String, "Done")
    }

    func testWixCMSCollectionPullStoresCollectionContextAsFileRemoteId() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let collections = try XCTUnwrap(config.resources.first(where: { $0.name == "collections" }))
        let child = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))

        let resolvedPull = PullConfig(
            method: child.pull?.method,
            url: child.pull?.url ?? "",
            type: child.pull?.type,
            query: child.pull?.query,
            body: .object([
                "dataCollectionId": .string("Todos"),
                "query": .object([
                    "paging": .object(["limit": .number(50)])
                ])
            ]),
            dataPath: child.pull?.dataPath,
            detail: child.pull?.detail,
            pagination: child.pull?.pagination,
            mediaConfig: child.pull?.mediaConfig,
            updatedSinceField: child.pull?.updatedSinceField,
            updatedSinceBodyPath: child.pull?.updatedSinceBodyPath,
            updatedSinceDateFormat: child.pull?.updatedSinceDateFormat,
            supportsETag: child.pull?.supportsETag
        )
        let resource = ResourceConfig(
            name: "collections.items.Todos",
            description: child.description,
            capabilityClass: child.capabilityClass,
            pull: resolvedPull,
            push: child.push,
            fileMapping: FileMappingConfig(
                strategy: child.fileMapping.strategy,
                directory: "cms",
                filename: "todos.csv",
                format: child.fileMapping.format,
                formatOptions: child.fileMapping.formatOptions,
                idField: child.fileMapping.idField,
                contentField: child.fileMapping.contentField,
                readOnly: child.fileMapping.readOnly,
                preserveExtension: child.fileMapping.preserveExtension,
                transforms: child.fileMapping.transforms,
                pushMode: child.fileMapping.pushMode,
                deleteFromAPI: child.fileMapping.deleteFromAPI
            ),
            children: nil,
            sync: child.sync,
            siteUrl: child.siteUrl,
            dashboardUrl: child.dashboardUrl
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"dataItems":[{"id":"todo-123","data":{"title":"Ship it","status":"To Do"}}]}"#.utf8))
        }

        let result = try await engine.pull(resource: resource)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files.first?.relativePath, "cms/todos.csv")
        XCTAssertEqual(result.files.first?.remoteId, "Todos")
    }

    func testMondayCreateBuildsGraphQLVariablesBody() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/monday.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(
            config.resources.first(where: { $0.name == "boards" })?
                .children?.first(where: { $0.name == "items" })
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"data":{"create_item":{"id":"12345"}}}"#.utf8))
        }

        let createdId = try await engine.pushRecord(
            [
                "boardId": "5093652867",
                "name": "Launch spring campaign",
                "columns": ["project_status": "Working on it"]
            ],
            resource: resource,
            action: .create
        )

        XCTAssertEqual(createdId, "12345")

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue((json["query"] as? String)?.contains("create_item") == true)

        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        XCTAssertEqual(variables["boardId"] as? String, "5093652867")
        XCTAssertEqual(variables["itemName"] as? String, "Launch spring campaign")
        XCTAssertEqual(
            variables["columnValues"] as? String,
            #"{"project_status":"Working on it"}"#
        )
    }

    func testMondayUpdateBuildsGraphQLVariablesBody() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/monday.adapter.json"))
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        let resource = try XCTUnwrap(
            config.resources.first(where: { $0.name == "boards" })?
                .children?.first(where: { $0.name == "items" })
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data(#"{"data":{"change_simple_column_value":{"id":"2800121775"}}}"#.utf8))
        }

        try await engine.pushRecord(
            [
                "id": "2800121775",
                "boardId": "5093652867",
                "name": "Launch summer campaign",
                "columns": ["project_status": "Done"]
            ],
            resource: resource,
            action: .update(id: "2800121775")
        )

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let query = try XCTUnwrap(json["query"] as? String)
        XCTAssertTrue(query.contains("change_simple_column_value"))
        XCTAssertTrue(query.contains(#"column_id: "project_status""#))
        XCTAssertFalse(query.contains("change_multiple_column_values"))

        let variables = try XCTUnwrap(json["variables"] as? [String: Any])
        XCTAssertEqual(variables["boardId"] as? String, "5093652867")
        XCTAssertEqual(variables["itemId"] as? String, "2800121775")
        XCTAssertEqual(variables["itemName"] as? String, "Launch summer campaign")
        XCTAssertEqual(variables["columnValue0"] as? String, "Done")
    }

    func testGraphQLPullUsesGlobalPOSTMethodWhenResourceMethodIsOmitted() async throws {
        let api2fileDir = tempDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let configJSON = """
        {
          "service": "monday-like",
          "displayName": "Monday-like",
          "version": "1.0",
          "auth": { "type": "bearer", "keychainKey": "test-key" },
          "globals": {
            "baseUrl": "https://api.example.com/graphql",
            "method": "POST",
            "headers": { "Content-Type": "application/json" }
          },
          "resources": [
            {
              "name": "boards",
              "pull": {
                "url": "{baseUrl}",
                "type": "graphql",
                "query": "{ boards { id name } }",
                "dataPath": "$.data.boards"
              },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "boards.csv",
                "format": "csv",
                "idField": "id"
              },
              "sync": { "interval": 60 }
            }
          ]
        }
        """
        try Data(configJSON.utf8).write(to: api2fileDir.appendingPathComponent("adapter.json"))

        let config = try AdapterEngine.loadConfig(from: tempDir)
        let resource = try XCTUnwrap(config.resources.first)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        let capture = RequestCapture()
        MockURLProtocol.requestHandler = { request in
            capture.request = request
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [:]
            )!
            let payload = #"{"data":{"boards":[]}}"#
            return (response, Data(payload.utf8))
        }

        _ = try await engine.pull(resource: resource)

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(Self.bodyData(from: request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["query"] as? String, "{ boards { id name } }")
    }

    func testPushPipeline_JSONDecode_TransformToAPIJSON() throws {
        // Simulate a JSON file that a user edited
        let jsonContent = """
        {
            "id": 42,
            "title": "Updated Post",
            "body": "New content here"
        }
        """
        let jsonData = Data(jsonContent.utf8)

        // Step 1: Decode JSON back to records
        let records = try FormatConverterFactory.decode(data: jsonData, format: .json)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["id"] as? Int, 42)
        XCTAssertEqual(records[0]["title"] as? String, "Updated Post")

        // Step 2: Apply push transforms (pick specific fields for API)
        let pushTransforms: [TransformOp] = [
            TransformOp(op: "pick", fields: ["title", "body"])
        ]
        let transformed = TransformPipeline.apply(pushTransforms, to: records)

        XCTAssertEqual(transformed.count, 1)
        XCTAssertEqual(transformed[0]["title"] as? String, "Updated Post")
        XCTAssertEqual(transformed[0]["body"] as? String, "New content here")
        XCTAssertNil(transformed[0]["id"]) // id was not picked
    }

    // MARK: - FileMapper.filePath

    func testFilePathGeneratesCorrectPathWithSlugify() {
        let config = FileMappingConfig(
            strategy: .onePerRecord,
            directory: "boards",
            filename: "{name|slugify}.csv",
            format: .csv
        )
        let record: [String: Any] = ["id": 1, "name": "Marketing Board"]

        let path = FileMapper.filePath(for: record, config: config)
        XCTAssertEqual(path, "boards/marketing-board.csv")
    }

    func testFilePathWithIdFallback() {
        let config = FileMappingConfig(
            strategy: .onePerRecord,
            directory: "items",
            format: .json,
            idField: "id"
        )
        let record: [String: Any] = ["id": 42, "name": "Widget"]

        let path = FileMapper.filePath(for: record, config: config)
        XCTAssertEqual(path, "items/42.json")
    }

    func testFilePathWithEmptyDirectory() {
        let config = FileMappingConfig(
            strategy: .onePerRecord,
            directory: "",
            filename: "{name|slugify}.md",
            format: .markdown
        )
        let record: [String: Any] = ["name": "Hello World"]

        let path = FileMapper.filePath(for: record, config: config)
        XCTAssertEqual(path, "hello-world.md")
    }

    func testFilePathWithDotDirectory() {
        let config = FileMappingConfig(
            strategy: .onePerRecord,
            directory: ".",
            filename: "{id}.json",
            format: .json
        )
        let record: [String: Any] = ["id": 99]

        let path = FileMapper.filePath(for: record, config: config)
        XCTAssertEqual(path, "99.json")
    }

    func testFilePathWithSpecialCharsInName() {
        let config = FileMappingConfig(
            strategy: .onePerRecord,
            directory: "pages",
            filename: "{title|slugify}.html",
            format: .html
        )
        let record: [String: Any] = ["title": "Q&A: Best Practices! (2024)"]

        let path = FileMapper.filePath(for: record, config: config)
        // slugify: lowercase, replace special chars with hyphens, trim trailing hyphens
        XCTAssertTrue(path.hasPrefix("pages/"))
        XCTAssertTrue(path.hasSuffix(".html"))
        XCTAssertFalse(path.contains("&"))
        XCTAssertFalse(path.contains("!"))
        XCTAssertFalse(path.contains("("))
    }

    // MARK: - FileMapper.writeFiles + readFile

    func testWriteFilesCreatesFilesOnDisk() throws {
        let files = [
            SyncableFile(
                relativePath: "boards/marketing.csv",
                format: .csv,
                content: Data("_id,name\n1,Marketing\n".utf8),
                remoteId: "1"
            ),
            SyncableFile(
                relativePath: "boards/engineering.csv",
                format: .csv,
                content: Data("_id,name\n2,Engineering\n".utf8),
                remoteId: "2"
            )
        ]

        try FileMapper.writeFiles(files, to: tempDir)

        // Verify files exist
        let file1Path = tempDir.appendingPathComponent("boards/marketing.csv")
        let file2Path = tempDir.appendingPathComponent("boards/engineering.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1Path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2Path.path))

        // Verify content
        let content1 = try String(contentsOf: file1Path, encoding: .utf8)
        XCTAssertEqual(content1, "_id,name\n1,Marketing\n")

        let content2 = try String(contentsOf: file2Path, encoding: .utf8)
        XCTAssertEqual(content2, "_id,name\n2,Engineering\n")
    }

    func testWriteFilesCreatesIntermediateDirectories() throws {
        let files = [
            SyncableFile(
                relativePath: "deeply/nested/dir/file.json",
                format: .json,
                content: Data("{\"key\": \"value\"}".utf8)
            )
        ]

        try FileMapper.writeFiles(files, to: tempDir)

        let filePath = tempDir.appendingPathComponent("deeply/nested/dir/file.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath.path))
    }

    func testReadFileReturnsWrittenContent() throws {
        let originalContent = Data("{\"id\": 1, \"name\": \"Test\"}".utf8)
        let files = [
            SyncableFile(
                relativePath: "items/test.json",
                format: .json,
                content: originalContent
            )
        ]

        try FileMapper.writeFiles(files, to: tempDir)

        let filePath = tempDir.appendingPathComponent("items/test.json")
        let readData = try FileMapper.readFile(at: filePath, format: .json)

        XCTAssertEqual(readData, originalContent)
    }

    func testWriteThenReadRoundtrip_CSV() throws {
        // Create records, encode to CSV, write, read back, decode
        let records: [[String: Any]] = [
            ["id": 1, "name": "Widget", "price": 9.99],
            ["id": 2, "name": "Gadget", "price": 19.99]
        ]

        let csvData = try FormatConverterFactory.encode(records: records, format: .csv)
        let files = [
            SyncableFile(
                relativePath: "products/all.csv",
                format: .csv,
                content: csvData
            )
        ]

        try FileMapper.writeFiles(files, to: tempDir)

        let filePath = tempDir.appendingPathComponent("products/all.csv")
        let readData = try FileMapper.readFile(at: filePath, format: .csv)
        let decodedRecords = try FormatConverterFactory.decode(data: readData, format: .csv)

        XCTAssertEqual(decodedRecords.count, 2)
        XCTAssertEqual(decodedRecords[0]["name"] as? String, "Widget")
        XCTAssertEqual(decodedRecords[1]["name"] as? String, "Gadget")
    }

    func testWriteThenReadRoundtrip_JSON() throws {
        let records: [[String: Any]] = [
            ["id": 1, "title": "Post One"]
        ]

        let jsonData = try FormatConverterFactory.encode(records: records, format: .json)
        let files = [
            SyncableFile(
                relativePath: "posts/post-one.json",
                format: .json,
                content: jsonData
            )
        ]

        try FileMapper.writeFiles(files, to: tempDir)

        let filePath = tempDir.appendingPathComponent("posts/post-one.json")
        let readData = try FileMapper.readFile(at: filePath, format: .json)
        let decodedRecords = try FormatConverterFactory.decode(data: readData, format: .json)

        XCTAssertEqual(decodedRecords.count, 1)
        XCTAssertEqual(decodedRecords[0]["id"] as? Int, 1)
        XCTAssertEqual(decodedRecords[0]["title"] as? String, "Post One")
    }

    // MARK: - End-to-End: API Response -> Files on Disk

    func testFullPipelineFromAPIResponseToFilesOnDisk() throws {
        // Simulate raw API response
        let apiResponse: [String: Any] = [
            "results": [
                [
                    "id": 101,
                    "name": "Project Alpha",
                    "metadata": ["status": "active", "priority": "high"] as [String: Any]
                ],
                [
                    "id": 102,
                    "name": "Project Beta",
                    "metadata": ["status": "archived", "priority": "low"] as [String: Any]
                ]
            ]
        ]

        // Extract data from response
        let extracted = JSONPath.extract("$.results", from: apiResponse) as! [[String: Any]]

        // Transform: flatten metadata, pick fields
        let transforms: [TransformOp] = [
            TransformOp(op: "rename", from: "metadata.status", to: "status"),
            TransformOp(op: "pick", fields: ["id", "name", "status"])
        ]
        let transformed = TransformPipeline.apply(transforms, to: extracted)

        // Create file mapping config for one-per-record JSON files
        let mappingConfig = FileMappingConfig(
            strategy: .onePerRecord,
            directory: "projects",
            filename: "{name|slugify}.json",
            format: .json
        )

        // Map to SyncableFiles
        var syncableFiles: [SyncableFile] = []
        for record in transformed {
            let path = FileMapper.filePath(for: record, config: mappingConfig)
            let data = try FormatConverterFactory.encode(records: [record], format: .json)
            syncableFiles.append(SyncableFile(
                relativePath: path,
                format: .json,
                content: data,
                remoteId: "\(record["id"]!)"
            ))
        }

        // Write to disk
        try FileMapper.writeFiles(syncableFiles, to: tempDir)

        // Verify files
        let file1 = tempDir.appendingPathComponent("projects/project-alpha.json")
        let file2 = tempDir.appendingPathComponent("projects/project-beta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path))

        // Read back and verify content
        let data1 = try FileMapper.readFile(at: file1, format: .json)
        let decoded1 = try FormatConverterFactory.decode(data: data1, format: .json)
        XCTAssertEqual(decoded1[0]["name"] as? String, "Project Alpha")
        XCTAssertEqual(decoded1[0]["status"] as? String, "active")
    }

    // MARK: - Child pull resilience

    func testPull_WithFailingChild_SkipsFailedChildAndReturnsSiblings() async throws {
        let configJSON = """
        {
            "service": "test-api",
            "displayName": "Test",
            "version": "1.0",
            "auth": {"type": "bearer", "keychainKey": "test.key"},
            "resources": [
                {
                    "name": "groups",
                    "pull": {
                        "method": "POST",
                        "url": "https://example.com/groups/query",
                        "dataPath": "$.groups"
                    },
                    "fileMapping": {
                        "strategy": "collection",
                        "directory": ".",
                        "filename": "groups.csv",
                        "format": "csv",
                        "idField": "id"
                    },
                    "children": [
                        {
                            "name": "group-members",
                            "pull": {
                                "method": "POST",
                                "url": "https://example.com/groups/{id}/members/query",
                                "dataPath": "$.members"
                            },
                            "fileMapping": {
                                "strategy": "collection",
                                "directory": "groups/{id}",
                                "filename": "members.csv",
                                "format": "csv",
                                "idField": "memberId"
                            }
                        },
                        {
                            "name": "group-posts",
                            "pull": {
                                "method": "POST",
                                "url": "https://example.com/groups/{id}/posts/query",
                                "dataPath": "$.posts"
                            },
                            "fileMapping": {
                                "strategy": "collection",
                                "directory": "groups/{id}/posts",
                                "filename": "posts.csv",
                                "format": "csv",
                                "idField": "postId"
                            }
                        }
                    ]
                }
            ]
        }
        """

        let config = try JSONDecoder().decode(AdapterConfig.self, from: Data(configJSON.utf8))
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == "groups" }))

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let client = HTTPClient(session: session)
        let engine = AdapterEngine(config: config, serviceDir: tempDir, httpClient: client)

        MockURLProtocol.requestHandler = { request in
            let url = request.url!.absoluteString
            if url.contains("/groups/query") {
                let body = #"{"groups":[{"id":"g1","name":"Alpha"},{"id":"g2","name":"Beta"}]}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                return (response, Data(body.utf8))
            } else if url.contains("/members/query") {
                let body = #"{"members":[{"memberId":"m1","role":{"value":"MEMBER"}}]}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
                return (response, Data(body.utf8))
            } else if url.contains("/posts/query") {
                // Simulates a feature endpoint that doesn't exist on this site
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!
                return (response, Data("Not Found".utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (response, Data("{}".utf8))
        }

        // Must NOT throw — failing children are non-fatal
        let result = try await engine.pull(resource: resource)

        // Parent CSV present
        XCTAssertTrue(result.files.contains(where: { $0.relativePath == "groups.csv" }),
                      "Expected groups.csv from parent pull")

        // Successful child (members) present for both groups
        let memberFiles = result.files.filter { $0.relativePath.hasSuffix("members.csv") }
        XCTAssertEqual(memberFiles.count, 2, "Expected one members.csv per group")

        // Failed child (posts) absent — gracefully skipped
        let postFiles = result.files.filter { $0.relativePath.hasSuffix("posts.csv") }
        XCTAssertTrue(postFiles.isEmpty, "Expected posts.csv to be absent when child pull returns 404")
    }
}
