import Foundation

public enum ServiceIdentity {
    public static func normalizedServiceID(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        var normalized = ""
        var previousWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                normalized.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                normalized.append("-")
                previousWasSeparator = true
            }
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public static func keychainKey(
        for serviceID: String,
        adapterService: String,
        templateKeychainKey: String
    ) -> String {
        guard serviceID != adapterService else { return templateKeychainKey }

        let adapterPrefix = "api2file.\(adapterService)"
        let servicePrefix = "api2file.\(serviceID)"

        if templateKeychainKey == adapterPrefix {
            return servicePrefix
        }

        if templateKeychainKey.hasPrefix(adapterPrefix + ".") {
            let suffix = templateKeychainKey.dropFirst(adapterPrefix.count)
            return servicePrefix + String(suffix)
        }

        return "\(servicePrefix).key"
    }

    public static func runtimeDisplayName(for config: AdapterConfig, serviceID: String) -> String {
        guard serviceID != config.service else { return config.displayName }
        let suffix = "(\(serviceID))"
        if config.displayName.contains(suffix) {
            return config.displayName
        }
        return "\(config.displayName) \(suffix)"
    }

    public static func installedAdapterJSON(
        template: AdapterTemplate,
        serviceID: String,
        extraFieldValues: [String: String],
        customizeConfig: ((inout [String: Any]) -> Void)? = nil
    ) throws -> String {
        var configJSON = template.rawJSON
        for field in template.config.setupFields ?? [] {
            let value = extraFieldValues[field.key] ?? ""
            configJSON = configJSON.replacingOccurrences(of: field.templateKey, with: value)
        }

        let data = Data(configJSON.utf8)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "API2FileCore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid adapter JSON"]
            )
        }

        if var auth = json["auth"] as? [String: Any] {
            auth["keychainKey"] = keychainKey(
                for: serviceID,
                adapterService: template.config.service,
                templateKeychainKey: template.config.auth.keychainKey
            )
            json["auth"] = auth
        }

        customizeConfig?(&json)

        let updatedData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: updatedData, as: UTF8.self)
    }
}
