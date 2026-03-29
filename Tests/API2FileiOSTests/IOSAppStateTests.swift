import XCTest
@testable import API2FileCore
@testable import API2FileiOSApp

@MainActor
final class IOSAppStateTests: XCTestCase {
    private var tempRoot: URL!
    private var keychainPrefix: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IOSAppStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        keychainPrefix = "com.api2file.tests.ios-app-state.\(UUID().uuidString)."
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        keychainPrefix = nil
        try super.tearDownWithError()
    }

    func testConfigMutationsPersistToInjectedSyncRoot() throws {
        let appState = IOSAppState(platformServices: makePlatformServices())

        appState.setShowNotificationsEnabled(false)
        appState.setGitAutoCommitEnabled(false)

        let savedConfig = try GlobalConfig.load(from: configURL)
        XCTAssertFalse(savedConfig.showNotifications)
        XCTAssertFalse(savedConfig.gitAutoCommit)
    }

    func testInitLoadsSavedConfigFromInjectedStorageLocations() throws {
        let savedConfig = GlobalConfig(
            syncFolder: tempRoot.path,
            gitAutoCommit: false,
            commitMessageFormat: "ios: {summary}",
            defaultSyncInterval: 300,
            showNotifications: false,
            finderBadges: false,
            serverPort: 32567,
            launchAtLogin: false,
            deleteFromAPI: true
        )
        try savedConfig.save(to: configURL)

        let appState = IOSAppState(platformServices: makePlatformServices())

        XCTAssertEqual(appState.config.commitMessageFormat, "ios: {summary}")
        XCTAssertFalse(appState.config.gitAutoCommit)
        XCTAssertFalse(appState.config.showNotifications)
        XCTAssertTrue(appState.config.deleteFromAPI)
    }

    func testStartEngineBootstrapsPausedWixStarterWhenEnvironmentIsEmpty() async throws {
        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )

        await appState.startEngineIfNeeded()

        let wixService = try XCTUnwrap(appState.services.first(where: { $0.serviceId == "wix" }))
        XCTAssertEqual(wixService.displayName, "Wix Starter")
        XCTAssertEqual(wixService.status, .paused)
        XCTAssertEqual(appState.selectedServiceID, appState.services.first?.serviceId)

        let adapterURL = tempRoot
            .appendingPathComponent("wix", isDirectory: true)
            .appendingPathComponent(".api2file/adapter.json")
        let adapterConfig = try AdapterEngine.loadConfig(from: adapterURL.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(adapterConfig.enabled, false)
        XCTAssertEqual(adapterConfig.displayName, "Wix Starter")
        XCTAssertEqual(adapterConfig.siteUrl, "https://example.wixsite.com/api2file")
        XCTAssertEqual(adapterConfig.globals?.headers?["wix-site-id"], "api2file-starter-site")
    }

    func testStartEngineBootstrapsPausedMondayStarterWhenEnvironmentIsEmpty() async throws {
        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )

        await appState.startEngineIfNeeded()

        let mondayService = try XCTUnwrap(appState.services.first(where: { $0.serviceId == "monday" }))
        XCTAssertEqual(mondayService.displayName, "Monday Starter")
        XCTAssertEqual(mondayService.status, .paused)

        let adapterURL = tempRoot
            .appendingPathComponent("monday", isDirectory: true)
            .appendingPathComponent(".api2file/adapter.json")
        let adapterConfig = try AdapterEngine.loadConfig(from: adapterURL.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(adapterConfig.enabled, false)
        XCTAssertEqual(adapterConfig.displayName, "Monday Starter")
        XCTAssertEqual(adapterConfig.resources.map(\.name), ["boards"])
    }

    func testStartEngineBootstrapsWixStarterWithSharedServiceScaffolding() async throws {
        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )

        await appState.startEngineIfNeeded()

        let serviceRoot = tempRoot.appendingPathComponent("wix", isDirectory: true)
        let adapterURL = serviceRoot.appendingPathComponent(".api2file/adapter.json")
        let manifestURL = serviceRoot.appendingPathComponent(".api2file-git/manifest.json")
        let gitURL = serviceRoot.appendingPathComponent(".git")
        let gitignoreURL = serviceRoot.appendingPathComponent(".gitignore")
        let guideURL = serviceRoot.appendingPathComponent("CLAUDE.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: adapterURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitignoreURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: guideURL.path))

        let starterConfig = try AdapterEngine.loadConfig(from: serviceRoot)
        let bundledWix = try bundledWixConfig()
        XCTAssertEqual(
            starterConfig.resources.map(\.name),
            bundledWix.resources.map(\.name),
            "Expected the iOS bootstrapped Wix service to preserve the same resource set as the shared Wix adapter"
        )
    }

    func testStartEngineUpgradesStarterWixWhenCredentialsBecomeAvailable() async throws {
        let initialAppState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )
        await initialAppState.startEngineIfNeeded()

        let upgradedAppState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [
                "WIX_API_KEY": "test-live-wix-key",
                "WIX_SITE_ID": "real-site-id-123",
                "WIX_SITE_URL": "https://example.com/live-site",
            ]
        )
        await upgradedAppState.startEngineIfNeeded()

        let wixService = try XCTUnwrap(upgradedAppState.services.first(where: { $0.serviceId == "wix" }))
        XCTAssertEqual(wixService.displayName, "Wix")
        XCTAssertNotEqual(wixService.status, .paused)

        let serviceRoot = tempRoot.appendingPathComponent("wix", isDirectory: true)
        let upgradedConfig = try AdapterEngine.loadConfig(from: serviceRoot)
        XCTAssertEqual(upgradedConfig.enabled, true)
        XCTAssertEqual(upgradedConfig.displayName, "Wix")
        XCTAssertEqual(upgradedConfig.siteUrl, "https://example.com/live-site")
        XCTAssertEqual(upgradedConfig.globals?.headers?["wix-site-id"], "real-site-id-123")

        let storedKey = await upgradedAppState.platformServices.keychainManager.load(key: "api2file.wix.key")
        XCTAssertEqual(storedKey, "test-live-wix-key")
    }

    func testStartEngineUpgradesStarterMondayWhenCredentialsBecomeAvailable() async throws {
        let initialAppState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )
        await initialAppState.startEngineIfNeeded()

        let upgradedAppState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [
                "MONDAY_API_KEY": "test-live-monday-key",
            ]
        )
        await upgradedAppState.startEngineIfNeeded()

        let mondayService = try XCTUnwrap(upgradedAppState.services.first(where: { $0.serviceId == "monday" }))
        XCTAssertEqual(mondayService.displayName, "Monday.com")
        XCTAssertNotEqual(mondayService.status, .paused)

        let serviceRoot = tempRoot.appendingPathComponent("monday", isDirectory: true)
        let upgradedConfig = try AdapterEngine.loadConfig(from: serviceRoot)
        XCTAssertEqual(upgradedConfig.enabled, true)
        XCTAssertEqual(upgradedConfig.displayName, "Monday.com")

        let storedKey = await upgradedAppState.platformServices.keychainManager.load(key: "api2file.monday.api-key")
        XCTAssertEqual(storedKey, "test-live-monday-key")
    }

    func testRefreshLoadsServicesFromDiskWhenEngineStateIsUnavailable() async throws {
        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )

        let serviceRoot = tempRoot.appendingPathComponent("wix", isDirectory: true)
        let api2fileDir = serviceRoot.appendingPathComponent(".api2file", isDirectory: true)
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let adapterJSON = """
        {
          "service": "wix",
          "displayName": "Wix",
          "version": "1.0",
          "siteUrl": "https://example.com",
          "dashboardUrl": "https://example.com/dashboard",
          "auth": { "type": "apiKey", "keychainKey": "api2file.wix.key" },
          "resources": [
            {
              "name": "blog-posts",
              "description": "Blog posts",
              "pull": { "url": "https://example.com/posts" },
              "fileMapping": {
                "strategy": "one-per-record",
                "directory": "blog-posts",
                "filename": "{id}.md",
                "format": "md",
                "idField": "id"
              }
            }
          ]
        }
        """
        try Data(adapterJSON.utf8).write(to: api2fileDir.appendingPathComponent("adapter.json"))

        var state = SyncState()
        state.files["blog-posts/post-1.md"] = FileSyncState(
            remoteId: "post-1",
            lastSyncedHash: "hash",
            lastSyncTime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try state.save(to: api2fileDir.appendingPathComponent("state.json"))

        var history = SyncHistoryLog()
        history.append(
            SyncHistoryEntry(
                timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                serviceId: "wix",
                serviceName: "Wix",
                direction: .pull,
                status: .success,
                duration: 0.4,
                files: [],
                summary: "pulled 1 files"
            )
        )
        try history.save(to: api2fileDir.appendingPathComponent("sync-history.json"))

        try FileManager.default.createDirectory(at: serviceRoot.appendingPathComponent("blog-posts"), withIntermediateDirectories: true)
        try Data("# Post".utf8).write(to: serviceRoot.appendingPathComponent("blog-posts/post-1.md"))

        await appState.refresh()

        let service = try XCTUnwrap(appState.services.first(where: { $0.serviceId == "wix" }))
        XCTAssertEqual(service.serviceId, "wix")
        XCTAssertEqual(service.displayName, "Wix")
        XCTAssertEqual(service.fileCount, 1)
        XCTAssertEqual(service.status, .connected)
        XCTAssertEqual(appState.selectedServiceID, "wix")
        XCTAssertEqual(appState.history.first?.serviceId, "wix")
    }

    func testAddServiceSupportsCustomServiceFolderAndKeychainKey() async throws {
        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: [:]
        )

        try await appState.platformServices.adapterStore.seedIfNeeded()
        let templates = try await appState.platformServices.adapterStore.loadAll()
        let wixTemplate = try XCTUnwrap(templates.first(where: { $0.config.service == "wix" }))

        try await appState.addService(
            template: wixTemplate,
            serviceID: "wix-client-a",
            apiKey: "custom-wix-key",
            extraFieldValues: [
                "wix-site-id": "site-abc",
                "wix-site-url": "https://example.com/client-a"
            ]
        )

        let serviceRoot = tempRoot.appendingPathComponent("wix-client-a", isDirectory: true)
        let config = try AdapterEngine.loadConfig(from: serviceRoot)
        let storedKey = await appState.platformServices.keychainManager.load(key: "api2file.wix-client-a.key")

        XCTAssertTrue(FileManager.default.fileExists(atPath: serviceRoot.appendingPathComponent(".api2file/adapter.json").path))
        XCTAssertEqual(config.service, "wix")
        XCTAssertEqual(config.auth.keychainKey, "api2file.wix-client-a.key")
        XCTAssertEqual(storedKey, "custom-wix-key")
        XCTAssertTrue(appState.services.contains(where: { $0.serviceId == "wix-client-a" }))
    }

    func testSQLExplorerReadsLocalMirrorAndResolvesRecordFiles() async throws {
        let serviceRoot = tempRoot.appendingPathComponent("peoplehub", isDirectory: true)
        let api2fileDir = serviceRoot.appendingPathComponent(".api2file", isDirectory: true)
        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)

        let adapterJSON = """
        {
          "service": "peoplehub",
          "displayName": "PeopleHub",
          "version": "1.0",
          "enabled": false,
          "auth": { "type": "apiKey", "keychainKey": "api2file.peoplehub.key" },
          "resources": [
            {
              "name": "contacts",
              "description": "Contacts",
              "pull": { "url": "https://example.com/contacts" },
              "fileMapping": {
                "strategy": "collection",
                "directory": ".",
                "filename": "contacts.csv",
                "format": "csv",
                "idField": "id"
              }
            }
          ]
        }
        """
        try Data(adapterJSON.utf8).write(to: api2fileDir.appendingPathComponent("adapter.json"))

        let projectionURL = serviceRoot.appendingPathComponent("contacts.csv")
        let projectionText = """
        id,name,team
        1,Ada,Infra
        2,Lin,API
        """
        try Data(projectionText.utf8).write(to: projectionURL)

        let canonicalPath = ObjectFileManager.objectFilePath(forUserFile: "contacts.csv", strategy: .collection)
        let canonicalURL = serviceRoot.appendingPathComponent(canonicalPath)
        try FileManager.default.createDirectory(at: canonicalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"id":"1","name":"Ada","team":"Infra"},{"id":"2","name":"Lin","team":"API"}]"#.utf8).write(to: canonicalURL)
        try FileLinkManager.save(
            FileLinkIndex(
                links: [
                    FileLinkEntry(
                        resourceName: "contacts",
                        mappingStrategy: .collection,
                        remoteId: "collection",
                        userPath: "contacts.csv",
                        canonicalPath: canonicalPath
                    )
                ]
            ),
            to: serviceRoot
        )

        var state = SyncState()
        state.files["contacts.csv"] = FileSyncState(
            remoteId: "",
            lastSyncedHash: "contacts-hash",
            lastSyncTime: Date(),
            status: .synced
        )
        try state.save(to: api2fileDir.appendingPathComponent("state.json"))

        let appState = IOSAppState(
            platformServices: makePlatformServices(),
            launchEnvironment: ["API2FILE_INITIAL_TAB": "data"]
        )

        await appState.startEngineIfNeeded()

        let tables = await appState.listSQLTables(serviceID: "peoplehub")
        XCTAssertEqual(tables.map(\.tableName), ["contacts"])

        let description = await appState.describeSQLTable(serviceID: "peoplehub", table: "contacts")
        let columnNames = Set(description?.columns.map(\.name) ?? [])
        XCTAssertTrue(columnNames.contains("_remote_id"))
        XCTAssertTrue(columnNames.contains("_projection_path"))
        XCTAssertTrue(columnNames.contains("_object_path"))
        XCTAssertTrue(columnNames.contains("_json_payload"))
        XCTAssertTrue(columnNames.contains("id"))
        XCTAssertTrue(columnNames.contains("name"))
        XCTAssertTrue(columnNames.contains("team"))

        let result = try await appState.runSQLQuery(
            serviceID: "peoplehub",
            query: "SELECT id, name, team FROM contacts ORDER BY name"
        )
        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.rows.map(\.recordId), ["1", "2"])
        XCTAssertEqual(result.rows.first?.values["name"], "Ada")

        let resolvedProjection = try await appState.openSQLRecordFile(
            serviceID: "peoplehub",
            resource: "contacts",
            recordID: "1",
            surface: "projection"
        )
        let resolvedCanonical = try await appState.openSQLRecordFile(
            serviceID: "peoplehub",
            resource: "contacts",
            recordID: "1",
            surface: "canonical"
        )

        XCTAssertEqual(resolvedProjection.path, projectionURL.path)
        XCTAssertEqual(resolvedCanonical.path, canonicalURL.path)
        XCTAssertEqual(appState.selectedTab, .dataExplorer)
    }

    private var configURL: URL {
        tempRoot.appendingPathComponent(".api2file.json")
    }

    private func makePlatformServices() -> PlatformServices {
        let storage = StorageLocations(
            homeDirectory: tempRoot,
            syncRootDirectory: tempRoot,
            adaptersDirectory: tempRoot.appendingPathComponent("Adapters", isDirectory: true),
            applicationSupportDirectory: tempRoot.appendingPathComponent("Application Support", isDirectory: true)
        )
        return PlatformServices(
            storageLocations: storage,
            adapterStore: AdapterStore(storageLocations: storage),
            keychainManager: KeychainManager(keyPrefix: keychainPrefix),
            versionControlFactory: .embedded
        )
    }

    private func bundledWixConfig() throws -> AdapterConfig {
        let adaptersDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/API2FileCore/Resources/Adapters", isDirectory: true)
        let wixURL = adaptersDirectory.appendingPathComponent("wix.adapter.json")
        return try JSONDecoder().decode(AdapterConfig.self, from: Data(contentsOf: wixURL))
    }
}
