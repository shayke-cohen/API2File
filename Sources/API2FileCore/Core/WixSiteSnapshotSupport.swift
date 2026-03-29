import Foundation

public struct SiteSnapshotManifest: Codable, Sendable, Equatable {
    public let generatedAt: String
    public let entries: [SiteSnapshotManifestEntry]

    public init(generatedAt: String, entries: [SiteSnapshotManifestEntry]) {
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

public struct SiteSnapshotManifestEntry: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let sourceURL: String
    public let finalURL: String
    public let title: String
    public let capturedAt: String
    public let status: String
    public let htmlPath: String?
    public let screenshotPath: String?
    public let error: String?

    public init(
        id: String,
        label: String,
        sourceURL: String,
        finalURL: String,
        title: String,
        capturedAt: String,
        status: String,
        htmlPath: String?,
        screenshotPath: String?,
        error: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.title = title
        self.capturedAt = capturedAt
        self.status = status
        self.htmlPath = htmlPath
        self.screenshotPath = screenshotPath
        self.error = error
    }
}

public struct WixSiteSnapshotTarget: Sendable, Equatable {
    public let id: String
    public let label: String
    public let url: String

    public init(id: String, label: String, url: String) {
        self.id = id
        self.label = label
        self.url = url
    }
}

public enum WixSiteSnapshotSupport {
    public static let catalogResourceName = "site-urls"
    public static let catalogRelativePath = "site/site-urls.json"
    public static let derivedDirectory = ".api2file/derived/site-snapshots"
    public static let manifestRelativePath = ".api2file/derived/site-snapshots/manifest.json"
    public static let exposedDirectory = "Snapshots"
    public static let exposedManifestRelativePath = "Snapshots/manifest.json"
    public static let exposedReadmeRelativePath = "Snapshots/README.md"

    public static func buildSiteURLCatalog(
        publishedResponse: [String: Any],
        editorResponse: [String: Any],
        capturedAt: Date = Date()
    ) -> [String: Any] {
        let publishedURLs = extractPublishedURLs(from: publishedResponse)
        let primaryURL = publishedURLs.first(where: { $0.isPrimary })?.url ?? publishedURLs.first?.url ?? ""
        let secondaryURLs = publishedURLs
            .map(\.url)
            .filter { !$0.isEmpty && $0 != primaryURL }

        return [
            "published": publishedResponse,
            "editor": editorResponse,
            "primaryUrl": primaryURL,
            "secondaryUrls": secondaryURLs,
            "capturedAt": iso8601String(capturedAt),
        ]
    }

    public static func snapshotTargets(config: AdapterConfig, catalogRecord: [String: Any]) -> [WixSiteSnapshotTarget] {
        guard let configuredSiteURL = config.siteUrl,
              let configuredSite = URL(string: configuredSiteURL),
              !configuredSiteURL.isEmpty else {
            return []
        }

        let publishedURLs = extractPublishedURLs(
            from: (catalogRecord["published"] as? [String: Any]) ?? [:]
        ).map(\.url)
        let canonicalBase = canonicalBaseURL(configuredSiteURL: configuredSiteURL, catalogRecord: catalogRecord)
        let resourceHosts = config.resources.compactMap { resource in
            resource.siteUrl.flatMap { URL(string: $0)?.host?.lowercased() }
        }
        let allowedHosts = Set(
            publishedURLs.compactMap { URL(string: $0)?.host?.lowercased() } +
            [configuredSite.host?.lowercased(), URL(string: canonicalBase)?.host?.lowercased()].compactMap { $0 } +
            resourceHosts
        )

        var seenURLs: Set<String> = []
        var targets: [WixSiteSnapshotTarget] = []

        func addTarget(id: String, label: String, urlString: String) {
            guard let normalized = normalizeTargetURL(
                urlString,
                configuredSiteURL: configuredSiteURL,
                canonicalBaseURL: canonicalBase,
                allowedHosts: allowedHosts
            ) else {
                return
            }
            guard seenURLs.insert(normalized).inserted else { return }
            let normalizedID = id == "home" ? id : targetID(for: normalized, fallback: id)
            targets.append(WixSiteSnapshotTarget(id: normalizedID, label: label, url: normalized))
        }

        addTarget(id: "home", label: "home", urlString: canonicalBase)

        for resource in config.resources {
            guard let siteURL = resource.siteUrl, !siteURL.isEmpty else { continue }

            let targetID = targetID(for: siteURL, fallback: resource.name)
            addTarget(id: targetID, label: resource.name, urlString: siteURL)
        }

        return targets
    }

