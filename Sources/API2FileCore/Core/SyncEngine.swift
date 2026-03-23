import Foundation

/// Top-level sync engine — ties together all components for the full sync lifecycle
public actor SyncEngine {
    private let config: GlobalConfig
    private let syncFolder: URL
    private let coordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let fileWatcher: FileWatcher
    private var gitManagers: [String: GitManager] = [:]
    private var adapterEngines: [String: AdapterEngine] = [:]
    private var syncStates: [String: SyncState] = [:]
    private var serviceInfos: [String: ServiceInfo] = [:]

    public init(config: GlobalConfig) {
        self.config = config
        self.syncFolder = config.resolvedSyncFolder
        self.coordinator = SyncCoordinator()
        self.networkMonitor = NetworkMonitor()
        self.fileWatcher = FileWatcher()
    }

    // MARK: - Lifecycle

    /// Start the sync engine — discover services, start watching, start polling
    public func start() async throws {
        // Ensure sync folder exists
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)

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

        // Start sync coordinator
        await coordinator.startAll()

        // Generate CLAUDE.md guides
        try generateGuides()
    }

    /// Stop the sync engine
    public func stop() async {
        fileWatcher.stop()
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
        guard let engine = adapterEngines[serviceId] else { return }
        let serviceDir = syncFolder.appendingPathComponent(serviceId)
        let fullPath = serviceDir.appendingPathComponent(filePath)

        // Find which resource this file belongs to
        guard let resource = findResource(for: filePath, in: engine.config) else { return }

        // Skip read-only resources
        if resource.fileMapping.readOnly == true { return }

        // Read file content
        let content = try Data(contentsOf: fullPath)
        let file = SyncableFile(
            relativePath: filePath,
            format: resource.fileMapping.format,
            content: content,
            remoteId: syncStates[serviceId]?.files[filePath]?.remoteId
        )

        // Push to API
        try await engine.push(file: file, resource: resource)

        // Update sync state
        syncStates[serviceId]?.files[filePath]?.lastSyncedHash = file.contentHash
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
        for change in changes {
            // Extract service ID and relative path from the full path
            let path = change.path
            guard let relativeParts = extractServiceAndPath(from: path) else { continue }
            let (serviceId, filePath) = relativeParts

            // Skip internal files
            if filePath.hasPrefix(".api2file/") || filePath.hasPrefix(".git/") { continue }
            if filePath == "CLAUDE.md" { continue }

            Task {
                await coordinator.queuePush(serviceId: serviceId, filePath: filePath)
            }
        }
    }

    private func extractServiceAndPath(from fullPath: String) -> (serviceId: String, filePath: String)? {
        let syncPath = syncFolder.path
        guard fullPath.hasPrefix(syncPath) else { return nil }

        let relative = String(fullPath.dropFirst(syncPath.count + 1)) // +1 for the /
        let components = relative.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }

        return (String(components[0]), String(components[1]))
    }

    // MARK: - Helpers

    private func findResource(for filePath: String, in config: AdapterConfig) -> ResourceConfig? {
        for resource in config.resources {
            if filePath.hasPrefix(resource.fileMapping.directory) {
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
}
