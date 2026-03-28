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

    private let keyPrefix: String

    public init(keyPrefix: String = "com.api2file.") {
        self.keyPrefix = keyPrefix
    }

    // MARK: - String CRUD

    /// Save a string value to the keychain under the given key.
    /// If the key already exists, it will be updated.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return saveData(key: key, data: data)
    }

    /// Load a string value from the keychain for the given key.
    public func load(key: String) async -> String? {
        guard let data = await loadData(key: key) else { return nil }
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
    public func loadOAuth2Token(key: String) async -> OAuth2Token? {
        guard let data = await loadData(key: key) else { return nil }
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
            // Use iOS-style accessibility — bypasses per-app ACL dialogs on macOS
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        // Item doesn't exist yet — add it.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    private func loadData(key: String) async -> Data? {
        let account = namespacedKey(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Try SecItemCopyMatching first with a 5-second timeout.
        // If it returns nil (ACL dialog blocked, securityd cold, or not found),
        // fall back to the `security` CLI which is always trusted and returns promptly.
        let apiResult = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let lock = NSLock()
            var resumed = false

            let finish: (Data?) -> Void = { data in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: data)
            }

            // Short timeout — if the Keychain API doesn't respond quickly, use the CLI fallback
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }

            DispatchQueue.global(qos: .utility).async {
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecSuccess, let data = result as? Data {
                    finish(data)
                } else {
                    finish(nil)
                }
            }
        }
        if let apiResult { return apiResult }

        #if os(macOS)
        // Fallback: use the `security` CLI which is always trusted by the login keychain ACL
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fallbackArguments: [[String]] = [
                    ["find-generic-password", "-a", account, "-w"],
                    // Legacy API2File macOS items were sometimes stored with an explicit service name.
                    ["find-generic-password", "-s", "API2File", "-a", account, "-w"],
                    ["find-generic-password", "-s", "com.api2file", "-a", account, "-w"],
                ]

                for arguments in fallbackArguments {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                    process.arguments = arguments
                    let outPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = Pipe()
                    do {
                        try process.run()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 {
                            var output = outPipe.fileHandleForReading.readDataToEndOfFile()
                            if output.last == 10 { output.removeLast() } // strip trailing newline
                            continuation.resume(returning: output.isEmpty ? nil : output)
                            return
                        }
                    } catch {
                        continue
                    }
                }
                continuation.resume(returning: nil)
            }
        }
        #else
        return nil
        #endif
    }
}
