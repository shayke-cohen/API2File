import Foundation

/// Sync status for an individual file
public enum SyncStatus: String, Codable, Sendable {
    case synced
    case syncing
    case modified
    case conflict
    case error
}

/// Overall status for a connected service
public enum ServiceStatus: String, Codable, Sendable {
    case connected
    case syncing
    case paused
    case error
    case disconnected
}
