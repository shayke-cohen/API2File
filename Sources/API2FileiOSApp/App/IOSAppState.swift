import SwiftUI
import Observation
import API2FileCore

private struct WixBootstrapContext {
    let apiKey: String
    let siteID: String
    let siteURL: String

    var shouldEnable: Bool { !apiKey.isEmpty }
}

private struct ServiceBootstrapContext {
    let apiKey: String

    var shouldEnable: Bool { !apiKey.isEmpty }
}

@MainActor
@Observable
final class IOSAppState {
    let platformServices: PlatformServices
    let launchEnvironment: [String: String]

    var config: GlobalConfig
    var services: [ServiceInfo] = []
    var history: [SyncHistoryEntry] = []
    var selectedServiceID: String?
    var selectedTab: IOSRootTab = .services
    var isPaused = false
    var isBootstrappingWorkspace = false
    var hasCompletedInitialLoad = false
    var lastError: String?

    private(set) var syncEngine: SyncEngine?
    private var engineStarted = false

    init(
        platformServices: PlatformServices = .iOSApp,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.platformServices = platformServices
        self.launchEnvironment = launchEnvironment
        let defaultConfig = GlobalConfig(
            syncFolder: platformServices.storageLocations.syncRootDirectory.path,
            showNotifications: false,
            finderBadges: false,
            launchAtLogin: false
        )
        self.config = GlobalConfig.loadOrDefault(
            syncFolder: platformServices.storageLocations.syncRootDirectory,
            defaultConfig: defaultConfig
        )
        if let initialTab = launchEnvironment["API2FILE_INITIAL_TAB"],
           let tab = IOSRootTab.launchValue(initialTab) {
            self.selectedTab = tab
        }
    }

    var syncRootURL: URL {
        config.resolvedSyncFolder(using: platformServices.storageLocations)
    }

    var configURL: URL {
        syncRootURL.appendingPathComponent(".api2file.json")
    }

    func startEngineIfNeeded() async {
        guard !engineStarted, !isBootstrappingWorkspace else { return }
        isBootstrappingWorkspace = true
        lastError = nil
        defer {
            isBootstrappingWorkspace = false
            hasCompletedInitialLoad = true
        }

        do {
            try FileManager.default.createDirectory(at: syncRootURL, withIntermediateDirectories: true)
            try await platformServices.adapterStore.seedIfNeeded()
            try await ensureWixServiceIfNeeded()
            try await ensureMondayServiceIfNeeded()
            let engine = SyncEngine(config: config, platformServices: platformServices)
            self.syncEngine = engine
            try await engine.start()
            engineStarted = true
            await refresh()
            schedulePostLaunchRefresh()
        } catch {
            engineStarted = false
            lastError = error.localizedDescription
        }
    }

    func handleAppBecameActive() async {
        await startEngineIfNeeded()
        await refresh()
        await syncAllServices()
    }

    func performBackgroundSync() async {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        await syncAllServices()
    }

    func refresh() async {
        let diskServices = loadServicesFromDisk()
        let diskHistory = loadHistoryFromDisk(limit: 100)

        var liveServices: [ServiceInfo] = []
        var liveHistory: [SyncHistoryEntry] = []

        if let syncEngine {
            liveServices = await syncEngine.getServices()

            let missingServiceIDs = Set(diskServices.map(\.serviceId))
                .subtracting(liveServices.map(\.serviceId))
                .sorted()

            if !missingServiceIDs.isEmpty {
                for serviceID in missingServiceIDs {
                    try? await syncEngine.registerNewService(serviceID)
                }
                liveServices = await syncEngine.getServices()
            }

            liveHistory = await syncEngine.getAllHistory(limit: 100)
        }

        services = mergeServices(primary: liveServices, fallback: diskServices)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        history = liveHistory.isEmpty ? diskHistory : liveHistory
        if selectedServiceID == nil || !services.contains(where: { $0.serviceId == selectedServiceID }) {
            selectedServiceID = services.first?.serviceId
        }
    }

