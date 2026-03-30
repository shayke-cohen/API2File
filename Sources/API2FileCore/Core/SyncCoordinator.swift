import Foundation

enum DeferredSyncError: Error {
    case authLoading
    case credentialsUnavailable
}

/// Coordinates sync operations across services — handles queuing, debouncing, and scheduling
public actor SyncCoordinator {
    private var services: [String: ServiceSyncContext] = [:]
    private var pendingPushes: [String: [String: PendingPush]] = [:] // serviceId -> [filePath -> push]
    private var syncTimers: [String: Task<Void, Never>] = [:]
    private var isPaused = false
    private var isFlushingPushes: [String: Bool] = [:]
    private var isSyncing: [String: Bool] = [:]
    private var pendingSyncRequests: Set<String> = []
    private var pushFailureCounts: [String: [String: Int]] = [:] // serviceId -> [filePath -> failureCount]

    /// Max consecutive push failures before a file is dropped from the queue
    private static let maxPushRetries = 3

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
        isSyncing.removeValue(forKey: serviceId)
        pendingSyncRequests.remove(serviceId)
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
        await performSync(serviceId: serviceId, context: context, queueIfBusy: true)
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
        await performSync(serviceId: serviceId, context: context, queueIfBusy: true)
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

    /// Drop all queued push/sync work for a service.
    public func clearPendingWork(serviceId: String) {
        pendingPushes[serviceId]?.removeAll()
        pushFailureCounts[serviceId]?.removeAll()
        pendingSyncRequests.remove(serviceId)
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
                await self.performSync(serviceId: serviceId, context: context, queueIfBusy: false)
            }
        }
    }

    func syncNow(serviceId: String, queueIfBusy: Bool) async {
        guard let context = services[serviceId] else { return }
        await performSync(serviceId: serviceId, context: context, queueIfBusy: queueIfBusy)
    }

    private func performSync(serviceId: String, context: ServiceSyncContext, queueIfBusy: Bool) async {
        if isSyncing[serviceId] == true {
            if queueIfBusy {
                pendingSyncRequests.insert(serviceId)
            }
            return
        }

        isSyncing[serviceId] = true
        var currentContext: ServiceSyncContext? = context

        while let activeContext = currentContext {
            await activeContext.onSyncStart?()

            // Process pushes individually — a single push failure must not block others or the pull
            let pushes = pendingPushes[serviceId] ?? [:]
            for (filePath, _) in pushes {
                do {
                    try await activeContext.pushHandler?(filePath)
                    pendingPushes[serviceId]?.removeValue(forKey: filePath)
                    pushFailureCounts[serviceId]?.removeValue(forKey: filePath)
                } catch {
                    if error is DeferredSyncError {
                        continue
                    }

                    // Track consecutive failures per file
                    if pushFailureCounts[serviceId] == nil {
                        pushFailureCounts[serviceId] = [:]
                    }
                    let count = (pushFailureCounts[serviceId]?[filePath] ?? 0) + 1
                    pushFailureCounts[serviceId]?[filePath] = count

                    if count >= Self.maxPushRetries {
                        // Give up on this file — remove from queue so it doesn't block the service
                        pendingPushes[serviceId]?.removeValue(forKey: filePath)
                        pushFailureCounts[serviceId]?.removeValue(forKey: filePath)
                        await activeContext.onPushAbandoned?(serviceId, filePath, error)
                    }
                }
            }

            // Always attempt pull, even if some pushes failed
            do {
                try await activeContext.pullHandler?()
                // Service is healthy if the pull succeeded (push errors are per-file, not service-wide)
                await activeContext.onSyncComplete?(nil)
            } catch {
                await activeContext.onSyncComplete?(error)
            }

            if pendingSyncRequests.remove(serviceId) != nil {
                currentContext = services[serviceId]
            } else {
                currentContext = nil
            }
        }

        isSyncing[serviceId] = false
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
    /// Called when a file's push is abandoned after max retries (serviceId, filePath, lastError)
    public let onPushAbandoned: (@Sendable (String, String, Error) async -> Void)?

    public init(
        syncInterval: TimeInterval = 60,
        pullHandler: (@Sendable () async throws -> Void)? = nil,
        pushHandler: (@Sendable (String) async throws -> Void)? = nil,
        onSyncStart: (@Sendable () async -> Void)? = nil,
        onSyncComplete: (@Sendable (Error?) async -> Void)? = nil,
        onPushAbandoned: (@Sendable (String, String, Error) async -> Void)? = nil
    ) {
        self.syncInterval = syncInterval
        self.pullHandler = pullHandler
        self.pushHandler = pushHandler
        self.onSyncStart = onSyncStart
        self.onSyncComplete = onSyncComplete
        self.onPushAbandoned = onPushAbandoned
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
