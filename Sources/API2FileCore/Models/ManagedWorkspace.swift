import Foundation

public enum ServiceStorageMode: String, Codable, Sendable, CaseIterable {
    case plainSync = "plain_sync"
    case managedWorkspace = "managed_workspace"
}

public enum ManagedCommitPolicy: String, Codable, Sendable, CaseIterable {
    case localFirst = "local-first"
    case validateThenCommit = "validate-then-commit"
    case pushThenCommit = "push-then-commit"
}

public enum ManagedWriteResultKind: String, Codable, Sendable {
    case accepted
    case rejectedValidation = "rejected_validation"
    case rejectedRemote = "rejected_remote"
    case conflict
}

public struct ManagedWriteResult: Codable, Sendable {
    public let kind: ManagedWriteResultKind
    public let filePath: String
    public let message: String
    public let timestamp: Date

    public init(
        kind: ManagedWriteResultKind,
        filePath: String,
        message: String,
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.filePath = filePath
        self.message = message
        self.timestamp = timestamp
    }
}

public struct RejectedManagedProposal: Codable, Sendable, Identifiable {
    public let id: UUID
    public let serviceId: String
    public let filePath: String
    public let contentHash: String?
    public let errorMessage: String
    public let sourceApplication: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        serviceId: String,
        filePath: String,
        contentHash: String?,
        errorMessage: String,
        sourceApplication: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.serviceId = serviceId
        self.filePath = filePath
        self.contentHash = contentHash
        self.errorMessage = errorMessage
        self.sourceApplication = sourceApplication
        self.timestamp = timestamp
    }
}

public struct ManagedRuntimeHealth: Codable, Sendable {
    public let isAvailable: Bool
    public let status: String
    public let detail: String?

    public init(isAvailable: Bool, status: String, detail: String? = nil) {
        self.isAvailable = isAvailable
        self.status = status
        self.detail = detail
    }
}
