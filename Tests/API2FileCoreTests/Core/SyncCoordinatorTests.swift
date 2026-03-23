import XCTest
@testable import API2FileCore

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