    public static func manifestFilePaths(_ manifest: SiteSnapshotManifest) -> [String] {
        var paths = [manifestRelativePath]
        for entry in manifest.entries {
            if let htmlPath = entry.htmlPath { paths.append(htmlPath) }
            if let screenshotPath = entry.screenshotPath { paths.append(screenshotPath) }
        }
        return Array(Set(paths)).sorted()
    }

    public static func exposedManifestFilePaths(_ manifest: SiteSnapshotManifest) -> [String] {
        var paths = [exposedManifestRelativePath, exposedReadmeRelativePath]
        for entry in manifest.entries {
            if let htmlPath = entry.htmlPath {
                paths.append(exposedPath(forDerivedPath: htmlPath))
            }
            if let screenshotPath = entry.screenshotPath {
                paths.append(exposedPath(forDerivedPath: screenshotPath))
            }
        }
        return Array(Set(paths)).sorted()
    }

    public static func loadManifest(from serviceDir: URL) -> SiteSnapshotManifest? {
        let manifestURL = serviceDir.appendingPathComponent(manifestRelativePath)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(SiteSnapshotManifest.self, from: data)
    }

    public static func saveManifest(_ manifest: SiteSnapshotManifest, to serviceDir: URL) throws {
        let manifestURL = serviceDir.appendingPathComponent(manifestRelativePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    public static func htmlPath(for targetID: String) -> String {
        "\(derivedDirectory)/\(targetID).rendered.html"
    }

    public static func screenshotPath(for targetID: String) -> String {
        "\(derivedDirectory)/\(targetID).png"
    }

    public static func exposedPath(forDerivedPath derivedPath: String) -> String {
        guard derivedPath.hasPrefix("\(derivedDirectory)/") else {
            return "\(exposedDirectory)/\(URL(fileURLWithPath: derivedPath).lastPathComponent)"
        }
        return derivedPath.replacingOccurrences(of: "\(derivedDirectory)/", with: "\(exposedDirectory)/")
    }

    public static func exposedManifest(from manifest: SiteSnapshotManifest) -> SiteSnapshotManifest {
        SiteSnapshotManifest(
            generatedAt: manifest.generatedAt,
            entries: manifest.entries.map { entry in
                SiteSnapshotManifestEntry(
                    id: entry.id,
                    label: entry.label,
                    sourceURL: entry.sourceURL,
                    finalURL: entry.finalURL,
                    title: entry.title,
                    capturedAt: entry.capturedAt,
                    status: entry.status,
                    htmlPath: entry.htmlPath.map(exposedPath(forDerivedPath:)),
                    screenshotPath: entry.screenshotPath.map(exposedPath(forDerivedPath:)),
                    error: entry.error
                )
            }
        )
    }

    public static func exposedReadme() -> String {
        """
        # Snapshots

        This folder exposes generated, read-only rendered page snapshots for agents and review.

        - These files are derived from the hidden originals in `.api2file/derived/site-snapshots/`.
        - They are not canonical API2File sync resources.
        - Edits here do not push back to Wix and may be replaced on the next sync.
        """
    }

    public static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct PublishedURL {
        let url: String
        let isPrimary: Bool
    }

    private static func extractPublishedURLs(from response: [String: Any]) -> [PublishedURL] {
        let candidates: [[String: Any]]
        if let urls = response["urls"] as? [[String: Any]] {
            candidates = urls
        } else if let urls = response["publishedSiteUrls"] as? [[String: Any]] {
            candidates = urls
        } else if let urls = response["published"] as? [[String: Any]] {
            candidates = urls
        } else {
            candidates = []
        }

        return candidates.compactMap { item in
            guard let url = (item["url"] as? String) ?? (item["publishedUrl"] as? String),
                  !url.isEmpty else {
                return nil
            }

            let isPrimary =
                boolValue(item["isPrimary"]) ??
                boolValue(item["primary"]) ??
                boolValue(item["main"]) ??
                false

            return PublishedURL(url: url, isPrimary: isPrimary)
        }
    }

    private static func canonicalBaseURL(configuredSiteURL: String, catalogRecord: [String: Any]) -> String {
        if let primary = catalogRecord["primaryUrl"] as? String, !primary.isEmpty {
            return primary
        }
        return configuredSiteURL
    }

    private static func normalizeTargetURL(
        _ urlString: String,
        configuredSiteURL: String,
        canonicalBaseURL: String,
        allowedHosts: Set<String>
    ) -> String? {
        guard let url = URL(string: urlString),
              let configuredBase = URL(string: configuredSiteURL),
              let canonicalBase = URL(string: canonicalBaseURL),
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let currentPath = components?.path ?? "/"
        let shouldCanonicalizeHost =
            host == configuredBase.host?.lowercased() ||
            host == canonicalBase.host?.lowercased()

        if shouldCanonicalizeHost {
            components?.path = remapPath(
                urlPath: currentPath,
                configuredBasePath: configuredBase.path,
                canonicalBasePath: canonicalBase.path
            )
            components?.scheme = canonicalBase.scheme
            components?.host = canonicalBase.host
            components?.port = canonicalBase.port
        }
        guard let normalized = components?.url?.absoluteString else {
            return nil
        }
        if normalized.hasSuffix("/") && URL(string: normalized)?.path == "/" {
            return String(normalized.dropLast())
        }
        return normalized
    }

    private static func targetID(for urlString: String, fallback: String) -> String {
        guard let url = URL(string: urlString) else { return slugify(fallback) }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard !components.isEmpty else { return "home" }
        return slugify(components.joined(separator: "-"))
    }

    private static func remapPath(urlPath: String, configuredBasePath: String, canonicalBasePath: String) -> String {
        let configured = normalizedBasePath(configuredBasePath)
        let canonical = normalizedBasePath(canonicalBasePath)
        let current = normalizedBasePath(urlPath)

        guard configured != "/" else { return current }

        if current == configured {
            return canonical
        }

        let configuredPrefix = configured.hasSuffix("/") ? configured : configured + "/"
        guard current.hasPrefix(configuredPrefix) else { return current }

        let suffix = String(current.dropFirst(configured.count))
        return joinPaths(base: canonical, suffix: suffix)
    }

    private static func normalizedBasePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        let withoutTrailingSlash = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return withoutTrailingSlash.hasPrefix("/") ? withoutTrailingSlash : "/" + withoutTrailingSlash
    }

    private static func joinPaths(base: String, suffix: String) -> String {
        let normalizedBase = normalizedBasePath(base)
        let normalizedSuffix = suffix.hasPrefix("/") ? suffix : "/" + suffix
        if normalizedBase == "/" { return normalizedSuffix }
        return normalizedBase + normalizedSuffix
    }

    private static func slugify(_ value: String) -> String {
        let lowercased = value.lowercased()
        let replaced = lowercased.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "page" : trimmed
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(number) {
                return number.boolValue
            }
            return nil
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" { return true }
            if normalized == "false" { return false }
            return nil
        default:
            return nil
        }
    }
}
