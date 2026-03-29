import Foundation

/// Top-level sync engine — ties together all components for the full sync lifecycle
public actor SyncEngine {
    private let platformServices: PlatformServices
    private enum AuthReadiness {
        case loading
        case ready
        case unavailable
    }

    private let config: GlobalConfig
    private let syncFolder: URL
    private let coordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let fileWatcher: FileWatcher
    private let configWatcher: ConfigWatcher
    private var gitManagers: [String: GitManager] = [:]
    private var adapterEngines: [String: AdapterEngine] = [:]
    private var syncStates: [String: SyncState] = [:]
    private var serviceInfos: [String: ServiceInfo] = [:]
    private var lastKnownRecords: [String: [[String: Any]]] = [:]
    private var lastKnownRawRecords: [String: [[String: Any]]] = [:]
    private var suppressedPaths: [String: Date] = [:]
    private var isPulling: [String: Bool] = [:]  // per-service pull lock
    private var authReadiness: [String: AuthReadiness] = [:]
    /// Files recently pushed — pull should re-pull to get updated revision but not overwrite content.
    /// Key: "serviceId:filePath", Value: push completion time
    private var recentlyPushed: [String: Date] = [:]
    private var historyLogs: [String: SyncHistoryLog] = [:]
    private let notificationManager: NotificationManager

    /// Gates all remote deletions. If nil, deletions proceed immediately (existing behaviour).
    /// AppState sets this at startup to show a confirmation dialog.
    public var deletionConfirmationHandler: (@Sendable (DeletionInfo) async -> Bool)?

    public init(config: GlobalConfig, platformServices: PlatformServices = .current) {
        self.platformServices = platformServices
        self.config = config
        self.syncFolder = config.resolvedSyncFolder(using: platformServices.storageLocations)
        self.coordinator = SyncCoordinator()
        self.networkMonitor = NetworkMonitor()
        self.fileWatcher = platformServices.fileWatcher
        self.configWatcher = platformServices.configWatcher
        self.notificationManager = platformServices.notificationManager
    }

    // MARK: - Lifecycle

    /// Start the sync engine — discover services, start watching, start polling
    public func start() async throws {
        // Ensure sync folder exists
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

        // Configure activity logger — writes to {syncFolder}/logs/
        let logDir = syncFolder.appendingPathComponent("logs")
        await ActivityLogger.shared.configure(logDirectory: logDir)
        await ActivityLogger.shared.info(.system, "SyncEngine starting — syncFolder: \(syncFolder.path)")

        // Request notification permission
        if config.showNotifications {
            notificationManager.requestPermission()
        }

        // Start network monitoring
        networkMonitor.start()

        // Discover and register services
        let serviceIds = try discoverServices()
        for serviceId in serviceIds {
            try await registerService(serviceId)
        }

        // Initial pull for all services BEFORE starting file watcher
        // (prevents FSEvents from triggering pushes while pull is writing files)
        for serviceId in serviceIds {
            do {
                try await performPull(serviceId: serviceId)
                let fileCount = serviceInfos[serviceId]?.fileCount ?? 0
                if config.showNotifications {
                    notificationManager.notifyConnected(
                        service: serviceInfos[serviceId]?.displayName ?? serviceId,
                        fileCount: fileCount
                    )
                }
                await ActivityLogger.shared.info(.sync, "Initial pull complete for \(serviceId) — \(fileCount) files")
            } catch {
                await ActivityLogger.shared.error(.sync, "Initial pull FAILED for \(serviceId) — \(error.localizedDescription)")
            }
        }

        // Queue pushes for files modified while the app was offline
        // (files whose on-disk hash differs from lastSyncedHash but had no FSEvent since startup)
        for serviceId in serviceIds {
            guard let engine = adapterEngines[serviceId] else { continue }
            let serviceDir = syncFolder.appendingPathComponent(serviceId)
            let state = syncStates[serviceId] ?? SyncState()
            for (filePath, fileState) in state.files {
                let lastHash = fileState.lastSyncedHash
                guard !lastHash.isEmpty else { continue }
                // Skip files in hidden directories (.api2file, .objects, etc.)
                if filePath.hasPrefix(".") || filePath.contains("/.") { continue }
                // Skip companion files and read-only resources
                if fileState.isCompanion == true { continue }
                if let resource = findResource(for: filePath, in: engine.config),
                   resource.fileMapping.effectivePushMode == .readOnly { continue }
                let fileURL = serviceDir.appendingPathComponent(filePath)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
                if data.sha256Hex != lastHash, modDate > fileState.lastSyncTime {
                    await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
                    await ActivityLogger.shared.info(.sync, "↑ Queuing offline-modified file: \(serviceId) — \(filePath)")
                }
            }
        }

        // NOW start file watcher (after initial pulls are done)
        let watchDirs = serviceIds.map { syncFolder.appendingPathComponent($0).path }
        fileWatcher.start(directories: watchDirs) { [weak self] changes in
            guard let self else { return }
            Task { await self.handleFileChanges(changes) }
        }

        // Start config watcher
        let configPaths = serviceIds.map {
            syncFolder.appendingPathComponent($0).appendingPathComponent(".api2file").path
        }
        configWatcher.start(directories: configPaths) { [weak self] serviceId in
            guard let self else { return }
            Task { await self.reloadService(serviceId) }
        }

        // Start sync coordinator (periodic polling)
        await coordinator.startAll()

        // Generate CLAUDE.md guides
        try generateGuides()

        await ActivityLogger.shared.info(.system, "SyncEngine started with \(serviceIds.count) service(s)")
    }

    /// Stop the sync engine
    public func stop() async {
        fileWatcher.stop()
        configWatcher.stop()
        networkMonitor.stop()
        await coordinator.stopAll()
    }

    public func setDeletionConfirmationHandler(_ handler: (@Sendable (DeletionInfo) async -> Bool)?) {
        self.deletionConfirmationHandler = handler
    }

    // MARK: - Service Discovery

    /// Discover services by scanning ~/API2File/ for directories with .api2file/adapter.json
    private func discoverServices() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(at: syncFolder, includingPropertiesForKeys: [.isDirectoryKey])
        var services: [String] = []

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let adapterPath = item.appendingPathComponent(".api2file/adapter.json")
            if FileManager.default.fileExists(atPath: adapterPath.path) {
                services.append(item.lastPathComponent)
            }
        }

        return services
    }

    /// Register a single service
    private func registerService(_ serviceId: String) async throws {
        await ActivityLogger.shared.info(.system, "Registering service: \(serviceId)")
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        if try await platformServices.adapterStore.refreshInstalledAdapterIfNeeded(serviceDir: serviceDir) {
            await ActivityLogger.shared.info(.system, "Refreshed deployed adapter for \(serviceId) from newer template")
        }
        let config = try AdapterEngine.loadConfig(from: serviceDir)

        // Track disabled services in serviceInfos but don't start syncing
        if config.enabled == false {
            await ActivityLogger.shared.info(.system, "Skipping disabled service: \(serviceId)")
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
            serviceInfos[serviceId] = ServiceInfo(
                serviceId: serviceId,
                displayName: ServiceIdentity.runtimeDisplayName(for: config, serviceID: serviceId),
                config: config,
                status: .paused,
                fileCount: state.files.count
            )
            authReadiness.removeValue(forKey: serviceId)
            return
        }

        let httpClient = HTTPClient()
        authReadiness[serviceId] = .loading

        // Load auth token from Keychain in background — don't block startup.
        // securityd initialization on first access from a new process can take 30-150s on macOS.
        // Retry up to 10 times (5 minutes total) to handle slow first-access or user dialogs.
        let keychainKey = config.auth.keychainKey
        let authType = config.auth.type
        Task {
            let keychain = platformServices.keychainManager
            var token: String? = nil
            for attempt in 1...10 {
                token = await keychain.load(key: keychainKey)
                if token != nil { break }
                if attempt < 10 {
                    try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s between retries
                }
            }

            guard let token else {
                await self.markAuthUnavailable(serviceId)
                await ActivityLogger.shared.warn(.system, "Auth unavailable for \(serviceId) — skipping authenticated pulls until credentials are updated")
                return
            }

            switch authType {
            case .bearer:
                await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
            case .apiKey:
                await httpClient.setAuthHeader("Authorization", value: token)
            case .basic:
                await httpClient.setAuthHeader("Authorization", value: "Basic \(token)")
            case .oauth2:
                await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
            }
            await self.markAuthReady(serviceId)
            await ActivityLogger.shared.info(.system, "Auth loaded for \(serviceId)")
            await self.coordinator.syncNow(serviceId: serviceId)
        }

        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        adapterEngines[serviceId] = engine

        // Load or create sync state
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
        syncStates[serviceId] = state

        // Pre-populate transformed and canonical collection caches from files
        // already on disk so the first push after startup has the correct
        // baseline for both human-file and object-file edits.
        for (filePath, _) in state.files {
            if let resource = findResource(for: filePath, in: config),
               resource.fileMapping.strategy == .collection {
                let fileURL = serviceDir.appendingPathComponent(filePath)
                if let data = try? Data(contentsOf: fileURL),
                   let records = try? FormatConverterFactory.decode(
                       data: data, format: resource.fileMapping.format,
                       options: resource.fileMapping.effectiveFormatOptions) {
                    lastKnownRecords["\(serviceId):\(filePath)"] = records
                }

                let objectPath = ObjectFileManager.objectFilePath(
                    forUserFile: filePath,
                    strategy: resource.fileMapping.strategy
                )
                let objectURL = serviceDir.appendingPathComponent(objectPath)
                if let rawRecords = try? ObjectFileManager.readCollectionObjectFile(from: objectURL) {
                    lastKnownRawRecords["\(serviceId):\(filePath)"] = rawRecords
                }
            }
        }

        synchronizeFileLinks(serviceDir: serviceDir, config: config, state: state)
        refreshSQLiteMirrorIfPossible(serviceId: serviceId, serviceDir: serviceDir, config: config, state: state)

        // Load or create sync history
        let historyURL = serviceDir.appendingPathComponent(".api2file/sync-history.json")
        historyLogs[serviceId] = (try? SyncHistoryLog.load(from: historyURL)) ?? SyncHistoryLog()

        // Init git if configured
        if self.config.gitAutoCommit {
            let git = GitManager(repoPath: serviceDir, backendFactory: platformServices.versionControlFactory)
            try await git.initRepo()
            try await git.createGitignore()
            gitManagers[serviceId] = git
        }

        // Compute sync interval — use adaptive interval based on change frequency
        let baseInterval = config.resources.first?.sync?.intervalSeconds ?? TimeInterval(self.config.defaultSyncInterval)
        let interval = adaptiveInterval(baseInterval: baseInterval, state: state)

        // Register with coordinator
        let context = ServiceSyncContext(
            syncInterval: interval,
            pullHandler: { [weak self] in
                guard let self else { return }
                try await self.performPull(serviceId: serviceId)
            },
            pushHandler: { [weak self] filePath in
                guard let self else { return }
                try await self.performPush(serviceId: serviceId, filePath: filePath)
            },
            onSyncStart: { [weak self] in
                guard let self else { return }
                await self.updateServiceStatus(serviceId, status: .syncing)
            },
            onSyncComplete: { [weak self] error in
                guard let self else { return }
                if let error {
                    await self.updateServiceStatus(serviceId, status: .error, error: error.localizedDescription)
                    if await self.config.showNotifications {
                        await self.notificationManager.notifyError(
                            service: config.displayName,
                            message: error.localizedDescription
                        )
                    }
                } else {
                    await self.updateServiceStatus(serviceId, status: .connected)
                }
            },
            onPushAbandoned: { [weak self] svcId, filePath, error in
                guard let self else { return }
                await self.handlePushAbandoned(serviceId: svcId, filePath: filePath, error: error)
            }
        )
        await coordinator.register(serviceId: serviceId, context: context)

        // Track service info
        serviceInfos[serviceId] = ServiceInfo(
            serviceId: serviceId,
            displayName: ServiceIdentity.runtimeDisplayName(for: config, serviceID: serviceId),
            config: config,
            status: .connected,
            fileCount: state.files.count
        )
    }

    // MARK: - Config Reload

    /// Reload a service when its adapter.json changes
    private func reloadService(_ serviceId: String) async {
        // Stop existing sync for this service
        await coordinator.unregister(serviceId: serviceId)
        adapterEngines.removeValue(forKey: serviceId)
        syncStates.removeValue(forKey: serviceId)
        serviceInfos.removeValue(forKey: serviceId)
        authReadiness.removeValue(forKey: serviceId)

        // Re-register with updated config
        do {
            try await registerService(serviceId)
            await coordinator.startService(serviceId: serviceId)
            try generateGuides()
            await ActivityLogger.shared.info(.system, "Reloaded config for \(serviceId)")
        } catch {
            await ActivityLogger.shared.error(.system, "Failed to reload \(serviceId) — \(error.localizedDescription)")
        }
    }

    // MARK: - Sync Operations

    /// Max concurrent resource pulls per service
    private static let pullConcurrency = 6

    private func performPull(serviceId: String) async throws {
        guard let engine = adapterEngines[serviceId] else { return }
        guard await isAuthReadyToPull(serviceId: serviceId) else { return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let startTime = Date()
        isPulling[serviceId] = true
        defer { isPulling[serviceId] = false }
        await ActivityLogger.shared.info(.sync, "↓ PULL START \(serviceId) [\(serviceName)]")

        // Work with a LOCAL copy of sync state to avoid exclusive access violations
        // across await points. Write back at the end.
        var localState = syncStates[serviceId] ?? SyncState()

        do {
            let resourcesToSkip = resourcesSkippedByBackoff(state: localState, config: engine.config)
            if !resourcesToSkip.isEmpty {
                await ActivityLogger.shared.debug(.sync, "↓ Skipping \(resourcesToSkip.count) empty resource(s) this cycle")
            }

            let enabledResources = engine.config.resources.filter { $0.enabled != false }
            let sortedResources = prioritizeResources(enabledResources, state: localState, skip: resourcesToSkip)
            let stateSnapshot = localState

            var pulledFiles: [SyncableFile] = []
            var isIncremental = false
            var unchangedCount = 0
            var fullSyncFilePathsByResource: [String: Set<String>] = [:]

            struct ResourcePullResult: Sendable {
                let name: String
                let result: PullResult?
                let responseETag: String?
                let wasIncremental: Bool
                let wasEmpty: Bool
            }

            func enqueuePullTask(
                _ resource: ResourceConfig,
                group: inout ThrowingTaskGroup<ResourcePullResult, Error>,
                stateSnapshot: SyncState
            ) {
                let needsFullSync = self.shouldDoFullSync(serviceId: serviceId, resource: resource)
                let lastSync = stateSnapshot.resourceSyncTimes[resource.name]
                let updatedSince = (!needsFullSync && lastSync != nil) ? lastSync : nil
                let storedETag = stateSnapshot.resourceETags[resource.name]

                group.addTask {
                    do {
                        let result = try await engine.pull(resource: resource, updatedSince: updatedSince, eTag: storedETag)
                        return ResourcePullResult(
                            name: resource.name,
                            result: result,
                            responseETag: result.responseETag,
                            wasIncremental: updatedSince != nil,
                            wasEmpty: result.files.isEmpty && !result.notModified
                        )
                    } catch {
                        await ActivityLogger.shared.error(.sync, "↓ \(resource.name) pull failed: \(error.localizedDescription)")
                        return ResourcePullResult(
                            name: resource.name,
                            result: nil,
                            responseETag: nil,
                            wasIncremental: updatedSince != nil,
                            wasEmpty: true
                        )
                    }
                }
            }

            try await withThrowingTaskGroup(of: ResourcePullResult.self, returning: Void.self) { group in
                var active = 0
                var index = 0

                while active < Self.pullConcurrency && index < sortedResources.count {
                    enqueuePullTask(sortedResources[index], group: &group, stateSnapshot: stateSnapshot)
                    active += 1
                    index += 1
                }

                while let pullResult = try await group.next() {
                    active -= 1

                    if let newETag = pullResult.responseETag {
                        localState.resourceETags[pullResult.name] = newETag
                    }

                    if pullResult.wasEmpty {
                        localState.emptyPullCounts[pullResult.name] = (localState.emptyPullCounts[pullResult.name] ?? 0) + 1
                    } else if let result = pullResult.result, !result.notModified {
                        localState.emptyPullCounts[pullResult.name] = 0
                        if !result.files.isEmpty {
                            localState.lastChangeTime[pullResult.name] = Date()
                        }
                    }

                    if let result = pullResult.result, result.notModified {
                        await ActivityLogger.shared.debug(.sync, "↓ \(pullResult.name) — 304 not modified")
                    }

                    if let result = pullResult.result, !result.notModified {
                        pulledFiles.append(contentsOf: result.files)
                        if pullResult.wasIncremental {
                            isIncremental = true
                        } else {
                            fullSyncFilePathsByResource[pullResult.name] = Set(result.files.map(\.relativePath))
                        }

                        try await applyPullFiles(
                            result: result,
                            resourceWasIncremental: pullResult.wasIncremental,
                            serviceId: serviceId,
                            serviceDir: serviceDir,
                            engine: engine,
                            localState: &localState,
                            unchangedCount: &unchangedCount
                        )
                    }

                    if index < sortedResources.count {
                        enqueuePullTask(sortedResources[index], group: &group, stateSnapshot: stateSnapshot)
                        active += 1
                        index += 1
                    }
                }
            }

            // Stale file cleanup — only for resources that performed a full sync this cycle
            for (resourceName, newFilePaths) in fullSyncFilePathsByResource {
                guard let resource = engine.config.resources.first(where: { $0.name == resourceName }) else { continue }
                let isOnePerRecord = resource.fileMapping.strategy == .onePerRecord
                let childNames = Set((resource.children ?? []).map(\.name))
                let hasCompanions = resource.fileMapping.companionFiles?.isEmpty == false
                guard isOnePerRecord || !childNames.isEmpty || hasCompanions else { continue }

                var staleFilePaths: [String] = []
                for (filePath, fileState) in localState.files where !newFilePaths.contains(filePath) {
                    // Companion file for a deleted record — scope check to this resource's companion dirs
                    if hasCompanions, fileState.isCompanion == true,
                       let companionConfigs = resource.fileMapping.companionFiles,
                       companionConfigs.contains(where: { cfg in
                           cfg.directory.isEmpty || cfg.directory == "."
                               ? true
                               : filePath.hasPrefix(cfg.directory + "/")
                       }) {
                        staleFilePaths.append(filePath)
                        continue
                    }
                    guard let matchedResource = findResource(for: filePath, in: engine.config) else { continue }
                    if isOnePerRecord,
                       matchedResource.name == resource.name,
                       matchedResource.fileMapping.strategy == .onePerRecord {
                        staleFilePaths.append(filePath)
                    } else if childNames.contains(matchedResource.name) {
                        staleFilePaths.append(filePath)
                    }
                }

                for filePath in staleFilePaths {
                    let fileURL = serviceDir.appendingPathComponent(filePath)
                    if let matchedResource = findResource(for: filePath, in: engine.config) {
                        let objectPath = ObjectFileManager.objectFilePath(
                            forUserFile: filePath,
                            strategy: matchedResource.fileMapping.strategy
                        )
                        let objectURL = serviceDir.appendingPathComponent(objectPath)
                        try? FileManager.default.removeItem(at: objectURL)
                        suppressPath(objectPath)
                        try? FileLinkManager.removeLinks(referencingAny: [filePath, objectPath], in: serviceDir)
                    }
                    try? FileManager.default.removeItem(at: fileURL)
                    suppressPath(filePath)
                    localState.files.removeValue(forKey: filePath)
                    await ActivityLogger.shared.info(.sync, "↓ Removed stale local file: \(filePath) (deleted from API)")
                }
            }

            for resource in engine.config.resources {
                let name = resource.name
                if shouldDoFullSync(serviceId: serviceId, resource: resource) {
                    localState.resourceSyncTimes[name] = Date()
                    localState.syncCounts[name] = 0
                } else {
                    localState.syncCounts[name] = (localState.syncCounts[name] ?? 0) + 1
                }
            }

            await refreshWixSiteArtifacts(
                serviceId: serviceId,
                serviceDir: serviceDir,
                engine: engine,
                state: &localState
            )

            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try localState.save(to: stateURL)
            syncStates[serviceId] = localState
            synchronizeFileLinks(serviceDir: serviceDir, config: engine.config, state: localState)
            refreshSQLiteMirrorIfPossible(serviceId: serviceId, serviceDir: serviceDir, config: engine.config, state: localState)

            if config.gitAutoCommit, let git = gitManagers[serviceId] {
                if try await git.hasChanges() {
                    let syncType = isIncremental ? "incremental pull" : "pull"
                    do {
                        try await git.commitAll(message: "sync: \(syncType) \(serviceId) — updated \(pulledFiles.count) files")
                    } catch {
                        await ActivityLogger.shared.warn(
                            .sync,
                            "↓ Pull data synced for \(serviceId), but git commit failed: \(error.localizedDescription)"
                        )
                    }
                }
            }

            serviceInfos[serviceId]?.fileCount = localState.files.count
            serviceInfos[serviceId]?.lastSyncTime = Date()

            let fileChanges = pulledFiles.map {
                FileChange(path: $0.relativePath, action: .downloaded)
            }
            let syncType = isIncremental ? "incremental pull" : "pulled"
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            let unchangedSuffix = unchangedCount > 0 ? ", \(unchangedCount) unchanged" : ""
            await ActivityLogger.shared.info(.sync, "↓ PULL OK \(serviceId) — \(syncType) \(pulledFiles.count) file(s)\(unchangedSuffix) (\(ms)ms)")
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .pull,
                status: .success,
                duration: Date().timeIntervalSince(startTime),
                files: fileChanges,
                summary: "\(syncType) \(pulledFiles.count) files\(unchangedSuffix)"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
        } catch {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogger.shared.error(.sync, "↓ PULL FAILED \(serviceId) — \(error.localizedDescription) (\(ms)ms)")
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .pull,
                status: .error,
                duration: Date().timeIntervalSince(startTime),
                files: [],
                summary: "pull failed: \(error.localizedDescription)"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
            throw error
        }
    }

    private func markAuthReady(_ serviceId: String) {
        authReadiness[serviceId] = .ready
    }

    private func markAuthUnavailable(_ serviceId: String) {
        authReadiness[serviceId] = .unavailable
    }

    private func isAuthReadyToPull(serviceId: String) async -> Bool {
        switch authReadiness[serviceId] ?? .loading {
        case .ready:
            return true
        case .loading:
            await ActivityLogger.shared.info(.system, "Skipping pull for \(serviceId) while auth is still loading")
            return false
        case .unavailable:
            await ActivityLogger.shared.warn(.system, "Skipping pull for \(serviceId) — credentials are unavailable")
            await updateServiceStatus(serviceId, status: .error, error: "Credentials unavailable. Update the service API key to resume sync.")
            return false
        }
    }

    private func ensureAuthReadyToPush(serviceId: String, filePath: String) async throws {
        switch authReadiness[serviceId] ?? .loading {
        case .ready:
            return
        case .loading:
            await ActivityLogger.shared.info(.system, "Deferring push for \(serviceId) while auth is still loading: \(filePath)")
            throw DeferredSyncError.authLoading
        case .unavailable:
            await ActivityLogger.shared.warn(.system, "Deferring push for \(serviceId) — credentials are unavailable: \(filePath)")
            await updateServiceStatus(serviceId, status: .error, error: "Credentials unavailable. Update the service API key to resume sync.")
            throw DeferredSyncError.credentialsUnavailable
        }
    }

    private func applyPullFiles(
        result: PullResult,
        resourceWasIncremental: Bool,
        serviceId: String,
        serviceDir: URL,
        engine: AdapterEngine,
        localState: inout SyncState,
        unchangedCount: inout Int
    ) async throws {
        for file in result.files {
            // Skip excluded files
            if localState.files[file.relativePath]?.excluded == true {
                await ActivityLogger.shared.debug(.sync, "↓ Skipping \(file.relativePath) — excluded from sync")
                continue
            }

            let filePath = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Companion files — write if changed, mark as companion in state, never push
            if file.isCompanion {
                if file.contentHash != localState.files[file.relativePath]?.lastSyncedHash {
                    suppressPath(file.relativePath)
                    try file.content.write(to: filePath, options: .atomic)
                }
                localState.files[file.relativePath] = FileSyncState(
                    remoteId: file.remoteId ?? "",
                    lastSyncedHash: file.contentHash,
                    lastSyncTime: Date(),
                    status: .synced,
                    isCompanion: true
                )
                continue
            }

            // Skip files with very recent local changes so the queued push runs first.
            if let lastSyncedHash = localState.files[file.relativePath]?.lastSyncedHash,
               let localData = try? Data(contentsOf: filePath),
               localData.sha256Hex != lastSyncedHash {
                let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path)
                let modDate = attrs?[.modificationDate] as? Date ?? .distantPast
                if Date().timeIntervalSince(modDate) < 5 {
                    await ActivityLogger.shared.info(.sync, "↓ Skipping \(file.relativePath) — local changes pending push")
                    continue
                }
            }

            if resourceWasIncremental,
               let resource = findResource(for: file.relativePath, in: engine.config),
               resource.fileMapping.strategy == .collection {
                let cacheKey = "\(serviceId):\(file.relativePath)"
                let mergeResult = try IncrementalCollectionMerger.merge(
                    existingRaw: loadExistingRawRecords(
                        serviceDir: serviceDir,
                        filePath: file.relativePath,
                        resource: resource
                    ),
                    existingTransformed: loadExistingTransformedRecords(
                        serviceDir: serviceDir,
                        filePath: file.relativePath,
                        resource: resource,
                        cacheKey: cacheKey
                    ),
                    newRaw: result.rawRecordsByFile[file.relativePath] ?? [],
                    resource: resource
                )
                let mergedHash = mergeResult.contentHash
                if mergedHash == localState.files[file.relativePath]?.lastSyncedHash {
                    unchangedCount += 1
                    lastKnownRecords[cacheKey] = mergeResult.transformedRecords
                    lastKnownRawRecords[cacheKey] = mergeResult.rawRecords
                    refreshObjectFileIfNeeded(
                        file: file,
                        rawRecords: mergeResult.rawRecords,
                        serviceDir: serviceDir,
                        engine: engine
                    )
                } else {
                    suppressPath(file.relativePath)
                    try mergeResult.content.write(to: filePath, options: .atomic)

                    let objectPath = ObjectFileManager.objectFilePath(
                        forUserFile: file.relativePath,
                        strategy: resource.fileMapping.strategy
                    )
                    let objectURL = serviceDir.appendingPathComponent(objectPath)
                    suppressPath(objectPath)
                    try ObjectFileManager.writeCollectionObjectFile(records: mergeResult.rawRecords, to: objectURL)
                    lastKnownRecords[cacheKey] = mergeResult.transformedRecords
                    lastKnownRawRecords[cacheKey] = mergeResult.rawRecords
                }

                let collectionContextId = collectionFileContextId(
                    existingRemoteId: file.remoteId ?? localState.files[file.relativePath]?.remoteId,
                    rawRecords: mergeResult.rawRecords,
                    resource: resource
                )
                localState.files[file.relativePath] = FileSyncState(
                    remoteId: collectionContextId ?? "",
                    lastSyncedHash: mergedHash,
                    lastSyncTime: Date(),
                    status: .synced
                )
                upsertFileLink(
                    serviceDir: serviceDir,
                    resource: resource,
                    userPath: file.relativePath,
                    remoteId: localState.files[file.relativePath]?.remoteId
                )
                continue
            }

            if file.contentHash == localState.files[file.relativePath]?.lastSyncedHash {
                unchangedCount += 1
                if let rawRecords = result.rawRecordsByFile[file.relativePath] {
                    refreshObjectFileIfNeeded(
                        file: file,
                        rawRecords: rawRecords,
                        serviceDir: serviceDir,
                        engine: engine
                    )
                    cacheRawCollectionRecords(file: file, pullResult: result, serviceId: serviceId, engine: engine)
                }
            } else {
                suppressPath(file.relativePath)
                try file.content.write(to: filePath, options: .atomic)
                writeObjectFile(file: file, pullResult: result, serviceId: serviceId, serviceDir: serviceDir, engine: engine)
                cacheCollectionRecords(file: file, serviceId: serviceId, engine: engine)
                cacheRawCollectionRecords(file: file, pullResult: result, serviceId: serviceId, engine: engine)
            }

            if let resource = findResource(for: file.relativePath, in: engine.config),
               resource.fileMapping.strategy == .collection {
                let collectionContextId = collectionFileContextId(
                    existingRemoteId: file.remoteId ?? localState.files[file.relativePath]?.remoteId,
                    rawRecords: result.rawRecordsByFile[file.relativePath] ?? [],
                    resource: resource
                )
                localState.files[file.relativePath] = FileSyncState(
                    remoteId: collectionContextId ?? "",
                    lastSyncedHash: file.contentHash,
                    lastSyncTime: Date(),
                    status: .synced
                )
                upsertFileLink(
                    serviceDir: serviceDir,
                    resource: resource,
                    userPath: file.relativePath,
                    remoteId: localState.files[file.relativePath]?.remoteId
                )
                continue
            } else if let remoteId = file.remoteId {
                localState.files[file.relativePath] = FileSyncState(
                    remoteId: remoteId,
                    lastSyncedHash: file.contentHash,
                    lastSyncTime: Date(),
                    status: .synced
                )
            } else if var existing = localState.files[file.relativePath] {
                existing.lastSyncedHash = file.contentHash
                existing.lastSyncTime = Date()
                localState.files[file.relativePath] = existing
            } else {
                localState.files[file.relativePath] = FileSyncState(
                    remoteId: "",
                    lastSyncedHash: file.contentHash,
                    lastSyncTime: Date(),
                    status: .synced
                )
            }

            if let resource = findResource(for: file.relativePath, in: engine.config) {
                upsertFileLink(
                    serviceDir: serviceDir,
                    resource: resource,
                    userPath: file.relativePath,
                    remoteId: localState.files[file.relativePath]?.remoteId
                )
            }
        }
    }

    private func performPush(serviceId: String, filePath: String) async throws {
        guard let engine = adapterEngines[serviceId] else { return }
        try await ensureAuthReadyToPush(serviceId: serviceId, filePath: filePath)
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let fullPath = serviceDir.appendingPathComponent(filePath)
        let startTime = Date()
        await ActivityLogger.shared.info(.sync, "↑ PUSH START \(serviceId) — \(filePath)")

        // Find which resource this file belongs to
        guard let resource = findResource(for: filePath, in: engine.config) else { return }

        // Skip disabled resources
        if resource.enabled == false { return }

        // Skip excluded files
        if syncStates[serviceId]?.files[filePath]?.excluded == true { return }

        // Skip companion files — they are generated from templates and never pushed
        if syncStates[serviceId]?.files[filePath]?.isCompanion == true { return }

        // Skip read-only resources
        if resource.fileMapping.effectivePushMode == .readOnly { return }

        // Skip if no push config (prevents errors for pull-only resources like blog-posts)
        if resource.push == nil { return }

        // Handle file deletion — if file is gone, optionally delete from API
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir), !isDir.boolValue else {
            let shouldDelete = resource.fileMapping.deleteFromAPI ?? config.deleteFromAPI
            if shouldDelete {
                if let handler = deletionConfirmationHandler {
                    let cacheKey = "\(serviceId):\(filePath)"
                    let knownCount: Int?
                    switch resource.fileMapping.strategy {
                    case .collection:
                        knownCount = lastKnownRecords[cacheKey]?.count
                    case .onePerRecord, .mirror:
                        knownCount = syncStates[serviceId]?.files[filePath]?.remoteId != nil ? 1 : nil
                    }
                    let info = DeletionInfo(
                        serviceName: serviceInfos[serviceId]?.displayName ?? serviceId,
                        serviceId: serviceId,
                        filePath: filePath,
                        recordCount: knownCount,
                        kind: .fileDeletion
                    )
                    let confirmed = await handler(info)
                    if !confirmed {
                        await ActivityLogger.shared.info(.sync, "↺ File deletion cancelled by user — triggering pull: \(filePath)")
                        Task { try? await self.performPull(serviceId: serviceId) }
                        return
                    }
                }
                try await handleFileDeletion(serviceId: serviceId, filePath: filePath, resource: resource, engine: engine)
            }
            return
        }
        let content = try Data(contentsOf: fullPath)

        // Skip if file content matches last synced hash (no actual change — e.g., file written by pull)
        let currentHash = content.sha256Hex
        if let lastHash = syncStates[serviceId]?.files[filePath]?.lastSyncedHash, lastHash == currentHash {
            return // File unchanged since last sync, skip push
        }

        do {
            var fileChange: FileChange

            // For collection-strategy files, use smart diffing to push only changes
            if resource.fileMapping.strategy == .collection {
                let diff = try await pushCollectionDiff(
                    serviceId: serviceId,
                    filePath: filePath,
                    content: content,
                    resource: resource,
                    engine: engine
                )
                fileChange = FileChange(
                    path: filePath,
                    action: .uploaded,
                    recordsCreated: diff?.created.count ?? 0,
                    recordsUpdated: diff?.updated.count ?? 0,
                    recordsDeleted: diff?.deleted.count ?? 0
                )
            } else {
                let existingRemoteId = syncStates[serviceId]?.files[filePath]?.remoteId
                let file = SyncableFile(
                    relativePath: filePath,
                    format: resource.fileMapping.format,
                    content: content,
                    remoteId: existingRemoteId
                )
                let createdId = try await engine.push(file: file, resource: resource)
                fileChange = FileChange(path: filePath, action: .uploaded)

                // For new one-per-record files, create a state entry with the new remote ID
                if existingRemoteId == nil, let newId = createdId {
                    syncStates[serviceId]?.files[filePath] = FileSyncState(
                        remoteId: newId,
                        lastSyncedHash: content.sha256Hex,
                        lastSyncTime: Date(),
                        status: .synced
                    )
                }

                if resource.fileMapping.strategy == .onePerRecord {
                    let recordId = existingRemoteId ?? createdId
                    try await refreshOnePerRecordFilesAfterPush(
                        serviceId: serviceId,
                        resource: resource,
                        userFilePath: filePath,
                        recordId: recordId,
                        engine: engine
                    )
                }
            }

            // Update sync state
            syncStates[serviceId]?.files[filePath]?.lastSyncedHash = content.sha256Hex
            syncStates[serviceId]?.files[filePath]?.lastSyncTime = Date()
            syncStates[serviceId]?.files[filePath]?.status = .synced

            // Mark as recently pushed — pull will skip overwriting for cooldown period
            recentlyPushed["\(serviceId):\(filePath)"] = Date()

            // Save state
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try syncStates[serviceId]?.save(to: stateURL)

            if let resource = findResource(for: filePath, in: engine.config) {
                upsertFileLink(
                    serviceDir: serviceDir,
                    resource: resource,
                    userPath: filePath,
                    remoteId: syncStates[serviceId]?.files[filePath]?.remoteId
                )
            }
            synchronizeFileLinks(serviceDir: serviceDir, config: engine.config, state: syncStates[serviceId] ?? SyncState())
            refreshSQLiteMirrorIfPossible(
                serviceId: serviceId,
                serviceDir: serviceDir,
                config: engine.config,
                state: syncStates[serviceId] ?? SyncState()
            )

            // Git commit
            if config.gitAutoCommit, let git = gitManagers[serviceId] {
                if try await git.hasChanges() {
                    try await git.commitAll(message: "sync: push \(serviceId) — \(filePath)")
                }
            }

            // Log history entry
            let summary: String
            if fileChange.recordsCreated + fileChange.recordsUpdated + fileChange.recordsDeleted > 0 {
                var parts: [String] = []
                if fileChange.recordsCreated > 0 { parts.append("\(fileChange.recordsCreated) created") }
                if fileChange.recordsUpdated > 0 { parts.append("\(fileChange.recordsUpdated) updated") }
                if fileChange.recordsDeleted > 0 { parts.append("\(fileChange.recordsDeleted) deleted") }
                summary = "pushed \(filePath) (\(parts.joined(separator: ", ")))"
            } else {
                summary = "pushed \(filePath)"
            }
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogger.shared.info(.sync, "↑ PUSH OK \(serviceId) — \(summary) (\(ms)ms)")
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .push,
                status: .success,
                duration: Date().timeIntervalSince(startTime),
                files: [fileChange],
                summary: summary
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
        } catch {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogger.shared.error(.sync, "↑ PUSH FAILED \(serviceId) — \(filePath): \(error.localizedDescription) (\(ms)ms)")
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .push,
                status: .error,
                duration: Date().timeIntervalSince(startTime),
                files: [FileChange(path: filePath, action: .error, errorMessage: error.localizedDescription)],
                summary: "push failed: \(error.localizedDescription)"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
            throw error
        }
    }

    // MARK: - File Change Handling

    private func handleFileChanges(_ changes: [FileWatcher.FileChange]) {
        for change in changes {
            // Extract service ID and relative path from the full path
            let path = change.path
            guard let relativeParts = extractServiceAndPath(from: path) else { continue }
            let (serviceId, filePath) = relativeParts

            // Skip changes while pulling (prevents concurrent access to syncStates)
            if isPulling[serviceId] == true { continue }

            // Skip internal, temp, and hidden files
            if filePath.hasPrefix(".api2file/") || filePath.hasPrefix(".git/") { continue }
            if filePath.hasPrefix("Snapshots/") { continue }
            if filePath == "CLAUDE.md" { continue }
            if filePath.contains("~$") { continue } // Office temp files
            if filePath.contains(".dat.nosync") { continue } // macOS temp files
            if filePath.contains(".tmp.") { continue } // atomic-write temp files (e.g. file.csv.tmp.PID.N)

            // Skip suppressed paths (written by pull or regeneration — prevents loops)
            if isSuppressed(filePath) { continue }

            if ObjectFileManager.isObjectFile(filePath) {
                guard !change.flags.contains(.removed) else { continue }
                Task { await self.performObjectPush(serviceId: serviceId, objectFilePath: filePath) }
                continue
            }

            // Skip companion files — they are generated from templates, not user-editable
            if syncStates[serviceId]?.files[filePath]?.isCompanion == true { continue }

            if filePath.hasPrefix(".") || filePath.contains("/.") { continue } // hidden files

            Task {
                await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
                await coordinator.flushPendingPushes(serviceId: serviceId)
            }
        }
    }

    /// Suppress self-generated watcher events just long enough to absorb duplicate
    /// FSEvents from pull/regeneration writes without hiding real user edits that
    /// happen shortly after a sync completes.
    private func suppressPath(_ filePath: String, for duration: TimeInterval = 1) {
        suppressedPaths[filePath] = Date().addingTimeInterval(duration)
    }

    private func isSuppressed(_ filePath: String) -> Bool {
        let now = Date()
        suppressedPaths = suppressedPaths.filter { $0.value > now }
        guard let expiresAt = suppressedPaths[filePath] else { return false }
        if expiresAt > now {
            return true
        }
        suppressedPaths.removeValue(forKey: filePath)
        return false
    }

    private func collectionFileContextId(existingRemoteId: String?, rawRecords: [[String: Any]], resource: ResourceConfig? = nil) -> String? {
        if let existingRemoteId, !existingRemoteId.isEmpty {
            return existingRemoteId
        }
        if let resourceId = collectionContextId(from: resource), !resourceId.isEmpty {
            return resourceId
        }
        for record in rawRecords {
            if let id = record["dataCollectionId"] as? String, !id.isEmpty {
                return id
            }
            if let id = record["collectionId"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    private func collectionContextId(from resource: ResourceConfig?) -> String? {
        guard let body = resource?.pull?.body else { return nil }
        return jsonString(body, path: ["dataCollectionId"])
    }

    private func jsonString(_ value: JSONValue, path: [String]) -> String? {
        if path.isEmpty {
            if case .string(let string) = value, !string.isEmpty, !string.contains("{") {
                return string
            }
            return nil
        }

        guard case .object(let object) = value,
              let child = object[path[0]] else {
            return nil
        }

        return jsonString(child, path: Array(path.dropFirst()))
    }

    private func collectionDeleteTemplateVars(collectionContextId: String?) -> [String: Any] {
        guard let collectionContextId, !collectionContextId.isEmpty else { return [:] }
        return ["dataCollectionId": collectionContextId]
    }

    private func wixGroupOwnerId(
        from rawRecord: [String: Any]?,
        rawRecords: [[String: Any]],
        siblingContext: [String: Any]
    ) -> String? {
        if let ownerId = siblingContext["ownerId"] as? String, !ownerId.isEmpty {
            return ownerId
        }
        let candidates = [rawRecord].compactMap { $0 } + rawRecords
        for candidate in candidates {
            if let ownerId = candidate["ownerId"] as? String, !ownerId.isEmpty {
                return ownerId
            }
            if let createdBy = candidate["createdBy"] as? [String: Any],
               let ownerId = createdBy["id"] as? String,
               !ownerId.isEmpty {
                return ownerId
            }
        }
        return nil
    }

    private func enrichWixHumanRecordForPush(
        _ record: [String: Any],
        resource: ResourceConfig,
        rawRecord: [String: Any]?,
        rawRecords: [[String: Any]],
        siblingContext: [String: Any],
        collectionContextId: String?
    ) -> [String: Any] {
        var enriched = record

        switch resource.name {
        case "groups":
            if enriched["ownerId"] == nil,
               let ownerId = wixGroupOwnerId(from: rawRecord, rawRecords: rawRecords, siblingContext: siblingContext) {
                enriched["ownerId"] = ownerId
            }
        case "bookings-services":
            let template = rawRecord ?? rawRecords.first

            if enriched["type"] == nil {
                enriched["type"] = template?["type"] ?? "APPOINTMENT"
            }
            if enriched["capacity"] == nil {
                if let defaultCapacity = template?["defaultCapacity"] {
                    enriched["capacity"] = defaultCapacity
                } else if let capacity = template?["capacity"] {
                    enriched["capacity"] = capacity
                } else {
                    enriched["capacity"] = 1
                }
            }
            if enriched["onlineBookingEnabled"] == nil {
                if let onlineBooking = template?["onlineBooking"] as? [String: Any],
                   let enabled = onlineBooking["enabled"] {
                    enriched["onlineBookingEnabled"] = enabled
                } else {
                    enriched["onlineBookingEnabled"] = true
                }
            }

            for key in ["onlineBooking", "payment", "locations", "schedule", "staffMemberIds"] {
                if enriched[key] == nil, let value = template?[key] {
                    enriched[key] = value
                }
            }
        case let name where name.hasPrefix("collections.items"):
            if enriched["dataCollectionId"] == nil, let collectionContextId {
                enriched["dataCollectionId"] = collectionContextId
            }
        default:
            break
        }

        return enriched
    }

    private func extractServiceAndPath(from fullPath: String) -> (serviceId: String, filePath: String)? {
        // FSEvents on macOS reports canonical paths (e.g. /private/var/..., /private/tmp/...)
        // while FileManager may return symlinked paths (e.g. /var/..., /tmp/...).
        // Try the stored path first, then the canonical variant with /private prefix.
        let syncPath = syncFolder.path
        let candidates = [
            syncPath,
            "/private" + syncPath,  // /var -> /private/var, /tmp -> /private/tmp
        ]

        var prefix: String?
        for candidate in candidates {
            if fullPath.hasPrefix(candidate + "/") {
                prefix = candidate
                break
            }
        }
        guard let prefix else { return nil }

        let relative = String(fullPath.dropFirst(prefix.count + 1)) // +1 for the /
        let components = relative.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }

        return (String(components[0]), String(components[1]))
    }

    // MARK: - File Deletion

    /// Handle a file deletion — delete records from the API if configured.
    private func handleFileDeletion(
        serviceId: String,
        filePath: String,
        resource: ResourceConfig,
        engine: AdapterEngine
    ) async throws {
        let cacheKey = "\(serviceId):\(filePath)"
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let startTime = Date()
        var deletedCount = 0

        do {
            switch resource.fileMapping.strategy {
            case .onePerRecord:
                if let remoteId = syncStates[serviceId]?.files[filePath]?.remoteId {
                    try await engine.delete(remoteId: remoteId, resource: resource)
                    syncStates[serviceId]?.files.removeValue(forKey: filePath)
                    deletedCount = 1
                    await ActivityLogger.shared.info(.sync, "DELETE record \(remoteId) from API (file removed: \(filePath))")
                }

            case .collection:
                let records = lastKnownRawRecords[cacheKey] ?? lastKnownRecords[cacheKey] ?? []
                let idField = resource.fileMapping.idField ?? "id"
                let collectionContextId = syncStates[serviceId]?.files[filePath]?.remoteId
                for record in records {
                    let recordId: String?
                    if let id = record[idField] as? String { recordId = id }
                    else if let id = record[idField] as? Int { recordId = "\(id)" }
                    else { recordId = nil }

                    if let id = recordId {
                        try await engine.delete(
                            remoteId: id,
                            resource: resource,
                            extraTemplateVars: collectionDeleteTemplateVars(collectionContextId: collectionContextId)
                        )
                        deletedCount += 1
                    }
                }
                lastKnownRecords.removeValue(forKey: cacheKey)
                lastKnownRawRecords.removeValue(forKey: cacheKey)
                syncStates[serviceId]?.files.removeValue(forKey: filePath)
                await ActivityLogger.shared.info(.sync, "DELETE \(deletedCount) records from API (file removed: \(filePath))")

            case .mirror:
                if let remoteId = syncStates[serviceId]?.files[filePath]?.remoteId {
                    try await engine.delete(remoteId: remoteId, resource: resource)
                    syncStates[serviceId]?.files.removeValue(forKey: filePath)
                    deletedCount = 1
                }
            }

            // Clean up object file
            let objectPath = ObjectFileManager.objectFilePath(forUserFile: filePath, strategy: resource.fileMapping.strategy)
            let objectURL = serviceDir.appendingPathComponent(objectPath)
            suppressPath(objectPath)
            try? FileManager.default.removeItem(at: objectURL)
            try? FileLinkManager.removeLinks(referencingAny: [filePath, objectPath], in: serviceDir)

            // Save state
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try syncStates[serviceId]?.save(to: stateURL)
            synchronizeFileLinks(serviceDir: serviceDir, config: engine.config, state: syncStates[serviceId] ?? SyncState())
            refreshSQLiteMirrorIfPossible(
                serviceId: serviceId,
                serviceDir: serviceDir,
                config: engine.config,
                state: syncStates[serviceId] ?? SyncState()
            )

            // Log history
            if deletedCount > 0 {
                let entry = SyncHistoryEntry(
                    serviceId: serviceId,
                    serviceName: serviceName,
                    direction: .push,
                    status: .success,
                    duration: Date().timeIntervalSince(startTime),
                    files: [FileChange(path: filePath, action: .deleted, recordsDeleted: deletedCount)],
                    summary: "deleted \(deletedCount) record(s) via file removal: \(filePath)"
                )
                logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
            }
        } catch {
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .push,
                status: .error,
                duration: Date().timeIntervalSince(startTime),
                files: [FileChange(path: filePath, action: .error, errorMessage: error.localizedDescription)],
                summary: "file deletion push failed: \(error.localizedDescription)"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
            throw error
        }
    }

    // MARK: - Collection Diff Push

    /// Smart push for collection files: diff old vs new records, push only changes.
    /// Applies inverse transforms when the resource uses auto-reverse pushMode.
    /// Returns the diff result (nil if no changes).
    @discardableResult
    private func pushCollectionDiff(
        serviceId: String,
        filePath: String,
        content: Data,
        resource: ResourceConfig,
        engine: AdapterEngine
    ) async throws -> CollectionDiffer.DiffResult? {
        let cacheKey = "\(serviceId):\(filePath)"
        let idField = resource.fileMapping.idField ?? "id"

        // Decode new records from the edited file
        // If decode fails (e.g., OOXML unzip issue), skip this push gracefully
        let newRecords: [[String: Any]]
        do {
            newRecords = try FormatConverterFactory.decode(
                data: content,
                format: resource.fileMapping.format,
                options: resource.fileMapping.effectiveFormatOptions
            )
        } catch {
            await ActivityLogger.shared.warn(.sync, "Skipping push for \(filePath) — decode failed: \(error.localizedDescription)")
            return nil
        }

        // Get old records (from cache or empty if first push)
        let oldRecords = lastKnownRecords[cacheKey] ?? []

        // Collect fields the push transform omits — these are server-controlled
        // and should be ignored when diffing (e.g., revision, updatedDate)
        var pushIgnoreFields = Set<String>()
        let pushTransforms = resource.fileMapping.transforms?.push ?? []
        for op in pushTransforms {
            if op.op == "omit", let fields = op.fields {
                pushIgnoreFields.formUnion(fields)
            }
        }
        // Always ignore revision fields — they're managed by the server
        pushIgnoreFields.insert("revision")
        pushIgnoreFields.insert("_revision")
        pushIgnoreFields.insert("updatedDate")
        pushIgnoreFields.insert("_updatedDate")

        // Diff
        let diff = CollectionDiffer.diff(old: oldRecords, new: newRecords, idField: idField, ignoreFields: pushIgnoreFields)

        if diff.isEmpty {
            return nil // No actual changes
        }

        await ActivityLogger.shared.debug(.sync, "Collection diff for \(filePath): \(diff.summary)")

        // Load raw records from object file for inverse transforms
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let objectPath = ObjectFileManager.objectFilePath(forUserFile: filePath, strategy: .collection)
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        let rawRecords: [[String: Any]]? = try? ObjectFileManager.readCollectionObjectFile(from: objectURL)
        let oldRawRecords = lastKnownRawRecords[cacheKey] ?? rawRecords ?? []

        // Compute inverse transforms if needed
        let pullTransforms = resource.fileMapping.transforms?.pull ?? []
        let inverseOps = pullTransforms.isEmpty ? [] : InverseTransformPipeline.computeInverse(of: pullTransforms)
        let usesCustomPushTransforms = resource.fileMapping.effectivePushMode == .custom && !pushTransforms.isEmpty
        let shouldInverse = resource.fileMapping.effectivePushMode == .autoReverse && !inverseOps.isEmpty
        let collectionContextId = collectionFileContextId(
            existingRemoteId: syncStates[serviceId]?.files[filePath]?.remoteId,
            rawRecords: rawRecords ?? [],
            resource: resource
        )

        // Build raw record lookup by ID for merging and revision injection
        var rawLookup: [String: [String: Any]] = [:]
        if !oldRawRecords.isEmpty {
            for raw in oldRawRecords {
                if let id = raw[idField] as? String {
                    rawLookup[id] = raw
                } else if let id = raw[idField] as? Int {
                    rawLookup["\(id)"] = raw
                }
            }
        }

        // Build sibling context: fields that appear in existing records (have IDs) but may be
        // missing in newly-added rows (e.g. boardId in child items.csv).
        let siblingRecords = newRecords.filter { r in
            if let id = r[idField] as? String { return !id.isEmpty }
            if r[idField] is Int { return true }
            return false
        }
        let siblingContext: [String: Any] = siblingRecords.first ?? [:]

        // Push creates
        for record in diff.created {
            // Enrich: fill any missing/empty fields from a sibling record so that
            // context fields like `boardId` are available even when the user omitted them.
            var enriched = record
            for (key, value) in siblingContext where key != idField {
                let cur = enriched[key]
                if cur == nil || (cur as? String) == "" {
                    enriched[key] = value
                }
            }

            enriched = enrichWixHumanRecordForPush(
                enriched,
                resource: resource,
                rawRecord: nil,
                rawRecords: oldRawRecords,
                siblingContext: siblingContext,
                collectionContextId: collectionContextId
            )

            // For creates there is no cached raw record to merge with, so skip
            // mechanical inverse — it would relocate fields (e.g. boardId → board.boardId)
            // that the push mutation template still expects at their user-facing position.
            try await engine.pushRecord(enriched, resource: resource, action: .create)
        }

        // Push updates (with inverse transform merging)
        // GraphQL mutations use explicit {field} template substitution with user-facing names,
        // so inverse transforms (which relocate flat fields like boardId → board.boardId) must
        // be skipped — the mutation template would fail to find {boardId} at the top level.
        let shouldSkipInverseForGraphQL = resource.push?.update?.type == .graphql
            && resource.push?.update?.bodyType == nil
        for (id, record) in diff.updated {
            var pushRecord: [String: Any]
            let existingRawRecord = rawLookup[id]
            if usesCustomPushTransforms {
                if let rawRecord = existingRawRecord {
                    pushRecord = rawRecord
                    for (key, value) in record {
                        pushRecord[key] = value
                    }
                } else {
                    pushRecord = record
                }
            } else if !shouldSkipInverseForGraphQL && shouldInverse, let rawRecord = rawLookup[id] {
                pushRecord = InverseTransformPipeline.apply(inverseOps: inverseOps, editedRecord: record, rawRecord: rawRecord)
            } else if !shouldSkipInverseForGraphQL && shouldInverse {
                pushRecord = InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record)
            } else {
                pushRecord = record
            }

            pushRecord = enrichWixHumanRecordForPush(
                pushRecord,
                resource: resource,
                rawRecord: existingRawRecord,
                rawRecords: oldRawRecords,
                siblingContext: siblingContext,
                collectionContextId: collectionContextId
            )

            // Inject latest revision from raw API record for optimistic concurrency.
            // APIs like Wix silently reject updates with stale revision numbers.
            if let rawRecord = existingRawRecord {
                if let rev = rawRecord["revision"] { pushRecord["revision"] = rev }
                if let rev = rawRecord["_revision"] { pushRecord["_revision"] = rev }
            }

            try await engine.pushRecord(pushRecord, resource: resource, action: .update(id: id))
        }

        // Push deletes — with optional confirmation
        var deletedIds: [String] = []
        if !diff.deleted.isEmpty {
            var proceed = true
            if let handler = deletionConfirmationHandler {
                let info = DeletionInfo(
                    serviceName: serviceInfos[serviceId]?.displayName ?? serviceId,
                    serviceId: serviceId,
                    filePath: filePath,
                    recordCount: diff.deleted.count,
                    kind: .rowDeletion
                )
                proceed = await handler(info)
            }
            if proceed {
                for id in diff.deleted {
                    try await engine.delete(
                        remoteId: id,
                        resource: resource,
                        extraTemplateVars: collectionDeleteTemplateVars(collectionContextId: collectionContextId)
                    )
                    deletedIds.append(id)
                }
            } else {
                await ActivityLogger.shared.info(.sync, "↺ Row deletion cancelled by user — restoring rows: \(filePath)")
                // Re-pull to restore the deleted rows from the server
                Task { try? await self.performPull(serviceId: serviceId) }
            }
        }

        // Update caches — use the file currently on disk (which may have been written by a
        // concurrent pull with fresh revision/updatedDate), not our pre-push newRecords.
        let freshURL = syncFolder.appendingPathComponent(serviceId).appendingPathComponent(filePath)
        if let freshData = try? Data(contentsOf: freshURL),
           let freshRecords = try? FormatConverterFactory.decode(data: freshData, format: resource.fileMapping.format, options: resource.fileMapping.effectiveFormatOptions) {
            lastKnownRecords[cacheKey] = freshRecords
        } else if deletedIds.count == diff.deleted.count || diff.deleted.isEmpty {
            lastKnownRecords[cacheKey] = newRecords
        } else {
            lastKnownRecords[cacheKey] = oldRecords
        }

        // Update object file with current state
        var updatedRawRecords = oldRawRecords
        if usesCustomPushTransforms || shouldInverse || rawRecords != nil {
            // Re-build raw records: apply inverse to all current records
            updatedRawRecords = []
            for record in newRecords {
                let recordId: String?
                if let id = record[idField] as? String { recordId = id }
                else if let id = record[idField] as? Int { recordId = "\(id)" }
                else { recordId = nil }

                if usesCustomPushTransforms {
                    var recordForPush = record
                    if recordForPush["dataCollectionId"] == nil, let collectionContextId {
                        recordForPush["dataCollectionId"] = collectionContextId
                    }
                    updatedRawRecords.append(
                        TransformPipeline.apply(pushTransforms, to: [recordForPush]).first ?? recordForPush
                    )
                } else if shouldInverse, let rid = recordId, let rawRecord = rawLookup[rid] {
                    updatedRawRecords.append(InverseTransformPipeline.apply(inverseOps: inverseOps, editedRecord: record, rawRecord: rawRecord))
                } else if shouldInverse {
                    updatedRawRecords.append(InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record))
                } else {
                    updatedRawRecords.append(record)
                }
            }
            suppressPath(objectPath)
            try? ObjectFileManager.writeCollectionObjectFile(records: updatedRawRecords, to: objectURL)
        } else if deletedIds.count == diff.deleted.count || diff.deleted.isEmpty {
            updatedRawRecords = newRecords
        }

        if deletedIds.count == diff.deleted.count || diff.deleted.isEmpty {
            lastKnownRawRecords[cacheKey] = updatedRawRecords
        } else {
            lastKnownRawRecords[cacheKey] = oldRawRecords
        }

        return diff
    }

    // MARK: - Object File Push (Agent edits raw records)

    /// Handle an agent editing an object file — push raw records to API, regenerate user file.
    private func performObjectPush(serviceId: String, objectFilePath: String) async {
        guard let engine = adapterEngines[serviceId] else { return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let objectURL = serviceDir.appendingPathComponent(objectFilePath)

        do {
            // Find which resource this object file belongs to
            guard let (resource, userFilePath) = findResourceForObjectFile(objectFilePath, in: engine.config, serviceDir: serviceDir) else {
                await ActivityLogger.shared.warn(.sync, "No resource found for object file: \(objectFilePath)")
                return
            }

            // Skip read-only resources
            if resource.fileMapping.effectivePushMode == .readOnly { return }

            let idField = resource.fileMapping.idField ?? "id"

            if resource.fileMapping.strategy == .onePerRecord {
                // One-per-record: read single record, push it
                let record = try ObjectFileManager.readRecordObjectFile(from: objectURL)
                let recordId: String?
                if let id = record[idField] as? String { recordId = id }
                else if let id = record[idField] as? Int { recordId = "\(id)" }
                else { recordId = nil }

                if let id = recordId {
                    do {
                        try await engine.pushRecord(record, resource: resource, action: .update(id: id))
                    } catch {
                        guard isOptimisticConcurrencyError(error),
                              let latest = try await fetchLatestRawRecordForOnePerRecordObjectPush(
                                  resource: resource,
                                  userFilePath: userFilePath,
                                  recordId: id,
                                  engine: engine
                              ) else {
                            throw error
                        }

                        var retryRecord = record
                        if let revision = latest["revision"] {
                            retryRecord["revision"] = revision
                        }
                        if let revision = latest["_revision"] {
                            retryRecord["_revision"] = revision
                        }
                        try await engine.pushRecord(retryRecord, resource: resource, action: .update(id: id))
                    }
                } else {
                    try await engine.pushRecord(record, resource: resource, action: .create)
                }

                try await refreshOnePerRecordFilesAfterPush(
                    serviceId: serviceId,
                    resource: resource,
                    userFilePath: userFilePath,
                    recordId: recordId,
                    engine: engine
                )
            } else {
                // Collection: read all records, diff and push
                let rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
                let cacheKey = "\(serviceId):\(userFilePath)"
                let oldRaw = lastKnownRawRecords[cacheKey] ?? []
                let createdRecords: [[String: Any]]
                let updatedRecords: [(String, [String: Any])]
                let deletedIds: [String]
                if oldRaw.isEmpty {
                    createdRecords = rawRecords.filter { record in
                        if let id = record[idField] as? String { return id.isEmpty }
                        return record[idField] == nil
                    }
                    updatedRecords = rawRecords.compactMap { record in
                        if let id = record[idField] as? String, !id.isEmpty { return (id, record) }
                        if let id = record[idField] as? Int { return ("\(id)", record) }
                        return nil
                    }
                    deletedIds = []
                } else {
                    let diff = CollectionDiffer.diff(
                        old: oldRaw,
                        new: rawRecords,
                        idField: idField,
                        ignoreFields: ["revision", "_revision", "updatedDate", "_updatedDate"]
                    )
                    createdRecords = diff.created
                    updatedRecords = diff.updated.map { ($0.id, $0.record) }
                    deletedIds = diff.deleted
                }

                let applyChangeSet: ([[String: Any]]) async throws -> Void = { baseRaw in
                    var rawLookup: [String: [String: Any]] = [:]
                    for raw in baseRaw {
                        if let id = raw[idField] as? String, !id.isEmpty {
                            rawLookup[id] = raw
                        } else if let id = raw[idField] as? Int {
                            rawLookup["\(id)"] = raw
                        }
                    }

                    if !createdRecords.isEmpty || !updatedRecords.isEmpty || !deletedIds.isEmpty {
                        for record in createdRecords {
                            try await engine.pushRecord(record, resource: resource, action: .create)
                        }
                        for (id, record) in updatedRecords {
                            var pushRecord = record
                            if let previous = rawLookup[id] {
                                if let revision = previous["revision"] {
                                    pushRecord["revision"] = revision
                                }
                                if let revision = previous["_revision"] {
                                    pushRecord["_revision"] = revision
                                }
                            }
                            try await engine.pushRecord(pushRecord, resource: resource, action: .update(id: id))
                        }
                        for id in deletedIds {
                            try await engine.delete(remoteId: id, resource: resource)
                        }
                    }
                }

                do {
                    try await applyChangeSet(oldRaw)
                } catch {
                    guard isOptimisticConcurrencyError(error) else { throw error }
                    let freshRaw = try await fetchLatestRawRecordsForObjectPush(
                        resource: resource,
                        userFilePath: userFilePath,
                        engine: engine
                    )
                    lastKnownRawRecords[cacheKey] = freshRaw
                    try await applyChangeSet(freshRaw)
                }
            }

            // Regenerate user file from raw records by applying pull transforms
            let pullTransforms = resource.fileMapping.transforms?.pull ?? []
            let rawRecords: [[String: Any]]
            if resource.fileMapping.strategy == .onePerRecord {
                rawRecords = [try ObjectFileManager.readRecordObjectFile(from: objectURL)]
            } else {
                rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
            }
            let transformed = pullTransforms.isEmpty ? rawRecords : TransformPipeline.apply(pullTransforms, to: rawRecords)

            // Encode and write the user file
            let format = resource.fileMapping.format
            let encoded = try FormatConverterFactory.encode(records: transformed, format: format, options: resource.fileMapping.effectiveFormatOptions)
            let userFileURL = serviceDir.appendingPathComponent(userFilePath)
            suppressPath(userFilePath)
            try encoded.write(to: userFileURL, options: .atomic)

            // Update lastKnownRecords cache
            let cacheKey = "\(serviceId):\(userFilePath)"
            lastKnownRecords[cacheKey] = transformed
            lastKnownRawRecords[cacheKey] = rawRecords
            let existingRemoteId = syncStates[serviceId]?.files[userFilePath]?.remoteId ?? ""
            syncStates[serviceId]?.files[userFilePath] = FileSyncState(
                remoteId: existingRemoteId,
                lastSyncedHash: encoded.sha256Hex,
                lastSyncTime: Date(),
                status: .synced
            )
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try? syncStates[serviceId]?.save(to: stateURL)
            upsertFileLink(
                serviceDir: serviceDir,
                resource: resource,
                userPath: userFilePath,
                remoteId: existingRemoteId
            )
            synchronizeFileLinks(
                serviceDir: serviceDir,
                config: engine.config,
                state: syncStates[serviceId] ?? SyncState()
            )
            refreshSQLiteMirrorIfPossible(
                serviceId: serviceId,
                serviceDir: serviceDir,
                config: engine.config,
                state: syncStates[serviceId] ?? SyncState()
            )

            await ActivityLogger.shared.debug(.sync, "Object file push: \(objectFilePath) → regenerated \(userFilePath)")

        } catch {
            await ActivityLogger.shared.error(.sync, "Object file push failed for \(objectFilePath) — \(error.localizedDescription)")
        }
    }

    /// Find the resource and user file path for a given object file path.
    private func findResourceForObjectFile(_ objectPath: String, in config: AdapterConfig, serviceDir: URL) -> (ResourceConfig, String)? {
        if let link = try? FileLinkManager.linkForCanonicalPath(objectPath, in: serviceDir),
           let resource = findResource(named: link.resourceName, in: config) {
            return (resource, link.userPath)
        }

        for resource in allResources(in: config) {
            let format = resource.fileMapping.format
            if let userPath = ObjectFileManager.userFilePath(forObjectFile: objectPath, strategy: resource.fileMapping.strategy, format: format) {
                // Verify this user path matches the resource
                if let matchedResource = findResource(for: userPath, in: config),
                   matchedResource.name == resource.name {
                    return (resource, userPath)
                }
            }
        }
        return nil
    }

    // MARK: - Incremental Sync Helpers

    /// Determine if this resource needs a full sync or can do incremental.
    /// Full sync if: never synced before, or enough intervals have passed since last full sync.
    private func shouldDoFullSync(serviceId: String, resource: ResourceConfig) -> Bool {
        let fullSyncEvery = resource.sync?.fullSyncEvery ?? 10
        let count = syncStates[serviceId]?.syncCounts[resource.name] ?? 0
        let hasLastSync = syncStates[serviceId]?.resourceSyncTimes[resource.name] != nil

        // Full sync if: never synced, or it's time for periodic full re-sync
        return !hasLastSync || count >= fullSyncEvery
    }

    // MARK: - Sync Optimizations

    /// Resources to skip this cycle based on empty-pull backoff.
    /// After 3 consecutive empty pulls, skip every other cycle.
    /// After 6, skip 3 out of 4. After 10+, skip 9 out of 10.
    private func resourcesSkippedByBackoff(state: SyncState, config: AdapterConfig) -> Set<String> {
        var skip = Set<String>()
        let currentCycle = state.syncCounts.values.max() ?? 0
        for resource in config.resources {
            let emptyCount = state.emptyPullCounts[resource.name] ?? 0
            guard emptyCount >= 3 else { continue }
            let skipInterval: Int
            if emptyCount >= 10 { skipInterval = 10 }
            else if emptyCount >= 6 { skipInterval = 4 }
            else { skipInterval = 2 }
            if currentCycle % skipInterval != 0 {
                skip.insert(resource.name)
            }
        }
        return skip
    }

    /// Sort resources: recently changed first, never-changed/empty last.
    private func prioritizeResources(_ resources: [ResourceConfig], state: SyncState, skip: Set<String>) -> [ResourceConfig] {
        resources
            .filter { !skip.contains($0.name) }
            .sorted { a, b in
                let aTime = state.lastChangeTime[a.name] ?? .distantPast
                let bTime = state.lastChangeTime[b.name] ?? .distantPast
                return aTime > bTime
            }
    }

    /// Adaptive interval: if no resource has changed in >1h, slow down to 2x interval.
    /// If no change in >24h, slow down to 5x. Recent changes keep the base interval.
    private func adaptiveInterval(baseInterval: TimeInterval, state: SyncState) -> TimeInterval {
        guard !state.lastChangeTime.isEmpty else {
            return baseInterval
        }

        let now = Date()
        let mostRecentChange = state.lastChangeTime.values.max() ?? .distantPast
        guard mostRecentChange != .distantPast else {
            return baseInterval
        }
        let timeSinceChange = now.timeIntervalSince(mostRecentChange)

        if timeSinceChange > 86400 { // >24 hours
            return min(baseInterval * 5, 600) // cap at 10 minutes
        } else if timeSinceChange > 3600 { // >1 hour
            return min(baseInterval * 2, 300) // cap at 5 minutes
        }
        return baseInterval
    }

    private func loadExistingRawRecords(
        serviceDir: URL,
        filePath: String,
        resource: ResourceConfig
    ) -> [[String: Any]] {
        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: filePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        if let records = try? ObjectFileManager.readCollectionObjectFile(from: objectURL) {
            return records
        }

        // Without an object file, only untransformed files can safely double as raw state.
        let pullTransforms = resource.fileMapping.transforms?.pull ?? []
        guard pullTransforms.isEmpty else { return [] }

        let fileURL = serviceDir.appendingPathComponent(filePath)
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? FormatConverterFactory.decode(
                data: data,
                format: resource.fileMapping.format,
                options: resource.fileMapping.effectiveFormatOptions
              ) else {
            return []
        }
        return records
    }

    private func currentObjectFileRawRecords(
        serviceDir: URL,
        filePath: String,
        resource: ResourceConfig
    ) -> [[String: Any]] {
        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: filePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)

        switch resource.fileMapping.strategy {
        case .onePerRecord:
            if let record = try? ObjectFileManager.readRecordObjectFile(from: objectURL) {
                return [record]
            }
            return []
        case .collection:
            return (try? ObjectFileManager.readCollectionObjectFile(from: objectURL)) ?? []
        case .mirror:
            return []
        }
    }

    private func refreshObjectFileIfNeeded(
        file: SyncableFile,
        rawRecords: [[String: Any]],
        serviceDir: URL,
        engine: AdapterEngine
    ) {
        guard let resource = findResource(for: file.relativePath, in: engine.config) else { return }
        let existingRaw = currentObjectFileRawRecords(
            serviceDir: serviceDir,
            filePath: file.relativePath,
            resource: resource
        )
        guard !rawRecordSetsEqual(existingRaw, rawRecords) else { return }

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: file.relativePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        suppressPath(objectPath)

        do {
            if resource.fileMapping.strategy == .onePerRecord {
                if let record = rawRecords.first {
                    try ObjectFileManager.writeRecordObjectFile(record: record, to: objectURL)
                }
            } else if resource.fileMapping.strategy == .collection {
                try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            }
        } catch {
            Task {
                await ActivityLogger.shared.warn(
                    .sync,
                    "Failed to refresh object file \(objectPath) — \(error.localizedDescription)"
                )
            }
        }
    }

    private func rawRecordSetsEqual(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        guard let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return lhsData == rhsData
    }

    private func loadExistingTransformedRecords(
        serviceDir: URL,
        filePath: String,
        resource: ResourceConfig,
        cacheKey: String
    ) -> [[String: Any]] {
        if let cached = lastKnownRecords[cacheKey] {
            return cached
        }

        let fileURL = serviceDir.appendingPathComponent(filePath)
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? FormatConverterFactory.decode(
                data: data,
                format: resource.fileMapping.format,
                options: resource.fileMapping.effectiveFormatOptions
              ) else {
            return []
        }
        return records
    }

    /// Write object file with raw API records for a pulled file.
    private func writeObjectFile(file: SyncableFile, pullResult: PullResult, serviceId: String, serviceDir: URL, engine: AdapterEngine) {
        // Companion files have no object files — they are generated from templates
        guard !file.isCompanion else { return }
        guard let rawRecords = pullResult.rawRecordsByFile[file.relativePath],
              let resource = findResource(for: file.relativePath, in: engine.config) else { return }

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: file.relativePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        suppressPath(objectPath)

        do {
            if resource.fileMapping.strategy == .onePerRecord {
                if let record = rawRecords.first {
                    try ObjectFileManager.writeRecordObjectFile(record: record, to: objectURL)
                }
            } else {
                try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
            }
        } catch {
            Task { await ActivityLogger.shared.warn(.sync, "Failed to write object file \(objectPath) — \(error.localizedDescription)") }
        }
    }

    private func upsertFileLink(
        serviceDir: URL,
        resource: ResourceConfig,
        userPath: String,
        remoteId: String?,
        derivedPaths: [String] = []
    ) {
        let canonicalPath = ObjectFileManager.objectFilePath(
            forUserFile: userPath,
            strategy: resource.fileMapping.strategy
        )
        let entry = FileLinkEntry(
            resourceName: resource.name,
            mappingStrategy: resource.fileMapping.strategy,
            remoteId: remoteId,
            userPath: userPath,
            canonicalPath: canonicalPath,
            derivedPaths: derivedPaths
        )
        try? FileLinkManager.replace(entry, in: serviceDir)
    }

    private func refreshWixSiteArtifacts(
        serviceId: String,
        serviceDir: URL,
        engine: AdapterEngine,
        state: inout SyncState
    ) async {
        guard engine.config.service == "wix",
              let resource = findResource(named: WixSiteSnapshotSupport.catalogResourceName, in: engine.config) else {
            return
        }

        var catalogRecord = loadExistingWixSiteCatalog(serviceDir: serviceDir)

        if let refreshedRecord = try? await fetchWixSiteURLCatalogRecord(engine: engine) {
            catalogRecord = refreshedRecord
        } else {
            await ActivityLogger.shared.warn(
                .sync,
                "Wix site URL catalog refresh failed for \(serviceId); using the most recent local catalog for snapshots if available"
            )
        }

        guard let catalogRecord else { return }

        do {
            state = try await writeWixSiteCatalogAndSnapshots(
                serviceDir: serviceDir,
                config: engine.config,
                resource: resource,
                state: state,
                catalogRecord: catalogRecord
            )
        } catch {
            await ActivityLogger.shared.warn(
                .sync,
                "Wix site artifacts refresh failed for \(serviceId) — \(error.localizedDescription)"
            )
        }
    }

    internal func writeWixSiteCatalogAndSnapshots(
        serviceDir: URL,
        config: AdapterConfig,
        resource: ResourceConfig,
        state: SyncState,
        catalogRecord: [String: Any]
    ) async throws -> SyncState {
        var nextState = state
        let userPath = FileMapper.filePath(for: catalogRecord, config: resource.fileMapping)
        let userURL = serviceDir.appendingPathComponent(userPath)
        try FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let data = try JSONFormat.encode(records: [catalogRecord], options: resource.fileMapping.effectiveFormatOptions)
        suppressPath(userPath)
        try data.write(to: userURL, options: .atomic)

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: userPath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        suppressPath(objectPath)
        try ObjectFileManager.writeCollectionObjectFile(records: [catalogRecord], to: objectURL)

        let derivedPaths = try await writeRenderedWixSiteSnapshotsIfAvailable(
            serviceDir: serviceDir,
            config: config,
            catalogRecord: catalogRecord
        )

        nextState.files[userPath] = FileSyncState(
            remoteId: "",
            lastSyncedHash: data.sha256Hex,
            lastSyncTime: Date(),
            status: .synced
        )

        upsertFileLink(
            serviceDir: serviceDir,
            resource: resource,
            userPath: userPath,
            remoteId: nextState.files[userPath]?.remoteId,
            derivedPaths: derivedPaths
        )

        return nextState
    }

    private func fetchWixSiteURLCatalogRecord(engine: AdapterEngine) async throws -> [String: Any] {
        let publishedResponse = try await requestJSON(
            url: "https://www.wixapis.com/urls-server/v2/published-site-urls",
            engine: engine
        )
        let editorResponse = try await requestJSON(
            url: "https://www.wixapis.com/editor-urls",
            engine: engine
        )
        return WixSiteSnapshotSupport.buildSiteURLCatalog(
            publishedResponse: publishedResponse,
            editorResponse: editorResponse
        )
    }

    private func requestJSON(url: String, engine: AdapterEngine) async throws -> [String: Any] {
        let request = APIRequest(
            method: .GET,
            url: url,
            headers: engine.config.globals?.headers ?? [:],
            body: nil
        )
        let response = try await engine.httpClient.request(request)
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw AdapterError.invalidResponseData
        }
        return json
    }

    private func loadExistingWixSiteCatalog(serviceDir: URL) -> [String: Any]? {
        let catalogURL = serviceDir.appendingPathComponent(WixSiteSnapshotSupport.catalogRelativePath)
        guard let data = try? Data(contentsOf: catalogURL) else { return nil }
        return try? JSONFormat.decode(data: data, options: nil).first
    }

    private func writeRenderedWixSiteSnapshotsIfAvailable(
        serviceDir: URL,
        config: AdapterConfig,
        catalogRecord: [String: Any]
    ) async throws -> [String] {
        let targets = WixSiteSnapshotSupport.snapshotTargets(config: config, catalogRecord: catalogRecord)
        let previousManifest = WixSiteSnapshotSupport.loadManifest(from: serviceDir)
        let now = Date()

        guard self.config.enableSnapshots else {
            return previousManifest.map {
                Array(
                    Set(
                        WixSiteSnapshotSupport.manifestFilePaths($0) +
                        WixSiteSnapshotSupport.exposedManifestFilePaths($0)
                    )
                ).sorted()
            } ?? []
        }

        guard let snapshotService = platformServices.renderedPageSnapshotService else {
            return previousManifest.map {
                Array(
                    Set(
                        WixSiteSnapshotSupport.manifestFilePaths($0) +
                        WixSiteSnapshotSupport.exposedManifestFilePaths($0)
                    )
                ).sorted()
            } ?? []
        }

        let fileManager = FileManager.default
        let derivedRootURL = serviceDir.appendingPathComponent(WixSiteSnapshotSupport.derivedDirectory)
        try fileManager.createDirectory(at: derivedRootURL, withIntermediateDirectories: true)

        let previousEntries = Dictionary(uniqueKeysWithValues: (previousManifest?.entries ?? []).map { ($0.id, $0) })
        var entries: [SiteSnapshotManifestEntry] = []

        for target in targets {
            let htmlPath = WixSiteSnapshotSupport.htmlPath(for: target.id)
            let screenshotPath = WixSiteSnapshotSupport.screenshotPath(for: target.id)
            let htmlURL = serviceDir.appendingPathComponent(htmlPath)
            let screenshotURL = serviceDir.appendingPathComponent(screenshotPath)

            do {
                let snapshot = try await snapshotService.capture(url: target.url)
                suppressPath(htmlPath)
                guard let htmlData = snapshot.html.data(using: .utf8) else {
                    throw AdapterError.invalidResponseData
                }
                try htmlData.write(to: htmlURL, options: .atomic)
                suppressPath(screenshotPath)
                try snapshot.screenshotData.write(to: screenshotURL, options: .atomic)

                entries.append(
                    SiteSnapshotManifestEntry(
                        id: target.id,
                        label: target.label,
                        sourceURL: snapshot.sourceURL,
                        finalURL: snapshot.finalURL,
                        title: snapshot.title,
                        capturedAt: WixSiteSnapshotSupport.iso8601String(snapshot.capturedAt),
                        status: "success",
                        htmlPath: htmlPath,
                        screenshotPath: screenshotPath
                    )
                )
            } catch {
                await ActivityLogger.shared.warn(
                    .sync,
                    "Rendered snapshot failed for \(target.url) — \(error.localizedDescription)"
                )

                let previous = previousEntries[target.id]
                entries.append(
                    SiteSnapshotManifestEntry(
                        id: target.id,
                        label: target.label,
                        sourceURL: target.url,
                        finalURL: previous?.finalURL ?? target.url,
                        title: previous?.title ?? "",
                        capturedAt: previous?.capturedAt ?? WixSiteSnapshotSupport.iso8601String(now),
                        status: "error",
                        htmlPath: previous?.htmlPath,
                        screenshotPath: previous?.screenshotPath,
                        error: error.localizedDescription
                    )
                )
            }
        }

        let manifest = SiteSnapshotManifest(
            generatedAt: WixSiteSnapshotSupport.iso8601String(now),
            entries: entries.sorted { $0.id < $1.id }
        )
        try cleanupHiddenWixSiteSnapshots(
            currentManifest: manifest,
            previousManifest: previousManifest,
            serviceDir: serviceDir
        )
        try WixSiteSnapshotSupport.saveManifest(manifest, to: serviceDir)
        let exposedPaths = try exposeWixSiteSnapshots(
            currentManifest: manifest,
            previousManifest: previousManifest,
            serviceDir: serviceDir
        )
        return Array(Set(WixSiteSnapshotSupport.manifestFilePaths(manifest) + exposedPaths)).sorted()
    }

    private func cleanupHiddenWixSiteSnapshots(
        currentManifest: SiteSnapshotManifest,
        previousManifest: SiteSnapshotManifest?,
        serviceDir: URL
    ) throws {
        let fileManager = FileManager.default
        let currentPaths = Set(WixSiteSnapshotSupport.manifestFilePaths(currentManifest))
        let previousPaths = Set(previousManifest.map(WixSiteSnapshotSupport.manifestFilePaths) ?? [])

        for path in previousPaths.subtracting(currentPaths).sorted(by: >) {
            let url = serviceDir.appendingPathComponent(path)
            suppressPath(path)
            try? fileManager.removeItem(at: url)
        }
    }

    private func exposeWixSiteSnapshots(
        currentManifest: SiteSnapshotManifest,
        previousManifest: SiteSnapshotManifest?,
        serviceDir: URL
    ) throws -> [String] {
        let fileManager = FileManager.default
        let currentPaths = Set(WixSiteSnapshotSupport.exposedManifestFilePaths(currentManifest))
        let previousPaths = Set(previousManifest.map(WixSiteSnapshotSupport.exposedManifestFilePaths) ?? [])

        for path in previousPaths.subtracting(currentPaths).sorted(by: >) {
            let url = serviceDir.appendingPathComponent(path)
            suppressPath(path)
            try? fileManager.removeItem(at: url)
        }

        let exposedRootURL = serviceDir.appendingPathComponent(WixSiteSnapshotSupport.exposedDirectory)
        try fileManager.createDirectory(at: exposedRootURL, withIntermediateDirectories: true)

        let readmePath = WixSiteSnapshotSupport.exposedReadmeRelativePath
        let readmeURL = serviceDir.appendingPathComponent(readmePath)
        suppressPath(readmePath)
        try WixSiteSnapshotSupport.exposedReadme().write(to: readmeURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestURL = serviceDir.appendingPathComponent(WixSiteSnapshotSupport.exposedManifestRelativePath)
        suppressPath(WixSiteSnapshotSupport.exposedManifestRelativePath)
        try encoder.encode(WixSiteSnapshotSupport.exposedManifest(from: currentManifest)).write(
            to: manifestURL,
            options: .atomic
        )

        for entry in currentManifest.entries {
            if let hiddenHTMLPath = entry.htmlPath {
                try copyExposedSnapshotFile(
                    fromHiddenPath: hiddenHTMLPath,
                    toExposedPath: WixSiteSnapshotSupport.exposedPath(forDerivedPath: hiddenHTMLPath),
                    serviceDir: serviceDir
                )
            }
            if let hiddenScreenshotPath = entry.screenshotPath {
                try copyExposedSnapshotFile(
                    fromHiddenPath: hiddenScreenshotPath,
                    toExposedPath: WixSiteSnapshotSupport.exposedPath(forDerivedPath: hiddenScreenshotPath),
                    serviceDir: serviceDir
                )
            }
        }

        return currentPaths.sorted()
    }

    private func copyExposedSnapshotFile(
        fromHiddenPath hiddenPath: String,
        toExposedPath exposedPath: String,
        serviceDir: URL
    ) throws {
        let fileManager = FileManager.default
        let sourceURL = serviceDir.appendingPathComponent(hiddenPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }

        let destinationURL = serviceDir.appendingPathComponent(exposedPath)
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        suppressPath(exposedPath)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func synchronizeFileLinks(serviceDir: URL, config: AdapterConfig, state: SyncState) {
        let existingIndex = (try? FileLinkManager.load(from: serviceDir)) ?? FileLinkIndex()
        let existingPaths = discoverUserFilePaths(in: serviceDir)
        let candidatePaths = Set(state.files.keys).union(existingPaths)
        var entriesByUserPath: [String: FileLinkEntry] = [:]

        for userPath in candidatePaths.sorted() {
            guard !shouldIgnoreForFileLinks(userPath),
                  let resource = findResource(for: userPath, in: config) else { continue }

            let canonicalPath = ObjectFileManager.objectFilePath(
                forUserFile: userPath,
                strategy: resource.fileMapping.strategy
            )
            let remoteId = normalizedRemoteId(state.files[userPath]?.remoteId)
            let preserved = existingIndex.links.first { existing in
                if let remoteId,
                   let existingRemoteId = normalizedRemoteId(existing.remoteId),
                   existing.resourceName == resource.name,
                   existingRemoteId == remoteId {
                    return true
                }
                return existing.userPath == userPath || existing.canonicalPath == canonicalPath
            }

            entriesByUserPath[userPath] = FileLinkEntry(
                resourceName: resource.name,
                mappingStrategy: resource.fileMapping.strategy,
                remoteId: remoteId,
                userPath: userPath,
                canonicalPath: canonicalPath,
                derivedPaths: preserved?.derivedPaths ?? [],
                updatedAt: preserved?.updatedAt ?? Date()
            )
        }

        let newIndex = FileLinkIndex(
            links: entriesByUserPath.values.sorted { lhs, rhs in
                if lhs.userPath == rhs.userPath {
                    return lhs.canonicalPath < rhs.canonicalPath
                }
                return lhs.userPath < rhs.userPath
            }
        )

        guard newIndex != existingIndex else { return }
        try? FileLinkManager.save(newIndex, to: serviceDir)
    }

    /// Cache decoded records for collection-strategy files (used for diffing on push).
    private func cacheCollectionRecords(file: SyncableFile, serviceId: String, engine: AdapterEngine) {
        guard let resource = findResource(for: file.relativePath, in: engine.config),
              resource.fileMapping.strategy == .collection else { return }

        let cacheKey = "\(serviceId):\(file.relativePath)"
        if let records = try? FormatConverterFactory.decode(data: file.content, format: file.format, options: resource.fileMapping.effectiveFormatOptions) {
            lastKnownRecords[cacheKey] = records
        }
    }

    /// Cache raw API records for collection-strategy files (used for object-file diffing).
    private func cacheRawCollectionRecords(
        file: SyncableFile,
        pullResult: PullResult,
        serviceId: String,
        engine: AdapterEngine
    ) {
        guard let resource = findResource(for: file.relativePath, in: engine.config),
              resource.fileMapping.strategy == .collection,
              let rawRecords = pullResult.rawRecordsByFile[file.relativePath] else { return }

        let cacheKey = "\(serviceId):\(file.relativePath)"
        lastKnownRawRecords[cacheKey] = rawRecords
    }

    private func isOptimisticConcurrencyError(_ error: Error) -> Bool {
        if case APIError.serverError(let statusCode) = error, statusCode == 409 {
            return true
        }

        let message = String(describing: error).uppercased()
        return message.contains("INVALID_REVISION")
            || message.contains("CONTACT_ALREADY_CHANGED")
            || message.contains("OUTDATED REVISION")
    }

    private func fetchLatestRawRecordsForObjectPush(
        resource: ResourceConfig,
        userFilePath: String,
        engine: AdapterEngine
    ) async throws -> [[String: Any]] {
        let pullResult = try await engine.pull(resource: resource)
        return pullResult.rawRecordsByFile[userFilePath] ?? []
    }

    private func fetchLatestRawRecordForOnePerRecordObjectPush(
        resource: ResourceConfig,
        userFilePath: String,
        recordId: String,
        engine: AdapterEngine
    ) async throws -> [String: Any]? {
        let pullResult = try await engine.pull(resource: resource)

        if let direct = pullResult.rawRecordsByFile[userFilePath]?.first {
            let directId = (direct["id"] as? String) ?? (direct["_id"] as? String)
            if directId == recordId {
                return direct
            }
        }

        for (_, records) in pullResult.rawRecordsByFile {
            guard let record = records.first else { continue }
            let currentId = (record["id"] as? String) ?? (record["_id"] as? String)
            if currentId == recordId {
                return record
            }
        }
        return nil
    }

    private func refreshOnePerRecordFilesAfterPush(
        serviceId: String,
        resource: ResourceConfig,
        userFilePath: String,
        recordId: String?,
        engine: AdapterEngine
    ) async throws {
        let pullResult = try await engine.pull(resource: resource)
        let serviceDir = syncFolder.appendingPathComponent(serviceId)

        let matchedFileAndRaw: (SyncableFile, [String: Any])? = {
            if let recordId {
                for file in pullResult.files {
                    if let raw = pullResult.rawRecordsByFile[file.relativePath]?.first {
                        let currentId = (raw["id"] as? String) ?? (raw["_id"] as? String)
                        if currentId == recordId {
                            return (file, raw)
                        }
                    }
                }
            }

            if let file = pullResult.files.first(where: { $0.relativePath == userFilePath }),
               let raw = pullResult.rawRecordsByFile[userFilePath]?.first {
                return (file, raw)
            }

            guard let firstFile = pullResult.files.first,
                  let raw = pullResult.rawRecordsByFile[firstFile.relativePath]?.first else {
                return nil
            }
            return (firstFile, raw)
        }()

        guard let (freshFile, freshRaw) = matchedFileAndRaw else { return }

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: userFilePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        suppressPath(objectPath)
        try ObjectFileManager.writeRecordObjectFile(record: freshRaw, to: objectURL)

        let userFileURL = serviceDir.appendingPathComponent(userFilePath)
        suppressPath(userFilePath)
        try FileManager.default.createDirectory(
            at: userFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try freshFile.content.write(to: userFileURL, options: .atomic)

        let cacheKey = "\(serviceId):\(userFilePath)"
        if let records = try? FormatConverterFactory.decode(
            data: freshFile.content,
            format: resource.fileMapping.format,
            options: resource.fileMapping.effectiveFormatOptions
        ) {
            lastKnownRecords[cacheKey] = records
        }
        lastKnownRawRecords[cacheKey] = [freshRaw]

        let remoteId = recordId
            ?? syncStates[serviceId]?.files[userFilePath]?.remoteId
            ?? (freshRaw["id"] as? String)
            ?? (freshRaw["_id"] as? String)
            ?? ""
        syncStates[serviceId]?.files[userFilePath] = FileSyncState(
            remoteId: remoteId,
            lastSyncedHash: freshFile.content.sha256Hex,
            lastSyncTime: Date(),
            status: .synced
        )

        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        try? syncStates[serviceId]?.save(to: stateURL)
        upsertFileLink(
            serviceDir: serviceDir,
            resource: resource,
            userPath: userFilePath,
            remoteId: remoteId
        )
        synchronizeFileLinks(
            serviceDir: serviceDir,
            config: engine.config,
            state: syncStates[serviceId] ?? SyncState()
        )
        refreshSQLiteMirrorIfPossible(
            serviceId: serviceId,
            serviceDir: serviceDir,
            config: engine.config,
            state: syncStates[serviceId] ?? SyncState()
        )
    }

    // MARK: - Helpers

    private func findResource(for filePath: String, in config: AdapterConfig) -> ResourceConfig? {
        for resource in config.resources {
            // Check child resources first — they have more specific paths
            if let children = resource.children {
                for child in children {
                    if let matched = matchResource(child, to: filePath) { return matched }
                }
            }
            if let matched = matchResource(resource, to: filePath) { return matched }
        }
        return nil
    }

    private func findResource(named resourceName: String, in config: AdapterConfig) -> ResourceConfig? {
        allResources(in: config).first(where: { $0.name == resourceName })
    }

    private func allResources(in config: AdapterConfig) -> [ResourceConfig] {
        config.resources.flatMap { resource in
            [resource] + (resource.children ?? [])
        }
    }

    private func matchResource(_ resource: ResourceConfig, to filePath: String) -> ResourceConfig? {
        let dir = resource.fileMapping.directory
        // For collection strategy, match by exact dir+filename path
        if resource.fileMapping.strategy == .collection, let filename = resource.fileMapping.filename {
            if dir.contains("{") || filename.contains("{") {
                // Template directory (e.g. "boards/{name|slugify}"): match by filename suffix
                if let expectedExtension = expectedPathExtension(for: filename) {
                    let actualExtension = URL(fileURLWithPath: filePath).pathExtension.lowercased()
                    guard actualExtension == expectedExtension else { return nil }
                }
                if dir == "." || dir.isEmpty {
                    return filePath.hasSuffix("/" + URL(fileURLWithPath: filename).lastPathComponent) ? resource : nil
                }
                if filePath.hasPrefix(dir + "/") {
                    return resource
                }
            } else {
                // Concrete directory: require exact path match to avoid collisions
                // (e.g. "events.csv" must not match cms-events with dir="cms")
                let expectedPath = dir == "." ? filename : "\(dir)/\(filename)"
                if filePath == expectedPath {
                    return resource
                }
            }
            return nil
        }
        // For one-per-record: match directory prefix
        if dir == "." || filePath.hasPrefix(dir + "/") || filePath == dir {
            if resource.fileMapping.strategy == .onePerRecord,
               let filenameTemplate = resource.fileMapping.filename,
               let expectedExtension = expectedPathExtension(for: filenameTemplate) {
                let actualExtension = URL(fileURLWithPath: filePath).pathExtension.lowercased()
                guard actualExtension == expectedExtension else { return nil }
            }
            return resource
        }
        return nil
    }

    private func expectedPathExtension(for filenameTemplate: String) -> String? {
        let filename = URL(fileURLWithPath: filenameTemplate).lastPathComponent
        guard let dot = filename.lastIndex(of: ".") else { return nil }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return ext.isEmpty ? nil : ext
    }

    private func discoverUserFilePaths(in serviceDir: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: serviceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var paths: Set<String> = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(
                of: serviceDir.path + "/",
                with: ""
            )
            guard !shouldIgnoreForFileLinks(relativePath) else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                paths.insert(relativePath)
            }
        }
        return paths
    }

    private func shouldIgnoreForFileLinks(_ filePath: String) -> Bool {
        if filePath.isEmpty { return true }
        if filePath == "CLAUDE.md" { return true }
        if filePath.hasPrefix(".api2file/") || filePath.hasPrefix(".git/") { return true }
        if filePath.contains("~$") || filePath.contains(".dat.nosync") || filePath.contains(".tmp.") {
            return true
        }
        if ObjectFileManager.isObjectFile(filePath) { return true }
        return filePath.hasPrefix(".") || filePath.contains("/.")
    }

    private func normalizedRemoteId(_ remoteId: String?) -> String? {
        guard let remoteId else { return nil }
        let trimmed = remoteId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func updateServiceStatus(_ serviceId: String, status: ServiceStatus, error: String? = nil) {
        serviceInfos[serviceId]?.status = status
        serviceInfos[serviceId]?.errorMessage = error
    }

    private func refreshSQLiteMirrorIfPossible(
        serviceId: String,
        serviceDir: URL,
        config: AdapterConfig,
        state: SyncState
    ) {
        do {
            try SQLiteMirror.refresh(serviceDir: serviceDir, config: config, state: state)
        } catch {
            Task {
                await ActivityLogger.shared.warn(
                    .sync,
                    "Failed to refresh SQLite mirror for \(serviceId) — \(error.localizedDescription)"
                )
            }
        }
    }

    private func ensureSQLiteMirror(serviceId: String) throws -> URL {
        guard let info = serviceInfos[serviceId] else {
            throw SQLiteMirror.MirrorError.invalidQuery("Unknown service '\(serviceId)'")
        }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let databaseURL = SQLiteMirror.databaseURL(in: serviceDir)
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            refreshSQLiteMirrorIfPossible(
                serviceId: serviceId,
                serviceDir: serviceDir,
                config: info.config,
                state: syncStates[serviceId] ?? SyncState()
            )
        }
        return serviceDir
    }

    /// Called when a push has been abandoned after max retries.
    /// Resets the file's synced hash to current content so it stops retrying.
    private func handlePushAbandoned(serviceId: String, filePath: String, error: Error) async {
        await ActivityLogger.shared.warn(.sync, "↑ Push abandoned for \(serviceId)/\(filePath) after max retries — \(error.localizedDescription)")

        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let fileURL = serviceDir.appendingPathComponent(filePath)
        if let data = try? Data(contentsOf: fileURL) {
            syncStates[serviceId]?.files[filePath]?.lastSyncedHash = data.sha256Hex
            syncStates[serviceId]?.files[filePath]?.status = .synced
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try? syncStates[serviceId]?.save(to: stateURL)
        }
    }

    /// Append a history entry and save to disk
    private func logHistory(_ entry: SyncHistoryEntry, serviceId: String, serviceDir: URL) {
        historyLogs[serviceId]?.append(entry)
        let historyURL = serviceDir.appendingPathComponent(".api2file/sync-history.json")
        try? historyLogs[serviceId]?.save(to: historyURL)
    }

    private func generateGuides() throws {
        let services = serviceInfos.map { (serviceId: $0.key, config: $0.value.config) }
        try AgentGuideGenerator.writeGuides(
            rootDir: syncFolder,
            services: services,
            serverPort: config.serverPort
        )
    }

    // MARK: - Public Accessors

    public func getServices() -> [ServiceInfo] {
        Array(serviceInfos.values)
    }

    public func getServiceStatus(_ serviceId: String) -> ServiceInfo? {
        serviceInfos[serviceId]
    }

    public func getSyncRootURL() -> URL {
        syncFolder
    }

    public func triggerSync(serviceId: String) async {
        await coordinator.syncNow(serviceId: serviceId)
    }

    public func listSQLTables(serviceId: String) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.listTablesJSON(in: serviceDir)
    }

    public func describeSQLTable(serviceId: String, table: String) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.describeTableJSON(table, in: serviceDir)
    }

    public func querySQL(serviceId: String, query: String) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.queryJSON(query, in: serviceDir)
    }

    public func searchSQL(serviceId: String, text: String, resources: [String]?) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.searchJSON(text: text, resources: resources, in: serviceDir)
    }

    public func getRecordByID(serviceId: String, resource: String, recordId: String) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.getRecordJSON(resource: resource, recordId: recordId, in: serviceDir)
    }

    func openRecordFile(
        serviceId: String,
        resource: String,
        recordId: String,
        surface: SQLiteMirror.FileSurface
    ) throws -> Data {
        let serviceDir = try ensureSQLiteMirror(serviceId: serviceId)
        return try SQLiteMirror.openRecordFileJSON(
            resource: resource,
            recordId: recordId,
            surface: surface,
            in: serviceDir
        )
    }

    public func setPaused(_ paused: Bool) async {
        await coordinator.setPaused(paused)
    }

    /// Remove a service — stops sync, cleans up .api2file dir, removes keychain credential
    /// Keeps the user's synced files intact.
    public func removeService(serviceId: String) async {
        // Stop sync for this service
        await coordinator.unregister(serviceId: serviceId)

        // Get config before removing (for keychain key)
        let keychainKey = serviceInfos[serviceId]?.config.auth.keychainKey

        // Remove from internal state
        adapterEngines.removeValue(forKey: serviceId)
        syncStates.removeValue(forKey: serviceId)
        serviceInfos.removeValue(forKey: serviceId)
        gitManagers.removeValue(forKey: serviceId)
        historyLogs.removeValue(forKey: serviceId)

        // Delete .api2file directory (adapter.json + state.json) but keep synced files
        let api2fileDir = syncFolder.appendingPathComponent(serviceId).appendingPathComponent(".api2file")
        try? FileManager.default.removeItem(at: api2fileDir)

        // Remove keychain credential
        if let key = keychainKey {
            let keychain = platformServices.keychainManager
            await keychain.delete(key: key)
        }

        // Regenerate CLAUDE.md guides
        try? generateGuides()
    }

    /// Enable or disable a service by updating its adapter.json and reloading
    public func setServiceEnabled(serviceId: String, enabled: Bool) async {
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let configURL = serviceDir.appendingPathComponent(".api2file/adapter.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        // Read raw JSON, flip the `enabled` field, write back
        do {
            let data = try Data(contentsOf: configURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            json["enabled"] = enabled
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: configURL, options: .atomic)
        } catch {
            await ActivityLogger.shared.error(.system, "Failed to update enabled state for \(serviceId): \(error)")
            return
        }

        // Reload the service to pick up the change
        await reloadService(serviceId)
        await ActivityLogger.shared.info(.system, "\(serviceId) \(enabled ? "enabled" : "disabled")")
    }

    /// Enable or disable a specific resource within a service by updating its adapter.json and reloading
    public func setResourceEnabled(serviceId: String, resourceName: String, enabled: Bool) async {
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let configURL = serviceDir.appendingPathComponent(".api2file/adapter.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        do {
            let data = try Data(contentsOf: configURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard var resources = json["resources"] as? [[String: Any]] else { return }
            for i in resources.indices where (resources[i]["name"] as? String) == resourceName {
                resources[i]["enabled"] = enabled
            }
            json["resources"] = resources
            let updatedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: configURL, options: .atomic)
        } catch {
            await ActivityLogger.shared.error(.system, "Failed to update enabled state for resource \(resourceName) in \(serviceId): \(error)")
            return
        }

        await reloadService(serviceId)
        await ActivityLogger.shared.info(.system, "\(serviceId)/\(resourceName) \(enabled ? "enabled" : "disabled")")
    }

    /// Exclude or include a specific file from sync by updating its state.json
    public func setFileExcluded(serviceId: String, relativePath: String, excluded: Bool) async {
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")

        var state = syncStates[serviceId] ?? SyncState()
        if var fileState = state.files[relativePath] {
            fileState.excluded = excluded
            state.files[relativePath] = fileState
        } else {
            state.files[relativePath] = FileSyncState(
                remoteId: "",
                lastSyncedHash: "",
                lastSyncTime: Date(),
                status: .synced,
                excluded: excluded
            )
        }

        do {
            try state.save(to: stateURL)
            syncStates[serviceId] = state
        } catch {
            await ActivityLogger.shared.error(.system, "Failed to update excluded state for \(relativePath) in \(serviceId): \(error)")
            return
        }

        await ActivityLogger.shared.info(.system, "\(serviceId)/\(relativePath) \(excluded ? "excluded" : "included") from sync")
    }

    /// Register and start a new service (for use after AddServiceView creates the directory)
    public func registerNewService(_ serviceId: String) async throws {
        try await registerService(serviceId)
        await coordinator.startService(serviceId: serviceId)
        try? await performPull(serviceId: serviceId)
        try? generateGuides()
    }

    /// Explicitly notify the engine that a synced file changed.
    /// iOS/tests use this because the platform does not provide the same
    /// always-on file watching guarantees as macOS.
    public func fileDidChange(serviceId: String, filePath: String) async {
        // Absorb the duplicate watcher event that often follows an explicit
        // notification in tests or platforms with manual change reporting.
        suppressPath(filePath)
        if ObjectFileManager.isObjectFile(filePath) {
            await performObjectPush(serviceId: serviceId, objectFilePath: filePath)
            return
        }
        await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
    }

    // MARK: - History Accessors

    /// Get sync history for a specific service
    public func getHistory(serviceId: String, limit: Int = 50) -> [SyncHistoryEntry] {
        Array(historyLogs[serviceId]?.entries.prefix(limit) ?? [])
    }

    /// Get sync history across all services, sorted by timestamp (newest first)
    public func getAllHistory(limit: Int = 50) -> [SyncHistoryEntry] {
        let all = historyLogs.values.flatMap(\.entries)
        return Array(all.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }
}
