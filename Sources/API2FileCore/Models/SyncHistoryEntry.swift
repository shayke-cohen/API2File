import Foundation

/// Direction of a sync operation
public enum SyncDirection: String, Codable, Sendable {
    case pull
    case push
}

/// Outcome of a sync operation
public enum SyncOutcome: String, Codable, Sendable {
    case success
    case error
    case conflict
}

/// What happened to a specific file during a sync operation
public enum FileAction: String, Codable, Sendable {
    case downloaded   // pull: file written to disk
    case uploaded     // push: file sent to API
    case created      // push: new records created
    case updated      // push: existing records modified
    case deleted      // push: records removed
    case conflicted   // conflict detected
    case error        // operation failed for this file
}

/// Per-file detail within a sync operation
public struct FileChange: Codable, Sendable, Identifiable {
    public var id: String { path }

    public let path: String
    public let action: FileAction
    public let recordsCreated: Int
    public let recordsUpdated: Int
    public let recordsDeleted: Int
    public let errorMessage: String?

    public init(
        path: String,
        action: FileAction,
        recordsCreated: Int = 0,
        recordsUpdated: Int = 0,
        recordsDeleted: Int = 0,
        errorMessage: String? = nil
    ) {
        self.path = path
        self.action = action
        self.recordsCreated = recordsCreated
        self.recordsUpdated = recordsUpdated
        self.recordsDeleted = recordsDeleted
        self.errorMessage = errorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case path, action, recordsCreated, recordsUpdated, recordsDeleted, errorMessage
    }
}

/// A single sync operation record in the audit trail
public struct SyncHistoryEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let serviceId: String
    public let serviceName: String
    public let direction: SyncDirection
    public let status: SyncOutcome
    public let duration: TimeInterval
    public let files: [FileChange]
    public let summary: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        serviceId: String,
        serviceName: String,
        direction: SyncDirection,
        status: SyncOutcome,
        duration: TimeInterval,
        files: [FileChange],
        summary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.serviceId = serviceId
        self.serviceName = serviceName
        self.direction = direction
        self.status = status
        self.duration = duration
        self.files = files
        self.summary = summary
    }
}
