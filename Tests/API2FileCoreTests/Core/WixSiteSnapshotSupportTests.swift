import XCTest
@testable import API2FileCore

private let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

final class WixSiteSnapshotSupportTests: XCTestCase {
    private func loadResolvedWixConfig() throws -> AdapterConfig {
        guard let url = Bundle.module.url(forResource: "wix.adapter", withExtension: "json", subdirectory: "Adapters") else {
            throw NSError(domain: "WixSiteSnapshotSupportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing wix.adapter.json"])
        }

        let raw = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "YOUR_SITE_ID_HERE", with: "site-123")
            .replacingOccurrences(of: "YOUR_SITE_URL_HERE", with: "https://example.wixsite.com/demo")
        return try JSONDecoder().decode(AdapterConfig.self, from: Data(raw.utf8))
    }

    func testSnapshotTargetsIncludeHomeAndResourceURLs() throws {
        let config = try loadResolvedWixConfig()
        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: [
                "urls": [
                    ["url": "https://www.example.com", "isPrimary": true],
                    ["url": "https://example.wixsite.com/demo", "isPrimary": false],
                ]
            ],
            editorResponse: [
                "editorUrl": "https://manage.wix.com/dashboard/site-123/editor",
                "previewUrl": "https://editor.wix.com/html/editor/web/renderer/preview/site-123"
            ],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let targets = WixSiteSnapshotSupport.snapshotTargets(config: config, catalogRecord: catalog)

        XCTAssertEqual(targets.first?.id, "home")
        XCTAssertEqual(targets.first?.url, "https://www.example.com")
        XCTAssertTrue(targets.contains(where: { $0.id == "blog" && $0.url == "https://www.example.com/blog" }))
        XCTAssertTrue(targets.contains(where: { $0.id == "shop" && $0.url == "https://www.example.com/shop" }))
        XCTAssertEqual(Set(targets.map(\.url)).count, targets.count, "Targets should be deduped by canonical URL")
    }

    func testSnapshotTargetsIncludeDashboardAndEditorResourceSiteURLs() throws {
        let config = AdapterConfig(
            service: "wix",
            displayName: "Wix",
            version: "1.0",
            auth: AuthConfig(type: .apiKey, keychainKey: "test"),
            resources: [
            ResourceConfig(
                name: "dashboard-home",
                description: "Dashboard",
                capabilityClass: .readOnly,
                pull: nil,
                push: nil,
                fileMapping: FileMappingConfig(strategy: .collection, directory: "tmp", filename: "dashboard.json", format: .json),
                sync: SyncConfig(interval: 600, debounceMs: nil),
                siteUrl: "https://manage.wix.com/dashboard/site-123/home",
                dashboardUrl: "https://manage.wix.com/dashboard/site-123/home"
            ),
            ResourceConfig(
                name: "editor-preview",
                description: "Editor Preview",
                capabilityClass: .readOnly,
                pull: nil,
                push: nil,
                fileMapping: FileMappingConfig(strategy: .collection, directory: "tmp", filename: "preview.json", format: .json),
                sync: SyncConfig(interval: 600, debounceMs: nil),
                siteUrl: "https://editor.wix.com/html/editor/web/renderer/preview/site-123",
                dashboardUrl: nil
            ),
            ],
            siteUrl: "https://example.wixsite.com/demo"
        )

        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: [
                "urls": [
                    ["url": "https://www.example.com", "isPrimary": true],
                ]
            ],
            editorResponse: [
                "editorUrl": "https://manage.wix.com/dashboard/site-123/editor",
                "previewUrl": "https://editor.wix.com/html/editor/web/renderer/preview/site-123"
            ]
        )

        let targets = WixSiteSnapshotSupport.snapshotTargets(config: config, catalogRecord: catalog)

        XCTAssertTrue(targets.contains(where: { $0.label == "dashboard-home" && $0.url == "https://manage.wix.com/dashboard/site-123/home" }))
        XCTAssertTrue(targets.contains(where: { $0.label == "editor-preview" && $0.url == "https://editor.wix.com/html/editor/web/renderer/preview/site-123" }))
    }

    func testBrowserRenderedPageSnapshotServiceUsesBrowserDelegate() async throws {
        let browser = await MainActor.run { BrowserSnapshotDelegate() }
        let service = BrowserRenderedPageSnapshotService(browserDelegate: browser)

        let result = try await service.capture(url: "https://www.example.com")

        let calls = await browser.recordedCalls()
        XCTAssertEqual(calls.first, "isBrowserOpen")
        XCTAssertTrue(calls.contains("openBrowser"))
        XCTAssertTrue(calls.contains("navigate"))
        XCTAssertTrue(calls.contains("getDOM"))
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == "evaluateJS" }.count, 3)
        XCTAssertEqual(calls.last, "captureScreenshot")
        XCTAssertEqual(result.sourceURL, "https://www.example.com")
        XCTAssertEqual(result.finalURL, "https://www.example.com/final")
        XCTAssertEqual(result.html, "<html><title>Snapshot</title></html>")
        XCTAssertEqual(result.title, "Snapshot Title")
        XCTAssertEqual(result.screenshotData, tinyPNGData)
        let screenshotRequests = await browser.screenshotRequests()
        XCTAssertEqual(screenshotRequests.count, 1)
        XCTAssertEqual(screenshotRequests.first?.width, 1280)
        XCTAssertEqual(screenshotRequests.first?.height, 2400)
    }

    func testWriteWixSiteCatalogAndSnapshotsCreatesDerivedArtifactsAndFileLinks() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WixSiteSnapshotSupportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let syncFolder = tempRoot.appendingPathComponent("sync", isDirectory: true)
        let serviceDir = syncFolder.appendingPathComponent("wix", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent(".api2file"), withIntermediateDirectories: true)

        let config = try loadResolvedWixConfig()
        let resource = try XCTUnwrap(config.resources.first(where: { $0.name == WixSiteSnapshotSupport.catalogResourceName }))
        let snapshotService = FakeRenderedPageSnapshotService(results: [
            "https://www.example.com": .success(
                RenderedPageSnapshot(
                    sourceURL: "https://www.example.com",
                    finalURL: "https://www.example.com",
                    html: "<html>home</html>",
                    screenshotData: tinyPNGData,
                    title: "Home",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            ),
            "https://www.example.com/blog": .success(
                RenderedPageSnapshot(
                    sourceURL: "https://www.example.com/blog",
                    finalURL: "https://www.example.com/blog",
                    html: "<html>blog</html>",
                    screenshotData: tinyPNGData,
                    title: "Blog",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_002)
                )
            ),
            "https://www.example.com/shop": .failure(NSError(domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "shop failed"]))
        ])

        let engine = SyncEngine(
            config: GlobalConfig(
                syncFolder: syncFolder.path,
                gitAutoCommit: false,
                showNotifications: false
            ),
            platformServices: PlatformServices(
                keychainManager: KeychainManager(keyPrefix: "com.api2file.tests.wixsnapshot.\(UUID().uuidString)."),
                renderedPageSnapshotService: snapshotService
            )
        )

        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: [
                "urls": [
                    ["url": "https://www.example.com", "isPrimary": true],
                    ["url": "https://example.wixsite.com/demo", "isPrimary": false],
                ]
            ],
            editorResponse: ["editorUrl": "https://manage.wix.com/dashboard/site-123/editor"]
        )

        let nextState = try await engine.writeWixSiteCatalogAndSnapshots(
            serviceDir: serviceDir,
            config: config,
            resource: resource,
            state: SyncState(),
            catalogRecord: catalog
        )

        let catalogURL = serviceDir.appendingPathComponent(WixSiteSnapshotSupport.catalogRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: WixSiteSnapshotSupport.catalogRelativePath,
            strategy: resource.fileMapping.strategy
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(objectPath).path))

        let manifest = try XCTUnwrap(WixSiteSnapshotSupport.loadManifest(from: serviceDir))
        XCTAssertEqual(manifest.entries.count, 3)
        XCTAssertTrue(manifest.entries.contains(where: { $0.id == "home" && $0.status == "success" }))
        XCTAssertTrue(manifest.entries.contains(where: { $0.id == "blog" && $0.status == "success" }))
        XCTAssertTrue(manifest.entries.contains(where: { $0.id == "shop" && $0.status == "error" }))

        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(".api2file/derived/site-snapshots/home.rendered.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent(".api2file/derived/site-snapshots/home.png").path))
        XCTAssertFalse(SyncedFilePreviewSupport.isUserFacingRelativePath(".api2file/derived/site-snapshots/home.rendered.html"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent("Snapshots/home.rendered.html").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent("Snapshots/home.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent("Snapshots/manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceDir.appendingPathComponent("Snapshots/README.md").path))
        XCTAssertTrue(SyncedFilePreviewSupport.isUserFacingRelativePath("Snapshots/home.rendered.html"))

        let link = try XCTUnwrap(FileLinkManager.linkForUserPath(WixSiteSnapshotSupport.catalogRelativePath, in: serviceDir))
        XCTAssertTrue(link.derivedPaths.contains(".api2file/derived/site-snapshots/manifest.json"))
        XCTAssertTrue(link.derivedPaths.contains(".api2file/derived/site-snapshots/home.rendered.html"))
        XCTAssertTrue(link.derivedPaths.contains(".api2file/derived/site-snapshots/blog.rendered.html"))
        XCTAssertTrue(link.derivedPaths.contains("Snapshots/manifest.json"))
        XCTAssertTrue(link.derivedPaths.contains("Snapshots/home.rendered.html"))
        XCTAssertTrue(link.derivedPaths.contains("Snapshots/blog.rendered.html"))

        let exposedManifestURL = serviceDir.appendingPathComponent("Snapshots/manifest.json")
        let exposedManifestData = try Data(contentsOf: exposedManifestURL)
        let exposedManifest = try JSONDecoder().decode(SiteSnapshotManifest.self, from: exposedManifestData)
        XCTAssertTrue(exposedManifest.entries.contains(where: { $0.id == "home" && $0.htmlPath == "Snapshots/home.rendered.html" }))
        XCTAssertTrue(exposedManifest.entries.contains(where: { $0.id == "blog" && $0.screenshotPath == "Snapshots/blog.png" }))

        XCTAssertNotNil(nextState.files[WixSiteSnapshotSupport.catalogRelativePath])
        let capturedURLs = await snapshotService.capturedURLs()
        XCTAssertEqual(capturedURLs, [
            "https://www.example.com",
            "https://www.example.com/blog",
            "https://www.example.com/shop",
        ])
    }

    func testWriteWixSiteCatalogAndSnapshotsRemovesStaleHiddenAndExposedFilesForDroppedTargets() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WixSiteSnapshotCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let syncFolder = tempRoot.appendingPathComponent("sync", isDirectory: true)
        let serviceDir = syncFolder.appendingPathComponent("wix", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serviceDir.appendingPathComponent(".api2file"), withIntermediateDirectories: true)

        let fullConfig = try loadResolvedWixConfig()
        let trimmedConfig = AdapterConfig(
            service: fullConfig.service,
            displayName: fullConfig.displayName,
            version: fullConfig.version,
            auth: fullConfig.auth,
            globals: fullConfig.globals,
            resources: fullConfig.resources.filter { $0.name != "products" },
            icon: fullConfig.icon,
            wizardDescription: fullConfig.wizardDescription,
            setupFields: fullConfig.setupFields,
            hidden: fullConfig.hidden,
            enabled: fullConfig.enabled,
            siteUrl: fullConfig.siteUrl,
            dashboardUrl: fullConfig.dashboardUrl
        )
        let resource = try XCTUnwrap(fullConfig.resources.first(where: { $0.name == WixSiteSnapshotSupport.catalogResourceName }))

        let catalog = WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: [
                "urls": [
                    ["url": "https://www.example.com", "isPrimary": true],
                    ["url": "https://example.wixsite.com/demo", "isPrimary": false],
                ]
            ],
            editorResponse: ["editorUrl": "https://manage.wix.com/dashboard/site-123/editor"]
        )

        let firstEngine = SyncEngine(
            config: GlobalConfig(syncFolder: syncFolder.path, gitAutoCommit: false, showNotifications: false),
            platformServices: PlatformServices(
                keychainManager: KeychainManager(keyPrefix: "com.api2file.tests.wixsnapshot.cleanup1.\(UUID().uuidString)."),
                renderedPageSnapshotService: FakeRenderedPageSnapshotService(results: [
                    "https://www.example.com": .success(
                        RenderedPageSnapshot(sourceURL: "https://www.example.com", finalURL: "https://www.example.com", html: "<html>home</html>", screenshotData: tinyPNGData, title: "Home")
                    ),
                    "https://www.example.com/blog": .success(
                        RenderedPageSnapshot(sourceURL: "https://www.example.com/blog", finalURL: "https://www.example.com/blog", html: "<html>blog</html>", screenshotData: tinyPNGData, title: "Blog")
                    ),
                    "https://www.example.com/shop": .success(
                        RenderedPageSnapshot(sourceURL: "https://www.example.com/shop", finalURL: "https://www.example.com/shop", html: "<html>shop</html>", screenshotData: tinyPNGData, title: "Shop")
                    ),
                ])
            )
        )

        var state = try await firstEngine.writeWixSiteCatalogAndSnapshots(
            serviceDir: serviceDir,
            config: fullConfig,
            resource: resource,
            state: SyncState(),
            catalogRecord: catalog
        )

        let hiddenShopHTML = serviceDir.appendingPathComponent(".api2file/derived/site-snapshots/shop.rendered.html")
        let hiddenShopPNG = serviceDir.appendingPathComponent(".api2file/derived/site-snapshots/shop.png")
        let exposedShopHTML = serviceDir.appendingPathComponent("Snapshots/shop.rendered.html")
        let exposedShopPNG = serviceDir.appendingPathComponent("Snapshots/shop.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenShopHTML.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenShopPNG.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exposedShopHTML.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exposedShopPNG.path))

        let secondEngine = SyncEngine(
            config: GlobalConfig(syncFolder: syncFolder.path, gitAutoCommit: false, showNotifications: false),
            platformServices: PlatformServices(
                keychainManager: KeychainManager(keyPrefix: "com.api2file.tests.wixsnapshot.cleanup2.\(UUID().uuidString)."),
                renderedPageSnapshotService: FakeRenderedPageSnapshotService(results: [
                    "https://www.example.com": .success(
                        RenderedPageSnapshot(sourceURL: "https://www.example.com", finalURL: "https://www.example.com", html: "<html>home-2</html>", screenshotData: tinyPNGData, title: "Home")
                    ),
                    "https://www.example.com/blog": .success(
                        RenderedPageSnapshot(sourceURL: "https://www.example.com/blog", finalURL: "https://www.example.com/blog", html: "<html>blog-2</html>", screenshotData: tinyPNGData, title: "Blog")
                    ),
                ])
            )
        )

        state = try await secondEngine.writeWixSiteCatalogAndSnapshots(
            serviceDir: serviceDir,
            config: trimmedConfig,
            resource: resource,
            state: state,
            catalogRecord: catalog
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenShopHTML.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenShopPNG.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exposedShopHTML.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exposedShopPNG.path))

        let manifest = try XCTUnwrap(WixSiteSnapshotSupport.loadManifest(from: serviceDir))
        XCTAssertEqual(Set(manifest.entries.map(\.id)), Set(["home", "blog"]))

        let link = try XCTUnwrap(FileLinkManager.linkForUserPath(WixSiteSnapshotSupport.catalogRelativePath, in: serviceDir))
        XCTAssertFalse(link.derivedPaths.contains(".api2file/derived/site-snapshots/shop.rendered.html"))
        XCTAssertFalse(link.derivedPaths.contains(".api2file/derived/site-snapshots/shop.png"))
        XCTAssertFalse(link.derivedPaths.contains("Snapshots/shop.rendered.html"))
        XCTAssertFalse(link.derivedPaths.contains("Snapshots/shop.png"))
        XCTAssertNotNil(state.files[WixSiteSnapshotSupport.catalogRelativePath])
    }
}

