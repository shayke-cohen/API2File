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
        let files = try await engine.pullAll()
        let serviceDir = syncFolder.appendingPathComponent(serviceId)

        // Write files to disk
        for file in files {
            let filePath = serviceDir.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.write(to: filePath, options: .atomic)

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
    }

    private func performPush(serviceId: String, filePath: String) async throws {
        print("[SyncEngine] performPush called: service=\(serviceId), file=\(filePath)")
        guard let engine = adapterEngines[serviceId] else { print("[SyncEngine]   -> no engine"); return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let fullPath = serviceDir.appendingPathComponent(filePath)

        // Find which resource this file belongs to
        guard let resource = findResource(for: filePath, in: engine.config) else { print("[SyncEngine]   -> no resource match for '\(filePath)'"); return }

        // Skip read-only resources
        if resource.fileMapping.readOnly == true { return }

        // Skip if file was deleted or is a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath.path, isDirectory: &isDir), !isDir.boolValue else { return }
        let content = try Data(contentsOf: fullPath)

        // For collection-strategy files, use smart diffing to push only changes
        if resource.fileMapping.strategy == .collection {
            try await pushCollectionDiff(
                serviceId: serviceId,
                filePath: filePath,
                content: content,
                resource: resource,
                engine: engine
            )
        } else {
            let file = SyncableFile(
                relativePath: filePath,
                format: resource.fileMapping.format,
                content: content,
                remoteId: syncStates[serviceId]?.files[filePath]?.remoteId
            )
            try await engine.push(file: file, resource: resource)
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
    }

    // MARK: - File Change Handling

    private func handleFileChanges(_ changes: [FileWatcher.FileChange]) {
        print("[SyncEngine] handleFileChanges called with \(changes.count) change(s)")
        for change in changes {
            // Extract service ID and relative path from the full path
            let path = change.path
            print("[SyncEngine]   change path: \(path)")
            guard let relativeParts = extractServiceAndPath(from: path) else {
                print("[SyncEngine]   -> skipped (could not extract service/path, syncFolder=\(syncFolder.path))")
                continue
            }
            let (serviceId, filePath) = relativeParts

            // Skip internal and temp files
            if filePath.hasPrefix(".api2file/") || filePath.hasPrefix(".git/") { continue }
            if filePath == "CLAUDE.md" { continue }
            if filePath.hasPrefix(".") { continue } // .DS_Store, .dat.nosync*, etc.
            if filePath.contains("~$") { continue } // Office temp files

            print("[SyncEngine]   -> queuing push: service=\(serviceId), file=\(filePath)")
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

    /// Smart push for collection files: diff old vs new records, push only changes
    private func pushCollectionDiff(
        serviceId: String,
        filePath: String,
        content: Data,
        resource: ResourceConfig,
        engine: AdapterEngine
    ) async throws {
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
            return // No actual changes
        }

        print("[SyncEngine] Collection diff for \(filePath): \(diff.summary)")

        // Push creates
        for record in diff.created {
            try await engine.pushRecord(record, resource: resource, action: .create)
        }

        // Push updates
        for (id, record) in diff.updated {
            try await engine.pushRecord(record, resource: resource, action: .update(id: id))
        }

        // Push deletes
        for id in diff.deleted {
            try await engine.delete(remoteId: id, resource: resource)
        }

        // Update cache with new records
        lastKnownRecords[cacheKey] = newRecords
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
}
