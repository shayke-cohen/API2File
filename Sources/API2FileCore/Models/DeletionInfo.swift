import Foundation

/// Describes a pending remote deletion that requires user confirmation.
public struct DeletionInfo: Sendable {
    public enum DeletionKind: Sendable {
        /// An entire local file was deleted; every record it maps to will be removed from the API.
        case fileDeletion
        /// One or more rows were removed from a collection file.
        case rowDeletion
    }

    /// Display name of the service, e.g. "Monday.com"
    public let serviceName: String
    /// Service directory ID, e.g. "monday"
    public let serviceId: String
    /// Relative path within the service directory, e.g. "contacts.csv"
    public let filePath: String
    /// Number of remote records that would be deleted (nil = unknown)
    public let recordCount: Int?
    /// Kind of deletion
    public let kind: DeletionKind
}
