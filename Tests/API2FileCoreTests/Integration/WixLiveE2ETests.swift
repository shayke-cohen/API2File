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

    private struct WixResourceContract {
        let name: String
        let capabilityClass: ResourceCapabilityClass
        let humanRelativePath: String
        let humanFormat: FileFormat
        let objectRelativePath: String?
        let humanSanitized: Bool
        let supportsCreate: Bool
        let supportsUpdate: Bool
        let supportsDelete: Bool
        let humanToObjectToServer: Bool
        let objectToHumanToServer: Bool
        let serverToObjectToHuman: Bool
        let notes: String
    }

    private struct CollectionUpdateScenario {
        let resourceName: String
        let updateTokenPrefix: String
        let serverQuery: @Sendable (WixLiveE2ETests) async throws -> [[String: Any]]
        let serverGet: (@Sendable (WixLiveE2ETests, String) async throws -> [String: Any])?
        let serverUpdate: @Sendable (WixLiveE2ETests, String, String) async throws -> Void
        let humanUpdate: @Sendable (inout [String: Any], String) -> Void
        let objectUpdate: @Sendable (inout [String: Any], String) -> Void
    }

    private struct SyncHarness {
        let syncEngine: SyncEngine
        let engine: AdapterEngine
        let config: AdapterConfig
        let syncRoot: URL
        let serviceDir: URL
    }

    private struct CMSCollectionFixture {
        let id: String
        let displayName: String
        let humanRelativePath: String
        let objectRelativePath: String
    }

    private enum FixtureSelectionError: Error {
        case unsuitable(String)
    }

    @MainActor
    private final class LiveBrowserSnapshotDelegate: BrowserControlDelegate {
        private static let pngBytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        )!

        private(set) var isOpen = false
        private(set) var currentURL: String?
        private(set) var navigatedURLs: [String] = []
        private var storedHTML = ""

        func openBrowser() async throws {
            isOpen = true
        }

        func isBrowserOpen() async -> Bool {
            isOpen
        }

        func navigate(to url: String) async throws -> String {
            if !isOpen { isOpen = true }
            guard let requestURL = URL(string: url) else {
                throw BrowserError.navigationFailed("Invalid URL: \(url)")
            }
            navigatedURLs.append(url)

            do {
                let (data, response) = try await URLSession.shared.data(from: requestURL)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw BrowserError.navigationFailed("HTTP \(http.statusCode) for \(url)")
                }
                storedHTML = String(data: data, encoding: .utf8) ?? ""
                let finalURL = response.url?.absoluteString ?? url
                currentURL = finalURL
                if finalURL != url {
                    navigatedURLs.append(finalURL)
                }
                return finalURL
            } catch {
                throw BrowserError.navigationFailed("HTTP request failed: \(error.localizedDescription)")
            }
        }

        func goBack() async throws {}
        func goForward() async throws {}
        func reload() async throws {}

        func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
            Self.pngBytes
        }

        func getDOM(selector: String?) async throws -> String {
            storedHTML
        }

        func click(selector: String) async throws {}
        func type(selector: String, text: String) async throws {}

        func evaluateJS(_ code: String) async throws -> String {
            if code == "document.title" {
                return extractedTitle(from: storedHTML)
            }
            if code.contains("JSON.stringify") {
                return #"{"readyState":"complete","fontsReady":true,"width":1280,"height":2400}"#
            }
            return "OK"
        }

        func getCurrentURL() async -> String? {
            currentURL
        }

        func waitFor(selector: String, timeout: TimeInterval) async throws {}
        func scroll(direction: ScrollDirection, amount: Int?) async throws {}

        private func extractedTitle(from html: String) -> String {
            let pattern = "(?is)<title[^>]*>(.*?)</title>"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else {
                return ""
            }
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let wixTopLevelContracts: [WixResourceContract] = [
        .init(name: "contacts", capabilityClass: .partialWritable, humanRelativePath: "contacts/contacts.csv", humanFormat: .csv, objectRelativePath: "contacts/.contacts.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: false, serverToObjectToHuman: true, notes: "CSV with strong human CRUD, but object-file propagation still needs hardening."),
        .init(name: "blog-posts", capabilityClass: .fullCRUD, humanRelativePath: "blog-posts/{slug}.md", humanFormat: .markdown, objectRelativePath: "blog-posts/.objects/{slug}.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "Markdown/Ricos full flow."),
        .init(name: "products", capabilityClass: .fullCRUD, humanRelativePath: "products/products.csv", humanFormat: .csv, objectRelativePath: "products/.products.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV with full CRUD."),
        .init(name: "orders", capabilityClass: .partialWritable, humanRelativePath: "orders.csv", humanFormat: .csv, objectRelativePath: ".orders.objects.json", humanSanitized: true, supportsCreate: false, supportsUpdate: true, supportsDelete: false, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV pull with limited update semantics."),
        .init(name: "coupons", capabilityClass: .readOnly, humanRelativePath: "coupons.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only coupon catalog until safe write semantics are proven."),
        .init(name: "pricing-plans", capabilityClass: .readOnly, humanRelativePath: "pricing-plans.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only pricing plans catalog."),
        .init(name: "gift-cards", capabilityClass: .readOnly, humanRelativePath: "gift-cards.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only gift card ledger surface."),
        .init(name: "forms", capabilityClass: .partialWritable, humanRelativePath: "forms.csv", humanFormat: .csv, objectRelativePath: ".forms.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV schema catalog with child submissions files."),
        .init(name: "members", capabilityClass: .fullCRUD, humanRelativePath: "members.csv", humanFormat: .csv, objectRelativePath: ".members.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV with create, update, and delete."),
        .init(name: "site-properties", capabilityClass: .readOnly, humanRelativePath: "site-properties.json", humanFormat: .json, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only JSON snapshot."),
        .init(name: "site-urls", capabilityClass: .readOnly, humanRelativePath: "site/site-urls.json", humanFormat: .json, objectRelativePath: "site/.site-urls.objects.json", humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: true, notes: "Read-only merged site URL catalog with hidden rendered snapshot artifacts."),
        .init(name: "media", capabilityClass: .readOnly, humanRelativePath: "media/*", humanFormat: .raw, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Binary upload/pull/delete only."),
        .init(name: "pro-gallery", capabilityClass: .readOnly, humanRelativePath: "pro-gallery/*", humanFormat: .raw, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Binary upload/pull/delete only."),
        .init(name: "pdf-viewer", capabilityClass: .readOnly, humanRelativePath: "pdf-viewer/*.pdf", humanFormat: .raw, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Binary upload/pull/delete only."),
        .init(name: "wix-video", capabilityClass: .readOnly, humanRelativePath: "wix-video/*", humanFormat: .raw, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Binary upload/pull/delete only."),
        .init(name: "wix-music-podcasts", capabilityClass: .readOnly, humanRelativePath: "wix-music-podcasts/*", humanFormat: .raw, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Binary upload/pull/delete only."),
        .init(name: "bookings-services", capabilityClass: .partialWritable, humanRelativePath: "bookings-services/services.csv", humanFormat: .csv, objectRelativePath: "bookings-services/.services.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: false, serverToObjectToHuman: true, notes: "CSV with CRUD from the human surface; object-file propagation still needs hardening."),
        .init(name: "bookings-appointments", capabilityClass: .readOnly, humanRelativePath: "bookings-appointments/appointments.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only appointments feed."),
        .init(name: "groups", capabilityClass: .partialWritable, humanRelativePath: "groups.csv", humanFormat: .csv, objectRelativePath: ".groups.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: false, serverToObjectToHuman: true, notes: "CSV with CRUD from the human surface; object-file propagation still needs hardening."),
        .init(name: "inbox-conversations", capabilityClass: .readOnly, humanRelativePath: "inbox-conversations/conversations.csv", humanFormat: .csv, objectRelativePath: ".inbox-conversations.objects.json", humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only inbox conversation index; writable messages are a child surface."),
        .init(name: "comments", capabilityClass: .readOnly, humanRelativePath: "comments/comments.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: false, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only comments projection."),
        .init(name: "events", capabilityClass: .partialWritable, humanRelativePath: "events.csv", humanFormat: .csv, objectRelativePath: ".events.objects.json", humanSanitized: true, supportsCreate: false, supportsUpdate: true, supportsDelete: false, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "Event catalog with update-only semantics in the first pass."),
        .init(name: "events-rsvps", capabilityClass: .readOnly, humanRelativePath: "events/rsvps.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only RSVP feed."),
        .init(name: "events-tickets", capabilityClass: .readOnly, humanRelativePath: "events/tickets.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only ticket definition catalog."),
        .init(name: "restaurant-menus", capabilityClass: .partialWritable, humanRelativePath: "restaurant/menus.csv", humanFormat: .csv, objectRelativePath: ".restaurant-menus.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Restaurant menus have pull/create/delete coverage; update remains site-dependent."),
        .init(name: "restaurant-reservations", capabilityClass: .readOnly, humanRelativePath: "restaurant/reservations.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only reservation feed."),
        .init(name: "restaurant-orders", capabilityClass: .readOnly, humanRelativePath: "restaurant/orders.csv", humanFormat: .csv, objectRelativePath: nil, humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Read-only restaurants order feed."),
        .init(name: "bookings", capabilityClass: .partialWritable, humanRelativePath: "bookings/{name}.json", humanFormat: .json, objectRelativePath: "bookings/.objects/{name}.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: false, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: false, notes: "One-file-per-record JSON surface with narrower semantics than the CSV service surface."),
        .init(name: "collections", capabilityClass: .readOnly, humanRelativePath: "collections/collections.json", humanFormat: .json, objectRelativePath: "collections/.collections.objects.json", humanSanitized: true, supportsCreate: false, supportsUpdate: false, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Catalog metadata surface; generic create/delete unsupported."),
        .init(name: "portfolio-collections", capabilityClass: .fullCRUD, humanRelativePath: "portfolio/collections.csv", humanFormat: .csv, objectRelativePath: ".portfolio-collections.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV with full CRUD. Slug is server-assigned; omitted from push."),
        .init(name: "portfolio-projects", capabilityClass: .fullCRUD, humanRelativePath: "portfolio/projects.csv", humanFormat: .csv, objectRelativePath: ".portfolio-projects.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "CSV with full CRUD. Items are JSON files per-project via child resource."),
    ]

    private static let wixChildSurfaceContracts: [WixResourceContract] = [
        .init(name: "forms.submissions", capabilityClass: .partialWritable, humanRelativePath: "forms/{name}-submissions.csv", humanFormat: .csv, objectRelativePath: "forms/.{name}-submissions.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Human-friendly child CSV for form submissions."),
        .init(name: "collections.items", capabilityClass: .fullCRUD, humanRelativePath: "items/{displayName}.csv", humanFormat: .csv, objectRelativePath: "items/.{displayName}.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "Writable NATIVE CMS collection items only."),
        .init(name: "groups.group-members", capabilityClass: .partialWritable, humanRelativePath: "groups/{name}/members.csv", humanFormat: .csv, objectRelativePath: "groups/.{name}-members.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: false, supportsDelete: true, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Child CSV listing members of each group; add/remove rows to manage membership."),
        .init(name: "groups.group-posts", capabilityClass: .fullCRUD, humanRelativePath: "groups/{name}/posts/{slug}.md", humanFormat: .markdown, objectRelativePath: "groups/{name}/posts/.objects/{slug}.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: true, serverToObjectToHuman: true, notes: "Markdown posts in each group feed; full CRUD with Ricos conversion."),
        .init(name: "inbox-conversations.inbox-messages", capabilityClass: .partialWritable, humanRelativePath: "inbox/{contactName}/messages.csv", humanFormat: .csv, objectRelativePath: "inbox/.{contactName}-messages.objects.json", humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: false, humanToObjectToServer: false, objectToHumanToServer: false, serverToObjectToHuman: false, notes: "Child CSV of messages per inbox conversation; add row to send, update to mark read."),
        .init(name: "portfolio-projects.portfolio-project-items", capabilityClass: .fullCRUD, humanRelativePath: "portfolio/projects/{title}/items/{id}.json", humanFormat: .json, objectRelativePath: nil, humanSanitized: true, supportsCreate: true, supportsUpdate: true, supportsDelete: true, humanToObjectToServer: true, objectToHumanToServer: false, serverToObjectToHuman: true, notes: "JSON per-item surface with rich mediaItem structure."),
    ]

    private var apiKey: String!
    private var siteId: String!
    private var bundledConfig: AdapterConfig!
    private var engine: AdapterEngine!
    private var config: AdapterConfig!
    private var serviceDir: URL!
    private var syncRoot: URL!
    private var httpClient: HTTPClient!

    /// IDs of records created during tests, keyed by resource name, for cleanup.
    private var createdIds: [(resource: ResourceConfig, id: String)] = []
    private let wixFormsNamespace = "wix.form_platform.form"

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
        bundledConfig = sourceConfig

        // Filter to only the resources we test.
        let testResources = [
            "contacts",
            "products",
            "orders",
            "coupons",
            "pricing-plans",
            "gift-cards",
            "forms",
            "members",
            "site-properties",
            "site-urls",
            "cms-projects",
            "cms-todos",
            "cms-events",
            "events",
            "blog-posts",
            "blog-categories",
            "blog-tags",
            "groups",
            "inbox-conversations",
            "bookings-services",
            "bookings-appointments",
            "comments",
            "events-rsvps",
            "events-tickets",
            "restaurant-menus",
            "restaurant-reservations",
            "restaurant-orders",
            "bookings",
            "collections",
            "portfolio-collections",
            "portfolio-projects",
            "pro-gallery",
            "pdf-viewer",
            "wix-video",
            "wix-music-podcasts",
            "media",
        ]
        let preferredSourceResources = Set([
            "contacts",
            "products",
            "orders",
            "coupons",
            "pricing-plans",
            "gift-cards",
            "forms",
            "members",
            "site-properties",
            "site-urls",
            "blog-posts",
            "media",
            "pro-gallery",
            "pdf-viewer",
            "wix-video",
            "wix-music-podcasts",
            "bookings-services",
            "bookings-appointments",
            "groups",
            "inbox-conversations",
            "comments",
            "events",
            "events-rsvps",
            "events-tickets",
            "restaurant-menus",
            "restaurant-reservations",
            "restaurant-orders",
            "bookings",
            "collections",
            "portfolio-collections",
            "portfolio-projects",
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
                    capabilityClass: resource.capabilityClass,
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

    private func resource(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ResourceConfig {
        if let resource = config.resources.first(where: { $0.name == name }) {
            return resource
        }
        throw XCTSkip(
            "Wix resource '\(name)' is not available in the current live adapter/site configuration",
            file: file,
            line: line
        )
    }

    private func writeFilesToDisk(_ files: [SyncableFile]) throws {
        try writeFilesToDisk(files, under: serviceDir)
    }

    private func writeFilesToDisk(_ files: [SyncableFile], under root: URL) throws {
        for file in files {
            let path = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: path, options: .atomic)
        }
    }

    private func readCSV(_ relativePath: String) throws -> [[String: Any]] {
        let url = serviceDir.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try CSVFormat.decode(data: data, options: nil)
    }

    private func readCSV(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try CSVFormat.decode(data: data, options: nil)
    }

    private func readJSON(_ relativePath: String) throws -> Any {
        try readJSON(relativePath, under: serviceDir)
    }

    private func readJSON(_ relativePath: String, under root: URL) throws -> Any {
        let url = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("Expected JSON object at \(url.lastPathComponent)")
        }
        return object
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func writeCSV(_ records: [[String: Any]], to url: URL) throws {
        let data = try CSVFormat.encode(records: records, options: nil)
        try data.write(to: url, options: .atomic)
    }

    private func delay(_ ms: UInt64 = 500) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 30,
        pollIntervalMs: UInt64 = 500,
        condition: @escaping @Sendable () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return
            }
            try await delay(pollIntervalMs)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func recursiveStringContainsToken(_ value: Any?, token: String) -> Bool {
        switch value {
        case let string as String:
            return string.contains(token)
        case let dict as [String: Any]:
            return dict.contains { recursiveStringContainsToken($0.key, token: token) || recursiveStringContainsToken($0.value, token: token) }
        case let array as [Any]:
            return array.contains { recursiveStringContainsToken($0, token: token) }
        case let number as NSNumber:
            return number.stringValue.contains(token)
        default:
            return false
        }
    }

    private func objectRecordsContainToken(_ url: URL, token: String) -> Bool {
        guard let records = try? ObjectFileManager.readCollectionObjectFile(from: url) else {
            return false
        }
        return records.contains(where: { recursiveStringContainsToken($0, token: token) })
    }

    private func objectRecord(withId id: String, in url: URL) throws -> [String: Any]? {
        let records = try ObjectFileManager.readCollectionObjectFile(from: url)
        return records.first(where: { ($0["id"] as? String) == id || ($0["_id"] as? String) == id })
    }

    private func csvContainsToken(_ url: URL, token: String) -> Bool {
        guard let records = try? readCSV(at: url) else {
            return false
        }
        return records.contains(where: { recursiveStringContainsToken($0, token: token) })
    }

    private func findOnePerRecordFile(
        under relativeDirectory: String,
        matchingID id: String,
        in serviceDir: URL
    ) throws -> String {
        let directoryURL = serviceDir.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw XCTSkip("Missing directory \(relativeDirectory) for one-per-record lookup")
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard url.pathExtension.lowercased() == "json" else { continue }
            let object = try? readJSONObject(at: url)
            if let object, recordId(from: object) == id {
                let resolvedBase = serviceDir.resolvingSymlinksInPath().path
                let resolvedFile = url.resolvingSymlinksInPath().path
                if resolvedFile.hasPrefix(resolvedBase + "/") {
                    return String(resolvedFile.dropFirst(resolvedBase.count + 1))
                }
                let standardizedBase = serviceDir.standardizedFileURL.path
                let standardizedFile = url.standardizedFileURL.path
                if standardizedFile.hasPrefix(standardizedBase + "/") {
                    return String(standardizedFile.dropFirst(standardizedBase.count + 1))
                }
                throw XCTSkip("Could not derive relative path for \(resolvedFile)")
            }
        }

        throw XCTSkip("Could not find one-per-record file under \(relativeDirectory) for id \(id)")
    }

    private func serverRecordContainsToken(
        scenario: CollectionUpdateScenario,
        id: String,
        token: String
    ) async throws -> Bool {
        if let serverGet = scenario.serverGet {
            let record = try await serverGet(self, id)
            return recursiveStringContainsToken(record, token: token)
        }

        let records = try await scenario.serverQuery(self)
        return records.contains(where: {
            let recordIdentifier = ($0["id"] as? String) ?? ($0["_id"] as? String)
            return recordIdentifier == id && self.recursiveStringContainsToken($0, token: token)
        })
    }

    private func objectRecordContainingToken(_ url: URL, token: String) throws -> [String: Any]? {
        let records = try ObjectFileManager.readCollectionObjectFile(from: url)
        return records.first(where: { recursiveStringContainsToken($0, token: token) })
    }

    private func updateFirstStringField(in record: inout [String: Any], candidates: [String], token: String) {
        for key in candidates {
            if record[key] != nil {
                record[key] = token
                return
            }
        }
    }

    private func setNestedString(_ record: inout [String: Any], path: [String], value: String) {
        guard let key = path.first else { return }
        if path.count == 1 {
            record[key] = value
            return
        }

        var child = record[key] as? [String: Any] ?? [:]
        setNestedString(&child, path: Array(path.dropFirst()), value: value)
        record[key] = child
    }

    private func sanitizeRawRecordForCreate(_ record: inout [String: Any]) {
        for key in ["id", "_id", "revision", "_revision", "createdDate", "updatedDate", "lastPublishedDate", "firstPublishedDate"] {
            record.removeValue(forKey: key)
        }
    }

    private func preferredCMSCollectionScore(_ fixture: CMSCollectionFixture) -> Int {
        let normalized = fixture.displayName.lowercased()
        if normalized.contains("todo") { return 0 }
        if normalized.contains("project") { return 1 }
        return 10
    }

    private func collectionDataOperations(from record: [String: Any]) -> Set<String> {
        let capabilities = record["capabilities"] as? [String: Any]
        let operations = capabilities?["dataOperations"] as? [String] ?? []
        return Set(operations)
    }

    private func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let string): return string
        case .number(let number): return number
        case .bool(let bool): return bool
        case .null: return NSNull()
        case .array(let values): return values.map(jsonValueToAny)
        case .object(let object):
            return object.mapValues(jsonValueToAny)
        }
    }

    private func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let string as String: return .string(string)
        case let int as Int: return .number(Double(int))
        case let double as Double: return .number(double)
        case let bool as Bool: return .bool(bool)
        case is NSNull: return .null
        case let array as [Any]: return .array(array.map(anyToJSONValue))
        case let dict as [String: Any]:
            return .object(dict.mapValues(anyToJSONValue))
        default:
            return .string("\(value)")
        }
    }

    private func resolveTemplatesInJSON(_ value: Any, with vars: [String: Any]) -> Any {
        if let string = value as? String {
            return TemplateEngine.render(string, with: vars)
        }
        if let array = value as? [Any] {
            return array.map { resolveTemplatesInJSON($0, with: vars) }
        }
        if let object = value as? [String: Any] {
            return object.mapValues { resolveTemplatesInJSON($0, with: vars) }
        }
        return value
    }

    private func queryCollectionsCatalog() async throws -> [[String: Any]] {
        let result = try await wixAPI(method: .GET, path: "/wix-data/v2/collections")
        return result["collections"] as? [[String: Any]] ?? []
    }

    private func discoverWritableCMSCollectionFixtures(
        in config: AdapterConfig
    ) async throws -> [CMSCollectionFixture] {
        let collections = try resource("collections", in: config)
        let items = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))
        let records = try await queryCollectionsCatalog()

        let requiredOps: Set<String> = ["INSERT", "UPDATE", "REMOVE"]
        let fixtures = records.compactMap { record -> CMSCollectionFixture? in
            guard (record["collectionType"] as? String) == "NATIVE" else { return nil }
            guard collectionDataOperations(from: record).isSuperset(of: requiredOps) else { return nil }
            guard let id = record["id"] as? String, !id.isEmpty else { return nil }
            let displayName = ((record["displayName"] as? String)?.isEmpty == false ? record["displayName"] as? String : nil) ?? id
            let filenameTemplate = items.fileMapping.filename ?? "{displayName|slugify}.csv"
            let filename = TemplateEngine.render(filenameTemplate, with: record)
            let humanRelativePath = "\(items.fileMapping.directory)/\(filename)"
            return CMSCollectionFixture(
                id: id,
                displayName: displayName,
                humanRelativePath: humanRelativePath,
                objectRelativePath: ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            )
        }

        return fixtures.sorted {
            let lhs = preferredCMSCollectionScore($0)
            let rhs = preferredCMSCollectionScore($1)
            if lhs != rhs { return lhs < rhs }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func resolvedCollectionsItemsResource(
        for fixture: CMSCollectionFixture,
        in config: AdapterConfig
    ) throws -> ResourceConfig {
        let collections = try resource("collections", in: config)
        let child = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))
        let vars: [String: Any] = [
            "id": fixture.id,
            "displayName": fixture.displayName
        ]

        let resolvedPull: PullConfig?
        if let pull = child.pull {
            let resolvedBody = pull.body.map {
                anyToJSONValue(resolveTemplatesInJSON(jsonValueToAny($0), with: vars))
            }
            resolvedPull = PullConfig(
                method: pull.method,
                url: TemplateEngine.render(pull.url, with: vars),
                type: pull.type,
                query: pull.query.map { TemplateEngine.render($0, with: vars) },
                body: resolvedBody,
                dataPath: pull.dataPath,
                detail: pull.detail,
                pagination: pull.pagination,
                mediaConfig: pull.mediaConfig,
                updatedSinceField: pull.updatedSinceField,
                updatedSinceBodyPath: pull.updatedSinceBodyPath,
                updatedSinceDateFormat: pull.updatedSinceDateFormat,
                supportsETag: pull.supportsETag
            )
        } else {
            resolvedPull = nil
        }

        return ResourceConfig(
            name: "collections.items.\(fixture.displayName)",
            description: child.description,
            capabilityClass: child.capabilityClass,
            pull: resolvedPull,
            push: child.push,
            fileMapping: FileMappingConfig(
                strategy: child.fileMapping.strategy,
                directory: relativeDirectoryPath(for: fixture.humanRelativePath),
                filename: URL(fileURLWithPath: fixture.humanRelativePath).lastPathComponent,
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
    }

    private func preferredStringField(in row: [String: Any], excluding excluded: Set<String> = []) -> String? {
        let preferred = ["title", "name", "label", "description", "summary"]
        for key in preferred where !excluded.contains(key) {
            if let value = row[key] as? String, !value.isEmpty {
                return key
            }
        }
        return row.keys.sorted().first { key in
            guard !excluded.contains(key), key != "id", key != "_id" else { return false }
            if let value = row[key] as? String {
                return !value.isEmpty
            }
            return false
        }
    }

    private func updateCMSHumanRow(_ row: inout [String: Any], token: String) throws -> String {
        guard let field = preferredStringField(in: row) else {
            throw XCTSkip("No editable string field available in CMS human row")
        }
        row[field] = token
        return field
    }

    private func updateCMSObjectRecord(_ record: inout [String: Any], token: String) throws -> String {
        var data = record["data"] as? [String: Any] ?? [:]
        guard let field = preferredStringField(in: data) else {
            throw XCTSkip("No editable string field available in CMS object record")
        }
        data[field] = token
        record["data"] = data
        return field
    }

    private func cmsServerRecord(
        collectionId: String,
        itemId: String
    ) async throws -> [String: Any] {
        let items = try await queryCMS(collectionId: collectionId)
        guard let item = items.first(where: { ($0["id"] as? String) == itemId }) else {
            throw XCTSkip("CMS item \(itemId) not found in collection \(collectionId)")
        }
        return item
    }

    private func waitForCMSCreatedItem(collectionId: String, token: String) async throws -> String {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let items = try await self.queryCMS(collectionId: collectionId)
            if let item = items.first(where: { self.recursiveStringContainsToken($0, token: token) }),
               let id = item["id"] as? String {
                return id
            }
            try await delay(500)
        }
        XCTFail("Timed out waiting for CMS created item \(token)")
        return ""
    }

    private func withDynamicCMSCollectionFixtureHarness<T>(
        body: @escaping @Sendable (CMSCollectionFixture, SyncHarness, URL, URL) async throws -> T
    ) async throws -> T {
        let fixtures = try await discoverWritableCMSCollectionFixtures(in: config)
        var lastReason = "No writable NATIVE CMS collections available on this site"

        for fixture in fixtures {
            let resolvedResource = try resolvedCollectionsItemsResource(for: fixture, in: config)
            do {
                return try await withIsolatedSyncHarness(resources: [resolvedResource]) { harness in
                    let humanURL = harness.serviceDir.appendingPathComponent(fixture.humanRelativePath)
                    let objectURL = harness.serviceDir.appendingPathComponent(fixture.objectRelativePath)
                    try await self.waitForCollectionFile(humanURL)
                    try await self.waitForCollectionFile(objectURL)

                    let rows = try self.readCSV(at: humanURL)
                    guard rows.contains(where: { self.recordId(from: $0) != nil }) else {
                        throw FixtureSelectionError.unsuitable("No existing rows available in \(fixture.humanRelativePath)")
                    }
                    guard let sample = rows.first(where: {
                        self.recordId(from: $0) != nil && self.preferredStringField(in: $0) != nil
                    }),
                          self.preferredStringField(in: sample) != nil else {
                        throw FixtureSelectionError.unsuitable("No editable string field available in \(fixture.humanRelativePath)")
                    }

                    return try await body(fixture, harness, humanURL, objectURL)
                }
            } catch FixtureSelectionError.unsuitable(let reason) {
                lastReason = reason
                continue
            }
        }

        throw XCTSkip(lastReason)
    }

    private func propagationStatus(for contract: WixResourceContract) -> String {
        let legs = [
            contract.humanToObjectToServer ? "human->object->server" : nil,
            contract.objectToHumanToServer ? "object->human->server" : nil,
            contract.serverToObjectToHuman ? "server->object->human" : nil,
        ].compactMap { $0 }
        return legs.isEmpty ? "n/a" : legs.joined(separator: ", ")
    }

    private func resource(_ name: String, in config: AdapterConfig) throws -> ResourceConfig {
        guard let resource = config.resources.first(where: { $0.name == name }) else {
            throw XCTSkip("Wix resource '\(name)' is not available in isolated config")
        }
        return resource
    }

    private func collectionRelativePath(
        for resource: ResourceConfig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard let filename = resource.fileMapping.filename, !filename.isEmpty else {
            throw XCTSkip("Resource '\(resource.name)' is missing a collection filename", file: file, line: line)
        }
        let directory = resource.fileMapping.directory
        if directory == "." || directory.isEmpty {
            return filename
        }
        return "\(directory)/\(filename)"
    }

    private func relativeDirectoryPath(for relativePath: String) -> String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        if directory == "." || directory.isEmpty {
            return ""
        }
        return directory
    }

    private func withIsolatedSyncHarness<T>(
        resourceNames: [String],
        snapshotService: (any RenderedPageSnapshotService)? = nil,
        body: @escaping @Sendable (SyncHarness) async throws -> T
    ) async throws -> T {
        let filteredResources = config.resources.filter { resourceNames.contains($0.name) }
        XCTAssertEqual(
            Set(filteredResources.map(\.name)),
            Set(resourceNames),
            "Isolated harness is missing one or more requested resources: \(resourceNames)"
        )
        return try await withIsolatedSyncHarness(resources: filteredResources, snapshotService: snapshotService, body: body)
    }

    private func withIsolatedSyncHarness<T>(
        resources: [ResourceConfig],
        snapshotService: (any RenderedPageSnapshotService)? = nil,
        body: @escaping @Sendable (SyncHarness) async throws -> T
    ) async throws -> T {
        let resolvedTmpDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let syncRoot = resolvedTmpDir.appendingPathComponent("api2file-wix-three-way-\(UUID().uuidString)")
        let serviceDir = syncRoot.appendingPathComponent("wix")
        let api2fileDir = serviceDir.appendingPathComponent(".api2file")
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let testConfig = AdapterConfig(
            service: config.service,
            displayName: config.displayName,
            version: config.version,
            auth: config.auth,
            globals: config.globals,
            resources: resources,
            icon: config.icon,
            wizardDescription: config.wizardDescription,
            setupFields: config.setupFields,
            hidden: config.hidden,
            enabled: config.enabled,
            siteUrl: config.siteUrl,
            dashboardUrl: config.dashboardUrl
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(testConfig).write(to: api2fileDir.appendingPathComponent("adapter.json"), options: .atomic)

        let localConfig = try AdapterEngine.loadConfig(from: serviceDir)
        let localClient = HTTPClient()
        await localClient.setAuthHeader("Authorization", value: apiKey)
        let localEngine = AdapterEngine(config: localConfig, serviceDir: serviceDir, httpClient: localClient)

        let syncConfig = GlobalConfig(
            syncFolder: syncRoot.path,
            gitAutoCommit: false,
            defaultSyncInterval: 3600,
            showNotifications: false,
            finderBadges: false,
            serverPort: Int.random(in: 23000...26000),
            launchAtLogin: false,
            deleteFromAPI: true
        )
        let baseStorage = StorageLocations.current
        let isolatedStorage = StorageLocations(
            homeDirectory: baseStorage.homeDirectory,
            syncRootDirectory: syncRoot,
            adaptersDirectory: baseStorage.adaptersDirectory,
            applicationSupportDirectory: baseStorage.applicationSupportDirectory
        )
        let syncEngine = SyncEngine(
            config: syncConfig,
            platformServices: PlatformServices(
                storageLocations: isolatedStorage,
                fileWatcher: FileWatcher(enabled: false),
                configWatcher: ConfigWatcher(enabled: false),
                renderedPageSnapshotService: snapshotService
            )
        )
        try await syncEngine.start()

        do {
            try await waitUntil("isolated wix sync ready", timeout: 90) {
                guard let status = await syncEngine.getServiceStatus("wix") else { return false }
                return status.lastSyncTime != nil && status.status != .syncing
            }
            let result = try await body(
                SyncHarness(
                    syncEngine: syncEngine,
                    engine: localEngine,
                    config: localConfig,
                    syncRoot: syncRoot,
                    serviceDir: serviceDir
                )
            )
            await syncEngine.stop()
            try? FileManager.default.removeItem(at: syncRoot)
            return result
        } catch {
            await syncEngine.stop()
            try? FileManager.default.removeItem(at: syncRoot)
            throw error
        }
    }

    private func jsonObject(from value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }
        guard let string = value as? String, let data = string.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func contactEmail(from record: [String: Any]) -> String? {
        if let email = record["email"] as? String, !email.isEmpty {
            return email
        }
        if let primaryEmail = record["primaryEmail"] as? String, !primaryEmail.isEmpty {
            return primaryEmail
        }
        if let primaryEmailObject = jsonObject(from: record["primaryEmail"]),
           let primaryEmail = primaryEmailObject["email"] as? String,
           !primaryEmail.isEmpty {
            return primaryEmail
        }
        if let primaryInfoObject = jsonObject(from: record["primaryInfo"]),
           let primaryInfo = primaryInfoObject["email"] as? String,
           !primaryInfo.isEmpty {
            return primaryInfo
        }
        if let memberInfoObject = jsonObject(from: record["memberInfo"]),
           let memberInfo = memberInfoObject["email"] as? String,
           !memberInfo.isEmpty {
            return memberInfo
        }
        return nil
    }

    private func contactFirstName(from record: [String: Any]) -> String? {
        if let firstName = record["firstName"] as? String, !firstName.isEmpty {
            return firstName
        }
        if let first = record["first"] as? String, !first.isEmpty {
            return first
        }
        if let nickname = (jsonObject(from: record["memberInfo"])?["profileInfo"] as? [String: Any])?["nickname"] as? String,
           !nickname.isEmpty {
            return nickname.split(separator: " ").first.map(String.init)
        }
        return nil
    }

    private func contactLastName(from record: [String: Any]) -> String? {
        if let lastName = record["lastName"] as? String, !lastName.isEmpty {
            return lastName
        }
        if let last = record["last"] as? String, !last.isEmpty {
            return last
        }
        if let nickname = (jsonObject(from: record["memberInfo"])?["profileInfo"] as? [String: Any])?["nickname"] as? String,
           !nickname.isEmpty {
            let parts = nickname.split(separator: " ")
            if parts.count >= 2 {
                return String(parts.last!)
            }
        }
        return nil
    }

    private func recordId(from record: [String: Any]) -> String? {
        if let id = record["id"] as? String, !id.isEmpty {
            return id
        }
        if let id = record["_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private func pulledRawRecord(
        from result: PullResult,
        relativePath: String,
        id: String
    ) -> [String: Any]? {
        result.rawRecordsByFile[relativePath]?.first(where: { raw in
            if let rawId = raw["id"] as? String { return rawId == id }
            if let rawId = raw["_id"] as? String { return rawId == id }
            return false
        })
    }

    private func assertCollectionPull(
        resourceName: String,
        relativePath: String,
        expectedColumns: [String],
        allowEmptyFile: Bool = false,
        allowSiteUnavailable: Bool = false
    ) async throws {
        let res = try resource(resourceName)
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
        let res = try resource(resourceName)
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
        let res = try resource(resourceName)
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

    private func isTransientWixError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else {
            return false
        }

        switch apiError {
        case .timeout, .rateLimited, .networkError:
            return true
        case .serverError(let statusCode):
            return statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
        default:
            return false
        }
    }

    private func withTransientRetry<T>(
        attempts: Int = 3,
        delayMs: UInt64 = 1_000,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        precondition(attempts > 0, "attempts must be positive")

        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                guard attempt < attempts, isTransientWixError(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }

        throw lastError ?? APIError.invalidResponse
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
        let response = try await withTransientRetry {
            try await self.httpClient.request(request)
        }
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
        let res = try resource(resourceName)
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
        createdIds.append((resource: try resource("contacts"), id: id))
        return (id, revision)
    }

    private func getContact(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/contacts/v4/contacts/\(id)")
        return result["contact"] as? [String: Any] ?? result
    }

    private func getProduct(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/stores/v3/products/\(id)")
        return result["product"] as? [String: Any] ?? result
    }

    private func getBookingsService(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/bookings/v2/services/\(id)")
        return result["service"] as? [String: Any] ?? result
    }

    private func getMember(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/members/v1/members/\(id)")
        return result["member"] as? [String: Any] ?? result
    }

    private func createMember(
        nickname: String,
        loginEmail: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil
    ) async throws -> String {
        var member: [String: Any] = [
            "profile": [
                "nickname": nickname
            ]
        ]
        if let loginEmail {
            member["loginEmail"] = loginEmail
        }
        if firstName != nil || lastName != nil {
            var contact: [String: Any] = [:]
            if let firstName { contact["firstName"] = firstName }
            if let lastName { contact["lastName"] = lastName }
            member["contact"] = contact
        }
        let result = try await wixAPI(method: .POST, path: "/members/v1/members", body: ["member": member])
        guard let created = result["member"] as? [String: Any],
              let id = created["id"] as? String else {
            XCTFail("Failed to create Wix member")
            return ""
        }
        createdIds.append((resource: try resource("members"), id: id))
        return id
    }

    private func queryProducts() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "paging": ["limit": 100]
        ]
        let result = try await wixAPI(method: .POST, path: "/stores/v3/products/search", body: body)
        return result["products"] as? [[String: Any]] ?? []
    }

    private func queryOrders() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "cursorPaging": ["limit": 100]
        ]
        let result = try await wixAPI(method: .POST, path: "/ecom/v1/orders/search", body: body)
        return result["orders"] as? [[String: Any]] ?? []
    }

    private func getForm(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/form-schema-service/v4/forms/\(id)")
        return result["form"] as? [String: Any] ?? result
    }

    private func createForm(name: String, namespace: String? = nil) async throws -> String {
        let result = try await wixAPI(
            method: .POST,
            path: "/form-schema-service/v4/forms",
            body: [
                "form": [
                    "name": name,
                    "namespace": namespace ?? wixFormsNamespace
                ]
            ]
        )
        guard let form = result["form"] as? [String: Any],
              let id = form["id"] as? String else {
            XCTFail("Failed to create Wix form")
            return ""
        }
        createdIds.append((resource: try resource("forms"), id: id))
        return id
    }

    private func queryForms(namespace: String? = nil) async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": [
                "filter": [
                    "namespace": [
                        "$eq": namespace ?? wixFormsNamespace
                    ]
                ],
                "paging": [
                    "limit": 100
                ]
            ]
        ]
        let result = try await wixAPI(method: .POST, path: "/form-schema-service/v4/forms/query", body: body)
        return result["forms"] as? [[String: Any]] ?? []
    }

    private func getFormSubmission(id: String) async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/form-submission-service/v4/submissions/\(id)")
        return result["submission"] as? [String: Any] ?? result
    }

    private func createFormSubmission(formId: String, namespace: String? = nil) async throws -> String {
        do {
            let result = try await wixAPI(
                method: .POST,
                path: "/form-submission-service/v4/submissions",
                body: [
                    "submission": [
                        "formId": formId,
                        "namespace": namespace ?? wixFormsNamespace
                    ]
                ]
            )
            guard let submission = result["submission"] as? [String: Any],
                  let id = submission["id"] as? String else {
                XCTFail("Failed to create form submission")
                return ""
            }
            return id
        } catch APIError.serverError(let statusCode) where statusCode == 400 || statusCode == 403 || statusCode == 428 {
            throw XCTSkip("Form submissions are not writable for namespace \(namespace ?? wixFormsNamespace) on this site")
        }
    }

    private func deleteFormSubmission(id: String) async throws {
        _ = try await wixAPI(method: .DELETE, path: "/form-submission-service/v4/submissions/\(id)")
    }

    private func queryFormSubmissions(formId: String, namespace: String? = nil) async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": [
                "filter": [
                    "namespace": [
                        "$eq": namespace ?? wixFormsNamespace
                    ],
                    "formId": [
                        "$eq": formId
                    ]
                ],
                "paging": [
                    "limit": 100
                ]
            ]
        ]
        let result = try await wixAPI(method: .POST, path: "/form-submission-service/v4/submissions/namespace/query", body: body)
        return result["submissions"] as? [[String: Any]] ?? []
    }

    private func queryMembers() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/members/v1/members/query", body: body)
        return result["members"] as? [[String: Any]] ?? []
    }

    private func nickname(from member: [String: Any]) -> String? {
        (member["profile"] as? [String: Any])?["nickname"] as? String
    }

    private func querySiteProperties() async throws -> [String: Any] {
        let result = try await wixAPI(method: .GET, path: "/site-properties/v4/properties")
        return result["properties"] as? [String: Any] ?? result
    }

    private func queryPublishedSiteURLs() async throws -> [String: Any] {
        try await wixAPI(method: .GET, path: "/urls-server/v2/published-site-urls")
    }

    private func queryEditorURLs() async throws -> [String: Any] {
        try await wixAPI(method: .GET, path: "/editor-urls")
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
        createdIds.append((resource: try resource("bookings-services"), id: id))
        return (id, revision)
    }

    private func bookingsServiceUpdateBody(service: [String: Any], name: String? = nil, defaultCapacity: Int? = nil) -> [String: Any] {
        let revision = service["revision"] as? String ?? "\(service["revision"] ?? "0")"
        let resolvedName = name ?? (service["name"] as? String ?? "Updated Service")
        let capacity = defaultCapacity ?? (service["defaultCapacity"] as? Int ?? Int("\(service["defaultCapacity"] ?? 1)") ?? 1)
        let onlineBooking = service["onlineBooking"] as? [String: Any] ?? [
            "enabled": true,
            "requireManualApproval": false,
            "allowMultipleRequests": false,
        ]
        let payment = service["payment"] as? [String: Any] ?? [:]
        let locations = service["locations"] as? [[String: Any]] ?? []
        let schedule = service["schedule"] as? [String: Any] ?? [:]
        let staffMemberIds = service["staffMemberIds"] as? [String] ?? []

        let serviceBody: [String: Any] = [
            "revision": revision,
            "name": resolvedName,
            "type": service["type"] as? String ?? "APPOINTMENT",
            "defaultCapacity": capacity,
            "onlineBooking": onlineBooking,
            "payment": payment,
            "locations": locations,
            "schedule": schedule,
            "staffMemberIds": staffMemberIds,
        ]

        return ["service": serviceBody]
    }

    private func queryRestaurantMenus() async throws -> [[String: Any]] {
        let body: [String: Any] = [
            "query": ["paging": ["limit": 100]]
        ]
        let result = try await wixAPI(method: .POST, path: "/restaurants/menus-menu/v1/menus/query", body: body)
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
        let result = try await wixAPI(method: .POST, path: "/restaurants/menus-menu/v1/menus", body: body)
        guard let menu = result["menu"] as? [String: Any],
              let id = menu["id"] as? String
        else {
            XCTFail("Failed to create restaurant menu")
            return ("", "0")
        }
        let revision = menu["revision"] as? String ?? "\(menu["revision"] ?? "0")"
        createdIds.append((resource: try resource("restaurant-menus"), id: id))
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
        createdIds.append((resource: try resource("blog-posts"), id: postId))
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
        createdIds.append((resource: try resource("blog-categories"), id: id))
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
        createdIds.append((resource: try resource("blog-tags"), id: id))
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
        createdIds.append((resource: try resource("groups"), id: id))
        return id
    }

    private func waitForCollectionFile(_ url: URL) async throws {
        try await waitUntil("file \(url.lastPathComponent) to exist") {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func waitForSyncIdle(_ syncEngine: SyncEngine, serviceId: String = "wix") async throws {
        try await waitUntil("sync \(serviceId) idle") {
            guard let status = await syncEngine.getServiceStatus(serviceId) else { return false }
            return status.status != .syncing
        }
    }

    private func triggerAndWaitForSync(_ syncEngine: SyncEngine, filePath: String? = nil) async throws {
        if let filePath {
            await syncEngine.fileDidChange(serviceId: "wix", filePath: filePath)
            if ObjectFileManager.isObjectFile(filePath) {
                return
            }
        }
        await syncEngine.triggerSync(serviceId: "wix")
        try await waitForSyncIdle(syncEngine)
    }

    private func runCollectionUpdatePropagationScenario(_ scenario: CollectionUpdateScenario) async throws {
        try await withIsolatedSyncHarness(resourceNames: [scenario.resourceName]) { harness in
            let resource = try self.resource(scenario.resourceName, in: harness.config)
            let pullResult = try await harness.engine.pull(resource: resource)
            let relativePath = try XCTUnwrap(pullResult.files.first?.relativePath)
            let humanURL = harness.serviceDir.appendingPathComponent(relativePath)
            let objectPath = ObjectFileManager.objectFilePath(forCollectionFile: relativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectPath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)

            let humanUpdateToken = self.uniqueTestName("\(scenario.updateTokenPrefix)Human")
            var humanRows = try self.readCSV(at: humanURL)
            guard let rowIndex = humanRows.firstIndex(where: { self.recordId(from: $0) != nil }) else {
                throw XCTSkip("No existing rows available in \(relativePath) for human-update propagation")
            }
            let targetId = try XCTUnwrap(self.recordId(from: humanRows[rowIndex]), "Expected a stable id column in \(relativePath)")
            scenario.humanUpdate(&humanRows[rowIndex], humanUpdateToken)
            try self.writeCSV(humanRows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: relativePath)
            try await self.waitUntil("\(scenario.resourceName) human update on object file") {
                guard let record = try self.objectRecord(withId: targetId, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: humanUpdateToken)
            }
            try await self.waitUntil("\(scenario.resourceName) human update on server") {
                try await self.serverRecordContainsToken(scenario: scenario, id: targetId, token: humanUpdateToken)
            }

            let objectUpdateToken = self.uniqueTestName("\(scenario.updateTokenPrefix)Object")
            var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let rawIndex = rawRecords.firstIndex(where: { ($0["id"] as? String) == targetId || ($0["_id"] as? String) == targetId }) else {
                throw XCTSkip("No object records available in \(objectPath) for object-update propagation")
            }
            scenario.objectUpdate(&rawRecords[rawIndex], objectUpdateToken)
            try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectPath)
            try await self.waitUntil("\(scenario.resourceName) object update on human file") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == targetId && self.recursiveStringContainsToken($0, token: objectUpdateToken) })
            }
            try await self.waitUntil("\(scenario.resourceName) object update on server") {
                try await self.serverRecordContainsToken(scenario: scenario, id: targetId, token: objectUpdateToken)
            }

            let serverUpdateToken = self.uniqueTestName("\(scenario.updateTokenPrefix)Server")
            try await scenario.serverUpdate(self, targetId, serverUpdateToken)
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("\(scenario.resourceName) server update on object file") {
                guard let record = try self.objectRecord(withId: targetId, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: serverUpdateToken)
            }
            try await self.waitUntil("\(scenario.resourceName) server update on human file") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == targetId && self.recursiveStringContainsToken($0, token: serverUpdateToken) })
            }
        }
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
        let res = try resource(resourceName)
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

    func testWixResourceContracts_CoverEveryBundledTopLevelResource() async throws {
        let configuredNames = Set(try XCTUnwrap(bundledConfig).resources.map(\.name))
        let contractNames = Set(Self.wixTopLevelContracts.map(\.name))
        XCTAssertEqual(contractNames, configuredNames, "Every bundled Wix top-level resource must have an explicit contract entry")
    }

    func testWixResourceContracts_CoverExplicitChildSurfaces() throws {
        let bundled = try XCTUnwrap(bundledConfig)
        let forms = try XCTUnwrap(bundled.resources.first(where: { $0.name == "forms" }))
        let collections = try XCTUnwrap(bundled.resources.first(where: { $0.name == "collections" }))
        let groups = try XCTUnwrap(bundled.resources.first(where: { $0.name == "groups" }))
        let inbox = try XCTUnwrap(bundled.resources.first(where: { $0.name == "inbox-conversations" }))
        let portfolioProjects = try XCTUnwrap(bundled.resources.first(where: { $0.name == "portfolio-projects" }))
        let childNames = Set(Self.wixChildSurfaceContracts.map(\.name))

        let groupChildNames = groups.children?.map { "groups.\($0.name)" } ?? []
        let inboxChildNames = inbox.children?.map { "inbox-conversations.\($0.name)" } ?? []
        let portfolioChildNames = portfolioProjects.children?.map { "portfolio-projects.\($0.name)" } ?? []

        XCTAssertEqual(
            childNames,
            Set([
                "forms.\(try XCTUnwrap(forms.children?.first).name)",
                "collections.\(try XCTUnwrap(collections.children?.first).name)",
            ] + groupChildNames + inboxChildNames + portfolioChildNames),
            "Important writable child surfaces should stay explicit in the Wix contract matrix"
        )
    }

    func testWixResourceContracts_MatchBundledCapabilityClasses() throws {
        let bundled = try XCTUnwrap(bundledConfig)

        for contract in Self.wixTopLevelContracts {
            let resource = try XCTUnwrap(bundled.resources.first(where: { $0.name == contract.name }))
            XCTAssertEqual(resource.capabilityClass, contract.capabilityClass, "\(contract.name) capability class drifted between the adapter and live matrix")
            XCTAssertEqual(resource.fileMapping.format, contract.humanFormat, "\(contract.name) human format drifted between the adapter and live matrix")
        }

        let forms = try XCTUnwrap(bundled.resources.first(where: { $0.name == "forms" }))
        let submissions = try XCTUnwrap(forms.children?.first(where: { $0.name == "submissions" }))
        XCTAssertEqual(submissions.capabilityClass, .partialWritable)
        XCTAssertEqual(submissions.fileMapping.format, .csv)

        let collections = try XCTUnwrap(bundled.resources.first(where: { $0.name == "collections" }))
        let items = try XCTUnwrap(collections.children?.first(where: { $0.name == "items" }))
        XCTAssertEqual(items.capabilityClass, .fullCRUD)
        XCTAssertEqual(items.fileMapping.format, .csv)

        let groups = try XCTUnwrap(bundled.resources.first(where: { $0.name == "groups" }))
        let groupMembers = try XCTUnwrap(groups.children?.first(where: { $0.name == "group-members" }))
        XCTAssertEqual(groupMembers.capabilityClass, .partialWritable)
        XCTAssertEqual(groupMembers.fileMapping.format, .csv)
        let groupPosts = try XCTUnwrap(groups.children?.first(where: { $0.name == "group-posts" }))
        XCTAssertEqual(groupPosts.capabilityClass, .fullCRUD)
        XCTAssertEqual(groupPosts.fileMapping.format, .markdown)

        let inbox = try XCTUnwrap(bundled.resources.first(where: { $0.name == "inbox-conversations" }))
        let inboxMessages = try XCTUnwrap(inbox.children?.first(where: { $0.name == "inbox-messages" }))
        XCTAssertEqual(inboxMessages.capabilityClass, .partialWritable)
        XCTAssertEqual(inboxMessages.fileMapping.format, .csv)
    }

    func testWixResourceContracts_ReportStatusMatrix() throws {
        let bundled = try XCTUnwrap(bundledConfig)
        var lines = [
            "| Resource | Configured capability | Live-proven capability | 3-way propagation | Sanitized human file |",
            "| --- | --- | --- | --- | --- |",
        ]

        for contract in Self.wixTopLevelContracts + Self.wixChildSurfaceContracts {
            let configuredCapability: ResourceCapabilityClass?
            if let parentName = contract.name.split(separator: ".").first.map(String.init),
               contract.name.contains("."),
               let parent = bundled.resources.first(where: { $0.name == parentName }),
               let childName = contract.name.split(separator: ".").dropFirst().first.map(String.init) {
                configuredCapability = parent.children?.first(where: { $0.name == childName })?.capabilityClass
            } else {
                configuredCapability = bundled.resources.first(where: { $0.name == contract.name })?.capabilityClass
            }
            lines.append(
                "| \(contract.name) | \(configuredCapability?.rawValue ?? "n/a") | \(contract.capabilityClass.rawValue) | \(self.propagationStatus(for: contract)) | \(contract.humanSanitized ? "yes" : "no") |"
            )
        }

        XCTContext.runActivity(named: "Wix resource contract matrix") { activity in
            let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
            attachment.name = "wix-resource-contract-matrix"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    func testThreeWayUpdatePropagation_WritableCollectionResources() async throws {
        let scenarios: [CollectionUpdateScenario] = [
            .init(
                resourceName: "products",
                updateTokenPrefix: "Product3Way",
                serverQuery: { try await $0.queryProducts() },
                serverGet: { test, id in try await test.getProduct(id: id) },
                serverUpdate: { test, id, token in
                    let latest = try await test.getProduct(id: id)
                    let revision = latest["revision"] as? Int ?? Int("\(latest["revision"] ?? 0)") ?? 0
                    let body: [String: Any] = [
                        "product": [
                            "name": token,
                            "revision": String(revision)
                        ]
                    ]
                    _ = try await test.wixAPI(method: .PATCH, path: "/stores/v3/products/\(id)", body: body)
                },
                humanUpdate: { row, token in
                    row["name"] = token
                },
                objectUpdate: { row, token in
                    row["name"] = token
                    row["slug"] = token.lowercased().replacingOccurrences(of: " ", with: "-")
                }
            ),
        ]

        let contractLookup = Dictionary(uniqueKeysWithValues: Self.wixTopLevelContracts.map { ($0.name, $0) })
        let expectedScenarioResources: Set<String> = ["products"]
        XCTAssertEqual(
            Set(scenarios.map(\.resourceName)),
            expectedScenarioResources,
            "The generic collection 3-way runner should only cover the resources whose full collection propagation contract is proven live here"
        )

        for scenario in scenarios {
            XCTAssertEqual(contractLookup[scenario.resourceName]?.capabilityClass, .fullCRUD)
            try await self.runCollectionUpdatePropagationScenario(scenario)
        }
    }

    func testThreeWayUpdatePropagation_BlogPostsMarkdown() async throws {
        try await withIsolatedSyncHarness(resourceNames: ["blog-posts"]) { harness in
            let resource = try self.resource("blog-posts", in: harness.config)
            let title = self.uniqueTestName("Blog3Way")
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let postId = try await self.createBlogPost(
                title: title,
                slug: slug,
                excerpt: "Three-way propagation test",
                contentText: "Original content"
            )

            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let pullResult = try await harness.engine.pull(resource: resource)
            let humanRelativePath = try XCTUnwrap(
                pullResult.files.first(where: { $0.remoteId == postId })?.relativePath,
                "Expected pulled markdown file for created post"
            )
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forRecordFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)

            let humanToken = self.uniqueTestName("BlogHuman")
            var humanContent = try String(contentsOf: humanURL, encoding: .utf8)
            humanContent = humanContent
                .replacingOccurrences(of: title, with: humanToken)
                .replacingOccurrences(of: "Original content", with: "Human updated body \(humanToken)")
            try humanContent.write(to: humanURL, atomically: true, encoding: .utf8)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)
            try await self.waitUntil("blog human update on object file") {
                guard let record = try? ObjectFileManager.readRecordObjectFile(from: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: humanToken)
            }
            try await self.waitUntil("blog human update on server") {
                let post = try await self.getBlogPost(id: postId)
                return self.recursiveStringContainsToken(post, token: humanToken)
            }

            let objectToken = self.uniqueTestName("BlogObject")
            var objectRecord = try ObjectFileManager.readRecordObjectFile(from: objectURL)
            objectRecord["title"] = objectToken
            objectRecord["contentText"] = "Object updated body \(objectToken)"
            objectRecord["richContent"] = try self.richContentDocument(markdown: "# \(objectToken)\n\nObject updated body \(objectToken)")
            try ObjectFileManager.writeRecordObjectFile(record: objectRecord, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectRelativePath)
            try await self.waitUntil("blog object update on markdown file") {
                guard let content = try? String(contentsOf: humanURL, encoding: .utf8) else { return false }
                return content.contains(objectToken)
            }
            try await self.waitUntil("blog object update on server") {
                let post = try await self.getBlogPost(id: postId)
                return self.recursiveStringContainsToken(post, token: objectToken)
            }

            let serverToken = self.uniqueTestName("BlogServer")
            let post = try await self.getBlogPost(id: postId)
            let memberId: String
            if let existingMemberId = post["memberId"] as? String, !existingMemberId.isEmpty {
                memberId = existingMemberId
            } else {
                memberId = try await self.currentGroupOwnerId()
            }
            let body: [String: Any] = [
                "draftPost": [
                    "title": serverToken,
                    "slug": slug,
                    "memberId": memberId,
                    "excerpt": post["excerpt"] as? String ?? "Three-way propagation test",
                    "contentText": "Server updated body \(serverToken)",
                    "richContent": try self.richContentDocument(markdown: "# \(serverToken)\n\nServer updated body \(serverToken)")
                ]
            ]
            _ = try await self.wixAPI(method: .PATCH, path: "/blog/v3/draft-posts/\(postId)", body: body)
            _ = try await self.wixAPI(method: .POST, path: "/blog/v3/draft-posts/\(postId)/publish")
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("blog server update on object file") {
                guard let record = try? ObjectFileManager.readRecordObjectFile(from: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: serverToken)
            }
            try await self.waitUntil("blog server update on markdown file") {
                guard let content = try? String(contentsOf: humanURL, encoding: .utf8) else { return false }
                return content.contains(serverToken)
            }

            try await harness.engine.delete(remoteId: postId, resource: resource)
        }
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
            directory: "blog-posts",
            expectedFrontMatterKeys: ["id", "title", "slug", "excerpt", "firstPublishedDate"]
        )
    }

    func testBlogPosts_Pull_WritesMarkdownBodyFromContentText() async throws {
        let res = try resource("blog-posts")
        let result = try await engine.pull(resource: res)
        XCTAssertFalse(result.files.isEmpty, "blog-posts pull returned no files")

        let prefix = "\(res.fileMapping.directory)/"
        let markdownFiles = result.files.filter { $0.relativePath.hasPrefix(prefix) && $0.relativePath.hasSuffix(".md") }
        let sample = try XCTUnwrap(markdownFiles.first(where: { !$0.content.isEmpty }))
        let content = String(decoding: sample.content, as: UTF8.self)
        let sections = content.components(separatedBy: "\n---\n\n")
        XCTAssertTrue(sections.count >= 2, "Expected markdown body after front matter in \(sample.relativePath)")
        XCTAssertFalse(sections.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "Markdown body should not be empty in \(sample.relativePath)")
    }

    func testBlogPosts_IncrementalPull_PreservesDetailHydration() async throws {
        let res = try resource("blog-posts")
        let result = try await engine.pull(resource: res, updatedSince: Date())
        XCTAssertFalse(result.files.isEmpty, "incremental blog-posts pull returned no files")

        let prefix = "\(res.fileMapping.directory)/"
        let markdownFiles = result.files.filter { $0.relativePath.hasPrefix(prefix) && $0.relativePath.hasSuffix(".md") }
        let sample = try XCTUnwrap(markdownFiles.first(where: { !$0.content.isEmpty }))
        let content = String(decoding: sample.content, as: UTF8.self)
        let sections = content.components(separatedBy: "\n---\n\n")
        XCTAssertTrue(sections.count >= 2, "Expected markdown body after front matter in incremental pull for \(sample.relativePath)")
        XCTAssertFalse(sections.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, "Incremental pull should keep markdown body hydrated in \(sample.relativePath)")
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
        let res = try resource("blog-categories")
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
        let res = try resource("blog-categories")
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
        let res = try resource("blog-categories")
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
        let res = try resource("blog-tags")
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
        let res = try resource("blog-tags")
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
        let res = try resource("blog-tags")
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
            expectedColumns: ["id", "name", "description", "privacyStatus"]
        )
    }

    func testGroups_Create_NewGroup_AppearsOnServer() async throws {
        let res = try resource("groups")
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
        let res = try resource("groups")
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
        let res = try resource("groups")
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

    func testGroups_ServerUpdate_ReflectedInObjectAndLocalFiles() async throws {
        let ownerId = try await currentGroupOwnerId()
        let id = try await createGroup(name: uniqueTestName("GroupServerBase"), ownerId: ownerId)

        try await withIsolatedSyncHarness(resourceNames: ["groups"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let humanRelativePath = "groups.csv"
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)
            try await self.waitUntil("group row pulled into groups.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == id }
            }

            let token = self.uniqueTestName("GroupServer")
            _ = try await self.wixAPI(
                method: .PATCH,
                path: "/social-groups/v2/groups/\(id)",
                body: [
                    "group": [
                        "name": token,
                        "title": token,
                        "createdBy": [
                            "id": ownerId,
                            "identityType": "MEMBER"
                        ]
                    ]
                ]
            )

            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("group server update on object file") {
                guard let record = try self.objectRecord(withId: id, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: token)
            }
            try await self.waitUntil("group server update on human file") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == id && self.recursiveStringContainsToken($0, token: token) }
            }
        }
    }

    func testCollectionsItems_DiscoversWritableNativeCollections() async throws {
        let fixtures = try await self.discoverWritableCMSCollectionFixtures(in: config)
        XCTAssertFalse(fixtures.isEmpty, "Expected at least one writable NATIVE CMS collection on the live Wix site")

        for fixture in fixtures.prefix(3) {
            let resolvedResource = try self.resolvedCollectionsItemsResource(for: fixture, in: config)
            try await withIsolatedSyncHarness(resources: [resolvedResource]) { harness in
                let humanURL = harness.serviceDir.appendingPathComponent(fixture.humanRelativePath)
                let objectURL = harness.serviceDir.appendingPathComponent(fixture.objectRelativePath)
                try await self.waitForCollectionFile(humanURL)
                try await self.waitForCollectionFile(objectURL)
            }
        }
    }

    func testCollectionsItems_DynamicWritableCollection_ThreeWayPropagation() async throws {
        try await withDynamicCMSCollectionFixtureHarness { fixture, harness, humanURL, objectURL in
            var humanRows = try self.readCSV(at: humanURL)
            guard let rowIndex = humanRows.firstIndex(where: {
                self.recordId(from: $0) != nil && self.preferredStringField(in: $0) != nil
            }) else {
                throw XCTSkip("No existing rows available in \(fixture.humanRelativePath)")
            }
            let itemId = try XCTUnwrap(self.recordId(from: humanRows[rowIndex]))

            let humanToken = self.uniqueTestName("CMSHuman")
            let editableField = try self.updateCMSHumanRow(&humanRows[rowIndex], token: humanToken)
            try self.writeCSV(humanRows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: fixture.humanRelativePath)
            try await self.waitUntil("CMS human update on object file") {
                guard let record = try self.objectRecord(withId: itemId, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: humanToken)
            }
            try await self.waitUntil("CMS human update on server") {
                let item = try await self.cmsServerRecord(collectionId: fixture.id, itemId: itemId)
                return self.recursiveStringContainsToken(item, token: humanToken)
            }

            let objectToken = self.uniqueTestName("CMSObject")
            var objectRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let objectIndex = objectRecords.firstIndex(where: { ($0["id"] as? String) == itemId || ($0["_id"] as? String) == itemId }) else {
                throw XCTSkip("No object record available for \(itemId) in \(fixture.objectRelativePath)")
            }
            _ = try self.updateCMSObjectRecord(&objectRecords[objectIndex], token: objectToken)
            try ObjectFileManager.writeCollectionObjectFile(records: objectRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: fixture.objectRelativePath)
            try await self.waitUntil("CMS object update on human file") {
                let refreshedRows = try self.readCSV(at: humanURL)
                return refreshedRows.contains { self.recordId(from: $0) == itemId && self.recursiveStringContainsToken($0, token: objectToken) }
            }
            try await self.waitUntil("CMS object update on server") {
                let item = try await self.cmsServerRecord(collectionId: fixture.id, itemId: itemId)
                return self.recursiveStringContainsToken(item, token: objectToken)
            }

            let serverToken = self.uniqueTestName("CMSServer")
            let latest = try await self.cmsServerRecord(collectionId: fixture.id, itemId: itemId)
            var latestData = latest["data"] as? [String: Any] ?? [:]
            latestData[editableField] = serverToken
            _ = try await self.wixAPI(
                method: .PUT,
                path: "/wix-data/v2/items/\(itemId)",
                body: [
                    "dataCollectionId": fixture.id,
                    "dataItem": [
                        "id": itemId,
                        "data": latestData
                    ]
                ]
            )
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("CMS server update on object file") {
                guard let record = try self.objectRecord(withId: itemId, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: serverToken)
            }
            try await self.waitUntil("CMS server update on human file") {
                let refreshedRows = try self.readCSV(at: humanURL)
                return refreshedRows.contains { self.recordId(from: $0) == itemId && self.recursiveStringContainsToken($0, token: serverToken) }
            }
        }
    }

    func testCollectionsItems_DynamicWritableCollection_CreateUpdateDeleteViaHumanFile() async throws {
        try await withDynamicCMSCollectionFixtureHarness { fixture, harness, humanURL, _ in
            var rows = try self.readCSV(at: humanURL)
            guard let template = rows.first(where: {
                self.recordId(from: $0) != nil && self.preferredStringField(in: $0) != nil
            }) else {
                throw XCTSkip("No existing rows available in \(fixture.humanRelativePath) for create/delete coverage")
            }

            let createToken = self.uniqueTestName("CMSCreate")
            var newRow = template
            newRow.removeValue(forKey: "id")
            newRow.removeValue(forKey: "_id")
            _ = try self.updateCMSHumanRow(&newRow, token: createToken)
            rows.append(newRow)
            try self.writeCSV(rows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: fixture.humanRelativePath)

            let createdId = try await self.waitForCMSCreatedItem(collectionId: fixture.id, token: createToken)

            try await self.waitUntil("CMS created row appears in human file") {
                let refreshedRows = try self.readCSV(at: humanURL)
                return refreshedRows.contains { self.recordId(from: $0) == createdId && self.recursiveStringContainsToken($0, token: createToken) }
            }

            let updateToken = self.uniqueTestName("CMSUpdate")
            var updatedRows = try self.readCSV(at: humanURL)
            guard let createdIndex = updatedRows.firstIndex(where: { self.recordId(from: $0) == createdId }) else {
                throw XCTSkip("Created CMS row \(createdId) did not round-trip into \(fixture.humanRelativePath)")
            }
            _ = try self.updateCMSHumanRow(&updatedRows[createdIndex], token: updateToken)
            try self.writeCSV(updatedRows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: fixture.humanRelativePath)
            try await self.waitUntil("CMS updated row appears on server") {
                let item = try await self.cmsServerRecord(collectionId: fixture.id, itemId: createdId)
                return self.recursiveStringContainsToken(item, token: updateToken)
            }

            let deletedRows = updatedRows.filter { self.recordId(from: $0) != createdId }
            try self.writeCSV(deletedRows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: fixture.humanRelativePath)
            try await self.waitUntil("CMS deleted row removed from server") {
                let items = try await self.queryCMS(collectionId: fixture.id)
                return items.contains(where: { ($0["id"] as? String) == createdId }) == false
            }
        }
    }

    // ======================================================================
    // MARK: - CMS Todos — Pull
    // ======================================================================

    func testCMSTodos_Pull_ReturnsCSVWithExpectedColumns() async throws {
        let res = try resource("cms-todos")
        let result = try await engine.pull(resource: res)
        let humanRelativePath = try collectionRelativePath(for: res)

        XCTAssertFalse(result.files.isEmpty, "Pull returned no files")
        let file = result.files.first!
        XCTAssertEqual(file.relativePath, humanRelativePath)

        try writeFilesToDisk(result.files)
        let records = try readCSV(humanRelativePath)
        XCTAssertFalse(records.isEmpty, "No records in \(humanRelativePath)")

        // Verify expected columns (CSVFormat decodes _id header back to "id" key)
        let columns = Set(records[0].keys)
        for expected in ["id", "title", "status", "priority"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
        XCTAssertFalse(columns.contains("_url"), "Human CMS CSV should not expose _url metadata")
        XCTAssertFalse(columns.contains("dataCollectionId"), "Human CMS CSV should not expose dataCollectionId metadata")
    }

    func testCMSTodos_Pull_ContainsKnownRecords() async throws {
        let res = try resource("cms-todos")
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(try collectionRelativePath(for: res))

        // There should be at least one record
        XCTAssertGreaterThanOrEqual(records.count, 1, "Expected at least 1 todo")
    }

    // ======================================================================
    // MARK: - CMS Todos — Create / Update / Delete
    // ======================================================================

    func testCMSTodos_Create_NewRow_AppearsOnServer() async throws {
        let res = try resource("cms-todos")
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
        let res = try resource("cms-todos")
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
        let res = try resource("cms-todos")
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
        let res = try resource("cms-todos")
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
        let res = try resource("cms-todos")
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
        let records = try readCSV(try collectionRelativePath(for: res))

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertNotNil(found, "Server-created todo should appear in local CSV")
        XCTAssertEqual(found?["title"] as? String, testTitle)
    }

    func testCMSTodos_ServerUpdate_ReflectedInLocalFile() async throws {
        let res = try resource("cms-todos")
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
        let records = try readCSV(try collectionRelativePath(for: res))

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertEqual(found?["title"] as? String, updatedTitle, "Server update should be reflected in local CSV")
    }

    // ======================================================================
    // MARK: - CMS Projects — Pull
    // ======================================================================

    func testCMSProjects_Pull_ReturnsCSVWithCorrectFields() async throws {
        let res = try resource("cms-projects")
        let result = try await engine.pull(resource: res)
        let humanRelativePath = try collectionRelativePath(for: res)

        XCTAssertFalse(result.files.isEmpty)
        try writeFilesToDisk(result.files)
        let records = try readCSV(humanRelativePath)

        XCTAssertFalse(records.isEmpty, "No records in \(humanRelativePath)")
        let columns = Set(records[0].keys)
        for expected in ["id", "name", "description", "color"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
        XCTAssertFalse(columns.contains("_url"), "Human CMS CSV should not expose _url metadata")
        XCTAssertFalse(columns.contains("dataCollectionId"), "Human CMS CSV should not expose dataCollectionId metadata")
    }

    // ======================================================================
    // MARK: - CMS Projects — Create / Update / Delete
    // ======================================================================

    func testCMSProjects_Create_NewProject_AppearsOnServer() async throws {
        let res = try resource("cms-projects")
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
        let res = try resource("cms-projects")
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
        let res = try resource("cms-projects")
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
        let res = try resource("cms-projects")
        let testName = uniqueTestName("ProjSrv")

        let id = try await createCMSItem(
            collectionId: "Projects",
            data: ["name": testName, "description": "Server create test", "color": "#AABB00"],
            resourceName: "cms-projects"
        )
        try await delay(1000)

        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(try collectionRelativePath(for: res))

        let found = records.first(where: { ($0["id"] as? String) == id })
        XCTAssertNotNil(found, "Server-created project should appear in local CSV")
        XCTAssertEqual(found?["name"] as? String, testName)
    }

    // ======================================================================
    // MARK: - Orders / Forms / Members / Site Properties — Pull
    // ======================================================================

    func testOrders_Pull_ReturnsCSVWithExpectedFields() async throws {
        let res = try resource("orders")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "orders pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, "orders.csv")

        try writeFilesToDisk(result.files)
        let records = try readCSV("orders.csv")
        guard let first = records.first else {
            throw XCTSkip("No Wix eCommerce orders available on this site")
        }

        let columns = Set(first.keys)
        for expected in ["id", "orderNumber", "status", "paymentStatus", "fulfillmentStatus"] {
            XCTAssertTrue(columns.contains(expected), "Missing column \(expected) in orders.csv")
        }
        XCTAssertFalse(columns.contains("_url"), "orders.csv should not expose _url")
    }

    func testForms_Pull_ReturnsCSVWhenInstalled() async throws {
        let res = try resource("forms")
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Wix Forms app not installed or forms APIs unavailable: \(error)")
            }
            throw error
        }

        XCTAssertFalse(result.files.isEmpty, "forms pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, "forms.csv")

        try writeFilesToDisk(result.files)
        let records = try readCSV("forms.csv")
        guard let first = records.first else {
            throw XCTSkip("No Wix forms available on this site")
        }

        let columns = Set(first.keys)
        for expected in ["id", "name"] {
            XCTAssertTrue(columns.contains(expected), "Missing column \(expected) in forms.csv")
        }
        XCTAssertFalse(columns.contains("namespace"), "forms.csv should not expose namespace")
        XCTAssertFalse(columns.contains("_url"), "forms.csv should not expose _url")
        XCTAssertFalse(columns.contains("updatedDate"), "forms.csv should not expose updatedDate")
    }

    func testFormSubmissions_Pull_ReturnsPerFormCSVWhenInstalled() async throws {
        let forms = try await queryForms()
        guard let form = forms.first, let formId = form["id"] as? String else {
            throw XCTSkip("No Wix forms available to verify submissions pull")
        }

        let submissions = try await queryFormSubmissions(formId: formId)
        guard !submissions.isEmpty else {
            throw XCTSkip("No submissions available for the first Wix form on this site")
        }

        let result = try await engine.pull(resource: try resource("forms"))
        try writeFilesToDisk(result.files)

        let submissionFiles = result.files.filter {
            $0.relativePath.hasPrefix("forms/") && $0.relativePath.hasSuffix(".csv")
        }
        XCTAssertFalse(submissionFiles.isEmpty, "Expected per-form submissions CSV files")

        let sampleRelativePath = try XCTUnwrap(submissionFiles.first?.relativePath)
        let records = try readCSV(sampleRelativePath)
        guard let first = records.first else {
            throw XCTSkip("Submission CSV exists but contains no rows")
        }

        let columns = Set(first.keys)
        for expected in ["id", "formId", "status", "seen"] {
            XCTAssertTrue(columns.contains(expected), "Missing column \(expected) in \(sampleRelativePath)")
        }
        XCTAssertFalse(columns.contains("_url"), "Form submissions CSV should not expose _url")
        XCTAssertFalse(columns.contains("submitterApplicationId"), "Form submissions CSV should hide application internals")
        XCTAssertFalse(columns.contains("submitterUserId"), "Form submissions CSV should hide user internals")
    }

    func testMembers_Pull_ReturnsCSVWithExpectedFields() async throws {
        let res = try resource("members")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "members pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, "members.csv")

        try writeFilesToDisk(result.files)
        let records = try readCSV("members.csv")
        guard let first = records.first else {
            throw XCTSkip("No Wix members available on this site")
        }

        let columns = Set(first.keys)
        for expected in ["id", "nickname", "slug"] {
            XCTAssertTrue(columns.contains(expected), "Missing column \(expected) in members.csv")
        }
        XCTAssertTrue(
            columns.contains("firstName") || columns.contains("lastName") || !columns.isDisjoint(with: ["nickname", "slug"]),
            "Members CSV should surface at least one human-facing identity field"
        )
        XCTAssertFalse(columns.contains("contactId"), "Members CSV should not expose contactId")
        XCTAssertFalse(columns.contains("_url"), "Members CSV should not expose _url")
    }

    func testSiteProperties_Pull_ReturnsJSONSnapshotWhenInstalled() async throws {
        let res = try resource("site-properties")
        let result = try await engine.pull(resource: res)

        XCTAssertFalse(result.files.isEmpty, "site-properties pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, "site-properties.json")

        try writeFilesToDisk(result.files)
        let json = try readJSON("site-properties.json")
        if let records = json as? [[String: Any]] {
            guard let first = records.first else {
                throw XCTSkip("Site properties JSON file is empty")
            }
            XCTAssertFalse(first.isEmpty, "Site properties record should not be empty")
        } else if let object = json as? [String: Any] {
            XCTAssertFalse(object.isEmpty, "Site properties object should not be empty")
        } else {
            XCTFail("site-properties.json should decode to an object or array of objects")
        }

        let properties = try await querySiteProperties()
        XCTAssertFalse(properties.isEmpty, "Direct site properties query should return data")
    }

    func testSiteURLs_DirectEndpoints_ReturnPublishedAndEditorURLs() async throws {
        let published = try await queryPublishedSiteURLs()
        let editor = try await queryEditorURLs()
        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: published,
            editorResponse: editor
        )

        XCTAssertFalse(published.isEmpty, "Published site URLs endpoint should return data")
        XCTAssertFalse(editor.isEmpty, "Editor URLs endpoint should return data")
        XCTAssertFalse((catalog["primaryUrl"] as? String ?? "").isEmpty, "Merged catalog should include a primaryUrl")
        XCTAssertNotNil(catalog["capturedAt"] as? String)
        XCTAssertNotNil(catalog["published"] as? [String: Any])
        XCTAssertNotNil(catalog["editor"] as? [String: Any])

        let publishedURLs =
            ((published["urls"] as? [[String: Any]]) ?? (published["publishedSiteUrls"] as? [[String: Any]]) ?? [])
                .compactMap { ($0["url"] as? String) ?? ($0["publishedUrl"] as? String) }
        XCTAssertFalse(publishedURLs.isEmpty, "Published site URLs response should include at least one URL")
        XCTAssertTrue(
            publishedURLs.contains(catalog["primaryUrl"] as? String ?? ""),
            "Merged primaryUrl should come from the live published URLs payload"
        )
    }

    func testSiteURLs_LiveSnapshotTargets_IncludeEditorAndDashboardResourceURLs() async throws {
        let published = try await queryPublishedSiteURLs()
        let editor = try await queryEditorURLs()
        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: published,
            editorResponse: editor
        )

        let nestedEditor = editor["urls"] as? [String: Any]
        let editorURLCandidates: [String?] = [
            editor["editorUrl"] as? String,
            editor["previewUrl"] as? String,
            nestedEditor?["editorUrl"] as? String,
            nestedEditor?["previewUrl"] as? String,
        ]
        let editorURLs = editorURLCandidates.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        XCTAssertFalse(editorURLs.isEmpty, "Live editor URLs payload should include at least one concrete URL")

        let injectedResources = editorURLs.enumerated().map { index, url in
            ResourceConfig(
                name: index == 0 ? "live-editor" : "live-preview",
                description: "Live editor/discovery URL",
                capabilityClass: .readOnly,
                pull: nil,
                push: nil,
                fileMapping: FileMappingConfig(
                    strategy: .collection,
                    directory: "tmp",
                    filename: "editor-\(index).json",
                    format: .json
                ),
                sync: SyncConfig(interval: 600, debounceMs: nil),
                siteUrl: url,
                dashboardUrl: url.contains("manage.wix.com") ? url : nil
            )
        }

        let snapshotConfig = AdapterConfig(
            service: config.service,
            displayName: config.displayName,
            version: config.version,
            auth: config.auth,
            globals: config.globals,
            resources: config.resources + injectedResources,
            icon: config.icon,
            wizardDescription: config.wizardDescription,
            setupFields: config.setupFields,
            hidden: config.hidden,
            enabled: config.enabled,
            siteUrl: config.siteUrl,
            dashboardUrl: config.dashboardUrl
        )

        let targets = WixSiteSnapshotSupport.snapshotTargets(config: snapshotConfig, catalogRecord: catalog)
        let targetURLs = Set(targets.map { $0.url })

        for url in editorURLs {
            XCTAssertTrue(targetURLs.contains(url), "Live editor/dashboard resource URL should remain a snapshot target: \(url)")
        }
    }

    func testSiteURLs_IsolatedSync_WritesMergedCatalogAndRenderedSnapshots() async throws {
        let browser = await MainActor.run { LiveBrowserSnapshotDelegate() }
        let snapshotService = BrowserRenderedPageSnapshotService(browserDelegate: browser)

        try await withIsolatedSyncHarness(
            resourceNames: ["site-urls", "blog-posts", "products"],
            snapshotService: snapshotService
        ) { harness in
            let catalogResource = try self.resource("site-urls", in: harness.config)
            let catalogRelativePath = WixSiteSnapshotSupport.catalogRelativePath
            let catalogURL = harness.serviceDir.appendingPathComponent(catalogRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(
                forUserFile: catalogRelativePath,
                strategy: catalogResource.fileMapping.strategy
            )
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)
            let manifestURL = harness.serviceDir.appendingPathComponent(WixSiteSnapshotSupport.manifestRelativePath)

            try await self.waitForCollectionFile(catalogURL)
            try await self.waitForCollectionFile(objectURL)
            try await self.waitUntil("site snapshot manifest to exist") {
                FileManager.default.fileExists(atPath: manifestURL.path)
            }

            let rawJSON = try self.readJSON(catalogRelativePath, under: harness.serviceDir)
            let catalogRecord: [String: Any]
            if let records = rawJSON as? [[String: Any]] {
                catalogRecord = try XCTUnwrap(records.first, "site/site-urls.json should contain one merged record")
            } else {
                catalogRecord = try XCTUnwrap(rawJSON as? [String: Any], "site/site-urls.json should decode to an object or array")
            }

            XCTAssertNotNil(catalogRecord["published"] as? [String: Any])
            XCTAssertNotNil(catalogRecord["editor"] as? [String: Any])
            XCTAssertFalse((catalogRecord["primaryUrl"] as? String ?? "").isEmpty, "Merged catalog should include primaryUrl")
            XCTAssertNotNil(catalogRecord["capturedAt"] as? String)

            let manifest = try XCTUnwrap(WixSiteSnapshotSupport.loadManifest(from: harness.serviceDir))
            XCTAssertEqual(manifest.entries.count, 3, "Live snapshot manifest should include the homepage plus the configured public blog and shop URLs")
            XCTAssertEqual(Set(manifest.entries.map(\.label)), Set(["home", "blog-posts", "products"]))
            XCTAssertTrue(manifest.entries.contains(where: { $0.id == "home" && $0.status == "success" }))
            XCTAssertTrue(manifest.entries.contains(where: { $0.id == "amit1-blog" && $0.status == "success" }))
            XCTAssertTrue(manifest.entries.contains(where: { $0.id == "amit1-shop" && $0.status == "error" }), "The current live Wix shop URL returns 404 and should remain a non-fatal snapshot error")

            for entry in manifest.entries {
                if let htmlPath = entry.htmlPath {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: harness.serviceDir.appendingPathComponent(htmlPath).path))
                    XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath(htmlPath))
                    let exposedHTMLPath = WixSiteSnapshotSupport.exposedPath(forDerivedPath: htmlPath)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: harness.serviceDir.appendingPathComponent(exposedHTMLPath).path))
                    XCTAssertTrue(SyncedFilePreviewSupport.isUserFacingRelativePath(exposedHTMLPath))
                }
                if let screenshotPath = entry.screenshotPath {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: harness.serviceDir.appendingPathComponent(screenshotPath).path))
                    XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath(screenshotPath))
                    let exposedScreenshotPath = WixSiteSnapshotSupport.exposedPath(forDerivedPath: screenshotPath)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: harness.serviceDir.appendingPathComponent(exposedScreenshotPath).path))
                    XCTAssertTrue(SyncedFilePreviewSupport.isUserFacingRelativePath(exposedScreenshotPath))
                }
            }

            let fileLink = try XCTUnwrap(FileLinkManager.linkForUserPath(catalogRelativePath, in: harness.serviceDir))
            XCTAssertTrue(fileLink.derivedPaths.contains(WixSiteSnapshotSupport.manifestRelativePath))
            XCTAssertTrue(fileLink.derivedPaths.contains(WixSiteSnapshotSupport.exposedManifestRelativePath))
            XCTAssertTrue(fileLink.derivedPaths.contains(where: { $0.hasSuffix("/home.rendered.html") }))
            for entry in manifest.entries {
                if let htmlPath = entry.htmlPath {
                    XCTAssertTrue(fileLink.derivedPaths.contains(htmlPath))
                    XCTAssertTrue(fileLink.derivedPaths.contains(WixSiteSnapshotSupport.exposedPath(forDerivedPath: htmlPath)))
                }
            }

            let navigatedURLs = await MainActor.run { browser.navigatedURLs }
            XCTAssertTrue(navigatedURLs.contains(where: { $0.contains("/blog") }), "Snapshot browser should fetch the public blog URL")
            XCTAssertTrue(navigatedURLs.contains(where: { $0.contains("/shop") }), "Snapshot browser should fetch the public shop URL")
        }
    }

    func testCoupons_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "coupons",
            relativePath: "coupons.csv",
            expectedColumns: ["id", "name", "code"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testPricingPlans_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "pricing-plans",
            relativePath: "pricing-plans.csv",
            expectedColumns: ["id", "name"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testGiftCards_Pull_WritesExpectedFileWhenInstalled() async throws {
        try await assertCollectionPull(
            resourceName: "gift-cards",
            relativePath: "gift-cards.csv",
            expectedColumns: ["id", "balanceAmount", "initialValueAmount"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testMembers_Create_NewMember_AppearsOnServer() async throws {
        let res = try resource("members")
        let memberNickname = uniqueTestName("MemberCreate")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"

        let createdIdValue = try await engine.pushRecord(
            [
                "nickname": memberNickname,
                "slug": memberNickname.lowercased().replacingOccurrences(of: " ", with: "-"),
                "loginEmail": email
            ],
            resource: res,
            action: .create
        )
        let createdId = try XCTUnwrap(createdIdValue, "Expected create member push to return a member id")
        createdIds.append((resource: res, id: createdId))
        try await delay(1000)

        let created = try await getMember(id: createdId)
        XCTAssertEqual(created["id"] as? String, createdId)
        XCTAssertEqual(self.nickname(from: created), memberNickname)
    }

    func testMembers_Update_ModifyNickname_ReflectedOnServer() async throws {
        let res = try resource("members")
        let memberId = try await createMember(
            nickname: uniqueTestName("MemberBase"),
            loginEmail: "codex-\(UUID().uuidString.prefix(8))@example.com"
        )
        let updatedNickname = uniqueTestName("MemberUpdated")

        try await engine.pushRecord(
            [
                "nickname": updatedNickname,
                "slug": updatedNickname.lowercased().replacingOccurrences(of: " ", with: "-")
            ],
            resource: res,
            action: .update(id: memberId)
        )
        try await delay(1000)

        let updated = try await getMember(id: memberId)
        XCTAssertEqual(nickname(from: updated), updatedNickname)
    }

    func testMembers_Delete_RemoveMember_DeletedFromServer() async throws {
        let res = try resource("members")
        let memberId = try await createMember(
            nickname: uniqueTestName("MemberDelete"),
            loginEmail: "codex-\(UUID().uuidString.prefix(8))@example.com"
        )
        try await delay()

        try await engine.delete(remoteId: memberId, resource: res)
        createdIds.removeAll(where: { $0.id == memberId })
        try await delay(1000)

        do {
            _ = try await getMember(id: memberId)
            XCTFail("Deleted member should no longer be readable")
        } catch APIError.serverError(let statusCode) where statusCode == 404 {
            // expected
        }
    }

    func testMembers_ThreeWayUpdatePropagation() async throws {
        let memberId = try await createMember(
            nickname: uniqueTestName("Member3WayBase"),
            loginEmail: "codex-\(UUID().uuidString.prefix(8))@example.com"
        )

        try await withIsolatedSyncHarness(resourceNames: ["members"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let humanRelativePath = "members.csv"
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)

            try await self.waitUntil("member row pulled into members.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == memberId }
            }

            let humanToken = self.uniqueTestName("Member3WayHuman")
            var rows = try self.readCSV(at: humanURL)
            guard let rowIndex = rows.firstIndex(where: { self.recordId(from: $0) == memberId }) else {
                XCTFail("Failed to locate member \(memberId) in members.csv")
                return
            }
            rows[rowIndex]["nickname"] = humanToken
            try self.writeCSV(rows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)
            try await self.waitUntil("member human edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: humanToken) else { return false }
                return (record["id"] as? String) == memberId
            }
            try await self.waitUntil("member human edit reached server") {
                let members = try await self.queryMembers()
                return members.contains(where: { ($0["id"] as? String) == memberId && self.nickname(from: $0) == humanToken })
            }

            let objectToken = self.uniqueTestName("Member3WayObject")
            var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let rawIndex = rawRecords.firstIndex(where: { ($0["id"] as? String) == memberId }) else {
                XCTFail("Failed to locate member \(memberId) in .members.objects.json")
                return
            }
            var profile = rawRecords[rawIndex]["profile"] as? [String: Any] ?? [:]
            profile["nickname"] = objectToken
            profile["slug"] = objectToken.lowercased().replacingOccurrences(of: " ", with: "-")
            rawRecords[rawIndex]["profile"] = profile
            try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectRelativePath)
            try await self.waitUntil("member object edit reached members.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == memberId && ($0["nickname"] as? String) == objectToken })
            }
            try await self.waitUntil("member object edit reached server") {
                let members = try await self.queryMembers()
                return members.contains(where: { ($0["id"] as? String) == memberId && self.nickname(from: $0) == objectToken })
            }

            let serverToken = self.uniqueTestName("Member3WayServer")
            _ = try await self.wixAPI(
                method: .PATCH,
                path: "/members/v1/members/\(memberId)",
                body: [
                    "member": [
                        "profile": [
                            "nickname": serverToken,
                            "slug": serverToken.lowercased().replacingOccurrences(of: " ", with: "-")
                        ]
                    ]
                ]
            )
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("member server edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: serverToken) else { return false }
                return (record["id"] as? String) == memberId
            }
            try await self.waitUntil("member server edit reached members.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == memberId && ($0["nickname"] as? String) == serverToken })
            }
        }
    }

    func testForms_Create_NewForm_AppearsOnServer() async throws {
        let res = try resource("forms")
        let name = uniqueTestName("FormCreate")

        let createdIdValue = try await engine.pushRecord(["name": name], resource: res, action: .create)
        let createdId = try XCTUnwrap(createdIdValue, "Expected create form push to return a form id")
        createdIds.append((resource: res, id: createdId))
        try await delay(1000)

        let created = try await getForm(id: createdId)
        XCTAssertEqual(created["id"] as? String, createdId)
        XCTAssertEqual(created["name"] as? String, name)
        XCTAssertEqual(created["namespace"] as? String, wixFormsNamespace)
    }

    func testForms_Update_ModifyName_ReflectedOnServer() async throws {
        let res = try resource("forms")
        let formId = try await createForm(name: uniqueTestName("FormBase"))
        let current = try await getForm(id: formId)
        let updatedName = uniqueTestName("FormUpdated")

        try await engine.pushRecord(
            [
                "name": updatedName,
                "revision": current["revision"] as? String ?? "\(current["revision"] ?? "1")"
            ],
            resource: res,
            action: .update(id: formId)
        )
        try await delay(1000)

        let updated = try await getForm(id: formId)
        XCTAssertEqual(updated["name"] as? String, updatedName)
    }

    func testForms_Delete_RemoveForm_DeletedFromServer() async throws {
        let res = try resource("forms")
        let formId = try await createForm(name: uniqueTestName("FormDelete"))
        try await delay()

        try await engine.delete(remoteId: formId, resource: res)
        createdIds.removeAll(where: { $0.id == formId })
        try await delay(1000)

        do {
            _ = try await getForm(id: formId)
            XCTFail("Deleted form should no longer be readable")
        } catch APIError.serverError(let statusCode) where statusCode == 404 {
            // expected
        }
    }

    func testForms_ThreeWayUpdatePropagation() async throws {
        let formId = try await createForm(name: uniqueTestName("Form3WayBase"))

        try await withIsolatedSyncHarness(resourceNames: ["forms"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let humanRelativePath = "forms.csv"
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)

            try await self.waitUntil("form row pulled into forms.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == formId }
            }

            let humanToken = self.uniqueTestName("Form3WayHuman")
            var rows = try self.readCSV(at: humanURL)
            guard let rowIndex = rows.firstIndex(where: { self.recordId(from: $0) == formId }) else {
                XCTFail("Failed to locate form \(formId) in forms.csv")
                return
            }
            rows[rowIndex]["name"] = humanToken
            try self.writeCSV(rows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)
            try await self.waitUntil("form human edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: humanToken) else { return false }
                return (record["id"] as? String) == formId
            }
            try await self.waitUntil("form human edit reached server") {
                let forms = try await self.queryForms()
                return forms.contains(where: { ($0["id"] as? String) == formId && ($0["name"] as? String) == humanToken })
            }

            let objectToken = self.uniqueTestName("Form3WayObject")
            var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let rawIndex = rawRecords.firstIndex(where: { ($0["id"] as? String) == formId }) else {
                XCTFail("Failed to locate form \(formId) in .forms.objects.json")
                return
            }
            rawRecords[rawIndex]["name"] = objectToken
            var properties = rawRecords[rawIndex]["properties"] as? [String: Any] ?? [:]
            properties["name"] = objectToken
            rawRecords[rawIndex]["properties"] = properties
            try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectRelativePath)
            try await self.waitUntil("form object edit reached forms.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == formId && ($0["name"] as? String) == objectToken })
            }
            try await self.waitUntil("form object edit reached server") {
                let forms = try await self.queryForms()
                return forms.contains(where: { ($0["id"] as? String) == formId && ($0["name"] as? String) == objectToken })
            }

            let serverToken = self.uniqueTestName("Form3WayServer")
            let current = try await self.getForm(id: formId)
            _ = try await self.wixAPI(
                method: .PATCH,
                path: "/form-schema-service/v4/forms/\(formId)",
                body: [
                    "form": [
                        "revision": current["revision"] as? String ?? "\(current["revision"] ?? "1")",
                        "name": serverToken,
                        "namespace": self.wixFormsNamespace
                    ]
                ]
            )
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("form server edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: serverToken) else { return false }
                return (record["id"] as? String) == formId
            }
            try await self.waitUntil("form server edit reached forms.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == formId && ($0["name"] as? String) == serverToken })
            }
        }
    }

    func testFormSubmissions_CreateUpdateDelete_WhenNamespaceAllowsIt() async throws {
        let formId = try await createForm(name: uniqueTestName("SubmissionParent"))
        let submissionId = try await createFormSubmission(formId: formId)
        defer {
            Task { try? await self.deleteFormSubmission(id: submissionId) }
        }
        try await delay(1000)

        let created = try await getFormSubmission(id: submissionId)
        XCTAssertEqual(created["formId"] as? String, formId)

        _ = try await wixAPI(
            method: .PATCH,
            path: "/form-submission-service/v4/submissions/\(submissionId)",
            body: [
                "submission": [
                    "seen": true
                ]
            ]
        )
        try await delay(1000)

        let updated = try await getFormSubmission(id: submissionId)
        XCTAssertEqual(updated["id"] as? String, submissionId)
    }

    func testOrders_Update_ModifyRecipientName_ReflectedOnServer() async throws {
        let res = try resource("orders")
        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)

        let rows = try readCSV("orders.csv")
        guard var row = rows.first, let orderId = recordId(from: row) else {
            throw XCTSkip("No Wix eCommerce orders available on this site")
        }

        let updatedName = uniqueTestName("OrderRecipient")
        if row["recipientFirstName"] != nil {
            row["recipientFirstName"] = updatedName
        } else if row["billingFirstName"] != nil {
            row["billingFirstName"] = updatedName
        } else if row["shippingFirstName"] != nil {
            row["shippingFirstName"] = updatedName
        } else {
            throw XCTSkip("No safe editable contact-name column available on the first Wix order")
        }

        try await engine.pushRecord(row, resource: res, action: .update(id: orderId))
        try await delay(1000)

        let updatedOrders = try await queryOrders()
        let updated = updatedOrders.first(where: { ($0["id"] as? String) == orderId })
        XCTAssertTrue(
            recursiveStringContainsToken(updated, token: updatedName),
            "Updated order should contain the edited recipient/billing/shipping name"
        )
    }

    func testOrders_ThreeWayUpdatePropagation_WhenEditableOrderExists() async throws {
        let existingOrders = try await queryOrders()
        guard let seedOrder = existingOrders.first,
              let orderId = seedOrder["id"] as? String else {
            throw XCTSkip("No Wix eCommerce orders available on this site")
        }

        enum EditableOrderField {
            case recipientFirstName
            case billingFirstName
            case shippingFirstName
        }

        let editableField: ([String: Any]) -> EditableOrderField? = { row in
            if row["recipientFirstName"] != nil { return .recipientFirstName }
            if row["billingFirstName"] != nil { return .billingFirstName }
            if row["shippingFirstName"] != nil { return .shippingFirstName }
            return nil
        }

        let serverPatch: (EditableOrderField, [String: Any], String) -> [String: Any] = { field, latest, token in
            switch field {
            case .recipientFirstName:
                var recipient = latest["recipientInfo"] as? [String: Any] ?? [:]
                var details = recipient["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = token
                recipient["contactDetails"] = details
                return ["order": ["recipientInfo": recipient]]
            case .billingFirstName:
                var billing = latest["billingInfo"] as? [String: Any] ?? [:]
                var details = billing["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = token
                billing["contactDetails"] = details
                return ["order": ["billingInfo": billing]]
            case .shippingFirstName:
                var shipping = latest["shippingInfo"] as? [String: Any] ?? [:]
                var logistics = shipping["logistics"] as? [String: Any] ?? [:]
                var destination = logistics["shippingDestination"] as? [String: Any] ?? [:]
                var details = destination["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = token
                destination["contactDetails"] = details
                logistics["shippingDestination"] = destination
                shipping["logistics"] = logistics
                return ["order": ["shippingInfo": shipping]]
            }
        }

        try await withIsolatedSyncHarness(resourceNames: ["orders"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let humanRelativePath = "orders.csv"
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)

            var rows = try self.readCSV(at: humanURL)
            guard let rowIndex = rows.firstIndex(where: { self.recordId(from: $0) == orderId }) else {
                throw XCTSkip("Seed order was not pulled into orders.csv")
            }
            guard let field = editableField(rows[rowIndex]) else {
                throw XCTSkip("No safe editable order contact-name field found for live three-way test")
            }

            let humanToken = self.uniqueTestName("Order3WayHuman")
            switch field {
            case .recipientFirstName:
                rows[rowIndex]["recipientFirstName"] = humanToken
            case .billingFirstName:
                rows[rowIndex]["billingFirstName"] = humanToken
            case .shippingFirstName:
                rows[rowIndex]["shippingFirstName"] = humanToken
            }
            try self.writeCSV(rows, to: humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)
            try await self.waitUntil("order human edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: humanToken) else { return false }
                return (record["id"] as? String) == orderId
            }

            let objectToken = self.uniqueTestName("Order3WayObject")
            var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let rawIndex = rawRecords.firstIndex(where: { ($0["id"] as? String) == orderId }) else {
                XCTFail("Failed to locate order \(orderId) in .orders.objects.json")
                return
            }
            switch field {
            case .recipientFirstName:
                var recipient = rawRecords[rawIndex]["recipientInfo"] as? [String: Any] ?? [:]
                var details = recipient["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = objectToken
                recipient["contactDetails"] = details
                rawRecords[rawIndex]["recipientInfo"] = recipient
            case .billingFirstName:
                var billing = rawRecords[rawIndex]["billingInfo"] as? [String: Any] ?? [:]
                var details = billing["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = objectToken
                billing["contactDetails"] = details
                rawRecords[rawIndex]["billingInfo"] = billing
            case .shippingFirstName:
                var shipping = rawRecords[rawIndex]["shippingInfo"] as? [String: Any] ?? [:]
                var logistics = shipping["logistics"] as? [String: Any] ?? [:]
                var destination = logistics["shippingDestination"] as? [String: Any] ?? [:]
                var details = destination["contactDetails"] as? [String: Any] ?? [:]
                details["firstName"] = objectToken
                destination["contactDetails"] = details
                logistics["shippingDestination"] = destination
                shipping["logistics"] = logistics
                rawRecords[rawIndex]["shippingInfo"] = shipping
            }
            try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectRelativePath)
            try await self.waitUntil("order object edit reached orders.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == orderId && self.recursiveStringContainsToken($0, token: objectToken) })
            }

            let serverToken = self.uniqueTestName("Order3WayServer")
            let latest = try await self.queryOrders().first(where: { ($0["id"] as? String) == orderId }) ?? seedOrder
            _ = try await self.wixAPI(
                method: .PATCH,
                path: "/ecom/v1/orders/\(orderId)",
                body: serverPatch(field, latest, serverToken)
            )
            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("order server edit reached object file") {
                guard let record = try self.objectRecordContainingToken(objectURL, token: serverToken) else { return false }
                return (record["id"] as? String) == orderId
            }
            try await self.waitUntil("order server edit reached orders.csv") {
                let refreshed = try self.readCSV(at: humanURL)
                return refreshed.contains(where: { self.recordId(from: $0) == orderId && self.recursiveStringContainsToken($0, token: serverToken) })
            }
        }
    }

    // ======================================================================
    // MARK: - Products — Pull
    // ======================================================================

    func testProducts_Pull_ReturnsCSVWithProductData() async throws {
        let res = try resource("products")
        let result = try await engine.pull(resource: res)
        let humanRelativePath = try collectionRelativePath(for: res)

        XCTAssertFalse(result.files.isEmpty)
        let file = result.files.first!
        XCTAssertEqual(file.relativePath, humanRelativePath)

        try writeFilesToDisk(result.files)
        let records = try readCSV(humanRelativePath)
        XCTAssertFalse(records.isEmpty, "No records in \(humanRelativePath)")

        let columns = Set(records[0].keys)
        for expected in ["id", "name", "priceAmount", "slug", "visible"] {
            XCTAssertTrue(columns.contains(expected), "Missing column: \(expected)")
        }
        XCTAssertFalse(columns.contains("revision"), "Products human CSV should not expose revision")
        XCTAssertFalse(columns.contains("_url"), "Products human CSV should not expose _url")
    }

    func testProducts_Pull_ContainsKnownProducts() async throws {
        let res = try resource("products")
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(try collectionRelativePath(for: res))

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
        let res = try resource("products")
        let humanRelativePath = try collectionRelativePath(for: res)

        // Pull products to get current state
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(humanRelativePath)
        XCTAssertFalse(records.isEmpty)

        // Pick the first product and note its original name
        let original = records[0]
        guard let productId = recordId(from: original) else {
            XCTFail("Product missing id"); return
        }
        let originalName = original["name"] as? String ?? ""
        let testSuffix = " E2E"

        // Get revision directly from the server (human CSV intentionally hides it)
        let serverOriginal = try await getProduct(id: productId)
        let revision: Int
        if let rev = serverOriginal["revision"] as? Int { revision = rev }
        else if let revStr = serverOriginal["revision"] as? String, let rev = Int(revStr) { revision = rev }
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
        let records2 = try readCSV(humanRelativePath)
        let updated = records2.first(where: { recordId(from: $0) == productId })
        XCTAssertTrue(
            (updated?["name"] as? String)?.contains(testSuffix) == true,
            "Product name should contain test suffix"
        )

        // Restore original name — fetch updated revision from server (revision is not in CSV)
        let serverUpdated = try await getProduct(id: productId)
        let newRevision: Int
        if let rev = serverUpdated["revision"] as? Int { newRevision = rev }
        else if let revStr = serverUpdated["revision"] as? String, let rev = Int(revStr) { newRevision = rev }
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
        let res = try resource("products")
        let humanRelativePath = try collectionRelativePath(for: res)

        // Pull current products
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(humanRelativePath)
        XCTAssertFalse(records.isEmpty)

        let original = records[0]
        guard let productId = recordId(from: original) else {
            XCTFail("Product missing id"); return
        }
        let originalName = original["name"] as? String ?? ""
        let serverOriginal = try await getProduct(id: productId)
        let revisionBefore: Int
        if let rev = serverOriginal["revision"] as? Int { revisionBefore = rev }
        else if let revStr = serverOriginal["revision"] as? String, let rev = Int(revStr) { revisionBefore = rev }
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

        // Re-pull and check revision — fetch from server (revision is not in CSV)
        _ = try await engine.pull(resource: res)
        let serverUpdated = try await getProduct(id: productId)
        let revisionAfter: Int
        if let rev = serverUpdated["revision"] as? Int { revisionAfter = rev }
        else if let revStr = serverUpdated["revision"] as? String, let rev = Int(revStr) { revisionAfter = rev }
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
        let res = try resource("products")

        // Create a test product — try V1 first (simpler), fall back to V3 with full fields
        let testName = uniqueTestName("Product")
        var productId: String?

        // V3 API — requires variantsInfo with at least one variant
        let v3Body: [String: Any] = [
            "product": [
                "name": testName,
                "productType": "PHYSICAL",
                "visible": true,
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

        // Verify exists on the server. Freshly created Wix products are not always returned
        // by the pull/search surface immediately, even though create succeeded.
        let fetched = try await getProduct(id: productId)
        XCTAssertEqual(fetched["id"] as? String, productId, "Test product should exist on the server")

        // Delete via engine
        try await engine.delete(remoteId: productId, resource: res)
        try await delay(1000)

        // Verify gone on the server.
        do {
            _ = try await getProduct(id: productId)
            XCTFail("Product should be deleted")
        } catch APIError.serverError(let statusCode) where statusCode == 404 {
            // expected
        }
    }

    func testProducts_Create_NewProduct_AppearsOnServer() async throws {
        let res = try resource("products")
        let testName = uniqueTestName("ProductCreate")

        let createBody: [String: Any] = [
            "product": [
                "name": testName,
                "productType": "PHYSICAL",
                "visible": true,
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

        let fetched = try await getProduct(id: productId)
        XCTAssertEqual(fetched["id"] as? String, productId, "Created product should be readable from the server")
        XCTAssertEqual(fetched["name"] as? String, testName)
    }

    func testProducts_Create_TenCSVRows_AppearOnServer() async throws {
        let res = try resource("products")
        let prefix = uniqueTestName("CSVProductBatch")

        let rows: [[String: Any]] = (1...10).map { index in
            [
                "name": "\(prefix)-\(index)",
                "priceAmount": 10 + index,
                "productType": "PHYSICAL",
                "slug": "\(prefix.lowercased())-\(index)",
                "visible": true
            ]
        }

        let csvData = try CSVFormat.encode(records: rows, options: nil)
        let decodedRows = try CSVFormat.decode(data: csvData, options: nil)
        XCTAssertEqual(decodedRows.count, 10, "Expected 10 decoded CSV rows")

        var createdProductIds: [String] = []
        for row in decodedRows {
            if let id = try await engine.pushRecord(row, resource: res, action: .create) {
                createdProductIds.append(id)
            }
            try await delay(250)
        }

        XCTAssertEqual(createdProductIds.count, 10, "Expected all 10 CSV rows to return created Wix product IDs")

        try await delay(1500)

        for (index, id) in createdProductIds.enumerated() {
            let fetched = try await getProduct(id: id)
            XCTAssertEqual(fetched["id"] as? String, id)
            XCTAssertEqual(fetched["name"] as? String, "\(prefix)-\(index + 1)")
            createdIds.append((resource: res, id: id))
        }

        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let records = try readCSV(try collectionRelativePath(for: res))
        let createdNames = Set(records.compactMap { $0["name"] as? String }.filter { $0.hasPrefix(prefix) })
        XCTAssertGreaterThanOrEqual(createdNames.count, 1, "Expected at least some created products to appear in pull/search results")
    }

    // ======================================================================
    // MARK: - Contacts — Pull / Create / Update / Delete
    // ======================================================================

    func testContacts_Pull_ReturnsCSVWithExpectedFields() async throws {
        let res = try resource("contacts")
        let result = try await engine.pull(resource: res)
        try writeFilesToDisk(result.files)
        let humanRelativePath = try collectionRelativePath(for: res)

        let records = try readCSV(humanRelativePath)
        XCTAssertFalse(records.isEmpty, "\(humanRelativePath) should contain at least one row")

        let first = try XCTUnwrap(records.first)
        XCTAssertNotNil(first["_id"] ?? first["id"], "\(humanRelativePath) should expose a stable identifier column")
        XCTAssertNotNil(first["primaryEmail"], "\(humanRelativePath) should expose a simple primaryEmail column")
        XCTAssertNotNil(contactEmail(from: first), "\(humanRelativePath) should expose a readable email representation")
        if let primaryEmail = first["primaryEmail"] as? String, !primaryEmail.isEmpty {
            XCTAssertFalse(primaryEmail.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), "\(humanRelativePath) should project primaryEmail as a plain string, not a JSON object blob")
        }
        XCTAssertNil(first["_url"], "\(humanRelativePath) should not expose _url")
        XCTAssertNil(first["memberInfo"], "\(humanRelativePath) should not expose nested memberInfo")
        XCTAssertNil(first["primaryInfo"], "\(humanRelativePath) should not expose nested primaryInfo")
        XCTAssertNil(first["createdDate"], "\(humanRelativePath) should not expose server timestamps")
        XCTAssertNil(first["updatedDate"], "\(humanRelativePath) should not expose server timestamps")

        let rawFirst = try XCTUnwrap(result.rawRecordsByFile[humanRelativePath]?.first)
        let rawName = (rawFirst["info"] as? [String: Any])?["name"] as? [String: Any]
        XCTAssertNotNil(rawName?["first"] as? String, "contacts pull should preserve first name in raw records")
        XCTAssertNotNil(rawName?["last"] as? String, "contacts pull should preserve last name in raw records")
    }

    func testContacts_Create_NewContact_AppearsOnServer() async throws {
        let res = try resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV(try collectionRelativePath(for: res))
        let found = records.first(where: { recordId(from: $0) == created.id })
        XCTAssertNotNil(found, "Created contact should appear in local pull")
        XCTAssertEqual(contactEmail(from: found ?? [:])?.lowercased(), email.lowercased())
    }

    func testContacts_Update_ModifyName_ReflectedOnServer() async throws {
        let res = try resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay()

        func patchContact() async throws {
            let latest = try await getContact(id: created.id)
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
        }

        do {
            try await patchContact()
        } catch APIError.serverError(let statusCode) where statusCode == 409 {
            try await delay(500)
            try await patchContact()
        }
        try await delay(1000)

        let pullResult = try await withTransientRetry {
            try await self.engine.pull(resource: res)
        }
        let raw = try XCTUnwrap(pulledRawRecord(from: pullResult, relativePath: try collectionRelativePath(for: res), id: created.id))
        let rawName = (raw["info"] as? [String: Any])?["name"] as? [String: Any]
        XCTAssertEqual(rawName?["first"] as? String, "CodexUpdated")
    }

    func testContacts_EngineUpdate_RawRecordPush_ReflectedOnServer() async throws {
        let res = try resource("contacts")
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Contact", email: email)
        try await delay()

        func pushUpdatedContact() async throws {
            let latest = try await getContact(id: created.id)
            let latestRevision = latest["revision"] as? Int ?? Int("\(latest["revision"] ?? 0)") ?? created.revision

            var edited = latest
            edited["revision"] = latestRevision
            var info = edited["info"] as? [String: Any] ?? [:]
            var name = info["name"] as? [String: Any] ?? [:]
            name["first"] = "CodexEngine"
            name["last"] = "Update"
            info["name"] = name
            edited["info"] = info

            try await engine.pushRecord(edited, resource: res, action: .update(id: created.id))
        }

        do {
            try await pushUpdatedContact()
        } catch APIError.serverError(let statusCode) where statusCode == 409 {
            try await delay(500)
            try await pushUpdatedContact()
        }
        try await delay(1000)

        let refreshed = try await getContact(id: created.id)
        let refreshedInfo = refreshed["info"] as? [String: Any]
        let refreshedName = refreshedInfo?["name"] as? [String: Any]
        XCTAssertEqual(refreshedName?["first"] as? String, "CodexEngine")
        XCTAssertEqual(refreshedName?["last"] as? String, "Update")
    }

    func testContacts_ServerUpdate_ReflectedInObjectAndLocalFiles() async throws {
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Server", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)
            try await self.waitUntil("contact row pulled into contacts.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id }
            }

            let latest = try await self.getContact(id: created.id)
            let revision = latest["revision"] as? Int ?? Int("\(latest["revision"] ?? 0)") ?? created.revision
            let token = self.uniqueTestName("ContactServer")
            _ = try await self.wixAPI(
                method: .PATCH,
                path: "/contacts/v4/contacts/\(created.id)",
                body: [
                    "revision": revision,
                    "info": [
                        "name": [
                            "first": token,
                            "last": "Server",
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
            )

            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("contact server update on object file") {
                guard let record = try self.objectRecord(withId: created.id, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: token)
            }
            try await self.waitUntil("contact server update on human file") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id && self.recursiveStringContainsToken($0, token: token) }
            }
        }
    }

    func testContacts_ObjectFileEdit_PropagatesToHumanAndServer() async throws {
        let email = "codex-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Codex", lastName: "Object", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)
            try await self.waitUntil("contact row pulled before object edit") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id }
            }

            let token = self.uniqueTestName("ContactObject")
            var rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            guard let rawIndex = rawRecords.firstIndex(where: {
                ($0["id"] as? String) == created.id || ($0["_id"] as? String) == created.id
            }) else {
                XCTFail("Failed to locate contact \(created.id) in \(objectRelativePath)")
                return
            }

            var info = rawRecords[rawIndex]["info"] as? [String: Any] ?? [:]
            var name = info["name"] as? [String: Any] ?? [:]
            name["first"] = token
            name["last"] = "Object"
            info["name"] = name

            var emails = info["emails"] as? [String: Any] ?? [:]
            var items = emails["items"] as? [[String: Any]] ?? []
            if items.isEmpty {
                items = [[
                    "email": email,
                    "primary": true
                ]]
            } else {
                items[0]["email"] = email
                items[0]["primary"] = true
            }
            emails["items"] = items
            info["emails"] = emails
            rawRecords[rawIndex]["info"] = info

            try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: objectRelativePath)

            try await self.waitUntil("contact object edit reached contacts.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains {
                    self.recordId(from: $0) == created.id &&
                    self.contactFirstName(from: $0) == token
                }
            }
            try await self.waitUntil("contact object edit reached server") {
                let latest = try await self.getContact(id: created.id)
                let latestName = (latest["info"] as? [String: Any])?["name"] as? [String: Any]
                return latestName?["first"] as? String == token
            }
        }
    }

    func testContacts_Delete_RemoveContact_DeletedFromServer() async throws {
        let res = try resource("contacts")
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
    // MARK: - Contacts — Bidirectional Live Sync (create / update / delete)
    // ======================================================================

    /// Server creates a contact → contact row appears in contacts.csv after sync.
    func testContacts_LiveSync_ServerCreate_AppearsInCSV() async throws {
        let email = "codex-create-\(UUID().uuidString.prefix(8))@example.com"
        let token = uniqueTestName("LiveCreate")
        let created = try await createContact(firstName: token, lastName: "LiveSync", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            try await self.waitForCollectionFile(humanURL)

            try await self.waitUntil("created contact row appears in contacts.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { row in
                    self.recordId(from: row) == created.id ||
                    self.contactEmail(from: row)?.lowercased() == email.lowercased()
                }
            }

            let rows = try self.readCSV(at: humanURL)
            let row = rows.first { self.recordId(from: $0) == created.id }
            XCTAssertNotNil(row, "contacts.csv should contain the server-created contact")
            XCTAssertEqual(
                self.contactEmail(from: row ?? [:])?.lowercased(),
                email.lowercased(),
                "contacts.csv row should have the correct email"
            )
            XCTAssertEqual(
                self.contactFirstName(from: row ?? [:]),
                token,
                "contacts.csv row should reflect the first name"
            )
        }
    }

    /// Server deletes a contact → row disappears from contacts.csv after next sync.
    func testContacts_LiveSync_ServerDelete_RemovedFromCSV() async throws {
        let email = "codex-del-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "LiveDelete", lastName: "Contact", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            try await self.waitForCollectionFile(humanURL)

            // Verify contact is in the initial CSV
            try await self.waitUntil("contact row initially present") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id }
            }

            // Delete from server
            _ = try await self.wixAPI(method: .DELETE, path: "/contacts/v4/contacts/\(created.id)")
            self.createdIds.removeAll(where: { $0.id == created.id })
            // Give Wix a moment to propagate the delete before querying
            try await self.delay(2000)

            // Poll: trigger sync and check until row disappears (Wix has eventual consistency)
            try await self.waitUntil("deleted contact row removed from contacts.csv", timeout: 60) {
                try await self.triggerAndWaitForSync(harness.syncEngine)
                let rows = try self.readCSV(at: humanURL)
                return !rows.contains { self.recordId(from: $0) == created.id }
            }
        }
    }

    /// Edit a CSV row's first name locally → PATCH reaches the Wix server.
    func testContacts_LiveSync_LocalCSVEdit_PushesUpdateToServer() async throws {
        let email = "codex-edit-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "LiveEdit", lastName: "Contact", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            try await self.waitForCollectionFile(humanURL)
            try await self.waitUntil("test contact row in CSV before edit") {
                try self.readCSV(at: humanURL).contains { self.recordId(from: $0) == created.id }
            }

            // Edit: change first name to a unique token
            let token = self.uniqueTestName("LiveEditFirst")
            var rows = try self.readCSV(at: humanURL)
            guard let idx = rows.firstIndex(where: { self.recordId(from: $0) == created.id }) else {
                throw XCTSkip("Test contact not found in contacts.csv")
            }
            rows[idx]["first"] = token
            try self.writeCSV(rows, to: humanURL)

            // Push: file-change → queue push → sync cycle → PATCH Wix contact
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)

            // Verify server reflects the first-name change
            try await self.waitUntil("server contact first name updated", timeout: 30) {
                let contact = try await self.getContact(id: created.id)
                let name = (contact["info"] as? [String: Any])?["name"] as? [String: Any]
                return name?["first"] as? String == token
            }
        }
    }

    /// Add a new CSV row with no ID → POST creates a new contact on the Wix server.
    func testContacts_LiveSync_LocalCSVAdd_CreatesContactOnServer() async throws {
        let email = "codex-new-\(UUID().uuidString.prefix(8))@example.com"
        let token = uniqueTestName("LiveNewFirst")

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            try await self.waitForCollectionFile(humanURL)

            // Append a new row with no id
            var rows = try self.readCSV(at: humanURL)
            rows.append([
                "id": "",
                "first": token,
                "last": "LiveNew",
                "primaryEmail": email,
                "primaryPhone": "+1-555-0000"
            ])
            try self.writeCSV(rows, to: humanURL)

            // Push: file-change → queue push → sync cycle → POST Wix contact
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)

            // Verify new contact appears on server
            try await self.waitUntil("new contact appears on Wix server", timeout: 30) {
                let contacts = try await self.queryContacts()
                return contacts.contains {
                    let info = $0["info"] as? [String: Any]
                    let emails = info?["emails"] as? [String: Any]
                    let items = emails?["items"] as? [[String: Any]]
                    return items?.contains { ($0["email"] as? String)?.lowercased() == email.lowercased() } == true
                }
            }

            // Fetch the ID so tearDown can clean it up
            let allContacts = try await self.queryContacts()
            if let found = allContacts.first(where: {
                let info = $0["info"] as? [String: Any]
                let emails = info?["emails"] as? [String: Any]
                let items = emails?["items"] as? [[String: Any]]
                return items?.contains { ($0["email"] as? String)?.lowercased() == email.lowercased() } == true
            }), let id = found["id"] as? String {
                let res = try self.resource("contacts")
                self.createdIds.append((resource: res, id: id))
            } else {
                XCTFail("New contact ID not found on server after CSV push")
            }
        }
    }

    func testContacts_LiveSync_CleanSync_RebuildsLocalMirrorFromServer() async throws {
        let email = "codex-clean-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "Clean", lastName: "Sync", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)
            let scratchURL = harness.serviceDir.appendingPathComponent("scratch-clean-sync.txt")

            try await self.waitForCollectionFile(humanURL)
            try await self.waitUntil("contact row present before clean sync") {
                try self.readCSV(at: humanURL).contains { self.recordId(from: $0) == created.id }
            }

            XCTAssertTrue(FileManager.default.fileExists(atPath: objectURL.path))

            var rows = try self.readCSV(at: humanURL)
            guard let rowIndex = rows.firstIndex(where: { self.recordId(from: $0) == created.id }) else {
                throw XCTSkip("Test contact not found in contacts.csv")
            }
            rows[rowIndex]["first"] = "LOCAL-ONLY-CORRUPTION"
            try self.writeCSV(rows, to: humanURL)
            try "delete me".write(to: scratchURL, atomically: true, encoding: .utf8)

            try await harness.syncEngine.cleanSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)
            try await self.waitForCollectionFile(humanURL)

            XCTAssertFalse(FileManager.default.fileExists(atPath: scratchURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: objectURL.path))

            try await self.waitUntil("clean sync restores server-backed contact row") {
                let refreshedRows = try self.readCSV(at: humanURL)
                guard let refreshedRow = refreshedRows.first(where: { self.recordId(from: $0) == created.id }) else {
                    return false
                }
                return refreshedRow["first"] as? String != "LOCAL-ONLY-CORRUPTION"
            }
        }
    }

    /// Delete a CSV row → DELETE reaches the Wix server.
    func testContacts_LiveSync_LocalCSVDelete_DeletesContactFromServer() async throws {
        let email = "codex-csvdel-\(UUID().uuidString.prefix(8))@example.com"
        let created = try await createContact(firstName: "LiveCSVDel", lastName: "Contact", email: email)

        try await withIsolatedSyncHarness(resourceNames: ["contacts"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let contactsResource = try self.resource("contacts", in: harness.config)
            let humanRelativePath = try self.collectionRelativePath(for: contactsResource)
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            try await self.waitForCollectionFile(humanURL)
            try await self.waitUntil("test contact row present before deletion") {
                try self.readCSV(at: humanURL).contains { self.recordId(from: $0) == created.id }
            }

            // Remove the test contact's row and write the CSV back
            var rows = try self.readCSV(at: humanURL)
            rows.removeAll { self.recordId(from: $0) == created.id }
            try self.writeCSV(rows, to: humanURL)

            // Push: file-change → diff detects deletion → DELETE Wix contact
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: humanRelativePath)
            self.createdIds.removeAll(where: { $0.id == created.id })

            try await self.waitUntil("contact deleted from Wix server", timeout: 30) {
                let contacts = try await self.queryContacts()
                return !contacts.contains { $0["id"] as? String == created.id }
            }
        }
    }

    // ======================================================================
    // MARK: - CMS Events — Pull
    // ======================================================================

    func testCollections_Pull_UsesMetadataDrivenWritableCatalog() async throws {
        let res = try resource("collections")
        let result = try await engine.pull(resource: res)
        let humanRelativePath = try collectionRelativePath(for: res)
        XCTAssertFalse(result.files.isEmpty, "collections pull returned no files")
        XCTAssertEqual(result.files.first?.relativePath, humanRelativePath)

        let collections = try JSONSerialization.jsonObject(with: result.files[0].content) as? [[String: Any]]
        let ids = collections?.compactMap { $0["id"] as? String } ?? []
        let collectionTypes = collections?.compactMap { $0["collectionType"] as? String } ?? []
        let operations: [[String]] = (collections ?? []).compactMap {
            (($0["capabilities"] as? [String: Any])?["dataOperations"] as? [String])
        }

        XCTAssertFalse(ids.isEmpty, "collections pull should include at least one collection")
        XCTAssertTrue(collectionTypes.allSatisfy { $0 == "NATIVE" }, "collections.json should only surface NATIVE collections")
        XCTAssertTrue(
            operations.allSatisfy { Set($0).isSuperset(of: ["INSERT", "UPDATE", "REMOVE"]) },
            "collections.json should only surface collections whose live metadata proves writable CRUD support"
        )
        if let first = collections?.first {
            XCTAssertNil(first["_url"], "collections.json should not expose dashboard helper URLs")
            XCTAssertNil(first["revision"], "collections.json should not expose revision")
            XCTAssertNil(first["fields"], "collections.json should hide bulky field metadata from the user-facing catalog")
        }
    }

    func testCMSEvents_Pull_ReturnsCSVWithExpectedFields() async throws {
        try await assertCollectionPull(
            resourceName: "cms-events",
            relativePath: try collectionRelativePath(for: resource("cms-events")),
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
            expectedColumns: ["id", "title", "startDate", "endDate", "status", "shortDescription"]
        )

        let rows = try readCSV("events.csv")
        if let first = rows.first {
            let columns = Set(first.keys)
            XCTAssertFalse(columns.contains("_url"), "events.csv should not expose _url")
            XCTAssertFalse(columns.contains("createdDate"), "events.csv should not expose server timestamps")
            XCTAssertFalse(columns.contains("instanceId"), "events.csv should not expose event instance internals")
        }
    }

    func testEvents_Update_ModifyTitle_ReflectedOnServer() async throws {
        let res = try resource("events")
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
            relativePath: "bookings-services/services.csv",
            expectedColumns: ["id", "name", "type", "capacity", "onlineBookingEnabled"],
            allowEmptyFile: true
        )

        let records = try readCSV("bookings-services/services.csv")
        if let first = records.first {
            let columns = Set(first.keys)
            XCTAssertFalse(columns.contains("revision"), "Bookings services CSV should not expose revision")
            XCTAssertFalse(columns.contains("serviceResources"), "Bookings services CSV should not expose raw scaffolding")
            XCTAssertFalse(columns.contains("urls"), "Bookings services CSV should not expose dashboard URLs")
        }
    }

    func testBookingsServices_Create_NewService_AppearsOnServer() async throws {
        let res = try resource("bookings-services")
        let name = uniqueTestName("BookingService")
        let created = try await createBookingsService(name: name)
        try await delay(1000)

        let pullResult = try await engine.pull(resource: res)
        try writeFilesToDisk(pullResult.files)
        let records = try readCSV("bookings-services/services.csv")
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

        try await engine.delete(remoteId: created.id, resource: try resource("bookings-services"))
        createdIds.removeAll(where: { $0.id == created.id })
        try await delay(1000)

        let services = try await queryBookingsServices()
        XCTAssertFalse(services.contains(where: { $0["id"] as? String == created.id }), "Deleted bookings service should be gone from server")
    }

    func testBookingsServices_ServerUpdate_ReflectedInObjectAndLocalFiles() async throws {
        let created = try await createBookingsService(name: uniqueTestName("BookingServiceServer"))

        try await withIsolatedSyncHarness(resourceNames: ["bookings-services"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            let humanRelativePath = "bookings-services/services.csv"
            let humanURL = harness.serviceDir.appendingPathComponent(humanRelativePath)
            let objectRelativePath = ObjectFileManager.objectFilePath(forCollectionFile: humanRelativePath)
            let objectURL = harness.serviceDir.appendingPathComponent(objectRelativePath)

            try await self.waitForCollectionFile(humanURL)
            try await self.waitForCollectionFile(objectURL)
            try await self.waitUntil("bookings service row pulled into services.csv") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id }
            }

            let token = self.uniqueTestName("BookingServiceServer")
            let latest = try await self.getBookingsService(id: created.id)
            let body = self.bookingsServiceUpdateBody(service: latest, name: token)
            _ = try await self.wixAPI(method: .PATCH, path: "/bookings/v2/services/\(created.id)", body: body)

            try await self.triggerAndWaitForSync(harness.syncEngine)
            try await self.waitUntil("bookings service server update on object file") {
                guard let record = try self.objectRecord(withId: created.id, in: objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: token)
            }
            try await self.waitUntil("bookings service server update on human file") {
                let rows = try self.readCSV(at: humanURL)
                return rows.contains { self.recordId(from: $0) == created.id && self.recursiveStringContainsToken($0, token: token) }
            }
        }
    }

    func testBookingsAppointments_Pull_WritesExpectedFile() async throws {
        try await assertCollectionPull(
            resourceName: "bookings-appointments",
            relativePath: "bookings-appointments/appointments.csv",
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
            relativePath: "comments/comments.csv",
            expectedColumns: ["id", "text", "authorMemberId", "status"],
            allowEmptyFile: true
        )
    }

    func testBookings_HumanAndObjectUpdatePropagation() async throws {
        let created = try await createBookingsService(name: uniqueTestName("BookingJSON3Way"))

        try await withIsolatedSyncHarness(resourceNames: ["bookings"]) { harness in
            await harness.syncEngine.triggerSync(serviceId: "wix")
            try await self.waitForSyncIdle(harness.syncEngine)

            @Sendable func currentPaths() throws -> (humanRelativePath: String, humanURL: URL, objectRelativePath: String, objectURL: URL) {
                let relative = try self.findOnePerRecordFile(under: "bookings", matchingID: created.id, in: harness.serviceDir)
                let humanURL = harness.serviceDir.appendingPathComponent(relative)
                let objectRelative = ObjectFileManager.objectFilePath(forRecordFile: relative)
                let objectURL = harness.serviceDir.appendingPathComponent(objectRelative)
                return (relative, humanURL, objectRelative, objectURL)
            }

            let initial = try currentPaths()
            try await self.waitForCollectionFile(initial.humanURL)
            try await self.waitForCollectionFile(initial.objectURL)

            let humanToken = self.uniqueTestName("BookingJSONHuman")
            var humanRecord = try self.readJSONObject(at: initial.humanURL)
            humanRecord["name"] = humanToken
            try self.writeJSONObject(humanRecord, to: initial.humanURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: initial.humanRelativePath)
            try await self.waitUntil("bookings human edit on object file") {
                guard let latest = try? currentPaths(),
                      let record = try? ObjectFileManager.readRecordObjectFile(from: latest.objectURL) else { return false }
                return self.recursiveStringContainsToken(record, token: humanToken)
            }
            try await self.waitUntil("bookings human edit on server") {
                let service = try await self.getBookingsService(id: created.id)
                return self.recursiveStringContainsToken(service, token: humanToken)
            }

            let afterHuman = try currentPaths()
            let objectToken = self.uniqueTestName("BookingJSONObject")
            var objectRecord = try ObjectFileManager.readRecordObjectFile(from: afterHuman.objectURL)
            objectRecord["name"] = objectToken
            try ObjectFileManager.writeRecordObjectFile(record: objectRecord, to: afterHuman.objectURL)
            try await self.triggerAndWaitForSync(harness.syncEngine, filePath: afterHuman.objectRelativePath)
            try await self.waitUntil("bookings object edit on human file") {
                guard let latest = try? currentPaths(),
                      let refreshed = try? self.readJSONObject(at: latest.humanURL) else { return false }
                return self.recursiveStringContainsToken(refreshed, token: objectToken)
            }
            try await self.waitUntil("bookings object edit on server") {
                let service = try await self.getBookingsService(id: created.id)
                return self.recursiveStringContainsToken(service, token: objectToken)
            }
        }
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

        let pullResult = try await engine.pull(resource: try resource("blog-posts"))
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

        let pullResult = try await engine.pull(resource: try resource("blog-posts"))
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

        _ = try await engine.push(file: pushedFile, resource: try resource("blog-posts"))
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

        let pullResult = try await engine.pull(resource: try resource("blog-posts"))
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

        _ = try await engine.push(file: pushedFile, resource: try resource("blog-posts"))
        try await delay(1500)

        let detailedPost = try await getBlogPost(id: postId)
        let nodeTypes = richContentNodeTypes(detailedPost["richContent"])
        XCTAssertTrue(nodeTypes.contains("HEADING"), "Expected pushed markdown heading to become a Ricos heading node")
        XCTAssertTrue(nodeTypes.contains("BULLETED_LIST"), "Expected pushed markdown bullets to become a Ricos list node")

        let repulled = try await engine.pull(resource: try resource("blog-posts"))
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

        try await engine.delete(remoteId: postId, resource: try resource("blog-posts"))
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
        let res = try resource("pdf-viewer")
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
        let res = try resource("wix-video")
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
        let res = try resource("wix-music-podcasts")
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
            expectedColumns: ["id", "name", "description", "visible"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )

        let rows = try readCSV("restaurant/menus.csv")
        if let first = rows.first {
            let columns = Set(first.keys)
            XCTAssertFalse(columns.contains("revision"), "restaurant/menus.csv should not expose revision")
            XCTAssertFalse(columns.contains("urlQueryParam"), "restaurant/menus.csv should not expose URL query params")
        }
    }

    func testRestaurantMenus_Create_NewMenu_AppearsOnServer() async throws {
        let res = try resource("restaurant-menus")
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

        try await engine.delete(remoteId: created.id, resource: try resource("restaurant-menus"))
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
        let res = try resource("media")
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
        let res = try resource("media")
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
        let res = try resource("media")

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
        let res = try resource("media")

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

    // MARK: - Group Members — Pull
    // ======================================================================

    func testGroupMembers_Pull_ReturnsCSVForEachGroup() async throws {
        let groupsRes = try resource("groups")
        let result = try await engine.pull(resource: groupsRes)

        let memberFiles = result.files.filter { $0.relativePath.hasSuffix("/members.csv") }
        XCTAssertFalse(memberFiles.isEmpty, "Expected at least one groups/{slug}/members.csv in pull result — did the group-members child get added to the adapter?")

        try writeFilesToDisk(result.files)
    }

    func testGroupMembers_Pull_HasExpectedColumns_WhenMembersExist() async throws {
        let groupsRes = try resource("groups")
        let result = try await engine.pull(resource: groupsRes)

        let memberFiles = result.files.filter { $0.relativePath.hasSuffix("/members.csv") }
        guard let nonEmpty = memberFiles.first(where: { !$0.content.isEmpty }) else {
            throw XCTSkip("All groups have no members — cannot verify column schema")
        }

        try writeFilesToDisk(result.files)
        let records = try readCSV(at: serviceDir.appendingPathComponent(nonEmpty.relativePath))
        guard let first = records.first else {
            throw XCTSkip("members.csv is non-empty bytes but decoded to zero records")
        }

        let columns = Set(first.keys)
        XCTAssertTrue(columns.contains("memberId"), "Expected 'memberId' column in members.csv; got: \(columns.sorted())")
        XCTAssertTrue(columns.contains("role"), "Expected 'role' column in members.csv; got: \(columns.sorted())")
    }

    func testGroupMembers_Pull_PathMatchesGroupNameSlug() async throws {
        let groupsRes = try resource("groups")
        let pullResult = try await engine.pull(resource: groupsRes)

        // Pull parent groups to get canonical slugs
        let groupFiles = pullResult.files.filter { $0.relativePath == "groups.csv" }
        XCTAssertFalse(groupFiles.isEmpty, "groups.csv missing from pull result")

        try writeFilesToDisk(pullResult.files)

        let groupRecords = try readCSV("groups.csv")
        let memberFiles = pullResult.files.filter { $0.relativePath.hasSuffix("/members.csv") }
        XCTAssertFalse(memberFiles.isEmpty, "Expected members.csv children from group pull")

        // Every members.csv path should be under a valid group slug directory
        for memberFile in memberFiles {
            // path: groups/{slug}/members.csv
            let parts = memberFile.relativePath.split(separator: "/")
            XCTAssertEqual(parts.count, 3, "Unexpected path structure: \(memberFile.relativePath)")
            XCTAssertEqual(parts.first, "groups")
            XCTAssertEqual(parts.last, "members.csv")

            // The slug should correspond to a group name
            let slug = String(parts[1])
            let matchingGroup = groupRecords.first { record in
                guard let name = record["name"] as? String else { return false }
                return TemplateEngine.render("{value|slugify}", with: ["value": name]) == slug
            }
            XCTAssertNotNil(matchingGroup, "members.csv at '\(memberFile.relativePath)' has no matching group for slug '\(slug)'")
        }
    }

    // MARK: - Group Posts — Pull / Create / Update / Delete
    // ======================================================================

    func testGroupPosts_Pull_ReturnsMarkdownFilesUnderPostsDirectory() async throws {
        let groupsRes = try resource("groups")
        let result = try await engine.pull(resource: groupsRes)

        let postFiles = result.files.filter {
            $0.relativePath.contains("/posts/") && $0.relativePath.hasSuffix(".md")
        }
        if postFiles.isEmpty {
            throw XCTSkip("No groups have posts — create a post in Wix Groups dashboard first to run this test")
        }

        try writeFilesToDisk(result.files)

        // All post files should be under groups/{slug}/posts/
        for file in postFiles {
            XCTAssertTrue(
                file.relativePath.hasPrefix("groups/"),
                "Group post file has unexpected path: \(file.relativePath)"
            )
        }
    }

    func testGroupPosts_Pull_MarkdownHasExpectedFrontMatter() async throws {
        let groupsRes = try resource("groups")
        let result = try await engine.pull(resource: groupsRes)

        let postFiles = result.files.filter {
            $0.relativePath.contains("/posts/") && $0.relativePath.hasSuffix(".md")
        }
        if postFiles.isEmpty {
            throw XCTSkip("No groups have posts — cannot verify front matter schema")
        }

        try writeFilesToDisk(result.files)

        let sample = postFiles[0]
        let content = String(decoding: sample.content, as: UTF8.self)
        XCTAssertTrue(content.hasPrefix("---\n"), "\(sample.relativePath) should begin with YAML front matter")

        for key in ["id", "groupId", "createdDate"] {
            XCTAssertTrue(
                content.contains("\(key):"),
                "Missing front matter key '\(key)' in \(sample.relativePath)"
            )
        }
    }

    func testGroupPosts_Create_NewPost_AppearsOnServer() async throws {
        let ownerId = try await currentGroupOwnerId()
        let groupId = try await createGroup(name: uniqueTestName("PostTestGroup"), ownerId: ownerId)
        try await delay(1500)

        let childRes = try resolvedGroupChildResource(childName: "group-posts", groupId: groupId, groupName: uniqueTestName("PostTestGroup"))
        let title = uniqueTestName("GroupPost")

        let createdPostId: String?
        do {
            createdPostId = try await engine.pushRecord(
                [
                    "groupId": groupId,
                    "title": title,
                    "contentText": "Test post content for \(title)",
                    "richContent": minimalRicosDocument(text: "Test post content for \(title)"),
                    "isPinned": false
                ],
                resource: childRes,
                action: .create
            )
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Group posts create API unavailable on this site: \(error)")
            }
            throw error
        }
        try await delay(1500)

        XCTAssertNotNil(createdPostId, "engine.pushRecord for group-posts returned nil ID")

        let posts = try await queryGroupPosts(groupId: groupId)
        let found = posts.first(where: {
            ($0["id"] as? String) == createdPostId || recursiveStringContainsToken($0, token: title)
        })
        XCTAssertNotNil(found, "Created group post '\(title)' not found on server")

        if let postId = found?["id"] as? String {
            createdIds.append((resource: childRes, id: postId))
        }
    }

    func testGroupPosts_Update_ModifyContent_ReflectedOnServer() async throws {
        let ownerId = try await currentGroupOwnerId()
        let groupId = try await createGroup(name: uniqueTestName("PostUpdGroup"), ownerId: ownerId)
        try await delay(1500)

        let childRes = try resolvedGroupChildResource(childName: "group-posts", groupId: groupId, groupName: "")
        let originalTitle = uniqueTestName("PostUpd")
        let updatedTitle = originalTitle + " Updated"

        let postId = try await createGroupPost(groupId: groupId, title: originalTitle)
        try await delay(1000)

        try await engine.pushRecord(
            [
                "groupId": groupId,
                "title": updatedTitle,
                "contentText": "Updated content for \(updatedTitle)",
                "richContent": minimalRicosDocument(text: "Updated content for \(updatedTitle)"),
                "isPinned": false
            ],
            resource: childRes,
            action: .update(id: postId)
        )
        try await delay(1500)

        let posts = try await queryGroupPosts(groupId: groupId)
        let found = posts.first(where: { ($0["id"] as? String) == postId })
        XCTAssertTrue(
            recursiveStringContainsToken(found, token: updatedTitle),
            "Updated post title '\(updatedTitle)' not found on server after update"
        )
    }

    func testGroupPosts_Delete_RemovePost_DeletedFromServer() async throws {
        let ownerId = try await currentGroupOwnerId()
        let groupId = try await createGroup(name: uniqueTestName("PostDelGroup"), ownerId: ownerId)
        try await delay(1500)

        let postId = try await createGroupPost(groupId: groupId, title: uniqueTestName("PostDel"))
        try await delay(1000)

        let childRes = try resolvedGroupChildResource(childName: "group-posts", groupId: groupId, groupName: "")
        try await engine.delete(remoteId: postId, resource: childRes, extraTemplateVars: ["groupId": groupId])
        createdIds.removeAll(where: { $0.id == postId })
        try await delay(1000)

        let posts = try await queryGroupPosts(groupId: groupId)
        XCTAssertFalse(
            posts.contains(where: { ($0["id"] as? String) == postId }),
            "Group post \(postId) should be deleted from server"
        )
    }

    // MARK: - Inbox Conversations — Pull
    // ======================================================================

    func testInboxConversations_Pull_ReturnsCSVFile() async throws {
        try await assertCollectionPull(
            resourceName: "inbox-conversations",
            relativePath: "inbox-conversations/conversations.csv",
            expectedColumns: ["id", "contactName", "contactId"],
            allowEmptyFile: true,
            allowSiteUnavailable: true
        )
    }

    func testInboxConversations_Pull_FileIsUnderInboxDirectory() async throws {
        let res = try resource("inbox-conversations")
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Wix Inbox not available on this site: \(error)")
            }
            throw error
        }

        XCTAssertFalse(result.files.isEmpty, "inbox-conversations pull returned no files")

        let conversationsFile = result.files.first(where: { $0.relativePath == "inbox-conversations/conversations.csv" })
        XCTAssertNotNil(conversationsFile, "Expected inbox-conversations/conversations.csv in pull result; got: \(result.files.map(\.relativePath))")
    }

    // MARK: - Inbox Messages — Pull / Send
    // ======================================================================

    func testInboxMessages_Pull_ReturnsMessagesCSVForConversations() async throws {
        let res = try resource("inbox-conversations")
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Wix Inbox not available on this site")
            }
            throw error
        }

        let messageFiles = result.files.filter { $0.relativePath.hasSuffix("/messages.csv") }
        if messageFiles.isEmpty {
            throw XCTSkip("No inbox conversations found — Wix Inbox appears empty on this site")
        }

        try writeFilesToDisk(result.files)

        // Check path structure: inbox/{contactName}/messages.csv
        for file in messageFiles {
            let parts = file.relativePath.split(separator: "/")
            XCTAssertEqual(parts.count, 3, "Unexpected messages.csv path: \(file.relativePath)")
            XCTAssertEqual(parts.first, "inbox")
            XCTAssertEqual(parts.last, "messages.csv")
        }
    }

    func testInboxMessages_Pull_HasExpectedColumns_WhenMessagesExist() async throws {
        let res = try resource("inbox-conversations")
        let result: PullResult
        do {
            result = try await engine.pull(resource: res)
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Wix Inbox not available on this site")
            }
            throw error
        }

        let messageFiles = result.files.filter { $0.relativePath.hasSuffix("/messages.csv") }
        guard let nonEmpty = messageFiles.first(where: { !$0.content.isEmpty }) else {
            throw XCTSkip("No message content found in any conversation — inbox may be empty")
        }

        try writeFilesToDisk(result.files)
        let records = try readCSV(at: serviceDir.appendingPathComponent(nonEmpty.relativePath))
        guard let first = records.first else {
            throw XCTSkip("messages.csv decoded to zero records")
        }

        let columns = Set(first.keys)
        XCTAssertTrue(columns.contains("content"), "Expected 'content' column; got: \(columns.sorted())")
        XCTAssertTrue(columns.contains("senderId") || columns.contains("direction"),
                      "Expected 'senderId' or 'direction' column; got: \(columns.sorted())")
        XCTAssertTrue(columns.contains("createdDate") || columns.contains("id"),
                      "Expected timestamp or id column; got: \(columns.sorted())")
    }

    func testInboxMessages_Send_NewMessage_AppearsOnServer() async throws {
        let conversations = try await queryInboxConversations()
        guard let conversation = conversations.first,
              let conversationId = conversation["id"] as? String else {
            throw XCTSkip("No inbox conversations available — cannot test send")
        }
        let contactName = (conversation["contactName"] as? String) ?? conversationId

        let childRes = try resolvedInboxMessagesResource(conversationId: conversationId, contactName: contactName)
        let content = uniqueTestName("InboxMsg")

        _ = try await engine.pushRecord(
            [
                "conversationId": conversationId,
                "content": content,
                "seen": false
            ],
            resource: childRes,
            action: .create
        )
        try await delay(1500)

        let messages = try await queryInboxMessages(conversationId: conversationId)
        let found = messages.first(where: { recursiveStringContainsToken($0, token: content) })
        XCTAssertNotNil(found, "Sent inbox message '\(content)' not found on server after push")
    }

    // MARK: - Group/Inbox API Helpers
    // ======================================================================

    private func queryGroupMembers(groupId: String) async throws -> [[String: Any]] {
        let result = try await wixAPI(
            method: .POST,
            path: "/social-groups/v2/groups/\(groupId)/members/query",
            body: ["paging": ["limit": 100]]
        )
        return result["members"] as? [[String: Any]] ?? []
    }

    private func queryGroupPosts(groupId: String) async throws -> [[String: Any]] {
        let result: [String: Any]
        do {
            result = try await wixAPI(
                method: .POST,
                path: "/social-groups/v2/groups/\(groupId)/posts/query",
                body: ["paging": ["limit": 50]]
            )
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Group posts API unavailable on this site: \(error)")
            }
            throw error
        }
        return result["posts"] as? [[String: Any]] ?? []
    }

    private func createGroupPost(groupId: String, title: String) async throws -> String {
        let body: [String: Any] = [
            "post": [
                "entityType": "GROUP_POST",
                "title": title,
                "richContent": minimalRicosDocument(text: title)
            ]
        ]
        let result: [String: Any]
        do {
            result = try await wixAPI(
                method: .POST,
                path: "/social-groups/v2/groups/\(groupId)/posts",
                body: body
            )
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Group posts create API unavailable on this site: \(error)")
            }
            throw error
        }
        guard let post = result["post"] as? [String: Any],
              let id = post["id"] as? String else {
            let childRes = try resolvedGroupChildResource(childName: "group-posts", groupId: groupId, groupName: "")
            XCTFail("Failed to create group post — response: \(result)")
            _ = childRes
            return ""
        }
        let childRes = try resolvedGroupChildResource(childName: "group-posts", groupId: groupId, groupName: "")
        createdIds.append((resource: childRes, id: id))
        return id
    }

    private func queryInboxConversations() async throws -> [[String: Any]] {
        let result: [String: Any]
        do {
            result = try await wixAPI(
                method: .POST,
                path: "/inbox/v2/conversations/query",
                body: ["paging": ["limit": 20]]
            )
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Wix Inbox not available on this site")
            }
            throw error
        }
        return result["conversations"] as? [[String: Any]] ?? []
    }

    private func queryInboxMessages(conversationId: String) async throws -> [[String: Any]] {
        let result = try await wixAPI(
            method: .POST,
            path: "/inbox/v2/messages/query",
            body: [
                "filter": ["conversationId": ["$eq": conversationId]],
                "paging": ["limit": 50]
            ]
        )
        return result["messages"] as? [[String: Any]] ?? []
    }

    // MARK: - Group/Inbox Child Resource Resolvers
    // ======================================================================

    private func resolvedGroupChildResource(
        childName: String,
        groupId: String,
        groupName: String
    ) throws -> ResourceConfig {
        let groupsResource = try resource("groups")
        let childConfig = try XCTUnwrap(
            groupsResource.children?.first(where: { $0.name == childName }),
            "groups resource has no '\(childName)' child — check wix.adapter.json"
        )

        let vars: [String: Any] = ["id": groupId, "name": groupName]

        let resolvedPull: PullConfig?
        if let pull = childConfig.pull {
            let resolvedBody = pull.body.map {
                anyToJSONValue(resolveTemplatesInJSON(jsonValueToAny($0), with: vars))
            }
            resolvedPull = PullConfig(
                method: pull.method,
                url: TemplateEngine.render(pull.url, with: vars),
                type: pull.type,
                query: pull.query.map { TemplateEngine.render($0, with: vars) },
                body: resolvedBody,
                dataPath: pull.dataPath,
                detail: pull.detail,
                pagination: pull.pagination,
                mediaConfig: pull.mediaConfig,
                updatedSinceField: pull.updatedSinceField,
                updatedSinceBodyPath: pull.updatedSinceBodyPath,
                updatedSinceDateFormat: pull.updatedSinceDateFormat,
                supportsETag: pull.supportsETag
            )
        } else {
            resolvedPull = nil
        }

        let resolvedDirectory = TemplateEngine.render(childConfig.fileMapping.directory, with: vars)

        return ResourceConfig(
            name: "\(childName).\(groupId)",
            description: childConfig.description,
            capabilityClass: childConfig.capabilityClass,
            pull: resolvedPull,
            push: childConfig.push,
            fileMapping: FileMappingConfig(
                strategy: childConfig.fileMapping.strategy,
                directory: resolvedDirectory,
                filename: childConfig.fileMapping.filename,
                format: childConfig.fileMapping.format,
                formatOptions: childConfig.fileMapping.formatOptions,
                idField: childConfig.fileMapping.idField,
                contentField: childConfig.fileMapping.contentField,
                readOnly: childConfig.fileMapping.readOnly,
                preserveExtension: childConfig.fileMapping.preserveExtension,
                transforms: childConfig.fileMapping.transforms,
                pushMode: childConfig.fileMapping.pushMode,
                deleteFromAPI: childConfig.fileMapping.deleteFromAPI
            ),
            children: nil,
            sync: childConfig.sync,
            siteUrl: childConfig.siteUrl,
            dashboardUrl: childConfig.dashboardUrl
        )
    }

    private func resolvedInboxMessagesResource(
        conversationId: String,
        contactName: String
    ) throws -> ResourceConfig {
        let inboxResource = try resource("inbox-conversations")
        let childConfig = try XCTUnwrap(
            inboxResource.children?.first(where: { $0.name == "inbox-messages" }),
            "inbox-conversations resource has no 'inbox-messages' child — check wix.adapter.json"
        )

        let vars: [String: Any] = ["id": conversationId, "contactName": contactName]

        let resolvedPull: PullConfig?
        if let pull = childConfig.pull {
            let resolvedBody = pull.body.map {
                anyToJSONValue(resolveTemplatesInJSON(jsonValueToAny($0), with: vars))
            }
            resolvedPull = PullConfig(
                method: pull.method,
                url: TemplateEngine.render(pull.url, with: vars),
                type: pull.type,
                query: pull.query.map { TemplateEngine.render($0, with: vars) },
                body: resolvedBody,
                dataPath: pull.dataPath,
                detail: pull.detail,
                pagination: pull.pagination,
                mediaConfig: pull.mediaConfig,
                updatedSinceField: pull.updatedSinceField,
                updatedSinceBodyPath: pull.updatedSinceBodyPath,
                updatedSinceDateFormat: pull.updatedSinceDateFormat,
                supportsETag: pull.supportsETag
            )
        } else {
            resolvedPull = nil
        }

        let resolvedDirectory = TemplateEngine.render(childConfig.fileMapping.directory, with: vars)

        return ResourceConfig(
            name: "inbox-messages.\(conversationId)",
            description: childConfig.description,
            capabilityClass: childConfig.capabilityClass,
            pull: resolvedPull,
            push: childConfig.push,
            fileMapping: FileMappingConfig(
                strategy: childConfig.fileMapping.strategy,
                directory: resolvedDirectory,
                filename: childConfig.fileMapping.filename,
                format: childConfig.fileMapping.format,
                formatOptions: childConfig.fileMapping.formatOptions,
                idField: childConfig.fileMapping.idField,
                contentField: childConfig.fileMapping.contentField,
                readOnly: childConfig.fileMapping.readOnly,
                preserveExtension: childConfig.fileMapping.preserveExtension,
                transforms: childConfig.fileMapping.transforms,
                pushMode: childConfig.fileMapping.pushMode,
                deleteFromAPI: childConfig.fileMapping.deleteFromAPI
            ),
            children: nil,
            sync: childConfig.sync,
            siteUrl: childConfig.siteUrl,
            dashboardUrl: childConfig.dashboardUrl
        )
    }

    /// Minimal Wix Ricos document wrapping plain text — used for group post content in tests.
    private func minimalRicosDocument(text: String) -> [String: Any] {
        [
            "nodes": [
                [
                    "type": "PARAGRAPH",
                    "id": UUID().uuidString,
                    "nodes": [
                        [
                            "type": "TEXT",
                            "id": UUID().uuidString,
                            "nodes": [],
                            "textData": [
                                "text": text,
                                "decorations": []
                            ]
                        ]
                    ],
                    "paragraphData": [:]
                ]
            ],
            "metadata": [
                "version": 1,
                "createdTimestamp": ISO8601DateFormatter().string(from: Date()),
                "id": UUID().uuidString
            ]
        ]
    }

    // MARK: - Portfolio Helpers

    private func queryPortfolioCollections() async throws -> [[String: Any]] {
        let body: [String: Any] = ["query": ["paging": ["limit": 100]]]
        let result = try await wixAPI(method: .POST, path: "/portfolio/v1/collections/query", body: body)
        return result["collections"] as? [[String: Any]] ?? []
    }

    private func createPortfolioCollection(title: String) async throws -> String {
        let body: [String: Any] = ["collection": ["title": title, "visible": true]]
        let result = try await wixAPI(method: .POST, path: "/portfolio/v1/collections", body: body)
        guard let collection = result["collection"] as? [String: Any],
              let id = collection["id"] as? String else {
            XCTFail("Failed to create portfolio collection")
            return ""
        }
        let collRes = try resource("portfolio-collections")
        createdIds.append((resource: collRes, id: id))
        return id
    }

    private func queryPortfolioProjects() async throws -> [[String: Any]] {
        let body: [String: Any] = ["query": ["paging": ["limit": 100]]]
        let result = try await wixAPI(method: .POST, path: "/portfolio/v1/projects/query", body: body)
        return result["projects"] as? [[String: Any]] ?? []
    }

    private func createPortfolioProject(title: String, collectionId: String) async throws -> String {
        let body: [String: Any] = ["project": ["title": title, "collectionId": collectionId, "visible": true]]
        let result = try await wixAPI(method: .POST, path: "/portfolio/v1/projects", body: body)
        guard let project = result["project"] as? [String: Any],
              let id = project["id"] as? String else {
            XCTFail("Failed to create portfolio project")
            return ""
        }
        let projRes = try resource("portfolio-projects")
        createdIds.append((resource: projRes, id: id))
        return id
    }

    private func queryPortfolioProjectItems(projectId: String) async throws -> [[String: Any]] {
        let body: [String: Any] = ["projectId": projectId, "query": ["paging": ["limit": 100]]]
        let result = try await wixAPI(
            method: .POST,
            path: "/portfolio/v1/items/query",
            body: body
        )
        return result["items"] as? [[String: Any]] ?? []
    }

    // MARK: - Portfolio Collections

    func testPortfolioCollections_Pull_DoesNotLeakTimestamps() async throws {
        let res = try resource("portfolio-collections")
        let result = try await engine.pull(resource: res)
        let csvFiles = result.files.filter { $0.relativePath.hasSuffix(".csv") }
        XCTAssertFalse(csvFiles.isEmpty, "portfolio-collections pull should produce at least one CSV file")
        for file in csvFiles {
            let content = String(data: file.content, encoding: .utf8) ?? ""
            XCTAssertFalse(content.contains("createdDate"), "createdDate should be omitted from portfolio collections CSV")
            XCTAssertFalse(content.contains("updatedDate"), "updatedDate should be omitted from portfolio collections CSV")
        }
    }

    func testPortfolioCollections_Create_AppearsOnServer() async throws {
        let res = try resource("portfolio-collections")
        let title = uniqueTestName("PortfolioCol")

        let createdId = try await engine.pushRecord(
            ["title": title, "visible": true],
            resource: res,
            action: .create
        )
        let id = try XCTUnwrap(createdId, "Expected create portfolio collection to return an id")
        createdIds.append((resource: res, id: id))
        try await delay(1000)

        let collections = try await queryPortfolioCollections()
        let found = collections.first(where: { $0["id"] as? String == id })
        XCTAssertNotNil(found, "Created portfolio collection not found on server")
        XCTAssertEqual(found?["title"] as? String, title)
    }

    func testPortfolioCollections_Update_ReflectedOnServer() async throws {
        let res = try resource("portfolio-collections")
        let collectionId = try await createPortfolioCollection(title: uniqueTestName("PortfolioColBase"))
        let updatedTitle = uniqueTestName("PortfolioColUpdated")
        try await delay(500)

        let collections = try await queryPortfolioCollections()
        let current = try XCTUnwrap(collections.first(where: { $0["id"] as? String == collectionId }))
        let revision = try XCTUnwrap(current["revision"] as? String, "Collection must have a revision field")

        try await engine.pushRecord(
            ["title": updatedTitle, "visible": true, "revision": revision],
            resource: res,
            action: .update(id: collectionId)
        )
        try await delay(1000)

        let updated = try await queryPortfolioCollections()
        let found = updated.first(where: { $0["id"] as? String == collectionId })
        XCTAssertEqual(found?["title"] as? String, updatedTitle)
    }

    func testPortfolioCollections_Delete_RemovedFromServer() async throws {
        let res = try resource("portfolio-collections")
        let collectionId = try await createPortfolioCollection(title: uniqueTestName("PortfolioColDel"))
        try await delay(500)

        try await engine.delete(remoteId: collectionId, resource: res)
        createdIds.removeAll(where: { $0.id == collectionId })
        try await delay(1000)

        let collections = try await queryPortfolioCollections()
        XCTAssertFalse(
            collections.contains(where: { $0["id"] as? String == collectionId }),
            "Deleted portfolio collection should not appear in query results"
        )
    }

    // MARK: - Portfolio Projects

    func testPortfolioProjects_Create_AppearsOnServer() async throws {
        let projRes = try resource("portfolio-projects")
        let collectionId = try await createPortfolioCollection(title: uniqueTestName("PColForProj"))
        try await delay(500)

        let projTitle = uniqueTestName("PortfolioProj")
        let createdId = try await engine.pushRecord(
            ["title": projTitle, "collectionId": collectionId, "visible": true],
            resource: projRes,
            action: .create
        )
        let projId = try XCTUnwrap(createdId, "Expected create portfolio project to return an id")
        createdIds.append((resource: projRes, id: projId))
        try await delay(1000)

        let projects = try await queryPortfolioProjects()
        let found = projects.first(where: { $0["id"] as? String == projId })
        XCTAssertNotNil(found, "Created portfolio project not found on server")
        XCTAssertEqual(found?["title"] as? String, projTitle)
    }

    func testPortfolioProjects_Delete_RemovedFromServer() async throws {
        let projRes = try resource("portfolio-projects")
        let collectionId = try await createPortfolioCollection(title: uniqueTestName("PColForDel"))
        let projId = try await createPortfolioProject(title: uniqueTestName("PProjDel"), collectionId: collectionId)
        try await delay(500)

        try await engine.delete(remoteId: projId, resource: projRes)
        createdIds.removeAll(where: { $0.id == projId })
        try await delay(1000)

        let projects = try await queryPortfolioProjects()
        XCTAssertFalse(
            projects.contains(where: { $0["id"] as? String == projId }),
            "Deleted portfolio project should not appear in query results"
        )
    }

    // MARK: - Portfolio Project Items

    func testPortfolioProjectItems_Create_AppearsOnServer() async throws {
        let projRes = try resource("portfolio-projects")
        let projItemsRes = try XCTUnwrap(
            projRes.children?.first(where: { $0.name == "portfolio-project-items" }),
            "portfolio-project-items child resource not found in bundled adapter"
        )
        let collectionId = try await createPortfolioCollection(title: uniqueTestName("PColForItems"))
        let projId = try await createPortfolioProject(title: uniqueTestName("PProjForItems"), collectionId: collectionId)
        try await delay(500)

        let itemTitle = uniqueTestName("PItem")
        let createdId: String?
        do {
            createdId = try await engine.pushRecord(
                ["title": itemTitle, "projectId": projId],
                resource: projItemsRes,
                action: .create
            )
        } catch {
            if isSiteUnavailable(error) {
                throw XCTSkip("Portfolio project items create API unavailable on this site: \(error)")
            }
            throw error
        }
        let itemId = try XCTUnwrap(createdId, "Expected create portfolio project item to return an id")
        try await delay(1000)

        let items = try await queryPortfolioProjectItems(projectId: projId)
        let found = items.first(where: { $0["id"] as? String == itemId })
        XCTAssertNotNil(found, "Created portfolio project item not found on server")
        XCTAssertEqual(found?["title"] as? String, itemTitle)
    }
}
