import XCTest
@testable import API2FileCore

final class ManagedWorkspaceManagerTests: XCTestCase {
    func testSynchronizeVisibleFilesCopiesAcceptedFilesAndSkipsHidden() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedWorkspaceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storage = StorageLocations(
            homeDirectory: tempRoot,
            syncRootDirectory: tempRoot.appendingPathComponent("sync", isDirectory: true),
            managedWorkspaceDirectory: tempRoot.appendingPathComponent("workspace", isDirectory: true),
            adaptersDirectory: tempRoot.appendingPathComponent("adapters", isDirectory: true),
            applicationSupportDirectory: tempRoot.appendingPathComponent("support", isDirectory: true)
        )
        let manager = ManagedWorkspaceManager(storageLocations: storage, config: GlobalConfig(
            syncFolder: storage.syncRootDirectory.path,
            managedWorkspaceFolder: storage.managedWorkspaceDirectory.path
        ))

        let acceptedRoot = storage.syncRootDirectory.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: acceptedRoot, withIntermediateDirectories: true)
        try Data("id,name\n1,Alice\n".utf8).write(to: acceptedRoot.appendingPathComponent("tasks.csv"))
        try Data("guide".utf8).write(to: acceptedRoot.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(at: acceptedRoot.appendingPathComponent(".api2file", isDirectory: true), withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: acceptedRoot.appendingPathComponent(".api2file/state.json"))

        try await manager.synchronizeVisibleFiles(serviceId: "demo", acceptedRoot: acceptedRoot)
        let workspaceRoot = await manager.serviceRootURL(serviceId: "demo")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("tasks.csv").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("CLAUDE.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(".api2file/state.json").path))
    }

    func testRejectedProposalRoundTrip() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedWorkspaceRejectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let storage = StorageLocations(
            homeDirectory: tempRoot,
            syncRootDirectory: tempRoot.appendingPathComponent("sync", isDirectory: true),
            managedWorkspaceDirectory: tempRoot.appendingPathComponent("workspace", isDirectory: true),
            adaptersDirectory: tempRoot.appendingPathComponent("adapters", isDirectory: true),
            applicationSupportDirectory: tempRoot.appendingPathComponent("support", isDirectory: true)
        )
        let manager = ManagedWorkspaceManager(storageLocations: storage, config: GlobalConfig(
            syncFolder: storage.syncRootDirectory.path,
            managedWorkspaceFolder: storage.managedWorkspaceDirectory.path
        ))

        let proposal = RejectedManagedProposal(
            serviceId: "demo",
            filePath: "tasks.csv",
            contentHash: "abc123",
            errorMessage: "Validation failed",
            sourceApplication: "Tests"
        )
        try await manager.recordRejectedProposal(proposal)

        let proposals = try await manager.loadRejectedProposals(serviceId: "demo", limit: 10)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals[0].filePath, "tasks.csv")
        XCTAssertEqual(proposals[0].sourceApplication, "Tests")
    }
}
