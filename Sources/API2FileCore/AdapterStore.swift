import Foundation

/// Manages user-editable adapter definitions in ~/.api2file/adapters/.
///
/// On first launch, all bundled adapters are seeded there. On subsequent launches,
/// only new adapters are added — existing user files are never overwritten. If a
/// bundled adapter ships a newer version, it lands as `{id}.adapter_new.json` so
/// the user can review the diff and decide what to keep.
public actor AdapterStore {

    public static let shared = AdapterStore()

    public static var userAdaptersURL: URL {
        StorageLocations.current.adaptersDirectory
    }

    private let storageLocations: StorageLocations

    public init(storageLocations: StorageLocations = .current) {
        self.storageLocations = storageLocations
    }

    // MARK: - Seeding

    /// Seeds bundled adapters into the user folder. Safe to call every launch.
    public func seedIfNeeded() throws {
        let fm = FileManager.default
        let dir = storageLocations.adaptersDirectory

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let bundledAdapters = bundledAdapterURLs()
        let decoder = JSONDecoder()

        for bundledURL in bundledAdapters {
            let filename = bundledURL.lastPathComponent
            let userFileURL = dir.appendingPathComponent(filename)

            guard let bundledData = try? Data(contentsOf: bundledURL) else { continue }

            if !fm.fileExists(atPath: userFileURL.path) {
                // New adapter — copy it to user folder
                try bundledData.write(to: userFileURL)
            } else {
                // Already exists — check if bundled version is newer
                guard
                    let userData = try? Data(contentsOf: userFileURL),
                    let bundledConfig = try? decoder.decode(AdapterConfig.self, from: bundledData),
                    let userConfig = try? decoder.decode(AdapterConfig.self, from: userData),
                    isNewer(bundledConfig.version, than: userConfig.version)
                else { continue }

                // Write update hint alongside the user's file
                let stem = filename.replacingOccurrences(of: ".adapter.json", with: "")
                let newURL = dir.appendingPathComponent("\(stem).adapter_new.json")
                try? bundledData.write(to: newURL)
            }
        }
    }

    // MARK: - Loading

    /// Returns all visible adapter templates from the user folder.
    /// Files named `*.adapter_new.json` and adapters with `hidden: true` are excluded.
    public func loadAll() throws -> [AdapterTemplate] {
        let fm = FileManager.default
        let dir = storageLocations.adaptersDirectory

        guard fm.fileExists(atPath: dir.path) else { return [] }

        let contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let adapterFiles = contents
            .filter {
                $0.lastPathComponent.hasSuffix(".adapter.json") &&
                !$0.lastPathComponent.hasSuffix(".adapter_new.json")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        var templates: [AdapterTemplate] = []

        for url in adapterFiles {
            guard
                let data = try? Data(contentsOf: url),
                let config = try? decoder.decode(AdapterConfig.self, from: data),
                config.hidden != true
            else { continue }

            let rawJSON = String(data: data, encoding: .utf8) ?? ""
            templates.append(AdapterTemplate(config: config, rawJSON: rawJSON))
        }

        return templates
    }

    // MARK: - Updates

    /// Returns true if any `*.adapter_new.json` files exist in the user folder.
    public func hasPendingUpdates() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: storageLocations.adaptersDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.lastPathComponent.hasSuffix(".adapter_new.json") }
    }

    /// Refresh an installed service adapter from the newest available template when the
    /// bundled or user template version is newer than the deployed copy.
    /// Returns true when the deployed adapter.json was rewritten.
    public func refreshInstalledAdapterIfNeeded(serviceDir: URL) throws -> Bool {
        let deployedURL = serviceDir.appendingPathComponent(".api2file/adapter.json")
        guard FileManager.default.fileExists(atPath: deployedURL.path) else { return false }

        let deployedData = try Data(contentsOf: deployedURL)
        let decoder = JSONDecoder()
        let deployedConfig = try decoder.decode(AdapterConfig.self, from: deployedData)
        guard let template = try latestTemplate(for: deployedConfig.service) else { return false }
        guard isNewer(template.config.version, than: deployedConfig.version) else { return false }

        let refreshedConfig = try refreshedInstalledConfig(from: deployedConfig, template: template)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let refreshedData = try encoder.encode(refreshedConfig)

        if refreshedData == deployedData { return false }
        try refreshedData.write(to: deployedURL, options: .atomic)
        return true
    }

    // MARK: - Private

    private func latestTemplate(for serviceId: String) throws -> AdapterTemplate? {
        let bundled = try bundledTemplate(for: serviceId)
        let user = try userTemplate(for: serviceId)

        switch (bundled, user) {
        case (nil, nil):
            return nil
        case let (template?, nil), let (nil, template?):
            return template
        case let (bundled?, user?):
            return isNewer(bundled.config.version, than: user.config.version) ? bundled : user
        }
    }

    private func bundledTemplate(for serviceId: String) throws -> AdapterTemplate? {
        let targetName = "\(serviceId).adapter.json"
        guard let url = bundledAdapterURLs().first(where: { $0.lastPathComponent == targetName }) else { return nil }
        return try loadTemplate(at: url)
    }

    private func userTemplate(for serviceId: String) throws -> AdapterTemplate? {
        let url = storageLocations.adaptersDirectory.appendingPathComponent("\(serviceId).adapter.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try loadTemplate(at: url)
    }

    private func loadTemplate(at url: URL) throws -> AdapterTemplate {
        let data = try Data(contentsOf: url)
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let config = try JSONDecoder().decode(AdapterConfig.self, from: data)
        return AdapterTemplate(config: config, rawJSON: rawJSON)
    }

    private func bundledAdapterURLs() -> [URL] {
        let fm = FileManager.default
        let bundle = Bundle.module
        let root = bundle.resourceURL ?? bundle.bundleURL
        let candidateDirectories = [
            root.appendingPathComponent("Resources/Adapters", isDirectory: true),
            root.appendingPathComponent("Adapters", isDirectory: true),
            root,
        ]

        for directory in candidateDirectories where fm.fileExists(atPath: directory.path) {
            guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }

            let adapterFiles = contents
                .filter { $0.lastPathComponent.hasSuffix(".adapter.json") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            if !adapterFiles.isEmpty {
                return adapterFiles
            }
        }

        return []
    }

    private func refreshedInstalledConfig(from deployed: AdapterConfig, template: AdapterTemplate) throws -> AdapterConfig {
        let substitutions = try resolveSetupFieldValues(from: deployed, using: template.config.setupFields ?? [])

        var rawJSON = template.rawJSON
        for field in template.config.setupFields ?? [] {
            guard let value = substitutions[field.key] else {
                throw NSError(domain: "AdapterStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing value for setup field '\(field.key)' while refreshing adapter"
                ])
            }
            rawJSON = rawJSON.replacingOccurrences(of: field.templateKey, with: value)
        }

        let decoded = try JSONDecoder().decode(AdapterConfig.self, from: Data(rawJSON.utf8))
        return mergedConfig(templateConfig: decoded, deployedConfig: deployed)
    }

    private func resolveSetupFieldValues(from deployed: AdapterConfig, using fields: [SetupField]) throws -> [String: String] {
        var values: [String: String] = [:]

        for field in fields {
            if let value = extractSetupFieldValue(field.key, from: deployed) {
                values[field.key] = value
            } else {
                throw NSError(domain: "AdapterStore", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Could not recover setup field '\(field.key)' from deployed adapter"
                ])
            }
        }

        return values
    }

    private func extractSetupFieldValue(_ key: String, from config: AdapterConfig) -> String? {
        if let headerValue = config.globals?.headers?[key], !headerValue.isEmpty {
            return headerValue
        }

        switch key {
        case let k where k.hasSuffix("-site-url"):
            return config.siteUrl
        case "base-id":
            return airtableURLSegments(from: config).baseId
        case "table-name":
            return airtableURLSegments(from: config).tableName
        default:
            return nil
        }
    }

    private func airtableURLSegments(from config: AdapterConfig) -> (baseId: String?, tableName: String?) {
        let urls = config.resources.flatMap { resource -> [String] in
            var collected: [String] = []
            if let pullURL = resource.pull?.url { collected.append(pullURL) }
            if let createURL = resource.push?.create?.url { collected.append(createURL) }
            if let updateURL = resource.push?.update?.url { collected.append(updateURL) }
            if let deleteURL = resource.push?.delete?.url { collected.append(deleteURL) }
            if let dashboardURL = resource.dashboardUrl { collected.append(dashboardURL) }
            return collected
        }

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            let parts = url.pathComponents.filter { $0 != "/" }
            if let apiIndex = parts.firstIndex(of: "v0"), parts.count > apiIndex + 2 {
                return (parts[apiIndex + 1], parts[apiIndex + 2])
            }
            if let baseComponent = parts.first(where: { $0.hasPrefix("app") }) {
                let tableComponent = parts.drop { !$0.hasPrefix("app") }.dropFirst().first
                return (baseComponent, tableComponent)
            }
        }

        return (nil, nil)
    }

    private func mergedConfig(templateConfig: AdapterConfig, deployedConfig: AdapterConfig) -> AdapterConfig {
        let mergedGlobals = mergedGlobalsConfig(templateConfig.globals, deployedConfig.globals)
        let deployedResourcesByName = Dictionary(uniqueKeysWithValues: deployedConfig.resources.map { ($0.name, $0) })
        var mergedResources = templateConfig.resources.map { templateResource in
            guard let deployedResource = deployedResourcesByName[templateResource.name] else { return templateResource }
            return ResourceConfig(
                name: templateResource.name,
                description: templateResource.description ?? deployedResource.description,
                pull: templateResource.pull,
                push: templateResource.push,
                fileMapping: templateResource.fileMapping,
                children: templateResource.children,
                sync: templateResource.sync ?? deployedResource.sync,
                siteUrl: templateResource.siteUrl ?? deployedResource.siteUrl,
                dashboardUrl: templateResource.dashboardUrl ?? deployedResource.dashboardUrl
            )
        }
        let templateResourceNames = Set(templateConfig.resources.map(\.name))
        mergedResources.append(contentsOf: deployedConfig.resources.filter { !templateResourceNames.contains($0.name) })

        return AdapterConfig(
            service: templateConfig.service,
            displayName: templateConfig.displayName,
            version: templateConfig.version,
            auth: templateConfig.auth,
            globals: mergedGlobals,
            resources: mergedResources,
            icon: templateConfig.icon,
            wizardDescription: templateConfig.wizardDescription,
            setupFields: templateConfig.setupFields,
            hidden: templateConfig.hidden,
            enabled: deployedConfig.enabled ?? templateConfig.enabled,
            siteUrl: templateConfig.siteUrl ?? deployedConfig.siteUrl,
            dashboardUrl: templateConfig.dashboardUrl ?? deployedConfig.dashboardUrl
        )
    }

    private func mergedGlobalsConfig(_ template: GlobalsConfig?, _ deployed: GlobalsConfig?) -> GlobalsConfig? {
        guard template != nil || deployed != nil else { return nil }
        var headers = template?.headers ?? [:]
        for (key, value) in deployed?.headers ?? [:] where headers[key] == nil {
            headers[key] = value
        }
        return GlobalsConfig(
            baseUrl: template?.baseUrl ?? deployed?.baseUrl,
            headers: headers.isEmpty ? nil : headers,
            method: template?.method ?? deployed?.method
        )
    }

    private func isNewer(_ v1: String, than v2: String) -> Bool {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(parts1.count, parts2.count) {
            let a = i < parts1.count ? parts1[i] : 0
            let b = i < parts2.count ? parts2[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// MARK: - AdapterTemplate

/// A loaded adapter, pairing the decoded config with the original JSON text
/// (used verbatim when writing the per-service adapter.json after placeholder substitution).
public struct AdapterTemplate: Sendable {
    public let config: AdapterConfig
    /// Raw JSON string from the adapter file — contains placeholder tokens like `YOUR_SITE_ID_HERE`
    public let rawJSON: String
}