@MainActor
private final class BrowserSnapshotDelegate: BrowserControlDelegate {
    private(set) var calls: [String] = []
    private(set) var browserOpen = false
    private(set) var requestedScreenshots: [(width: Int?, height: Int?)] = []

    func recordedCalls() -> [String] {
        calls
    }

    func screenshotRequests() -> [(width: Int?, height: Int?)] {
        requestedScreenshots
    }

    func openBrowser() async throws {
        calls.append("openBrowser")
        browserOpen = true
    }

    func isBrowserOpen() async -> Bool {
        calls.append("isBrowserOpen")
        return browserOpen
    }

    func navigate(to url: String) async throws -> String {
        calls.append("navigate")
        return "\(url)/final"
    }

    func goBack() async throws {}
    func goForward() async throws {}
    func reload() async throws {}

    func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
        calls.append("captureScreenshot")
        requestedScreenshots.append((width: width, height: height))
        return tinyPNGData
    }

    func getDOM(selector: String?) async throws -> String {
        calls.append("getDOM")
        return "<html><title>Snapshot</title></html>"
    }

    func click(selector: String) async throws {}
    func type(selector: String, text: String) async throws {}

    func evaluateJS(_ code: String) async throws -> String {
        calls.append("evaluateJS")
        if code == "document.title" {
            return "Snapshot Title"
        }
        if code.contains("JSON.stringify") {
            return #"{"readyState":"complete","fontsReady":true,"width":1280,"height":2400}"#
        }
        return "Snapshot Title"
    }

    func getCurrentURL() async -> String? { nil }
    func waitFor(selector: String, timeout: TimeInterval) async throws {}
    func scroll(direction: ScrollDirection, amount: Int?) async throws {}
}

private actor FakeRenderedPageSnapshotService: RenderedPageSnapshotService {
    private let results: [String: Result<RenderedPageSnapshot, Error>]
    private var urls: [String] = []

    init(results: [String: Result<RenderedPageSnapshot, Error>]) {
        self.results = results
    }

    func capture(url: String) async throws -> RenderedPageSnapshot {
        urls.append(url)
        guard let result = results[url] else {
            throw NSError(domain: "FakeRenderedPageSnapshotService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No result for \(url)"])
        }
        return try result.get()
    }

    func capturedURLs() -> [String] {
        urls
    }
}
