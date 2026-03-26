import Foundation

/// Top-level sync engine — ties together all components for the full sync lifecycle
public actor SyncEngine {
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
    private var suppressedPaths: Set<String> = []
    private var isPulling: [String: Bool] = [:]  // per-service pull lock
    /// Files recently pushed — pull should re-pull to get updated revision but not overwrite content.
    /// Key: "serviceId:filePath", Value: push completion time
    private var recentlyPushed: [String: Date] = [:]
    private var historyLogs: [String: SyncHistoryLog] = [:]
    private var _notificationManager: NotificationManager?
    private var notificationManager: NotificationManager {
        if _notificationManager == nil {
            _notificationManager = NotificationManager()
        }
        return _notificationManager!
    }

    /// Gates all remote deletions. If nil, deletions proceed immediately (existing behaviour).
    /// AppState sets this at startup to show a confirmation dialog.
    public var deletionConfirmationHandler: (@Sendable (DeletionInfo) async -> Bool)?

    public init(config: GlobalConfig) {
        self.config = config
        self.syncFolder = config.resolvedSyncFolder
        self.coordinator = SyncCoordinator()
        self.networkMonitor = NetworkMonitor()
        self.fileWatcher = FileWatcher()
        self.configWatcher = ConfigWatcher()
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
                // Skip read-only resources
                if let resource = findResource(for: filePath, in: engine.config),
                   resource.fileMapping.effectivePushMode == .readOnly { continue }
                let fileURL = serviceDir.appendingPathComponent(filePath)
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                if data.sha256Hex != lastHash {
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
        let config = try AdapterEngine.loadConfig(from: serviceDir)

        // Track disabled services in serviceInfos but don't start syncing
        if config.enabled == false {
            await ActivityLogger.shared.info(.system, "Skipping disabled service: \(serviceId)")
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
            serviceInfos[serviceId] = ServiceInfo(
                serviceId: serviceId,
                displayName: config.displayName,
                config: config,
                status: .paused,
                fileCount: state.files.count
            )
            return
        }

        let httpClient = HTTPClient()

        // Load auth token from Keychain in background — don't block startup.
        // securityd initialization on first access from a new process can take 30-150s on macOS.
        // Retry up to 10 times (5 minutes total) to handle slow first-access or user dialogs.
        let keychainKey = config.auth.keychainKey
        let authType = config.auth.type
        Task { [weak httpClient] in
            let keychain = KeychainManager()
            var token: String? = nil
            for attempt in 1...10 {
                token = await keychain.load(key: keychainKey)
                if token != nil { break }
                if attempt < 10 {
                    try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s between retries
                }
            }
            guard let token, let httpClient else { return }
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
            await ActivityLogger.shared.info(.system, "Auth loaded for \(serviceId)")
        }

        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        adapterEngines[serviceId] = engine

        // Load or create sync state
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
        syncStates[serviceId] = state

        // Pre-populate lastKnownRecords from files already on disk so that the
        // first push after startup doesn't treat all existing records as creates.
        for (filePath, _) in state.files {
            if let resource = findResource(for: filePath, in: config),
               resource.fileMapping.strategy == .collection {
                let fileURL = serviceDir.appendingPathComponent(filePath)
                if let data = try? Data(contentsOf: fileURL),
                   let records = try? FormatConverterFactory.decode(
                       data: data, format: resource.fileMapping.format,
                       options: resource.fileMapping.formatOptions) {
                    lastKnownRecords["\(serviceId):\(filePath)"] = records
                }
            }
        }

        // Load or create sync history
        let historyURL = serviceDir.appendingPathComponent(".api2file/sync-history.json")
        historyLogs[serviceId] = (try? SyncHistoryLog.load(from: historyURL)) ?? SyncHistoryLog()

        // Init git if configured
        if self.config.gitAutoCommit {
            let git = GitManager(repoPath: serviceDir)
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
            displayName: config.displayName,
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
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let startTime = Date()
        await ActivityLogger.shared.info(.sync, "↓ PULL START \(serviceId) [\(serviceName)]")

        // Work with a LOCAL copy of sync state to avoid exclusive access violations
        // across await points. Write back at the end.
        var localState = syncStates[serviceId] ?? SyncState()

        do {
            // --- Optimization: skip empty resources with backoff ---
            let resourcesToSkip = resourcesSkippedByBackoff(state: localState, config: engine.config)
            if !resourcesToSkip.isEmpty {
                await ActivityLogger.shared.debug(.sync, "↓ Skipping \(resourcesToSkip.count) empty resource(s) this cycle")
            }

            // --- Optimization: priority ordering — recently changed first ---
            let sortedResources = prioritizeResources(engine.config.resources, state: localState, skip: resourcesToSkip)

            // Always use per-resource parallel pull for all optimizations
            var allFiles: [SyncableFile] = []
            var allRawRecords: [String: [[String: Any]]] = [:]
            var isIncremental = false

            // Snapshot sync state before async loop
            let stateSnapshot = localState

            // --- Optimization: parallel pulls with TaskGroup ---
            struct ResourcePullResult: Sendable {
                let name: String
                let result: PullResult?
                let responseETag: String?
                let wasIncremental: Bool
                let wasEmpty: Bool
            }

            let pullResults = await withTaskGroup(of: ResourcePullResult.self, returning: [ResourcePullResult].self) { group in
                var active = 0
                var index = 0
                var collected: [ResourcePullResult] = []

                // Seed initial batch
                while active < Self.pullConcurrency && index < sortedResources.count {
                    let resource = sortedResources[index]
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
                            return ResourcePullResult(name: resource.name, result: nil, responseETag: nil, wasIncremental: false, wasEmpty: true)
                        }
                    }
                    active += 1
                    index += 1
                }

                for await pullResult in group {
                    collected.append(pullResult)
                    active -= 1
                    if index < sortedResources.count {
                        let resource = sortedResources[index]
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
                                return ResourcePullResult(name: resource.name, result: nil, responseETag: nil, wasIncremental: false, wasEmpty: true)
                            }
                        }
                        active += 1
                        index += 1
                    }
                }

                return collected
            }

            // Process results and update state
            for pr in pullResults {
                // --- Optimization: ETag storage ---
                if let newETag = pr.responseETag {
                    localState.resourceETags[pr.name] = newETag
                }

                // --- Optimization: skip-empty tracking ---
                if pr.wasEmpty {
                    localState.emptyPullCounts[pr.name] = (localState.emptyPullCounts[pr.name] ?? 0) + 1
                } else if let result = pr.result, !result.notModified {
                    localState.emptyPullCounts[pr.name] = 0
                    // --- Optimization: adaptive intervals — track last change ---
                    if !result.files.isEmpty {
                        localState.lastChangeTime[pr.name] = Date()
                    }
                }

                guard let result = pr.result, !result.notModified else {
                    if pr.result?.notModified == true {
                        await ActivityLogger.shared.debug(.sync, "↓ \(pr.name) — 304 not modified")
                    }
                    continue
                }

                allFiles.append(contentsOf: result.files)
                allRawRecords.merge(result.rawRecordsByFile) { _, new in new }

                if pr.wasIncremental { isIncremental = true }
            }

            let pullResult = PullResult(files: allFiles, rawRecordsByFile: allRawRecords)

            let files = pullResult.files

            var unchangedCount = 0

            if isIncremental {
                // MERGE: update existing records with incremental changes
                for file in files {
                    let filePath = serviceDir.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                    // Skip files with pending local changes so the queued push runs first
                    if let lastSyncedHash = localState.files[file.relativePath]?.lastSyncedHash,
                       let localData = try? Data(contentsOf: filePath),
                       localData.sha256Hex != lastSyncedHash {
                        await ActivityLogger.shared.info(.sync, "↓ Skipping \(file.relativePath) — local changes pending push")
                        continue
                    }

                    if let resource = findResource(for: file.relativePath, in: engine.config),
                       resource.fileMapping.strategy == .collection {
                        // Merge incremental records with cached records
                        let newRecords = pullResult.rawRecordsByFile[file.relativePath] ?? []
                        let mergedRaw = mergeIncrementalRecords(
                            serviceId: serviceId,
                            filePath: file.relativePath,
                            newRecords: newRecords,
                            resource: resource
                        )

                        // Apply transforms and re-encode merged records
                        let transforms = resource.fileMapping.transforms?.pull ?? []
                        let transformed = transforms.isEmpty ? mergedRaw : TransformPipeline.apply(transforms, to: mergedRaw)
                        let mergedContent = try FormatConverterFactory.encode(
                            records: transformed,
                            format: file.format,
                            options: resource.fileMapping.formatOptions
                        )

                        // Skip write if content unchanged
                        let mergedHash = mergedContent.sha256Hex
                        if mergedHash == localState.files[file.relativePath]?.lastSyncedHash {
                            unchangedCount += 1
                            // Still update cache with merged records
                            let cacheKey = "\(serviceId):\(file.relativePath)"
                            lastKnownRecords[cacheKey] = transformed
                        } else {
                            suppressedPaths.insert(file.relativePath)
                            try mergedContent.write(to: filePath, options: .atomic)

                            // Update object file with merged raw records
                            let objectPath = ObjectFileManager.objectFilePath(
                                forUserFile: file.relativePath,
                                strategy: resource.fileMapping.strategy
                            )
                            let objectURL = serviceDir.appendingPathComponent(objectPath)
                            suppressedPaths.insert(objectPath)
                            try ObjectFileManager.writeCollectionObjectFile(records: mergedRaw, to: objectURL)

                            // Update cache
                            let cacheKey = "\(serviceId):\(file.relativePath)"
                            lastKnownRecords[cacheKey] = transformed
                        }
                    } else {
                        // Non-collection or no resource match: write as full (same as non-incremental)
                        if file.contentHash == localState.files[file.relativePath]?.lastSyncedHash {
                            unchangedCount += 1
                        } else {
                            suppressedPaths.insert(file.relativePath)
                            try file.content.write(to: filePath, options: .atomic)
                            writeObjectFile(file: file, pullResult: pullResult, serviceId: serviceId, serviceDir: serviceDir, engine: engine)
                            cacheCollectionRecords(file: file, serviceId: serviceId, engine: engine)
                        }
                    }

                    // Update sync state — always record hash (even for collection files without remoteId)
                    // to prevent file-watcher from falsely pushing freshly-pulled files.
                    if let remoteId = file.remoteId {
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
                }
            } else {
                // FULL: write all files (existing behavior)
                for file in files {
                    let filePath = serviceDir.appendingPathComponent(file.relativePath)
                    try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                    // Skip files with pending local changes so the queued push runs first
                    if let lastSyncedHash = localState.files[file.relativePath]?.lastSyncedHash,
                       let localData = try? Data(contentsOf: filePath),
                       localData.sha256Hex != lastSyncedHash {
                        await ActivityLogger.shared.info(.sync, "↓ Skipping \(file.relativePath) — local changes pending push")
                        continue
                    }

                    // Skip files recently pushed — server may not have propagated yet
                    // Skip write if content unchanged
                    if file.contentHash == localState.files[file.relativePath]?.lastSyncedHash {
                        unchangedCount += 1
                    } else {
                        suppressedPaths.insert(file.relativePath)
                        try file.content.write(to: filePath, options: .atomic)
                        writeObjectFile(file: file, pullResult: pullResult, serviceId: serviceId, serviceDir: serviceDir, engine: engine)
                        cacheCollectionRecords(file: file, serviceId: serviceId, engine: engine)
                    }

                    // Update sync state — always record hash (even for collection files without remoteId)
                    // to prevent file-watcher from falsely pushing freshly-pulled files.
                    if let remoteId = file.remoteId {
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
                }
            }

            // Stale file cleanup — for full pulls, remove local files that are no longer in the API
            // (only applies to one-per-record resources where each API record = one local file)
            if !isIncremental {
                let newFilePaths = Set(files.map { $0.relativePath })
                var staleFilePaths: [String] = []
                for (filePath, _) in localState.files {
                    if !newFilePaths.contains(filePath),
                       let resource = findResource(for: filePath, in: engine.config),
                       resource.fileMapping.strategy == .onePerRecord {
                        staleFilePaths.append(filePath)
                    }
                }
                for filePath in staleFilePaths {
                    let fileURL = serviceDir.appendingPathComponent(filePath)
                    try? FileManager.default.removeItem(at: fileURL)
                    suppressedPaths.insert(filePath)
                    localState.files.removeValue(forKey: filePath)
                    await ActivityLogger.shared.info(.sync, "↓ Removed stale local file: \(filePath) (deleted from API)")
                }
            }

            // Update sync counters for incremental tracking
            for resource in engine.config.resources {
                let name = resource.name
                if shouldDoFullSync(serviceId: serviceId, resource: resource) {
                    localState.resourceSyncTimes[name] = Date()
                    localState.syncCounts[name] = 0
                } else {
                    localState.syncCounts[name] = (localState.syncCounts[name] ?? 0) + 1
                }
            }

            // Save state
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try localState.save(to: stateURL)
            syncStates[serviceId] = localState
            // Git commit
            if config.gitAutoCommit, let git = gitManagers[serviceId] {
                if try await git.hasChanges() {
                    let syncType = isIncremental ? "incremental pull" : "pull"
                    try await git.commitAll(message: "sync: \(syncType) \(serviceId) — updated \(files.count) files")
                }
            }

            // Update file count
            serviceInfos[serviceId]?.fileCount = localState.files.count ?? 0
            serviceInfos[serviceId]?.lastSyncTime = Date()

            // Log history entry
            let fileChanges = files.map {
                FileChange(path: $0.relativePath, action: .downloaded)
            }
            let syncType = isIncremental ? "incremental pull" : "pulled"
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            let unchangedSuffix = unchangedCount > 0 ? ", \(unchangedCount) unchanged" : ""
            await ActivityLogger.shared.info(.sync, "↓ PULL OK \(serviceId) — \(syncType) \(files.count) file(s)\(unchangedSuffix) (\(ms)ms)")
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .pull,
                status: .success,
                duration: Date().timeIntervalSince(startTime),
                files: fileChanges,
                summary: "\(syncType) \(files.count) files\(unchangedSuffix)"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
        } catch {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            await ActivityLogger.shared.error(.sync, "↓ PULL FAILED \(serviceId) — \(error.localizedDescription) (\(ms)ms)")
            // Log error entry
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

    private func performPush(serviceId: String, filePath: String) async throws {
        guard let engine = adapterEngines[serviceId] else { return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let fullPath = serviceDir.appendingPathComponent(filePath)
        let startTime = Date()
        await ActivityLogger.shared.info(.sync, "↑ PUSH START \(serviceId) — \(filePath)")

        // Find which resource this file belongs to
        guard let resource = findResource(for: filePath, in: engine.config) else { return }

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
                let file = SyncableFile(
                    relativePath: filePath,
                    format: resource.fileMapping.format,
                    content: content,
                    remoteId: syncStates[serviceId]?.files[filePath]?.remoteId
                )
                try await engine.push(file: file, resource: resource)
                fileChange = FileChange(path: filePath, action: .uploaded)
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
            if filePath == "CLAUDE.md" { continue }
            if filePath.contains("~$") { continue } // Office temp files
            if filePath.contains(".dat.nosync") { continue } // macOS temp files
            if filePath.contains(".tmp.") { continue } // atomic-write temp files (e.g. file.csv.tmp.PID.N)
            if filePath.contains(".objects/") || filePath.contains(".objects") { continue } // object files (not yet supported)
            if filePath.hasPrefix(".") || filePath.contains("/.") { continue } // hidden files

            // Skip suppressed paths (written by pull or regeneration — prevents loops)
            if suppressedPaths.remove(filePath) != nil { continue }

            Task {
                await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
                await coordinator.flushPendingPushes(serviceId: serviceId)
            }
        }
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
                let records = lastKnownRecords[cacheKey] ?? []
                let idField = resource.fileMapping.idField ?? "id"
                for record in records {
                    let recordId: String?
                    if let id = record[idField] as? String { recordId = id }
                    else if let id = record[idField] as? Int { recordId = "\(id)" }
                    else { recordId = nil }

                    if let id = recordId {
                        try await engine.delete(remoteId: id, resource: resource)
                        deletedCount += 1
                    }
                }
                lastKnownRecords.removeValue(forKey: cacheKey)
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
            suppressedPaths.insert(objectPath)
            try? FileManager.default.removeItem(at: objectURL)

            // Save state
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try syncStates[serviceId]?.save(to: stateURL)

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
                options: resource.fileMapping.formatOptions
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

        // Compute inverse transforms if needed
        let pullTransforms = resource.fileMapping.transforms?.pull ?? []
        let inverseOps = pullTransforms.isEmpty ? [] : InverseTransformPipeline.computeInverse(of: pullTransforms)
        let shouldInverse = resource.fileMapping.effectivePushMode == .autoReverse && !inverseOps.isEmpty

        // Build raw record lookup by ID for merging
        var rawLookup: [String: [String: Any]] = [:]
        if shouldInverse, let rawRecords {
            for raw in rawRecords {
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

            // For creates there is no cached raw record to merge with, so skip
            // mechanical inverse — it would relocate fields (e.g. boardId → board.boardId)
            // that the push mutation template still expects at their user-facing position.
            try await engine.pushRecord(enriched, resource: resource, action: .create)
        }

        // Push updates (with inverse transform merging)
        // GraphQL mutations use explicit {field} template substitution with user-facing names,
        // so inverse transforms (which relocate flat fields like boardId → board.boardId) must
        // be skipped — the mutation template would fail to find {boardId} at the top level.
        let isUpdateGraphQL = resource.push?.update?.type == .graphql
        for (id, record) in diff.updated {
            var pushRecord: [String: Any]
            if !isUpdateGraphQL && shouldInverse, let rawRecord = rawLookup[id] {
                pushRecord = InverseTransformPipeline.apply(inverseOps: inverseOps, editedRecord: record, rawRecord: rawRecord)
            } else if !isUpdateGraphQL && shouldInverse {
                pushRecord = InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record)
            } else {
                pushRecord = record
            }

            // Inject latest revision from raw API record for optimistic concurrency.
            // APIs like Wix silently reject updates with stale revision numbers.
            if let rawRecord = rawLookup[id] {
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
                    try await engine.delete(remoteId: id, resource: resource)
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
           let freshRecords = try? FormatConverterFactory.decode(data: freshData, format: resource.fileMapping.format, options: resource.fileMapping.formatOptions) {
            lastKnownRecords[cacheKey] = freshRecords
        } else if deletedIds.count == diff.deleted.count || diff.deleted.isEmpty {
            lastKnownRecords[cacheKey] = newRecords
        } else {
            lastKnownRecords[cacheKey] = oldRecords
        }

        // Update object file with current state
        if shouldInverse || rawRecords != nil {
            // Re-build raw records: apply inverse to all current records
            var updatedRawRecords: [[String: Any]] = []
            for record in newRecords {
                let recordId: String?
                if let id = record[idField] as? String { recordId = id }
                else if let id = record[idField] as? Int { recordId = "\(id)" }
                else { recordId = nil }

                if shouldInverse, let rid = recordId, let rawRecord = rawLookup[rid] {
                    updatedRawRecords.append(InverseTransformPipeline.apply(inverseOps: inverseOps, editedRecord: record, rawRecord: rawRecord))
                } else if shouldInverse {
                    updatedRawRecords.append(InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record))
                } else {
                    updatedRawRecords.append(record)
                }
            }
            suppressedPaths.insert(objectPath)
            try? ObjectFileManager.writeCollectionObjectFile(records: updatedRawRecords, to: objectURL)
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
            guard let (resource, userFilePath) = findResourceForObjectFile(objectFilePath, in: engine.config) else {
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
                    try await engine.pushRecord(record, resource: resource, action: .update(id: id))
                } else {
                    try await engine.pushRecord(record, resource: resource, action: .create)
                }
            } else {
                // Collection: read all records, diff and push
                let rawRecords = try ObjectFileManager.readCollectionObjectFile(from: objectURL)
                let cacheKey = "\(serviceId):\(userFilePath)"
                let oldRaw = lastKnownRecords[cacheKey] ?? []

                let diff = CollectionDiffer.diff(old: oldRaw, new: rawRecords, idField: idField)
                if !diff.isEmpty {
                    for record in diff.created {
                        try await engine.pushRecord(record, resource: resource, action: .create)
                    }
                    for (id, record) in diff.updated {
                        try await engine.pushRecord(record, resource: resource, action: .update(id: id))
                    }
                    for id in diff.deleted {
                        try await engine.delete(remoteId: id, resource: resource)
                    }
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
            let encoded = try FormatConverterFactory.encode(records: transformed, format: format, options: resource.fileMapping.formatOptions)
            let userFileURL = serviceDir.appendingPathComponent(userFilePath)
            suppressedPaths.insert(userFilePath)
            try encoded.write(to: userFileURL, options: .atomic)

            // Update lastKnownRecords cache
            lastKnownRecords["\(serviceId):\(userFilePath)"] = transformed

            await ActivityLogger.shared.debug(.sync, "Object file push: \(objectFilePath) → regenerated \(userFilePath)")

        } catch {
            await ActivityLogger.shared.error(.sync, "Object file push failed for \(objectFilePath) — \(error.localizedDescription)")
        }
    }

    /// Find the resource and user file path for a given object file path.
    private func findResourceForObjectFile(_ objectPath: String, in config: AdapterConfig) -> (ResourceConfig, String)? {
        for resource in config.resources {
            let format = resource.fileMapping.format
            if let userPath = ObjectFileManager.userFilePath(forObjectFile: objectPath, strategy: resource.fileMapping.strategy, format: format) {
                // Verify this user path matches the resource
                if findResource(for: userPath, in: config) != nil {
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
        let now = Date()
        let mostRecentChange = state.lastChangeTime.values.max() ?? .distantPast
        let timeSinceChange = now.timeIntervalSince(mostRecentChange)

        if timeSinceChange > 86400 { // >24 hours
            return min(baseInterval * 5, 600) // cap at 10 minutes
        } else if timeSinceChange > 3600 { // >1 hour
            return min(baseInterval * 2, 300) // cap at 5 minutes
        }
        return baseInterval
    }

    /// Merge incremental (partial) records into the existing cached records.
    /// Matches by idField — updates existing records and appends new ones.
    private func mergeIncrementalRecords(
        serviceId: String,
        filePath: String,
        newRecords: [[String: Any]],
        resource: ResourceConfig
    ) -> [[String: Any]] {
        let cacheKey = "\(serviceId):\(filePath)"
        let idField = resource.fileMapping.idField ?? "id"
        var existing = lastKnownRecords[cacheKey] ?? []

        for newRecord in newRecords {
            let newId = stringifyId(newRecord[idField])
            if let idx = existing.firstIndex(where: { stringifyId($0[idField]) == newId && newId != nil }) {
                existing[idx] = newRecord  // Update existing record
            } else {
                existing.append(newRecord)  // Append new record
            }
        }

        return existing
    }

    /// Stringify an ID value for comparison during merge.
    private func stringifyId(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case let s as String: return s
        case let n as Int: return "\(n)"
        case let n as Double:
            if n == n.rounded() && n < 1e15 { return "\(Int(n))" }
            return "\(n)"
        default: return "\(value)"
        }
    }

    /// Write object file with raw API records for a pulled file.
    private func writeObjectFile(file: SyncableFile, pullResult: PullResult, serviceId: String, serviceDir: URL, engine: AdapterEngine) {
        guard let rawRecords = pullResult.rawRecordsByFile[file.relativePath],
              let resource = findResource(for: file.relativePath, in: engine.config) else { return }

        let objectPath = ObjectFileManager.objectFilePath(
            forUserFile: file.relativePath,
            strategy: resource.fileMapping.strategy
        )
        let objectURL = serviceDir.appendingPathComponent(objectPath)
        suppressedPaths.insert(objectPath)

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

    /// Cache decoded records for collection-strategy files (used for diffing on push).
    private func cacheCollectionRecords(file: SyncableFile, serviceId: String, engine: AdapterEngine) {
        guard let resource = findResource(for: file.relativePath, in: engine.config),
              resource.fileMapping.strategy == .collection else { return }

        let cacheKey = "\(serviceId):\(file.relativePath)"
        if let records = try? FormatConverterFactory.decode(data: file.content, format: file.format, options: resource.fileMapping.formatOptions) {
            lastKnownRecords[cacheKey] = records
        }
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

    private func matchResource(_ resource: ResourceConfig, to filePath: String) -> ResourceConfig? {
        let dir = resource.fileMapping.directory
        // For collection strategy, match by exact dir+filename path
        if resource.fileMapping.strategy == .collection, let filename = resource.fileMapping.filename {
            if dir.contains("{") {
                // Template directory (e.g. "boards/{name|slugify}"): match by filename suffix
                if filePath == filename || filePath.hasSuffix("/\(filename)") {
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
            return resource
        }
        return nil
    }

    private func updateServiceStatus(_ serviceId: String, status: ServiceStatus, error: String? = nil) {
        serviceInfos[serviceId]?.status = status
        serviceInfos[serviceId]?.errorMessage = error
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

    public func triggerSync(serviceId: String) async {
        await coordinator.syncNow(serviceId: serviceId)
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
            let keychain = KeychainManager()
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

    /// Register and start a new service (for use after AddServiceView creates the directory)
    public func registerNewService(_ serviceId: String) async throws {
        try await registerService(serviceId)
        await coordinator.startService(serviceId: serviceId)
        try? await performPull(serviceId: serviceId)
        try? generateGuides()
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
