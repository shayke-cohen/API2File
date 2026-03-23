import Foundation

/// Represents a file that is synced between local disk and a cloud API
public struct SyncableFile: Sendable {
    /// Relative path from the service root (e.g., "boards/marketing.csv")
    public let relativePath: String

    /// The file format
    public let format: FileFormat

    /// The file content as raw data
    public var content: Data

    /// Server-side record ID (nil for new files)
    public var remoteId: String?

    /// Whether this file is read-only (server → local only)
    public let readOnly: Bool

    /// SHA256 hash of the content
    public var contentHash: String {
        content.sha256Hex
    }

    public init(relativePath: String, format: FileFormat, content: Data, remoteId: String? = nil, readOnly: Bool = false) {
        self.relativePath = relativePath
        self.format = format
        self.content = content
        self.remoteId = remoteId
        self.readOnly = readOnly
    }
}

// MARK: - ServiceInfo

/// Runtime information about a connected service
public struct ServiceInfo: Sendable {
    public let serviceId: String
    public let displayName: String
    public let config: AdapterConfig
    public var status: ServiceStatus
    public var lastSyncTime: Date?
    public var fileCount: Int
    public var errorMessage: String?

    public init(serviceId: String, displayName: String, config: AdapterConfig, status: ServiceStatus = .connected, lastSyncTime: Date? = nil, fileCount: Int = 0, errorMessage: String? = nil) {
        self.serviceId = serviceId
        self.displayName = displayName
        self.config = config
        self.status = status
        self.lastSyncTime = lastSyncTime
        self.fileCount = fileCount
        self.errorMessage = errorMessage
    }
}

// MARK: - Data extension

extension Data {
    var sha256Hex: String {
        // Use CryptoKit-free SHA256 via CC
        var hash = [UInt8](repeating: 0, count: 32)
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

import CommonCrypto
