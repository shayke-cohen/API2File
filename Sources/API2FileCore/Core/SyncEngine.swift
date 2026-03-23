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
    private var historyLogs: [String: SyncHistoryLog] = [:]
    private var _notificationManager: NotificationManager?
    private var notificationManager: NotificationManager {
        if _notificationManager == nil {
            _notificationManager = NotificationManager()
        }
        return _notificationManager!
    }

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

        // Start file watcher
        let watchDirs = serviceIds.map { syncFolder.appendingPathComponent($0).path }
        fileWatcher.start(directories: watchDirs) { [weak self] changes in
            guard let self else { return }
            Task {
                await self.handleFileChanges(changes)
            }
        }

        // Start config watcher — auto-reload when adapter.json changes
        let configPaths = serviceIds.map {
            syncFolder.appendingPathComponent($0).appendingPathComponent(".api2file").path
        }
        configWatcher.start(directories: configPaths) { [weak self] serviceId in
            guard let self else { return }
            Task {
                await self.reloadService(serviceId)
            }
        }

        // Initial pull for all services (so files appear immediately)
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
                print("[SyncEngine] Initial pull complete for \(serviceId)")
            } catch {
                print("[SyncEngine] Initial pull failed for \(serviceId): \(error)")
            }
        }

        // Start sync coordinator (periodic polling)
        await coordinator.startAll()

        // Generate CLAUDE.md guides
        try generateGuides()

        print("[SyncEngine] Started with \(serviceIds.count) service(s)")
    }

    /// Stop the sync engine
    public func stop() async {
        fileWatcher.stop()
        configWatcher.stop()
        networkMonitor.stop()
        await coordinator.stopAll()
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
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let config = try AdapterEngine.loadConfig(from: serviceDir)
        let httpClient = HTTPClient()

        // Load auth token from Keychain and set on HTTP client
        let keychain = KeychainManager()
        if let token = await keychain.load(key: config.auth.keychainKey) {
            switch config.auth.type {
            case .bearer:
                await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
            case .apiKey:
                await httpClient.setAuthHeader("Authorization", value: token)
            case .basic:
                await httpClient.setAuthHeader("Authorization", value: "Basic \(token)")
            case .oauth2:
                await httpClient.setAuthHeader("Authorization", value: "Bearer \(token)")
            }
        }

        let engine = AdapterEngine(config: config, serviceDir: serviceDir, httpClient: httpClient)
        adapterEngines[serviceId] = engine

        // Load or create sync state
        let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
        let state = (try? SyncState.load(from: stateURL)) ?? SyncState()
        syncStates[serviceId] = state

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

        // Compute sync interval
        let interval = config.resources.first?.sync?.intervalSeconds ?? TimeInterval(self.config.defaultSyncInterval)

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
            print("[SyncEngine] Reloaded config for \(serviceId)")
        } catch {
            print("[SyncEngine] Failed to reload \(serviceId): \(error)")
        }
    }

    // MARK: - Sync Operations

    private func performPull(serviceId: String) async throws {
        guard let engine = adapterEngines[serviceId] else { return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let serviceName = serviceInfos[serviceId]?.displayName ?? serviceId
        let startTime = Date()

        do {
            let pullResult = try await engine.pullAll()
            let files = pullResult.files

            // Write files to disk
            for file in files {
                let filePath = serviceDir.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                // Suppress file watcher for user files we're about to write
                suppressedPaths.insert(file.relativePath)
                try file.content.write(to: filePath, options: .atomic)

                // Write object file with raw API records
                if let rawRecords = pullResult.rawRecordsByFile[file.relativePath],
                   let resource = findResource(for: file.relativePath, in: engine.config) {
                    let objectPath = ObjectFileManager.objectFilePath(
                        forUserFile: file.relativePath,
                        strategy: resource.fileMapping.strategy
                    )
                    let objectURL = serviceDir.appendingPathComponent(objectPath)
                    suppressedPaths.insert(objectPath)

                    if resource.fileMapping.strategy == .onePerRecord {
                        if let record = rawRecords.first {
                            try ObjectFileManager.writeRecordObjectFile(record: record, to: objectURL)
                        }
                    } else {
                        try ObjectFileManager.writeCollectionObjectFile(records: rawRecords, to: objectURL)
                    }
                }

                // Cache decoded records for collection-strategy files (for diffing on push)
                if let resource = findResource(for: file.relativePath, in: engine.config),
                   resource.fileMapping.strategy == .collection {
                    let cacheKey = "\(serviceId):\(file.relativePath)"
                    if let records = try? FormatConverterFactory.decode(data: file.content, format: file.format, options: resource.fileMapping.formatOptions) {
                        lastKnownRecords[cacheKey] = records
                    }
                }

                // Update sync state
                if let remoteId = file.remoteId {
                    syncStates[serviceId]?.files[file.relativePath] = FileSyncState(
                        remoteId: remoteId,
                        lastSyncedHash: file.contentHash,
                        lastSyncTime: Date(),
                        status: .synced
                    )
                }
            }

            // Save state
            let stateURL = serviceDir.appendingPathComponent(".api2file/state.json")
            try syncStates[serviceId]?.save(to: stateURL)

            // Git commit
            if config.gitAutoCommit, let git = gitManagers[serviceId] {
                if try await git.hasChanges() {
                    try await git.commitAll(message: "sync: pull \(serviceId) — updated \(files.count) files")
                }
            }

            // Update file count
            serviceInfos[serviceId]?.fileCount = syncStates[serviceId]?.files.count ?? 0
            serviceInfos[serviceId]?.lastSyncTime = Date()

            // Log history entry
            let fileChanges = files.map {
                FileChange(path: $0.relativePath, action: .downloaded)
            }
            let entry = SyncHistoryEntry(
                serviceId: serviceId,
                serviceName: serviceName,
                direction: .pull,
                status: .success,
                duration: Date().timeIntervalSince(startTime),
                files: fileChanges,
                summary: "pulled \(files.count) files"
            )
            logHistory(entry, serviceId: serviceId, serviceDir: serviceDir)
        } catch {
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

        // Find which resource this file belongs to
        guard let resource = findResource(for: filePath, in: engine.config) else { return }

        // Skip read-only resources
        if resource.fileMapping.effectivePushMode == .readOnly { return }

        // Skip if file was deleted or is a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir), !isDir.boolValue else { return }
        let content = try Data(contentsOf: fullPath)

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

            // Skip internal and temp files
            if filePath.hasPrefix(".api2file/") || filePath.hasPrefix(".git/") { continue }
            if filePath == "CLAUDE.md" { continue }
            if filePath.contains("~$") { continue } // Office temp files

            // Skip suppressed paths (written by pull or regeneration — prevents loops)
            if suppressedPaths.remove(filePath) != nil { continue }

            // Check if this is an object file change (agent editing raw records)
            if ObjectFileManager.isObjectFile(filePath) {
                Task { [weak self] in
                    guard let self else { return }
                    await self.performObjectPush(serviceId: serviceId, objectFilePath: filePath)
                }
                continue
            }

            // Skip other hidden files (.DS_Store, etc.) — but not object files (handled above)
            if filePath.hasPrefix(".") || filePath.contains("/.") { continue }

            Task {
                await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
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
        let newRecords = try FormatConverterFactory.decode(
            data: content,
            format: resource.fileMapping.format,
            options: resource.fileMapping.formatOptions
        )

        // Get old records (from cache or empty if first push)
        let oldRecords = lastKnownRecords[cacheKey] ?? []

        // Diff
        let diff = CollectionDiffer.diff(old: oldRecords, new: newRecords, idField: idField)

        if diff.isEmpty {
            return nil // No actual changes
        }

        print("[SyncEngine] Collection diff for \(filePath): \(diff.summary)")

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

        // Push creates
        for record in diff.created {
            let pushRecord: [String: Any]
            if shouldInverse {
                pushRecord = InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record)
            } else {
                pushRecord = record
            }
            try await engine.pushRecord(pushRecord, resource: resource, action: .create)
        }

        // Push updates (with inverse transform merging)
        for (id, record) in diff.updated {
            let pushRecord: [String: Any]
            if shouldInverse, let rawRecord = rawLookup[id] {
                pushRecord = InverseTransformPipeline.apply(inverseOps: inverseOps, editedRecord: record, rawRecord: rawRecord)
            } else if shouldInverse {
                pushRecord = InverseTransformPipeline.applyMechanical(inverseOps: inverseOps, editedRecord: record)
            } else {
                pushRecord = record
            }
            try await engine.pushRecord(pushRecord, resource: resource, action: .update(id: id))
        }

        // Push deletes
        for id in diff.deleted {
            try await engine.delete(remoteId: id, resource: resource)
        }

        // Update caches
        lastKnownRecords[cacheKey] = newRecords

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
                print("[SyncEngine] No resource found for object file: \(objectFilePath)")
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

            print("[SyncEngine] Object file push: \(objectFilePath) → regenerated \(userFilePath)")

        } catch {
            print("[SyncEngine] Object file push failed for \(objectFilePath): \(error)")
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

    // MARK: - Helpers

    private func findResource(for filePath: String, in config: AdapterConfig) -> ResourceConfig? {
        for resource in config.resources {
            let dir = resource.fileMapping.directory
            // "." means root of the service directory — matches any file at the top level
            if dir == "." || filePath.hasPrefix(dir + "/") || filePath.hasPrefix(dir) {
                // For collection strategy, also check filename match
                if let filename = resource.fileMapping.filename,
                   resource.fileMapping.strategy == .collection {
                    if filePath == filename || filePath.hasSuffix("/\(filename)") {
                        return resource
                    }
                    continue
                }
                return resource
            }
        }
        return nil
    }

    private func updateServiceStatus(_ serviceId: String, status: ServiceStatus, error: String? = nil) {
        serviceInfos[serviceId]?.status = status
        serviceInfos[serviceId]?.errorMessage = error
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
