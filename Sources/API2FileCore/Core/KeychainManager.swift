import Foundation
import Security

// MARK: - OAuth2Token

/// Represents an OAuth2 token set, stored as JSON-encoded data in the keychain.
public struct OAuth2Token: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether the token has expired (with a 60-second safety margin).
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60)
    }
}

// MARK: - KeychainManager

/// Thread-safe keychain wrapper for storing API credentials and OAuth2 tokens.
/// All keys are namespaced with "com.api2file." to avoid collisions.
public actor KeychainManager {

    /// Shared singleton instance.
    public static let shared = KeychainManager()

    private let keyPrefix = "com.api2file."

    public init() {}

    // MARK: - String CRUD

    /// Save a string value to the keychain under the given key.
    /// If the key already exists, it will be updated.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(key: key, data: data)
    }

    /// Load a string value from the keychain for the given key.
    public func load(key: String) -> String? {
        guard let data = loadData(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete the value stored under the given key from the keychain.
    @discardableResult
    public func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: namespacedKey(key),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }

    // MARK: - OAuth2 Token

    /// Save an OAuth2 token set to the keychain, JSON-encoded.
    @discardableResult
    public func saveOAuth2Token(
        key: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) -> Bool {
        let token = OAuth2Token(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
        guard let data = try? JSONEncoder().encode(token) else { return false }
        return saveData(key: key, data: data)
    }

    /// Load an OAuth2 token set from the keychain.
    public func loadOAuth2Token(key: String) -> OAuth2Token? {
        guard let data = loadData(key: key) else { return nil }
        return try? JSONDecoder().decode(OAuth2Token.self, from: data)
    }

    // MARK: - Private Helpers

    private func namespacedKey(_ key: String) -> String {
        key.hasPrefix(keyPrefix) ? key : keyPrefix + key
    }

    private func saveData(key: String, data: Data) -> Bool {
        let account = namespacedKey(key)

        // Try to update first — avoids a delete-then-add race.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        // Item doesn't exist yet — add it.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    private func loadData(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: namespacedKey(key),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
    }
}
