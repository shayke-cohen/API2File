import XCTest
@testable import API2FileCore

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor CounterBox {
    private var value = 0

    func increment() -> Int {
        value += 1
        return value
    }

    func current() -> Int {
        value
    }
}

final class SyncCoordinatorTests: XCTestCase {

    // MARK: - Registration

    func testRegisterAndUnregisterServices() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)

        await coordinator.register(serviceId: "svc-1", context: context)
        var registered = await coordinator.registeredServices()
        XCTAssertTrue(registered.contains("svc-1"))

        await coordinator.unregister(serviceId: "svc-1")
        registered = await coordinator.registeredServices()
        XCTAssertFalse(registered.contains("svc-1"))
    }

    func testRegisteredServicesReturnsRegisteredIDs() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)

        await coordinator.register(serviceId: "alpha", context: context)
        await coordinator.register(serviceId: "beta", context: context)

        let registered = await coordinator.registeredServices()
        XCTAssertEqual(Set(registered), Set(["alpha", "beta"]))
    }

    func testMultipleServicesCanBeRegisteredIndependently() async {
        let coordinator = SyncCoordinator()
        let ctx1 = ServiceSyncContext(syncInterval: 10)
        let ctx2 = ServiceSyncContext(syncInterval: 20)
        let ctx3 = ServiceSyncContext(syncInterval: 30)

        await coordinator.register(serviceId: "s1", context: ctx1)
        await coordinator.register(serviceId: "s2", context: ctx2)
        await coordinator.register(serviceId: "s3", context: ctx3)

        var registered = await coordinator.registeredServices()
        XCTAssertEqual(registered.count, 3)

        // Unregistering one doesn't affect the others
        await coordinator.unregister(serviceId: "s2")
        registered = await coordinator.registeredServices()
        XCTAssertEqual(registered.count, 2)
        XCTAssertTrue(registered.contains("s1"))
        XCTAssertFalse(registered.contains("s2"))
        XCTAssertTrue(registered.contains("s3"))
    }

    func testIsServiceRegistered() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)

        let beforeRegister = await coordinator.isServiceRegistered("svc-1")
        XCTAssertFalse(beforeRegister)
        await coordinator.register(serviceId: "svc-1", context: context)
        let afterRegister = await coordinator.isServiceRegistered("svc-1")
        XCTAssertTrue(afterRegister)
    }

    // MARK: - Pending Pushes

    func testQueuePushAddsPendingPushes() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)
        await coordinator.register(serviceId: "svc", context: context)

        await coordinator.queuePush(serviceId: "svc", filePath: "file-a.json")
        await coordinator.queuePush(serviceId: "svc", filePath: "file-b.json")

        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        let paths = Set(pending.map(\.filePath))
        XCTAssertEqual(paths, Set(["file-a.json", "file-b.json"]))
    }

    func testGetPendingPushesReturnsQueuedItems() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)
        await coordinator.register(serviceId: "svc", context: context)

        // Initially empty
        let empty = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertTrue(empty.isEmpty)

        await coordinator.queuePush(serviceId: "svc", filePath: "notes/readme.md")
        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].filePath, "notes/readme.md")
    }

    func testClearPendingPushRemovesSpecificFile() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)
        await coordinator.register(serviceId: "svc", context: context)

        await coordinator.queuePush(serviceId: "svc", filePath: "keep.json")
        await coordinator.queuePush(serviceId: "svc", filePath: "remove.json")
        await coordinator.queuePush(serviceId: "svc", filePath: "also-keep.json")

        await coordinator.clearPendingPush(serviceId: "svc", filePath: "remove.json")

        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        let paths = Set(pending.map(\.filePath))
        XCTAssertEqual(paths, Set(["keep.json", "also-keep.json"]))
    }

    func testQueuePushDeduplicatesSameFilePath() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)
        await coordinator.register(serviceId: "svc", context: context)

        await coordinator.queuePush(serviceId: "svc", filePath: "file.json")
        await coordinator.queuePush(serviceId: "svc", filePath: "file.json")
        await coordinator.queuePush(serviceId: "svc", filePath: "file.json")

        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertEqual(pending.count, 1)
    }

    // MARK: - syncNow

    func testSyncNowTriggersPullAndPushHandlers() async {
        let pullExpectation = expectation(description: "pull handler called")
        let pushExpectation = expectation(description: "push handler called")

        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: {
                pullExpectation.fulfill()
            },
            pushHandler: { filePath in
                XCTAssertEqual(filePath, "data.json")
                pushExpectation.fulfill()
            }
        )

        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.queuePush(serviceId: "svc", filePath: "data.json")
        await coordinator.syncNow(serviceId: "svc")

        await fulfillment(of: [pushExpectation, pullExpectation], timeout: 5.0)

        // After sync, pending pushes should be cleared
        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertTrue(pending.isEmpty)
    }

    func testSyncNowCallsOnSyncStartAndOnSyncComplete() async {
        let startExpectation = expectation(description: "sync start callback")
        let completeExpectation = expectation(description: "sync complete callback")

        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            onSyncStart: {
                startExpectation.fulfill()
            },
            onSyncComplete: { error in
                XCTAssertNil(error)
                completeExpectation.fulfill()
            }
        )

        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.syncNow(serviceId: "svc")

        await fulfillment(of: [startExpectation, completeExpectation], timeout: 5.0)
    }

    func testSyncNowWithUnregisteredServiceIsNoOp() async {
        let coordinator = SyncCoordinator()
        // Should not crash or throw
        await coordinator.syncNow(serviceId: "nonexistent")
    }

    func testSyncNowReportsErrorOnPullFailure() async {
        struct TestError: Error {}
        let completeExpectation = expectation(description: "sync complete with error")

        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: {
                throw TestError()
            },
            onSyncComplete: { error in
                XCTAssertNotNil(error)
                XCTAssertTrue(error is TestError)
                completeExpectation.fulfill()
            }
        )

        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.syncNow(serviceId: "svc")

        await fulfillment(of: [completeExpectation], timeout: 5.0)
    }

    func testSyncNowCoalescesOverlappingRequestsPerService() async {
        let firstPullStarted = expectation(description: "first pull started")
        let secondPullStarted = expectation(description: "second pull started after first completes")
        let gate = AsyncGate()
        let pullCount = CounterBox()

        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: {
                let count = await pullCount.increment()
                if count == 1 {
                    firstPullStarted.fulfill()
                    await gate.wait()
                } else if count == 2 {
                    secondPullStarted.fulfill()
                }
            }
        )

        await coordinator.register(serviceId: "svc", context: context)

        Task { await coordinator.syncNow(serviceId: "svc") }
        await fulfillment(of: [firstPullStarted], timeout: 2.0)

        Task { await coordinator.syncNow(serviceId: "svc") }
        Task { await coordinator.syncNow(serviceId: "svc") }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let blockedCount = await pullCount.current()
        XCTAssertEqual(blockedCount, 1, "overlapping sync requests should not start a second pull immediately")

        await gate.open()
        await fulfillment(of: [secondPullStarted], timeout: 2.0)
        let finalCount = await pullCount.current()
        XCTAssertEqual(finalCount, 2, "queued overlapping sync requests should collapse into a single follow-up pull")
    }

    func testNonQueuedOverlapDoesNotScheduleFollowUpSync() async {
        let firstPullStarted = expectation(description: "first non-queued pull started")
        let gate = AsyncGate()
        let pullCount = CounterBox()

        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: {
                let count = await pullCount.increment()
                if count == 1 {
                    firstPullStarted.fulfill()
                    await gate.wait()
                }
            }
        )

        await coordinator.register(serviceId: "svc", context: context)

        Task { await coordinator.syncNow(serviceId: "svc", queueIfBusy: false) }
        await fulfillment(of: [firstPullStarted], timeout: 2.0)

        Task { await coordinator.syncNow(serviceId: "svc", queueIfBusy: false) }
        Task { await coordinator.syncNow(serviceId: "svc", queueIfBusy: false) }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let blockedCount = await pullCount.current()
        XCTAssertEqual(blockedCount, 1, "non-queued overlaps should not start an extra pull while one is running")

        await gate.open()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let finalCount = await pullCount.current()
        XCTAssertEqual(finalCount, 1, "non-queued overlaps should be dropped instead of scheduling a follow-up sync")
    }

    // MARK: - Pausing

    func testSetPausedStopsAndStartsPolling() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 600)
        await coordinator.register(serviceId: "svc", context: context)

        // Pause
        await coordinator.setPaused(true)

        // Resume
        await coordinator.setPaused(false)

        // Service should still be registered after pause/resume cycle
        let registered = await coordinator.registeredServices()
        XCTAssertTrue(registered.contains("svc"))
    }

    // MARK: - flushPendingPushes

    func testFlushPendingPushesRunsPushAndPullHandlers() async {
        let pushExp = expectation(description: "push handler called")
        let pullExp = expectation(description: "pull handler called")
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: { pullExp.fulfill() },
            pushHandler: { _ in pushExp.fulfill() }
        )
        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.queuePush(serviceId: "svc", filePath: "data.csv")
        await coordinator.flushPendingPushes(serviceId: "svc")
        await fulfillment(of: [pushExp, pullExp], timeout: 3.0)
    }

    func testFlushPendingPushesClearsPendingQueue() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: {},
            pushHandler: { _ in }
        )
        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.queuePush(serviceId: "svc", filePath: "a.csv")
        await coordinator.queuePush(serviceId: "svc", filePath: "b.csv")
        await coordinator.flushPendingPushes(serviceId: "svc")
        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertTrue(pending.isEmpty, "pending queue should be drained after flush")
    }

    func testFlushPendingPushesKeepsDeferredAuthPushQueued() async {
        let pullExp = expectation(description: "pull still runs")
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: { pullExp.fulfill() },
            pushHandler: { _ in
                throw DeferredSyncError.authLoading
            }
        )

        await coordinator.register(serviceId: "svc", context: context)
        await coordinator.queuePush(serviceId: "svc", filePath: "contacts.csv")
        await coordinator.flushPendingPushes(serviceId: "svc")

        await fulfillment(of: [pullExp], timeout: 3.0)

        let pending = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertEqual(pending.map(\.filePath), ["contacts.csv"], "deferred auth pushes should stay queued for retry")
    }

    func testFlushPendingPushesIsNoOpForUnregisteredService() async {
        let coordinator = SyncCoordinator()
        // Should not crash or hang
        await coordinator.flushPendingPushes(serviceId: "nonexistent")
    }

    func testFlushPendingPushesWithNoPendingPushesStillPulls() async {
        let pullExp = expectation(description: "pull called even with no pending pushes")
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(
            syncInterval: 600,
            pullHandler: { pullExp.fulfill() }
        )
        await coordinator.register(serviceId: "svc", context: context)
        // No queuePush — flush should still trigger a pull
        await coordinator.flushPendingPushes(serviceId: "svc")
        await fulfillment(of: [pullExp], timeout: 3.0)
    }

    // MARK: - Unregister cleans up pending pushes

    func testUnregisterCleansPendingPushes() async {
        let coordinator = SyncCoordinator()
        let context = ServiceSyncContext(syncInterval: 30)
        await coordinator.register(serviceId: "svc", context: context)

        await coordinator.queuePush(serviceId: "svc", filePath: "file.json")
        let beforeUnregister = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertEqual(beforeUnregister.count, 1)

        await coordinator.unregister(serviceId: "svc")

        let afterUnregister = await coordinator.getPendingPushes(serviceId: "svc")
        XCTAssertTrue(afterUnregister.isEmpty)
    }
}