    func syncAllServices() async {
        guard let syncEngine else { return }
        for service in services {
            await syncEngine.triggerSync(serviceId: service.serviceId)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await refresh()
    }

    func sync(serviceID: String) async {
        await syncEngine?.triggerSync(serviceId: serviceID)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await refresh()
    }

    func toggleService(_ serviceID: String, enabled: Bool) async {
        await syncEngine?.setServiceEnabled(serviceId: serviceID, enabled: enabled)
        await refresh()
    }

    func removeService(_ serviceID: String) async {
        await syncEngine?.removeService(serviceId: serviceID)
        await refresh()
    }

    func updateAPIKey(serviceID: String, newKey: String) async {
        guard let service = services.first(where: { $0.serviceId == serviceID }) else { return }
        await platformServices.keychainManager.save(key: service.config.auth.keychainKey, value: newKey)
        if let syncEngine {
            await syncEngine.removeService(serviceId: serviceID)
            try? await syncEngine.registerNewService(serviceID)
        }
        await refresh()
    }

    func addService(
        template: AdapterTemplate,
        serviceID requestedServiceID: String? = nil,
        apiKey: String,
        extraFieldValues: [String: String]
    ) async throws {
        let serviceID = try await persistService(
            template: template,
            serviceID: requestedServiceID,
            apiKey: apiKey,
            extraFieldValues: extraFieldValues
        )

        if let syncEngine {
            try await syncEngine.registerNewService(serviceID)
        } else {
            await startEngineIfNeeded()
            try await syncEngine?.registerNewService(serviceID)
        }
        selectedServiceID = serviceID
        await refresh()
    }

    func markFileChanged(serviceID: String, fileURL: URL) async {
        let serviceDir = syncRootURL.appendingPathComponent(serviceID, isDirectory: true)
        let prefix = serviceDir.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return }
        let relativePath = String(fileURL.path.dropFirst(prefix.count))
        await syncEngine?.fileDidChange(serviceId: serviceID, filePath: relativePath)
        try? await Task.sleep(nanoseconds: 200_000_000)
        await refresh()
    }

    func setShowNotificationsEnabled(_ enabled: Bool) {
        config.showNotifications = enabled
        persistConfig()
    }

