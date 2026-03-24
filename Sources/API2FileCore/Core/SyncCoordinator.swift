import Foundation

/// Coordinates sync operations across services — handles queuing, debouncing, and scheduling
public actor SyncCoordinator {
    private var services: [String: ServiceSyncContext] = [:]
    private var pendingPushes: [String: [String: PendingPush]] = [:] // serviceId -> [filePath -> push]
    private var syncTimers: [String: Task<Void, Never>] = [:]
    private var isPaused = false
    private var isFlushingPushes: [String: Bool] = [:]

    public init() {}

    // MARK: - Service Management

    /// Register a service for sync coordination
    public func register(serviceId: String, context: ServiceSyncContext) {
        services[serviceId] = context
    }

    /// Unregister a service
    public func unregister(serviceId: String) {
        services.removeValue(forKey: serviceId)
        syncTimers[serviceId]?.cancel()
        syncTimers.removeValue(forKey: serviceId)
        pendingPushes.removeValue(forKey: serviceId)
    }

    // MARK: - Sync Control

    /// Start periodic sync for all registered services
    public func startAll() {
        isPaused = false
        for (serviceId, context) in services {
            startPolling(serviceId: serviceId, interval: context.syncInterval)
        }
    }

    /// Start sync for a single service
    public func startService(serviceId: String) {
        guard let context = services[serviceId] else { return }
        startPolling(serviceId: serviceId, interval: context.syncInterval)
    }

    /// Stop all sync operations
    public func stopAll() {
        isPaused = true
        for (_, task) in syncTimers {
            task.cancel()
        }
        syncTimers.removeAll()
    }

    /// Pause/resume syncing
    public func setPaused(_ paused: Bool) {
        if paused {
            stopAll()
        } else {
            startAll()
        }
        isPaused = paused
    }

    /// Trigger an immediate sync for a service
    public func syncNow(serviceId: String) async {
        guard let context = services[serviceId] else { return }
        await performSync(serviceId: serviceId, context: context)
    }

    /// Queue a push for a local file change (debounced)
    public func queuePush(serviceId: String, filePath: String) {
        if pendingPushes[serviceId] == nil {
            pendingPushes[serviceId] = [:]
        }
        pendingPushes[serviceId]?[filePath] = PendingPush(
            filePath: filePath,
            queuedAt: Date()
        )

        // The actual push happens on the next sync cycle or can be triggered explicitly
    }

    /// Immediately flush all pending pushes for a service, then pull.
    /// No-ops if a flush is already in progress for the service.
    public func flushPendingPushes(serviceId: String) async {
        guard isFlushingPushes[serviceId] != true else { return }
        guard let context = services[serviceId] else { return }
        isFlushingPushes[serviceId] = true
        await performSync(serviceId: serviceId, context: context)
        isFlushingPushes[serviceId] = false
    }

    /// Get all pending pushes for a service
    public func getPendingPushes(serviceId: String) -> [PendingPush] {
        return Array(pendingPushes[serviceId]?.values ?? [:].values)
    }

    /// Clear pending pushes for a file (after successful push)
    public func clearPendingPush(serviceId: String, filePath: String) {
        pendingPushes[serviceId]?.removeValue(forKey: filePath)
    }

    // MARK: - Status

    /// Get all registered service IDs
    public func registeredServices() -> [String] {
        Array(services.keys)
    }

    public func isServiceRegistered(_ serviceId: String) -> Bool {
        services[serviceId] != nil
    }

    // MARK: - Private

    private func startPolling(serviceId: String, interval: TimeInterval) {
        syncTimers[serviceId]?.cancel()
        syncTimers[serviceId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self else { break }
                guard let context = await self.services[serviceId] else { break }
                await self.performSync(serviceId: serviceId, context: context)
            }
        }
    }

    private func performSync(serviceId: String, context: ServiceSyncContext) async {
        await context.onSyncStart?()

        do {
            let pushes = pendingPushes[serviceId] ?? [:]
            for (filePath, _) in pushes {
                try await context.pushHandler?(filePath)
                pendingPushes[serviceId]?.removeValue(forKey: filePath)
            }

            try await context.pullHandler?()
            await context.onSyncComplete?(nil)
        } catch {
            await context.onSyncComplete?(error)
        }
    }
}

// MARK: - Supporting Types

/// Context for a registered service
public struct ServiceSyncContext: Sendable {
    public let syncInterval: TimeInterval
    public let pullHandler: (@Sendable () async throws -> Void)?
    public let pushHandler: (@Sendable (String) async throws -> Void)?
    public let onSyncStart: (@Sendable () async -> Void)?
    public let onSyncComplete: (@Sendable (Error?) async -> Void)?

    public init(
        syncInterval: TimeInterval = 60,
        pullHandler: (@Sendable () async throws -> Void)? = nil,
        pushHandler: (@Sendable (String) async throws -> Void)? = nil,
        onSyncStart: (@Sendable () async -> Void)? = nil,
        onSyncComplete: (@Sendable (Error?) async -> Void)? = nil
    ) {
        self.syncInterval = syncInterval
        self.pullHandler = pullHandler
        self.pushHandler = pushHandler
        self.onSyncStart = onSyncStart
        self.onSyncComplete = onSyncComplete
    }
}

/// A queued push operation
public struct PendingPush: Sendable {
    public let filePath: String
    public let queuedAt: Date

    public init(filePath: String, queuedAt: Date) {
        self.filePath = filePath
        self.queuedAt = queuedAt
    }
}
