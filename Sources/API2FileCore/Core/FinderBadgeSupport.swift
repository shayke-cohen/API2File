#if os(macOS)
import Foundation

public enum FinderBadgeSupport {
    public static var appGroupIdentifier: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "API2FileAppGroupIdentifier") as? String,
           !configured.isEmpty {
            return configured
        }
        return "group.com.api2file"
    }
    public static let syncRootPathKey = "finder.syncRootPath"
    public static let syncRootBookmarkKey = "finder.syncRootBookmark"
    public static let badgesEnabledKey = "finder.badgesEnabled"
    public static let badgeKeyPrefix = "badge."
    public static let serviceConfigKeyPrefix = "serviceConfig."
    public static let refreshNotificationName = Notification.Name("com.api2file.finder-badges-updated")
    public static let supportedStatuses: Set<String> = ["synced", "syncing", "conflict", "error"]

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    public static func syncRootURL(in defaults: UserDefaults? = sharedDefaults(), fallback: URL) -> URL {
        guard let path = stringValue(forKey: syncRootPathKey, defaults: defaults), !path.isEmpty else {
            return fallback
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func setSyncRootURL(_ url: URL, in defaults: UserDefaults? = sharedDefaults()) {
        persist(url.path, forKey: syncRootPathKey, defaults: defaults)
    }

    public static func syncRootBookmarkData(in defaults: UserDefaults? = sharedDefaults()) -> Data? {
        dataValue(forKey: syncRootBookmarkKey, defaults: defaults)
    }

    public static func setSyncRootBookmarkData(_ data: Data?, in defaults: UserDefaults? = sharedDefaults()) {
        persist(data, forKey: syncRootBookmarkKey, defaults: defaults)
    }

    public static func badgesEnabled(in defaults: UserDefaults? = sharedDefaults()) -> Bool {
        boolValue(forKey: badgesEnabledKey, defaults: defaults) ?? true
    }

    public static func setBadgesEnabled(_ enabled: Bool, in defaults: UserDefaults? = sharedDefaults()) {
        persist(enabled, forKey: badgesEnabledKey, defaults: defaults)
    }

    public static func badgeKey(forRelativePath relativePath: String) -> String {
        badgeKeyPrefix + normalizeRelativePath(relativePath)
    }

    public static func setBadgeState(_ status: String, forRelativePath relativePath: String, in defaults: UserDefaults? = sharedDefaults()) {
        let normalizedStatus = normalizeStatus(status)
        let key = badgeKey(forRelativePath: relativePath)
        if normalizedStatus.isEmpty {
            persist(nil, forKey: key, defaults: defaults)
        } else {
            persist(normalizedStatus, forKey: key, defaults: defaults)
        }
    }

    public static func badgeState(forRelativePath relativePath: String, in defaults: UserDefaults? = sharedDefaults()) -> String? {
        stringValue(forKey: badgeKey(forRelativePath: relativePath), defaults: defaults)
    }

    public static func clearBadgeStates(in defaults: UserDefaults? = sharedDefaults()) {
        clearValues(withPrefix: badgeKeyPrefix, defaults: defaults)
    }

    public static func serviceConfigKey(forServiceId serviceId: String) -> String {
        serviceConfigKeyPrefix + serviceId
    }

    public static func setServiceConfig(_ config: AdapterConfig, forServiceId serviceId: String, in defaults: UserDefaults? = sharedDefaults()) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else {
            persist(nil, forKey: serviceConfigKey(forServiceId: serviceId), defaults: defaults)
            return
        }

        persist(json, forKey: serviceConfigKey(forServiceId: serviceId), defaults: defaults)
    }

    public static func serviceConfig(forServiceId serviceId: String, in defaults: UserDefaults? = sharedDefaults()) -> AdapterConfig? {
        guard let json = stringValue(forKey: serviceConfigKey(forServiceId: serviceId), defaults: defaults),
              let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(AdapterConfig.self, from: data)
    }

    public static func clearServiceConfigs(in defaults: UserDefaults? = sharedDefaults()) {
        clearValues(withPrefix: serviceConfigKeyPrefix, defaults: defaults)
    }

    public static func relativePath(for itemURL: URL, syncRootURL: URL) -> String? {
        let syncRootPath = syncRootURL.path
        guard itemURL.path == syncRootPath || itemURL.path.hasPrefix(syncRootPath + "/") else {
            return nil
        }

        if itemURL.path == syncRootPath {
            return nil
        }

        let relativePath = String(itemURL.path.dropFirst(syncRootPath.count + 1))
        return normalizeRelativePath(relativePath)
    }

    public static func serviceId(forRelativePath relativePath: String) -> String? {
        let normalized = normalizeRelativePath(relativePath)
        return normalized.split(separator: "/").first.map(String.init)
    }

    public static func badgeIdentifier(
        for status: String,
        relativePath: String,
        defaults: UserDefaults? = sharedDefaults()
    ) -> String {
        let normalizedStatus = normalizeStatus(status)
        guard !normalizedStatus.isEmpty else { return "" }

        if let serviceId = serviceId(forRelativePath: relativePath),
           serviceId == "wix" || serviceConfig(forServiceId: serviceId, in: defaults)?.service == "wix" {
            return "wix-\(normalizedStatus)"
        }
        return normalizedStatus
    }

    public static func normalizeStatus(_ status: String) -> String {
        switch status {
        case "synced", "syncing", "conflict", "error":
            return status
        case "modified":
            return "syncing"
        default:
            return ""
        }
    }

    public static func normalizeRelativePath(_ relativePath: String) -> String {
        relativePath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "//", with: "/")
    }

    private static func stringValue(forKey key: String, defaults: UserDefaults?) -> String? {
        if let value = defaults?.string(forKey: key), !value.isEmpty {
            return value
        }
        return preferencesDictionary()[key] as? String
    }

    private static func boolValue(forKey key: String, defaults: UserDefaults?) -> Bool? {
        if let value = defaults?.object(forKey: key) as? Bool {
            return value
        }
        return preferencesDictionary()[key] as? Bool
    }

    private static func dataValue(forKey key: String, defaults: UserDefaults?) -> Data? {
        if let value = defaults?.data(forKey: key), !value.isEmpty {
            return value
        }
        return preferencesDictionary()[key] as? Data
    }

    private static func preferencesDictionary() -> [String: Any] {
        guard let preferencesURL = preferencesPlistURL(),
              let data = try? Data(contentsOf: preferencesURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private static func persist(_ value: Any?, forKey key: String, defaults: UserDefaults?) {
        if let value {
            defaults?.set(value, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }

        mutatePreferencesDictionary { dictionary in
            dictionary[key] = value
        }
    }

    private static func clearValues(withPrefix prefix: String, defaults: UserDefaults?) {
        let persistedKeys: [String]
        if let defaults {
            persistedKeys = Array(defaults.dictionaryRepresentation().keys)
        } else {
            persistedKeys = []
        }
        for key in persistedKeys where key.hasPrefix(prefix) {
            defaults?.removeObject(forKey: key)
        }

        mutatePreferencesDictionary { dictionary in
            for key in dictionary.keys where key.hasPrefix(prefix) {
                dictionary.removeValue(forKey: key)
            }
        }
    }

    private static func mutatePreferencesDictionary(_ mutate: (inout [String: Any]) -> Void) {
        guard let preferencesURL = preferencesPlistURL() else { return }

        var dictionary = preferencesDictionary()
        mutate(&dictionary)

        do {
            let parentDirectory = preferencesURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            try data.write(to: preferencesURL, options: .atomic)
        } catch {
            NSLog("FinderBadgeSupport failed writing shared preferences at %@: %@", preferencesURL.path, error.localizedDescription)
        }
    }

    private static func preferencesPlistURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent("Library/Preferences/\(appGroupIdentifier).plist", isDirectory: false)
    }
}
#endif
