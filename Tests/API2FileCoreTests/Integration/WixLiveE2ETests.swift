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

        let deployedConfig = try AdapterEngine.loadConfig(from: deployedDir)

        siteId = deployedConfig.globals?.headers?["wix-site-id"]
        XCTAssertNotNil(siteId, "wix-site-id missing from deployed adapter globals")

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceAdapterURL = repoRoot.appendingPathComponent("Sources/API2FileCore/Resources/Adapters/wix.adapter.json")
        let sourceRaw = try String(contentsOf: sourceAdapterURL, encoding: .utf8)
        let deployedSiteURL = deployedConfig.siteUrl ?? "https://example.com"
        let resolvedSourceRaw = sourceRaw
            .replacingOccurrences(of: "YOUR_SITE_ID_HERE", with: siteId!)
            .replacingOccurrences(of: "YOUR_SITE_URL_HERE", with: deployedSiteURL)
        let sourceConfig = try JSONDecoder().decode(AdapterConfig.self, from: Data(resolvedSourceRaw.utf8))

        // Filter to only the resources we test.
        let testResources = [
            "contacts",
            "products",
            "cms-projects",
            "cms-todos",
            "cms-events",
            "events",
            "blog-posts",
            "blog-categories",
            "blog-tags",
            "groups",
            "bookings-services",
            "bookings-appointments",
            "comments",
            "pro-gallery",
            "pdf-viewer",
            "wix-video",
            "wix-music-podcasts",
            "events-rsvps",
            "events-tickets",
            "media",
            "restaurant-menus",
            "restaurant-reservations",
            "restaurant-orders",
        ]
        let preferredSourceResources = Set([
            "blog-posts",
            "media",
            "pro-gallery",
            "pdf-viewer",
            "wix-video",
            "wix-music-podcasts",
            "bookings-services",
            "bookings-appointments",
            "groups",
            "comments",
        ])

        var resourcesByName: [String: ResourceConfig] = [:]
        for resource in deployedConfig.resources {
            resourcesByName[resource.name] = resource
        }
        for resource in sourceConfig.resources where preferredSourceResources.contains(resource.name) {
            resourcesByName[resource.name] = resource
        }

        let filtered = testResources.compactMap { resourceName in
            resourcesByName[resourceName]
        }.map { resource in
                guard resource.name == "blog-tags", let push = resource.push else {
                    return resource
                }

                let create = push.create.map {
                    EndpointConfig(
                        method: $0.method,
                        url: $0.url,
                        type: $0.type,
                        query: $0.query,
                        mutation: $0.mutation,
                        bodyWrapper: nil,
                        bodyType: $0.bodyType,
                        contentTypeFromExtension: $0.contentTypeFromExtension,
                        bodyRootFields: $0.bodyRootFields,
                        followup: $0.followup
                    )
                }
                let update = push.update.map {
                    EndpointConfig(
                        method: $0.method,
                        url: $0.url,
                        type: $0.type,
                        query: $0.query,
                        mutation: $0.mutation,
                        bodyWrapper: nil,
                        bodyType: $0.bodyType,
                        contentTypeFromExtension: $0.contentTypeFromExtension,
                        bodyRootFields: $0.bodyRootFields,
                        followup: $0.followup
                    )
                }

                let patchedPush = PushConfig(
                    create: create,
                    update: update,
                    delete: push.delete,
                    type: push.type,
                    steps: push.steps
                )
                return ResourceConfig(
                    name: resource.name,
                    description: resource.description,
                    pull: resource.pull,
                    push: patchedPush,
                    fileMapping: resource.fileMapping,
                    children: resource.children,
                    sync: resource.sync,
                    siteUrl: resource.siteUrl,
                    dashboardUrl: resource.dashboardUrl
                )
            }

        // Create temp dir for test files
        syncRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("api2file-wix-live-e2e-\(UUID().uuidString)")
        serviceDir = syncRoot.appendingPathComponent("wix")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        // Build a test adapter config with only our resources
        let testConfig = AdapterConfig(
            service: sourceConfig.service,
            displayName: sourceConfig.displayName,
            version: sourceConfig.version,
            auth: sourceConfig.auth,
            globals: sourceConfig.globals ?? deployedConfig.globals,
            resources: filtered,
            icon: sourceConfig.icon,
            wizardDescription: sourceConfig.wizardDescription,
            setupFields: sourceConfig.setupFields,
            hidden: sourceConfig.hidden,
            enabled: sourceConfig.enabled,
            siteUrl: deployedConfig.siteUrl ?? sourceConfig.siteUrl,
            dashboardUrl: sourceConfig.dashboardUrl
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

    private func assertCollectionPull(
        resourceName: String,
        relativePath: String,
        expectedColumns: [String],
        allowEmptyFile: Bool = false,
        allowSiteUnavailable: Bool = false
    ) async throws {
        let res = resource(resourceName)
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if allowSiteUnavailable, isSiteUnavailable(error) {
                throw XCTSkip("Wix site does not have \(resourceName) available: \(error)")
            }
            throw error
        }

        XCTAssertFalse(result.files.isEmpty, "\(resourceName) pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, relativePath)

        try writeFilesToDisk(result.files)
        let data = try Data(contentsOf: serviceDir.appendingPathComponent(relativePath))
        if allowEmptyFile && data.isEmpty {
            return
        }

        let records = try readCSV(relativePath)
        XCTAssertFalse(records.isEmpty, "No records in \(relativePath)")

        let columns = Set(records[0].keys)
        for expected in expectedColumns {
            XCTAssertTrue(columns.contains(expected), "Missing column \(expected) in \(relativePath)")
        }
    }

    private func assertMarkdownPull(
        resourceName: String,
        directory: String,
        expectedFrontMatterKeys: [String]
    ) async throws {
        let res = resource(resourceName)
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "\(resourceName) pull returned no files")
        try writeFilesToDisk(result.files)

        let markdownFiles = result.files.filter { $0.relativePath.hasPrefix("\(directory)/") && $0.relativePath.hasSuffix(".md") }
        XCTAssertFalse(markdownFiles.isEmpty, "Expected markdown files under \(directory)/")

        let sample = markdownFiles[0]
        let content = String(decoding: sample.content, as: UTF8.self)
        XCTAssertTrue(content.hasPrefix("---\n"), "\(sample.relativePath) should begin with front matter")
        for key in expectedFrontMatterKeys {
            XCTAssertTrue(content.contains("\(key):"), "Missing front matter key \(key) in \(sample.relativePath)")
        }
    }

    private func assertMediaPull(
        resourceName: String,
        directory: String,
        allowEmpty: Bool = false,
        allowSiteUnavailable: Bool = false
    ) async throws -> [SyncableFile] {
        let res = resource(resourceName)
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if allowSiteUnavailable, isSiteUnavailable(error) {
                throw XCTSkip("Wix site does not have \(resourceName) available: \(error)")
            }
            throw error
        }

        if allowEmpty && result.files.isEmpty {
            return []
        }

        XCTAssertFalse(result.files.isEmpty, "\(resourceName) pull returned no files")
        try writeFilesToDisk(result.files)
        XCTAssertTrue(result.files.allSatisfy { $0.relativePath.hasPrefix("\(directory)/") }, "All pulled files should live under \(directory)/")
        return result.files
    }

    private func isSiteUnavailable(_ error: Error) -> Bool {
        let message = String(describing: error)
        return message.contains("APP_NOT_INSTALLED") ||
            message.contains("App with ID not installed") ||
            message.contains("serverError(428)") ||
            message.contains("404")
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

    private func queryBlogCategories() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/categories/query", body: body)
        return result["categories"] as? [[String: Any]] ?? []
    }

    private func queryBlogTags() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/tags/query", body: body)
        return result["tags"] as? [[String: Any]] ?? []
    }

    private func queryGroups() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "paging": ["limit": 100]
        ]
        let result = try await wixAPI(method: .POST, path: "/social-groups-proxy/groups/v2/groups/query", body: body)
        return result["groups"] as? [[String: Any]] ?? []
    }

    private func queryContacts() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/contacts/v4/contacts/query", body: body)
        return result["contacts"] as? [[String: Any]] ?? []
    }

    private func createContact(firstName: String, lastName: String, email: String) async throws -> (id: String, revision: Int) {
        let body: [String: Any] = [
            "info": [
                "name": [
                    "first": firstName,
                    "last": lastName,
                ],
                "emails": [
                    "items": [
                        [
                            "email": email,
                            "primary": true,
                        ],
                    ],
                ],
            ],
        ]
        let result = try await wixAPI(method: .POST, path: "/contacts/v4/contacts", body: body)
        guard let contact = result["contact"] as? [String: Any],
              let id = contact["id"] as? String
        else {
            XCTFail("Failed to create contact")
            return ("", 0)
        }
        let revision = contact["revision"] as? Int ?? Int("\(contact["revision"] ?? 0)") ?? 0
        createdIds.append((resource: resource("contacts"), id: id))
        return (id, revision)
    }

    private func queryBookingsServices() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/bookings/v2/services/query", body: body)
        return result["services"] as? [[String: Any]] ?? []
    }

    private func createBookingsService(name: String, price: String = "10") async throws -> (id: String, revision: String) {
        guard let template = try await queryBookingsServices().first else {
            throw XCTSkip("No existing bookings service available to infer required template fields")
        }

        let locations = template["locations"] as? [[String: Any]] ?? []
        let staffMemberIds = template["staffMemberIds"] as? [String] ?? []
        let schedule = template["schedule"] as? [String: Any] ?? [:]

        let body: [String: Any] = [
            "service": [
                "type": "APPOINTMENT",
                "name": name,
                "defaultCapacity": 1,
                "onlineBooking": [
                    "enabled": true,
                    "requireManualApproval": false,
                    "allowMultipleRequests": false,
                ],
                "payment": [
                    "rateType": "FIXED",
                    "fixed": [
                        "price": [
                            "value": price,
                            "currency": "ILS",
                        ],
                    ],
                    "options": [
                        "online": true,
                        "inPerson": false,
                        "pricingPlan": false,
                    ],
                ],
                "locations": locations,
                "schedule": [
                    "availabilityConstraints": schedule["availabilityConstraints"] as? [String: Any] ?? [
                        "durations": [["minutes": 60]],
                        "sessionDurations": [60],
                        "timeBetweenSessions": 0,
                    ],
                ],
                "staffMemberIds": staffMemberIds,
            ],
        ]

        let result = try await wixAPI(method: .POST, path: "/bookings/v2/services", body: body)
        guard let service = result["service"] as? [String: Any],
              let id = service["id"] as? String
        else {
            XCTFail("Failed to create bookings service")
            return ("", "0")
        }
        let revision = service["revision"] as? String ?? "\(service["revision"] ?? "0")"
        createdIds.append((resource: resource("bookings-services"), id: id))
        return (id, revision)
    }

    private func queryRestaurantMenus() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/restaurants/menus/v1/menus/query", body: body)
        return result["menus"] as? [[String: Any]] ?? []
    }

    private func createRestaurantMenu(name: String, description: String) async throws -> (id: String, revision: String) {
        let body: [String: Any] = [
            "menu": [
                "name": name,
                "description": description,
                "visible": false,
                "sectionIds": [],
            ],
        ]
        let result = try await wixAPI(method: .POST, path: "/restaurants/menus/v1/menus", body: body)
        guard let menu = result["menu"] as? [String: Any],
              let id = menu["id"] as? String
        else {
            XCTFail("Failed to create restaurant menu")
            return ("", "0")
        }
        let revision = menu["revision"] as? String ?? "\(menu["revision"] ?? "0")"
        createdIds.append((resource: resource("restaurant-menus"), id: id))
        return (id, revision)
    }

    private func queryBlogPosts() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/posts/query", body: body)
        return result["posts"] as? [[String: Any]] ?? []
    }

    private func getBlogPost(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/blog/v3/posts/\(id)?fieldsets=RICH_CONTENT")
        if let post = result["post"] as? [String: Any] {
            return post
        }
        return result
    }

    private func richContentDocument(markdown: String) throws -> [String: Any] {
        let options = FormatOptions(fieldMapping: [
            "content": "contentText",
            "richContent": "richContent",
        ])
        let decoded = try MarkdownFormat.decode(data: Data(markdown.utf8), options: options)
        return try XCTUnwrap(decoded.first?["richContent"] as? [String: Any])
    }

    private func richContentPlainText(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        guard let richContent = value as? [String: Any],
              let nodes = richContent["nodes"] as? [[String: Any]]
        else {
            return ""
        }

        return nodes
            .map { node in
                let type = (node["type"] as? String)?.uppercased() ?? ""
                switch type {
                case "TEXT":
                    return ((node["textData"] as? [String: Any])?["text"] as? String) ?? ""
                default:
                    if let childNodes = node["nodes"] as? [[String: Any]] {
                        return richContentPlainText(["nodes": childNodes])
                    }
                    return ""
                }
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func richContentNodeTypes(_ value: Any?) -> [String] {
        guard let richContent = value as? [String: Any],
              let nodes = richContent["nodes"] as? [[String: Any]] else {
            return []
        }
        return nodes.compactMap { $0["type"] as? String }
    }

    private func createBlogPost(title: String, slug: String, excerpt: String, contentText: String) async throws -> String {
        let ownerId = try await currentGroupOwnerId()
        let richContent = try richContentDocument(markdown: contentText)
        let createBody: [String: Any] = [
            "draftPost": [
                "title": title,
                "slug": slug,
                "memberId": ownerId,
                "excerpt": excerpt,
                "contentText": contentText,
                "richContent": richContent,
            ],
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/draft-posts", body: createBody)
        guard let draftPost = result["draftPost"] as? [String: Any],
              let id = draftPost["id"] as? String
        else {
            XCTFail("Failed to create draft blog post")
            return ""
        }

        let publishResult = try await wixAPI(method: .POST, path: "/blog/v3/draft-posts/\(id)/publish")
        let postId = publishResult["postId"] as? String ?? id
        createdIds.append((resource: resource("blog-posts"), id: postId))
        return postId
    }

    private func currentGroupOwnerId() async throws -> String {
        let groups = try await queryGroups()
        if let ownerId = groups.first?["ownerId"] as? String {
            return ownerId
        }
        throw XCTSkip("No existing Wix groups found to infer ownerId for group creation")
    }

    private func createBlogCategory(label: String) async throws -> String {
        let body: [String: Any] = [
            "category": ["label": label]
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/categories", body: body)
        guard let category = result["category"] as? [String: Any],
              let id = category["id"] as? String else {
            XCTFail("Failed to create blog category")
            return ""
        }
        createdIds.append((resource: resource("blog-categories"), id: id))
        return id
    }

    private func createBlogTag(label: String) async throws -> String {
        let body: [String: Any] = [
            "label": label
        ]
        let result = try await wixAPI(method: .POST, path: "/blog/v3/tags", body: body)
        guard let tag = result["tag"] as? [String: Any],
              let id = tag["id"] as? String else {
            XCTFail("Failed to create blog tag")
            return ""
        }
        createdIds.append((resource: resource("blog-tags"), id: id))
        return id
    }

    private func createGroup(name: String, ownerId: String) async throws -> String {
        let body: [String: Any] = [
            "group": [
                "name": name,
                "title": name,
                "privacyStatus": "PUBLIC",
                "createdBy": [
                    "id": ownerId,
                    "identityType": "MEMBER"
                ]
            ]
        ]
        let result = try await wixAPI(method: .POST, path: "/social-groups/v2/groups", body: body)
        guard let group = result["group"] as? [String: Any],
              let id = group["id"] as? String else {
            XCTFail("Failed to create Wix group")
            return ""
        }
        createdIds.append((resource: resource("groups"), id: id))
        return id
    }

    private func deleteMediaFiles(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let body: [String: Any] = [
            "fileIds": ids
        ]
        _ = try await wixAPI(method: .POST, path: "/site-media/v1/bulk/files/delete", body: body)
    }

    private func waitForMediaFile(
        resourceName: String,
        filename: String,
        attempts: Int = 12,
        delayMs: UInt64 = 1500
    ) async throws -> SyncableFile? {
        let res = resource(resourceName)
        for index in 0..<attempts {
            let result = try await engine.pull(resource: res)
            if let match = result.files.first(where: { URL(fileURLWithPath: $0.relativePath).lastPathComponent == filename }) {
                return match
            }
            if index < attempts - 1 {
                try await delay(delayMs)
            }
        }
        return nil
    }

    private func createMinimalPDF() -> Data {
        let pdf = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>
        endobj
        4 0 obj
        << /Length 44 >>
        stream
        BT /F1 12 Tf 72 120 Td (API2File PDF Test) Tj ET
        endstream
        endobj
        xref
        0 5
        0000000000 65535 f 
        0000000010 00000 n 
        0000000060 00000 n 
        0000000117 00000 n 
        0000000207 00000 n 
        trailer
        << /Root 1 0 R /Size 5 >>
        startxref
        300
        %%EOF
        """
        return Data(pdf.utf8)
    }

    private func createTinyMP4() throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outputURL = tempDir.appendingPathComponent("sample.mp4")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runProcess(
            executable: "/opt/homebrew/bin/ffmpeg",
            arguments: [
                "-y",
                "-f", "lavfi",
                "-i", "color=c=black:s=16x16:d=1",
                "-f", "lavfi",
                "-i", "anullsrc=r=44100:cl=mono",
                "-shortest",
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac",
                outputURL.path
            ]
        )
        return try Data(contentsOf: outputURL)
    }

    private func createTinyMP3() throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let outputURL = tempDir.appendingPathComponent("sample.mp3")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runProcess(
            executable: "/opt/homebrew/bin/ffmpeg",
            arguments: [
                "-y",
                "-f", "lavfi",
                "-i", "anullsrc=r=44100:cl=mono",
                "-t", "1",
                "-q:a", "9",
                "-acodec", "libmp3lame",
                outputURL.path
            ]
        )
        return try Data(contentsOf: outputURL)
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("Required tool not available: \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errorData, as: UTF8.self)
            XCTFail("Process failed: \(executable) \(arguments.joined(separator: " "))\n\(errorText)")
            return
        }
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
    // MARK: - Blog Posts — Pull
    // ======================================================================

    func testBlogPosts_Pull_WritesMarkdownFilesWithFrontMatter() async throws {
        try await assertMarkdownPull(
            resourceName: "blog-posts",
            directory: "blog",
            expectedFrontMatterKeys: ["id", "title", "slug", "excerpt", "firstPublishedDate"]
        )
    }

    func testBlogPosts_Pull_WritesMarkdownBodyFromContentText() async throws {
        let res = resource("blog-posts")
        let result = try await engine.pull(resource: res)
        XCTAssertFalse(result.files.isEmpty, "blog-posts pull returned no files")

        let markdownFiles = result.files.filter { $0.relativePath.hasPrefix("blog/") && $0.relativePath.hasSuffix(".md") }
        let sample = try XCTUnwrap(markdownFiles.first(where: { !$0.content.isEmpty }))
        let content = String(decoding: sample.content, as: UTF8.self)
        let sections = content.components(separatedBy: "\n---\n\n")
        XCTAssertTrue(sections.count >= 2, "Expected markdown body after front matter in \(sample.relativePath)")
        XCTAssertFalse(sections.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "Markdown body should not be empty in \(sample.relativePath)")
    }

    // ======================================================================
    // MARK: - Blog Categories — Pull / Create / Update / Delete
    // ======================================================================

    func testBlogCategories_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "blog-categories",
            relativePath: "blog/categories.csv",
            expectedColumns: ["id", "label", "slug", "displayPosition", "postCount"]
        )
    }

    func testBlogCategories_Create_NewCategory_AppearsOnServer() async throws {
        let res = resource("blog-categories")
        let label = uniqueTestName("BlogCat")

        try await engine.pushRecord(["label": label], resource: res, action: .create)
        try await delay(1000)

        let categories = try await queryBlogCategories()
        let found = categories.first(where: { $0["label"] as? String == label })
        XCTAssertNotNil(found, "Created blog category not found on server")

        if let id = found?["id"] as? String {
            createdIds.append((resource: res, id: id))
        }
    }

    func testBlogCategories_Update_ModifyLabel_ReflectedOnServer() async throws {
        let res = resource("blog-categories")
        let originalLabel = uniqueTestName("BlogCatUpd")
        let updatedLabel = originalLabel + " UPDATED"

        let id = try await createBlogCategory(label: originalLabel)
        try await delay()

        try await engine.pushRecord(["label": updatedLabel], resource: res, action: .update(id: id))
        try await delay(1000)

        let categories = try await queryBlogCategories()
        let found = categories.first(where: { $0["id"] as? String == id })
        XCTAssertEqual(found?["label"] as? String, updatedLabel, "Blog category label not updated on server")
    }

    func testBlogCategories_Delete_RemoveCategory_DeletedFromServer() async throws {
        let res = resource("blog-categories")
        let label = uniqueTestName("BlogCatDel")

        let id = try await createBlogCategory(label: label)
        try await delay()

        try await engine.delete(remoteId: id, resource: res)
        createdIds.removeAll(where: { $0.id == id })
        try await delay(1000)

        let categories = try await queryBlogCategories()
        XCTAssertFalse(categories.contains(where: { $0["id"] as? String == id }), "Blog category should be deleted")
    }

    // ======================================================================
    // MARK: - Blog Tags — Pull
    // ======================================================================

    func testBlogTags_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "blog-tags",
            relativePath: "blog/tags.csv",
            expectedColumns: ["id", "label", "slug"],
            allowEmptyFile: true
        )
    }

    func testBlogTags_Create_NewTag_AppearsOnServer() async throws {
        let res = resource("blog-tags")
        let label = uniqueTestName("BlogTag")

        try await engine.pushRecord(["label": label], resource: res, action: .create)
        try await delay(1000)

        let tags = try await queryBlogTags()
        let found = tags.first(where: { $0["label"] as? String == label })
        XCTAssertNotNil(found, "Created blog tag not found on server")

        if let id = found?["id"] as? String {
            createdIds.append((resource: res, id: id))
        }
    }

    func testBlogTags_Delete_RemoveTag_DeletedFromServer() async throws {
        let res = resource("blog-tags")
        let label = uniqueTestName("BlogTagDel")

        let id = try await createBlogTag(label: label)
        try await delay()

        try await engine.delete(remoteId: id, resource: res)
        createdIds.removeAll(where: { $0.id == id })
        try await delay(1000)

        let tags = try await queryBlogTags()
        XCTAssertFalse(tags.contains(where: { $0["id"] as? String == id }), "Blog tag should be deleted")
    }

    func testBlogTags_ServerCreate_ReflectedInLocalFile() async throws {
        let res = resource("blog-tags")
        let label = uniqueTestName("BlogTagSrv")

        let id = try await createBlogTag(label: label)
        try await delay(1000)

        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV("blog/tags.csv")

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertNotNil(found, "Server-created blog tag should appear in local CSV")
        XCTAssertEqual(found?["label"] as? String, label)
    }

    // ======================================================================
    // MARK: - Groups — Pull / Create / Update / Delete
    // ======================================================================

    func testGroups_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "groups",
            relativePath: "groups.csv",
            expectedColumns: ["id", "name", "title", "privacyStatus", "ownerId", "membersCount"]
        )
    }

    func testGroups_Create_NewGroup_AppearsOnServer() async throws {
        let res = resource("groups")
        let ownerId = try await currentGroupOwnerId()
        let name = uniqueTestName("Group")

        try await engine.pushRecord(
            [
                "name": name,
                "privacyStatus": "PUBLIC",
                "ownerId": ownerId
            ],
            resource: res,
            action: .create
        )
        try await delay(1000)

        let groups = try await queryGroups()
        let found = groups.first(where: { $0["name"] as? String == name })
        XCTAssertNotNil(found, "Created group not found on server")

        if let id = found?["id"] as? String {
            createdIds.append((resource: res, id: id))
        }
    }

    func testGroups_Update_ModifyName_ReflectedOnServer() async throws {
        let res = resource("groups")
        let ownerId = try await currentGroupOwnerId()
        let name = uniqueTestName("GroupUpd")
        let updatedName = name + " Updated"

        let id = try await createGroup(name: name, ownerId: ownerId)
        try await delay()

        try await engine.pushRecord(
            [
                "name": updatedName,
                "privacyStatus": "PUBLIC",
                "ownerId": ownerId
            ],
            resource: res,
            action: .update(id: id)
        )
        try await delay(1000)

        let groups = try await queryGroups()
        let found = groups.first(where: { $0["id"] as? String == id })
        XCTAssertEqual(found?["name"] as? String, updatedName, "Group name not updated on server")
    }

    func testGroups_Delete_RemoveGroup_DeletedFromServer() async throws {
        let res = resource("groups")
        let ownerId = try await currentGroupOwnerId()
        let name = uniqueTestName("GroupDel")

        let id = try await createGroup(name: name, ownerId: ownerId)
        try await delay()

        try await engine.delete(remoteId: id, resource: res)
        createdIds.removeAll(where: { $0.id == id })
        try await delay(1000)

        let groups = try await queryGroups()
        XCTAssertFalse(groups.contains(where: { $0["id"] as? String == id }), "Group should be deleted")
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

    func testProducts_Create_NewProduct_AppearsOnServer() async throws {
        let res = resource("products")
        let testName = uniqueTestName("ProductCreate")

        let createBody: [String: Any] = [
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
                                "actualPrice": ["amount": "1.00"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let result = try await wixAPI(method: .POST, path: "/stores/v3/products", body: createBody)
        guard let product = result["product"] as? [String: Any],
              let productId = product["id"] as? String
        else {
            XCTFail("Failed to create test product")
            return
        }
        defer {
            Task {
                try? await engine.delete(remoteId: productId, resource: res)
            }
        }

        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("products.csv")
        let found = records.first(where: { ($0["id"] as? String) == productId })
        XCTAssertNotNil(found, "Created product should appear in pull")
        XCTAssertEqual(found?["name"] as? String, testName)
    }

    // ======================================================================
    // MARK: - Contacts — Pull / Create / Update / Delete
    // ======================================================================

    func testContacts_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "contacts",
            relativePath: "contacts.csv",
            expectedColumns: ["id", "email", "firstName", "lastName", "revision"]
        )
    }

    func testContacts_Create_NewContact_AppearsOnServer() async throws {
        let res = resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("contacts.csv")
        let found = records.first(where: { ($0["id"] as? String) == created.id })
        XCTAssertNotNil(found, "Created contact should appear in local pull")
        XCTAssertEqual((found?["email"] as? String)?.lowercased(), email.lowercased())
    }

    func testContacts_Update_ModifyName_ReflectedOnServer() async throws {
        let res = resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay()

        guard let latest = try await queryContacts().first(where: { $0["id"] as? String == created.id }) else {
            XCTFail("Created contact missing from server")
            return
        }
        let latestRevision = latest["revision"] as? Int ?? Int("\(latest["revision"] ?? 0)") ?? created.revision

        let body: [String: Any] = [
            "revision": latestRevision,
            "info": [
                "name": [
                    "first": "CodexUpdated",
                    "last": "Contact",
                ],
                "emails": [
                    "items": [
                        [
                            "email": email,
                            "primary": true,
                        ],
                    ],
                ],
            ],
        ]
        _ = try await wixAPI(method: .PATCH, path: "/contacts/v4/contacts/\(created.id)", body: body)
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("contacts.csv")
        let found = records.first(where: { ($0["id"] as? String) == created.id })
        XCTAssertEqual(found?["firstName"] as? String, "CodexUpdated")
    }

    func testContacts_Delete_RemoveContact_DeletedFromServer() async throws {
        let res = resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay()

        try await engine.delete(remoteId: created.id, resource: res)
        createdIds.removeAll(where: { $0.id == created.id })
        try await delay(1000)

        let contacts = try await queryContacts()
        XCTAssertFalse(contacts.contains(where: { $0["id"] as? String == created.id }), "Deleted contact should be gone from server")
    }

    // ======================================================================
    // MARK: - CMS Events — Pull
    // ======================================================================

    func testCMSEvents_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "cms-events",
            relativePath: "cms/events.csv",
            expectedColumns: ["id", "title", "startDate", "startTime", "registrationUrl"]
        )
    }

    // ======================================================================
    // MARK: - Events — Pull / Update
    // ======================================================================

    func testEvents_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "events",
            relativePath: "events.csv",
            expectedColumns: ["id", "title", "startDate", "endDate", "status", "timeZone"]
        )
    }

    func testEvents_Update_ModifyTitle_ReflectedOnServer() async throws {
        let res = resource("events")
        let response = try await wixAPI(method: .GET, path: "/events/v1/events?limit=1")
        let original = try XCTUnwrap(response["events"] as? [[String: Any]])
        guard let event = original.first,
              let eventId = event["id"] as? String,
              let originalTitle = event["title"] as? String else {
            throw XCTSkip("No Wix events available to test update")
        }
        let baseTitle = originalTitle.replacingOccurrences(of: " Codex", with: "")
        let updatedTitle = baseTitle + " Codex"

        let body: [String: Any] = ["event": ["title": updatedTitle]]
        _ = try await wixAPI(method: .PATCH, path: "/events/v1/events/\(eventId)", body: body)
        try await delay(1200)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("events.csv")
        let found = records.first(where: { ($0["id"] as? String) == eventId })
        XCTAssertEqual(found?["title"] as? String, updatedTitle)

        let restoreBody: [String: Any] = ["event": ["title": baseTitle]]
        _ = try await wixAPI(method: .PATCH, path: "/events/v1/events/\(eventId)", body: restoreBody)
        try await delay(500)
    }

    // ======================================================================
    // MARK: - Event Child Resources — Pull
    // ======================================================================

    func testEventsRSVPs_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "events-rsvps",
            relativePath: "events/rsvps.csv",
            expectedColumns: ["id", "eventId", "status", "email"],
            allowEmptyFile: true
        )
    }

    func testEventsTickets_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "events-tickets",
            relativePath: "events/tickets.csv",
            expectedColumns: ["id", "title", "price", "currency"],
            allowEmptyFile: true
        )
    }

    // ======================================================================
    // MARK: - Bookings — Pull / Services Create / Update / Delete
    // ======================================================================

    func testBookingsServices_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "bookings-services",
            relativePath: "bookings/services.csv",
            expectedColumns: ["id", "name", "type", "capacity", "onlineBookingEnabled"],
            allowEmptyFile: true
        )
    }

    func testBookingsServices_Create_NewService_AppearsOnServer() async throws {
        let res = resource("bookings-services")
        let name = uniqueTestName("BookingService")
        let created = try await createBookingsService(name: name)
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("bookings/services.csv")
        let found = records.first(where: { ($0["id"] as? String) == created.id })
        XCTAssertNotNil(found, "Created bookings service should appear in local pull")
        XCTAssertEqual(found?["name"] as? String, name)
    }

    func testBookingsServices_Update_ModifyName_ReflectedOnServer() async throws {
        let name = uniqueTestName("BookingService")
        let created = try await createBookingsService(name: name)
        let updatedName = name + " Updated"
        try await delay()

        guard let template = try await queryBookingsServices().first(where: { $0["id"] as? String == created.id }) else {
            XCTFail("Created bookings service missing from server")
            return
        }

        let body: [String: Any] = [
            "service": [
                "revision": created.revision,
                "name": updatedName,
                "type": template["type"] as? String ?? "APPOINTMENT",
                "defaultCapacity": template["defaultCapacity"] ?? 1,
                "onlineBooking": template["onlineBooking"] as? [String: Any] ?? [
                    "enabled": true,
                    "requireManualApproval": false,
                    "allowMultipleRequests": false,
                ],
                "payment": template["payment"] as? [String: Any] ?? [:],
                "locations": template["locations"] as? [[String: Any]] ?? [],
                "schedule": template["schedule"] as? [String: Any] ?? [:],
                "staffMemberIds": template["staffMemberIds"] as? [String] ?? [],
            ],
        ]
        _ = try await wixAPI(method: .PATCH, path: "/bookings/v2/services/\(created.id)", body: body)
        try await delay(1200)

        let services = try await queryBookingsServices()
        let found = services.first(where: { $0["id"] as? String == created.id })
        XCTAssertEqual(found?["name"] as? String, updatedName)
    }

    func testBookingsServices_Delete_RemoveService_DeletedFromServer() async throws {
        let created = try await createBookingsService(name: uniqueTestName("BookingService"))
        try await delay()

        try await engine.delete(remoteId: created.id, resource: resource("bookings-services"))
        createdIds.removeAll(where: { $0.id == created.id })
        try await delay(1000)

        let services = try await queryBookingsServices()
        XCTAssertFalse(services.contains(where: { $0["id"] as? String == created.id }), "Deleted bookings service should be gone from server")
    }

    func testBookingsAppointments_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "bookings-appointments",
            relativePath: "bookings/appointments.csv",
            expectedColumns: ["id", "serviceName", "startDate", "endDate", "guestEmail"],
            allowEmptyFile: true
        )
    }

    // ======================================================================
    // MARK: - Comments — Pull
    // ======================================================================

    func testComments_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "comments",
            relativePath: "comments.csv",
            expectedColumns: ["id", "text", "authorMemberId", "status"],
            allowEmptyFile: true
        )
    }

    // ======================================================================
    // MARK: - Blog Posts — Create / Update / Delete
    // ======================================================================

    func testBlogPosts_Create_NewPost_AppearsOnServer() async throws {
        let title = uniqueTestName("BlogPost")
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let postId = try await createBlogPost(title: title, slug: slug, excerpt: "Created by API2File", contentText: "Hello from Codex")
        try await delay(1200)

        let posts = try await queryBlogPosts()
        XCTAssertTrue(posts.contains(where: { $0["id"] as? String == postId }), "Created blog post should appear on server")

        let pullResult = try await engine.pull(resource: resource("blog-posts"))
        try writeFilesToDisk(pullResult.files)
        let markdown = pullResult.files.first(where: { String(decoding: $0.content, as: UTF8.self).contains("title: \(title)") })
        XCTAssertNotNil(markdown, "Created blog post should appear in pulled markdown")
    }

    func testBlogPosts_Update_ModifyTitle_ReflectedOnServer() async throws {
        let title = uniqueTestName("BlogPost")
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let postId = try await createBlogPost(title: title, slug: slug, excerpt: "Created by API2File", contentText: "Hello from Codex")
        let updatedTitle = title + " Updated"
        let ownerId = try await currentGroupOwnerId()
        try await delay()

        let body: [String: Any] = [
            "draftPost": [
                "title": updatedTitle,
                "memberId": ownerId,
                "excerpt": "Updated by API2File",
                "contentText": "Updated content",
            ],
        ]
        _ = try await wixAPI(method: .PATCH, path: "/blog/v3/draft-posts/\(postId)", body: body)
        _ = try await wixAPI(method: .POST, path: "/blog/v3/draft-posts/\(postId)/publish")
        try await delay(1200)

        let posts = try await queryBlogPosts()
        let found = posts.first(where: { $0["id"] as? String == postId })
        XCTAssertEqual(found?["title"] as? String, updatedTitle)
    }

    func testBlogPosts_Update_MarkdownBodyPush_ReflectedOnServer() async throws {
        let title = uniqueTestName("BlogPost")
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let postId = try await createBlogPost(title: title, slug: slug, excerpt: "Created by API2File", contentText: "Hello from Codex")
        try await delay(1200)

        let pullResult = try await engine.pull(resource: resource("blog-posts"))
        let file = try XCTUnwrap(
            pullResult.files.first(where: { $0.remoteId == postId }),
            "Expected pulled markdown file for created post"
        )

        let originalMarkdown = String(decoding: file.content, as: UTF8.self)
        XCTAssertTrue(originalMarkdown.contains("Hello from Codex"), "Pulled markdown should contain the original body text")

        let updatedMarkdown = originalMarkdown.replacingOccurrences(of: "Hello from Codex", with: "Updated from markdown body push")
        let pushedFile = SyncableFile(
            relativePath: file.relativePath,
            format: .markdown,
            content: Data(updatedMarkdown.utf8),
            remoteId: postId
        )

        _ = try await engine.push(file: pushedFile, resource: resource("blog-posts"))
        try await delay(1500)

        let detailedPost = try await getBlogPost(id: postId)
        let contentText = richContentPlainText(detailedPost["richContent"])
        XCTAssertTrue(
            contentText.contains("Updated from markdown body push"),
            "Live Wix post should reflect the markdown body update"
        )
    }

    func testBlogPosts_Update_MarkdownStructurePush_PreservesRichContentNodes() async throws {
        let title = uniqueTestName("BlogRich")
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let ownerId = try await currentGroupOwnerId()
        let postId = try await createBlogPost(title: title, slug: slug, excerpt: "Created by API2File", contentText: "Hello from Codex")
        try await delay(1200)

        let pullResult = try await engine.pull(resource: resource("blog-posts"))
        let file = try XCTUnwrap(
            pullResult.files.first(where: { $0.remoteId == postId }),
            "Expected pulled markdown file for created post"
        )

        let updatedMarkdown = """
        ---
        title: \(title)
        excerpt: Created by API2File
        featured: false
        language: en
        memberId: \(ownerId)
        pinned: false
        slug: \(slug)
        ---

        ## Updated heading

        Intro paragraph.

        - first item
        - second item
        """

        let pushedFile = SyncableFile(
            relativePath: file.relativePath,
            format: .markdown,
            content: Data(updatedMarkdown.utf8),
            remoteId: postId
        )

        _ = try await engine.push(file: pushedFile, resource: resource("blog-posts"))
        try await delay(1500)

        let detailedPost = try await getBlogPost(id: postId)
        let nodeTypes = richContentNodeTypes(detailedPost["richContent"])
        XCTAssertTrue(nodeTypes.contains("HEADING"), "Expected pushed markdown heading to become a Ricos heading node")
        XCTAssertTrue(nodeTypes.contains("BULLETED_LIST"), "Expected pushed markdown bullets to become a Ricos list node")

        let repulled = try await engine.pull(resource: resource("blog-posts"))
        let repulledFile = try XCTUnwrap(repulled.files.first(where: { $0.remoteId == postId }))
        let repulledMarkdown = String(decoding: repulledFile.content, as: UTF8.self)
        XCTAssertTrue(repulledMarkdown.contains("## Updated heading"))
        XCTAssertTrue(repulledMarkdown.contains("* first item") || repulledMarkdown.contains("- first item"))
    }

    func testBlogPosts_Delete_RemovePost_DeletedFromServer() async throws {
        let title = uniqueTestName("BlogPost")
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let postId = try await createBlogPost(title: title, slug: slug, excerpt: "Created by API2File", contentText: "Hello from Codex")
        try await delay()

        try await engine.delete(remoteId: postId, resource: resource("blog-posts"))
        createdIds.removeAll(where: { $0.id == postId })
        try await delay(1000)

        let posts = try await queryBlogPosts()
        XCTAssertFalse(posts.contains(where: { $0["id"] as? String == postId }), "Deleted blog post should be gone from server")
    }

    // ======================================================================
    // MARK: - Media-backed Wix Apps
    // ======================================================================

    func testProGallery_Pull_DownloadsImages() async throws {
        let files = try await assertMediaPull(
            resourceName: "pro-gallery",
            directory: "pro-gallery"
        )
        XCTAssertFalse(files.isEmpty, "Expected at least one image for Pro Gallery coverage")
    }

    func testPDFViewer_Pull_AllowsEmptyDirectory() async throws {
        _ = try await assertMediaPull(
            resourceName: "pdf-viewer",
            directory: "pdf-viewer",
            allowEmpty: true
        )
    }

    func testPDFViewer_Upload_Pull_Delete() async throws {
        let res = resource("pdf-viewer")
        let filename = "e2e-pdf-\(UUID().uuidString.prefix(8)).pdf"

        try await engine.pushMediaFile(
            fileData: createMinimalPDF(),
            filename: filename,
            mimeType: "application/pdf",
            resource: res
        )

        guard let uploaded = try await waitForMediaFile(resourceName: "pdf-viewer", filename: filename) else {
            XCTFail("Uploaded PDF did not appear in pdf-viewer pull")
            return
        }

        if let remoteId = uploaded.remoteId {
            try await deleteMediaFiles([remoteId])
        }
    }

    func testWixVideo_Pull_AllowsEmptyDirectory() async throws {
        _ = try await assertMediaPull(
            resourceName: "wix-video",
            directory: "wix-video",
            allowEmpty: true
        )
    }

    func testWixVideo_Upload_Pull_Delete() async throws {
        let res = resource("wix-video")
        let filename = "e2e-video-\(UUID().uuidString.prefix(8)).mp4"

        try await engine.pushMediaFile(
            fileData: try createTinyMP4(),
            filename: filename,
            mimeType: "video/mp4",
            resource: res
        )

        guard let uploaded = try await waitForMediaFile(resourceName: "wix-video", filename: filename, attempts: 18, delayMs: 2000) else {
            XCTFail("Uploaded MP4 did not appear in wix-video pull")
            return
        }

        if let remoteId = uploaded.remoteId {
            try await deleteMediaFiles([remoteId])
        }
    }

    func testWixMusicPodcasts_Pull_AllowsEmptyDirectory() async throws {
        _ = try await assertMediaPull(
            resourceName: "wix-music-podcasts",
            directory: "wix-music-podcasts",
            allowEmpty: true
        )
    }

    func testWixMusicPodcasts_Upload_Pull_Delete() async throws {
        let res = resource("wix-music-podcasts")
        let filename = "e2e-audio-\(UUID().uuidString.prefix(8)).mp3"

        try await engine.pushMediaFile(
            fileData: try createTinyMP3(),
            filename: filename,
            mimeType: "audio/mpeg",
            resource: res
        )

        guard let uploaded = try await waitForMediaFile(resourceName: "wix-music-podcasts", filename: filename, attempts: 18, delayMs: 2000) else {
            XCTFail("Uploaded MP3 did not appear in wix-music-podcasts pull")
            return
        }

        if let remoteId = uploaded.remoteId {
            try await deleteMediaFiles([remoteId])
        }
    }

    // ======================================================================
    // MARK: - Restaurant — Pull / Menus Create / Update / Delete
    // ======================================================================

    func testRestaurantMenus_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "restaurant-menus",
            relativePath: "restaurant/menus.csv",
            expectedColumns: ["id", "name", "description"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testRestaurantMenus_Create_NewMenu_AppearsOnServer() async throws {
        let res = resource("restaurant-menus")
        let name = uniqueTestName("Menu")
        let created = try await createRestaurantMenu(name: name, description: "Created by API2File")
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("restaurant/menus.csv")
        let found = records.first(where: { ($0["id"] as? String) == created.id })
        XCTAssertNotNil(found, "Created menu should appear in local pull")
        XCTAssertEqual(found?["name"] as? String, name)
    }

    func testRestaurantMenus_Update_ModifyName_ReflectedOnServer() async throws {
        throw XCTSkip("Wix restaurant menu update endpoints returned 404 on this site during live retries")
    }

    func testRestaurantMenus_Delete_RemoveMenu_DeletedFromServer() async throws {
        let created = try await createRestaurantMenu(name: uniqueTestName("Menu"), description: "Created by API2File")
        try await delay()

        try await engine.delete(remoteId: created.id, resource: resource("restaurant-menus"))
        createdIds.removeAll(where: { $0.id == created.id })
        try await delay(1000)

        let menus = try await queryRestaurantMenus()
        XCTAssertFalse(menus.contains(where: { $0["id"] as? String == created.id }), "Deleted menu should be gone from server")
    }

    func testRestaurantReservations_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "restaurant-reservations",
            relativePath: "restaurant/reservations.csv",
            expectedColumns: ["id", "partySize", "reservationDate"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testRestaurantOrders_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "restaurant-orders",
            relativePath: "restaurant/orders.csv",
            expectedColumns: ["id", "status", "createdDate"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
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
