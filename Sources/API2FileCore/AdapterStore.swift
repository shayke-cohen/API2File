import Foundation

/// Manages user-editable adapter definitions in ~/.api2file/adapters/.
///
/// On first launch, all bundled adapters are seeded there. On subsequent launches,
/// only new adapters are added — existing user files are never overwritten. If a
/// bundled adapter ships a newer version, it lands as `{id}.adapter_new.json` so
/// the user can review the diff and decide what to keep.
public actor AdapterStore {

    public static let shared = AdapterStore()

    public static let userAdaptersURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".api2file/adapters")
    }()

    private init() {}

    // MARK: - Seeding

    /// Seeds bundled adapters into the user folder. Safe to call every launch.
    public func seedIfNeeded() throws {
        let fm = FileManager.default
        let dir = AdapterStore.userAdaptersURL

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard let adaptersDir = Bundle.module.url(forResource: "Adapters", withExtension: nil, subdirectory: "Resources") else {
            return
        }

        let contents = try fm.contentsOfDirectory(at: adaptersDir, includingPropertiesForKeys: nil)
        let bundledAdapters = contents.filter { $0.lastPathComponent.hasSuffix(".adapter.json") }
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
        let dir = AdapterStore.userAdaptersURL

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
            at: AdapterStore.userAdaptersURL,
            includingPropertiesForKeys: nil
        ) else { return false }
        return contents.contains { $0.lastPathComponent.hasSuffix(".adapter_new.json") }
    }

    // MARK: - Private

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