    func listSQLTables(serviceID: String) async -> [SQLMirrorTableSummary] {
        guard let syncEngine else { return [] }
        do {
            let data = try await syncEngine.listSQLTables(serviceId: serviceID)
            let payload = try JSONDecoder().decode(SQLTablesPayload.self, from: data)
            return payload.tables
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func describeSQLTable(serviceID: String, table: String) async -> SQLMirrorTableDescription? {
        guard let syncEngine else { return nil }
        do {
            let data = try await syncEngine.describeSQLTable(serviceId: serviceID, table: table)
            return try JSONDecoder().decode(SQLMirrorTableDescription.self, from: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func runSQLQuery(serviceID: String, query: String) async throws -> SQLMirrorQueryResult {
        guard let syncEngine else {
            throw SQLExplorerError.unavailable
        }

        let data = try await syncEngine.querySQL(serviceId: serviceID, query: query)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLExplorerError.invalidResponse
        }

        let rawRows = object["rows"] as? [[String: Any]] ?? []
        let columns = resolvedSQLColumns(from: object, rows: rawRows)
        let rows = rawRows.map { row in
            SQLMirrorQueryRow(
                values: Dictionary(uniqueKeysWithValues: columns.map { column in
                    (column, Self.sqlDisplayString(row[column]))
                }),
                recordId: Self.sqlRecordIdentifier(from: row)
            )
        }

        return SQLMirrorQueryResult(
            databasePath: object["databasePath"] as? String,
            query: object["query"] as? String ?? query,
            rowCount: object["rowCount"] as? Int ?? rows.count,
            columns: columns,
            rows: rows
        )
    }

    func openSQLRecordFile(
        serviceID: String,
        resource: String,
        recordID: String,
        surface: String
    ) async throws -> URL {
        guard let syncEngine else {
            throw SQLExplorerError.unavailable
        }

        let data = try await syncEngine.getRecordByID(serviceId: serviceID, resource: resource, recordId: recordID)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLExplorerError.invalidResponse
        }

        let key = surface == "canonical" ? "canonicalFile" : "projectionFile"
        guard let path = object[key] as? String else {
            throw SQLExplorerError.invalidResponse
        }

        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SQLExplorerError.missingFilePath(path)
        }
        return fileURL
    }

    func setGitAutoCommitEnabled(_ enabled: Bool) {
        config.gitAutoCommit = enabled
        persistConfig()
    }

    private func persistConfig() {
        do {
            try FileManager.default.createDirectory(at: syncRootURL, withIntermediateDirectories: true)
            try config.save(to: configURL)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureWixServiceIfNeeded() async throws {
        let wixTemplate = try await loadBundledTemplate(serviceID: "wix")
        let bootstrap = await wixBootstrapContext(for: wixTemplate)
        let serviceDir = syncRootURL.appendingPathComponent("wix", isDirectory: true)
        let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")

        if FileManager.default.fileExists(atPath: adapterURL.path) {
            try await reconcileExistingWixServiceIfNeeded(
                adapterURL: adapterURL,
                template: wixTemplate,
                bootstrap: bootstrap
            )
            return
        }

        _ = try await persistService(
            template: wixTemplate,
            apiKey: bootstrap.apiKey,
            extraFieldValues: [
                "wix-site-id": bootstrap.siteID,
                "wix-site-url": bootstrap.siteURL,
            ],
            customizeConfig: { json in
                json["enabled"] = bootstrap.shouldEnable
                if !bootstrap.shouldEnable {
                    json["displayName"] = "Wix Starter"
                }
            }
        )
    }

    private func ensureMondayServiceIfNeeded() async throws {
        let mondayTemplate = try await loadBundledTemplate(serviceID: "monday")
        let bootstrap = await bootstrapContext(
            environmentKey: "MONDAY_API_KEY",
            keychainKey: mondayTemplate.config.auth.keychainKey
        )
        let serviceDir = syncRootURL.appendingPathComponent("monday", isDirectory: true)
        let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")

        if FileManager.default.fileExists(atPath: adapterURL.path) {
            try await reconcileExistingServiceIfNeeded(
                adapterURL: adapterURL,
                template: mondayTemplate,
                enabledDisplayName: "Monday.com",
                pausedDisplayName: "Monday Starter",
                bootstrap: bootstrap
            )
            return
        }

        _ = try await persistService(
            template: mondayTemplate,
            apiKey: bootstrap.apiKey,
            extraFieldValues: [:],
            customizeConfig: { json in
                json["enabled"] = bootstrap.shouldEnable
                if !bootstrap.shouldEnable {
                    json["displayName"] = "Monday Starter"
                }
            }
        )
    }

    private func wixBootstrapContext(for template: AdapterTemplate) async -> WixBootstrapContext {
        let storedAPIKey = await resolvedAPIKey(
            environmentKey: "WIX_API_KEY",
            keychainKey: template.config.auth.keychainKey
        )
        return WixBootstrapContext(
            apiKey: storedAPIKey,
            siteID: launchEnvironment["WIX_SITE_ID"] ?? "api2file-starter-site",
            siteURL: launchEnvironment["WIX_SITE_URL"] ?? "https://example.wixsite.com/api2file"
        )
    }

    private func reconcileExistingWixServiceIfNeeded(
        adapterURL: URL,
        template: AdapterTemplate,
        bootstrap: WixBootstrapContext
    ) async throws {
        guard bootstrap.shouldEnable else { return }

        let data = try Data(contentsOf: adapterURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        await platformServices.keychainManager.save(key: template.config.auth.keychainKey, value: bootstrap.apiKey)

        var didChange = false

        if (json["enabled"] as? Bool) != true {
            json["enabled"] = true
            didChange = true
        }

        if (json["displayName"] as? String) == "Wix Starter" {
            json["displayName"] = "Wix"
            didChange = true
        }

        if let siteURL = json["siteUrl"] as? String {
            if siteURL == "https://example.wixsite.com/api2file" {
                json["siteUrl"] = bootstrap.siteURL
                didChange = true
            }
        } else {
            json["siteUrl"] = bootstrap.siteURL
            didChange = true
        }

        var globals = json["globals"] as? [String: Any] ?? [:]
        var headers = globals["headers"] as? [String: Any] ?? [:]
        let currentSiteID = headers["wix-site-id"] as? String
        if currentSiteID == nil || currentSiteID == "api2file-starter-site" || currentSiteID == "YOUR_SITE_ID_HERE" {
            headers["wix-site-id"] = bootstrap.siteID
            globals["headers"] = headers
            json["globals"] = globals
            didChange = true
        }

        guard didChange else { return }

        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: adapterURL, options: .atomic)
    }

    private func reconcileExistingServiceIfNeeded(
        adapterURL: URL,
        template: AdapterTemplate,
        enabledDisplayName: String,
        pausedDisplayName: String,
        bootstrap: ServiceBootstrapContext
    ) async throws {
        guard bootstrap.shouldEnable else { return }

        let data = try Data(contentsOf: adapterURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        await platformServices.keychainManager.save(key: template.config.auth.keychainKey, value: bootstrap.apiKey)

        var didChange = false
        if (json["enabled"] as? Bool) != true {
            json["enabled"] = true
            didChange = true
        }
        if (json["displayName"] as? String) == pausedDisplayName {
            json["displayName"] = enabledDisplayName
            didChange = true
        }

        guard didChange else { return }
        let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updatedData.write(to: adapterURL, options: .atomic)
    }

    private func loadBundledTemplate(serviceID: String) async throws -> AdapterTemplate {
        let templates = try await platformServices.adapterStore.loadAll()
        guard let template = templates.first(where: { $0.config.service == serviceID }) else {
            throw NSError(
                domain: "API2FileiOSApp",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled adapter template for \(serviceID)"]
            )
        }
        return template
    }

    private func bootstrapContext(
        environmentKey: String,
        keychainKey: String
    ) async -> ServiceBootstrapContext {
        ServiceBootstrapContext(
            apiKey: await resolvedAPIKey(environmentKey: environmentKey, keychainKey: keychainKey)
        )
    }

    private func resolvedAPIKey(environmentKey: String, keychainKey: String) async -> String {
        if let environmentAPIKey = launchEnvironment[environmentKey], !environmentAPIKey.isEmpty {
            return environmentAPIKey
        }
        return await platformServices.keychainManager.load(key: keychainKey) ?? ""
    }

    private func schedulePostLaunchRefresh() {
        Task { @MainActor in
            await refreshAfterStartupSync()
        }
    }

    private func resolvedSQLColumns(from object: [String: Any], rows: [[String: Any]]) -> [String] {
        if let columns = object["columns"] as? [String], !columns.isEmpty {
            return columns
        }
        return rows.first.map { $0.keys.sorted() } ?? []
    }

    private static func sqlDisplayString(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull:
            return ""
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return double.rounded() == double ? String(Int(double)) : String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\(array)"
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return "\(dictionary)"
        default:
            return String(describing: value ?? "")
        }
    }

    private static func sqlRecordIdentifier(from row: [String: Any]) -> String? {
        for key in ["_remote_id", "id", "_id"] {
            if let string = row[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let int = row[key] as? Int {
                return String(int)
            }
            if let double = row[key] as? Double {
                return double.rounded() == double ? String(Int(double)) : String(double)
            }
            if let number = row[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private func refreshAfterStartupSync() async {
        var settledRefreshes = 0

        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refresh()

            let hasEnabledServices = services.contains { $0.config.enabled != false }
            let hasRemoteResults = !history.isEmpty || services.contains { $0.fileCount > 0 || $0.lastSyncTime != nil }
            let isSyncing = services.contains(where: { $0.status == .syncing })

            if !hasEnabledServices {
                settledRefreshes += 1
            } else if hasRemoteResults && !isSyncing {
                settledRefreshes += 1
            } else {
                settledRefreshes = 0
            }

            if settledRefreshes >= 2 {
                break
            }
        }
    }

    private func persistService(
        template: AdapterTemplate,
        serviceID requestedServiceID: String? = nil,
        apiKey: String,
        extraFieldValues: [String: String],
        customizeConfig: ((inout [String: Any]) -> Void)? = nil
    ) async throws -> String {
        let rawServiceID = requestedServiceID ?? template.config.service
        let serviceID = ServiceIdentity.normalizedServiceID(from: rawServiceID)
        guard !serviceID.isEmpty else {
            throw NSError(
                domain: "API2FileiOSApp",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Enter a valid workspace folder name."]
            )
        }

        let serviceDir = syncRootURL.appendingPathComponent(serviceID, isDirectory: true)
        let api2fileDir = serviceDir.appendingPathComponent(".api2file", isDirectory: true)
        let configURL = api2fileDir.appendingPathComponent("adapter.json")

        if requestedServiceID != nil, FileManager.default.fileExists(atPath: configURL.path) {
            throw NSError(
                domain: "API2FileiOSApp",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "A workspace folder named '\(serviceID)' already exists."]
            )
        }

        try FileManager.default.createDirectory(at: api2fileDir, withIntermediateDirectories: true)
        if !apiKey.isEmpty {
            let keychainKey = ServiceIdentity.keychainKey(
                for: serviceID,
                adapterService: template.config.service,
                templateKeychainKey: template.config.auth.keychainKey
            )
            await platformServices.keychainManager.save(key: keychainKey, value: apiKey)
        }

        let configJSON = try ServiceIdentity.installedAdapterJSON(
            template: template,
            serviceID: serviceID,
            extraFieldValues: extraFieldValues,
            customizeConfig: customizeConfig
        )
        try Data(configJSON.utf8).write(to: configURL, options: .atomic)

        let git = GitManager(repoPath: serviceDir, backendFactory: platformServices.versionControlFactory)
        try await git.initRepo()
        try await git.createGitignore()
        return serviceID
    }

    private func loadServicesFromDisk() -> [ServiceInfo] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: syncRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { serviceDir in
            let isDirectory = (try? serviceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }

            let adapterURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
            guard FileManager.default.fileExists(atPath: adapterURL.path) else { return nil }

            do {
                let config = try AdapterEngine.loadConfig(from: serviceDir)
                let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
                let historyURL = serviceDir.appendingPathComponent(".api2file/sync-history.json")
                let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
                let historyLog = (try? SyncHistoryLog.load(from: historyURL)) ?? SyncHistoryLog()
                let latestEntry = historyLog.entries.first
                let fileCount = max(state.files.count, visibleDiskFileCount(in: serviceDir))

                let status: ServiceStatus
                if config.enabled == false {
                    status = .paused
                } else if latestEntry?.status == .error {
                    status = .error
                } else {
                    status = .connected
                }

                return ServiceInfo(
                    serviceId: serviceDir.lastPathComponent,
                    displayName: ServiceIdentity.runtimeDisplayName(for: config, serviceID: serviceDir.lastPathComponent),
                    config: config,
                    status: status,
                    lastSyncTime: latestEntry?.timestamp,
                    fileCount: fileCount,
                    errorMessage: latestEntry?.status == .error ? latestEntry?.summary : nil
                )
            } catch {
                return nil
            }
        }
    }

    private func loadHistoryFromDisk(limit: Int) -> [SyncHistoryEntry] {
        let serviceDirs = loadServicesFromDisk().map {
            syncRootURL.appendingPathComponent($0.serviceId, isDirectory: true)
        }

        let entries = serviceDirs.compactMap { serviceDir in
            try? SyncHistoryLog.load(from: serviceDir.appendingPathComponent(".api2file/sync-history.json"))
        }
        .flatMap(\.entries)
        .sorted { $0.timestamp > $1.timestamp }

        return Array(entries.prefix(limit))
    }

    private func mergeServices(primary: [ServiceInfo], fallback: [ServiceInfo]) -> [ServiceInfo] {
        var merged: [String: ServiceInfo] = [:]

        for service in fallback {
            merged[service.serviceId] = service
        }

        for service in primary {
            var resolved = service
            if let fallbackService = merged[service.serviceId] {
                resolved.fileCount = max(service.fileCount, fallbackService.fileCount)
                resolved.lastSyncTime = service.lastSyncTime ?? fallbackService.lastSyncTime
                resolved.errorMessage = service.errorMessage ?? fallbackService.errorMessage
            }
            merged[service.serviceId] = resolved
        }

        return Array(merged.values)
    }

    private func visibleDiskFileCount(in serviceDir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: serviceDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            if url.lastPathComponent == "CLAUDE.md" { continue }
            count += 1
        }
        return count
    }
}
