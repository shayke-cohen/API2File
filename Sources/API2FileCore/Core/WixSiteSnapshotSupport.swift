import Foundation

struct SiteSnapshotManifestEntry: Codable, Equatable {
    let id: String
    let label: String
    let sourceURL: String
    let finalURL: String
    let title: String
    let capturedAt: String
    let status: String
    let htmlPath: String?
    let screenshotPath: String?
    let error: String?

    init(
        id: String,
        label: String,
        sourceURL: String,
        finalURL: String,
        title: String,
        capturedAt: String,
        status: String,
        htmlPath: String? = nil,
        screenshotPath: String? = nil,
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

struct SiteSnapshotManifest: Codable, Equatable {
    let generatedAt: String
    let entries: [SiteSnapshotManifestEntry]
}

enum WixSiteSnapshotSupport {
    static let catalogResourceName = "site-urls"
    static let catalogRelativePath = "site/site-urls.json"
    static let derivedDirectory = ".api2file/derived/site-snapshots"
    static let exposedDirectory = "Snapshots"
    static let exposedManifestRelativePath = "Snapshots/manifest.json"
    static let exposedReadmeRelativePath = "Snapshots/README.md"
    static let manifestRelativePath = ".api2file/derived/site-snapshots/manifest.json"

    struct SnapshotTarget: Equatable {
        let id: String
        let label: String
        let url: String
    }

    static func buildSiteURLCatalog(
        publishedResponse: [String: Any],
        editorResponse: [String: Any],
        capturedAt: Date = Date()
    ) -> [String: Any] {
        var pages: [[String: String]] = []
        let timestamp = iso8601String(capturedAt)

        func appendPage(id: String, label: String, url: String) {
            guard !url.isEmpty else { return }
            pages.append([
                "id": id,
                "label": label,
                "url": url,
            ])
        }

        let publishedURLs = publishedResponse["urls"] as? [[String: Any]] ?? []
        if !publishedURLs.isEmpty {
            for (index, item) in publishedURLs.enumerated() {
                let url = item["url"] as? String ?? item["formattedUrl"] as? String ?? item["link"] as? String ?? ""
                let id = normalizedSnapshotID(item["id"] as? String ?? item["slug"] as? String ?? "page-\(index)")
                let label = item["title"] as? String ?? item["name"] as? String ?? item["slug"] as? String ?? "Page \(index + 1)"
                appendPage(id: id, label: label, url: url)
            }
        }

        if let editorUrls = editorResponse["urls"] as? [[String: Any]] {
            for (index, item) in editorUrls.enumerated() {
                let url = item["url"] as? String ?? item["formattedUrl"] as? String ?? item["link"] as? String ?? ""
                let id = normalizedSnapshotID("editor-\(item["id"] as? String ?? item["slug"] as? String ?? "\(index)")")
                let label = item["title"] as? String ?? item["name"] as? String ?? "Editor \(index + 1)"
                appendPage(id: id, label: label, url: url)
            }
        }

        let primaryPublishedURL = publishedURLs.first(where: {
            ($0["isPrimary"] as? Bool) == true
        }).flatMap { $0["url"] as? String ?? $0["formattedUrl"] as? String ?? $0["link"] as? String }

        let siteURL =
            primaryPublishedURL
            ?? (publishedResponse["baseUrl"] as? String)
            ?? (publishedResponse["siteUrl"] as? String)
            ?? (editorResponse["siteUrl"] as? String)
            ?? pages.first?["url"]
            ?? ""

        return [
            "primaryUrl": siteURL,
            "siteUrl": siteURL,
            "capturedAt": timestamp,
            "published": publishedResponse,
            "editor": editorResponse,
            "pages": deduplicatedPages(pages),
        ]
    }

    static func snapshotTargets(config: AdapterConfig, catalogRecord: [String: Any]) -> [SnapshotTarget] {
        var targets: [SnapshotTarget] = []
        let fallbackSiteURL = catalogRecord["primaryUrl"] as? String ?? config.siteUrl ?? catalogRecord["siteUrl"] as? String ?? ""

        if !fallbackSiteURL.isEmpty {
            targets.append(SnapshotTarget(id: "home", label: "home", url: fallbackSiteURL))
        }

        for resource in config.resources {
            let candidateURL: String?
            if let siteURL = resource.siteUrl, !siteURL.isEmpty {
                candidateURL = publishedResourceURL(
                    resourceURL: siteURL,
                    configuredSiteURL: config.siteUrl,
                    publishedSiteURL: fallbackSiteURL
                )
            } else if let dashboardURL = resource.dashboardUrl,
                      shouldSnapshotNonPublishedURL(dashboardURL, resourceName: resource.name) {
                candidateURL = dashboardURL
            } else {
                candidateURL = nil
            }

            guard let candidateURL, !candidateURL.isEmpty else { continue }
            guard canonicalURLString(candidateURL) != canonicalURLString(fallbackSiteURL) else { continue }
            targets.append(
                SnapshotTarget(
                    id: normalizedSnapshotID(snapshotIdentifier(for: resource, primaryURL: fallbackSiteURL, candidateURL: candidateURL)),
                    label: resource.name,
                    url: candidateURL
                )
            )
        }

        return uniqueTargets(targets)
    }

    static func htmlPath(for id: String) -> String {
        "\(derivedDirectory)/\(normalizedSnapshotID(id)).rendered.html"
    }

    static func screenshotPath(for id: String) -> String {
        "\(derivedDirectory)/\(normalizedSnapshotID(id)).png"
    }

    static func manifestFilePaths(_ manifest: SiteSnapshotManifest) -> [String] {
        [manifestRelativePath] + manifest.entries.flatMap { entry in
            [entry.htmlPath, entry.screenshotPath].compactMap { $0 }
        }
    }

    static func exposedManifestFilePaths(_ manifest: SiteSnapshotManifest) -> [String] {
        [exposedManifestRelativePath, exposedReadmeRelativePath] + manifest.entries.flatMap { entry in
            [entry.htmlPath, entry.screenshotPath]
                .compactMap { $0 }
                .map(exposedPath(forDerivedPath:))
        }
    }

    static func exposedPath(forDerivedPath path: String) -> String {
        path.replacingOccurrences(of: derivedDirectory + "/", with: exposedDirectory + "/")
    }

    static func exposedReadme() -> String {
        """
        # Rendered Site Pages

        These files are generated from the Wix site URL catalog. HTML and screenshot artifacts are derived outputs and are excluded from push flows.
        """
    }

    static func exposedManifest(from manifest: SiteSnapshotManifest) -> SiteSnapshotManifest {
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

    static func loadManifest(from serviceDir: URL) -> SiteSnapshotManifest? {
        let url = serviceDir.appendingPathComponent(manifestRelativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiteSnapshotManifest.self, from: data)
    }

    static func saveManifest(_ manifest: SiteSnapshotManifest, to serviceDir: URL) throws {
        let url = serviceDir.appendingPathComponent(manifestRelativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    static func iso8601String(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func normalizedSnapshotID(_ rawValue: String) -> String {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? "page" : normalized
    }

    private static func uniqueTargets(_ targets: [SnapshotTarget]) -> [SnapshotTarget] {
        var seenURLs = Set<String>()
        return targets.filter { target in
            let urlKey = canonicalURLString(target.url)
            guard seenURLs.insert(urlKey).inserted else { return false }
            return true
        }
    }

    private static func deduplicatedPages(_ pages: [[String: String]]) -> [[String: String]] {
        var seen = Set<String>()
        return pages.filter { page in
            let key = canonicalURLString(page["url"] ?? page["id"] ?? UUID().uuidString)
            guard seen.insert(key).inserted else { return false }
            return true
        }
    }

    private static func snapshotIdentifier(for resource: ResourceConfig, primaryURL: String, candidateURL: String) -> String {
        guard let primary = URL(string: primaryURL),
              let candidate = URL(string: candidateURL),
              let primaryHost = primary.host,
              let candidateHost = candidate.host,
              primaryHost == candidateHost else {
            return resource.name
        }

        let primaryPath = primary.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = candidate.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if candidatePath.isEmpty || candidatePath == primaryPath {
            return resource.name
        }
        return candidatePath
    }

    private static func publishedResourceURL(
        resourceURL: String,
        configuredSiteURL: String?,
        publishedSiteURL: String
    ) -> String {
        guard let configuredSiteURL, !configuredSiteURL.isEmpty,
              let configured = URL(string: configuredSiteURL),
              let resource = URL(string: resourceURL),
              let published = URL(string: publishedSiteURL),
              canonicalURLString(resourceURL).hasPrefix(canonicalURLString(configuredSiteURL)) else {
            return resourceURL
        }

        let configuredPath = configured.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let resourcePath = resource.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix: String
        if configuredPath.isEmpty {
            suffix = resourcePath
        } else if resourcePath == configuredPath {
            suffix = ""
        } else if resourcePath.hasPrefix(configuredPath + "/") {
            suffix = String(resourcePath.dropFirst(configuredPath.count + 1))
        } else {
            suffix = resourcePath
        }

        var components = URLComponents()
        components.scheme = published.scheme
        components.host = published.host
        components.port = published.port
        let publishedPath = published.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = ([publishedPath].filter { !$0.isEmpty } + [suffix].filter { !$0.isEmpty }).joined(separator: "/")
        components.path = "/" + joinedPath
        return components.string ?? resourceURL
    }

    private static func shouldSnapshotNonPublishedURL(_ rawValue: String, resourceName: String) -> Bool {
        guard let host = URL(string: rawValue)?.host?.lowercased() else { return false }
        if host.contains("editor.wix.com") {
            return true
        }
        if host.contains("manage.wix.com") {
            let normalizedName = resourceName.lowercased()
            return normalizedName.contains("dashboard") || normalizedName.contains("editor")
        }
        return false
    }

    private static func canonicalURLString(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else {
            return rawValue
        }
        components.fragment = nil
        if let path = components.path.removingPercentEncoding, path != "/" {
            components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !components.path.hasPrefix("/") && !components.path.isEmpty {
                components.path = "/" + components.path
            }
        }
        let string = components.string ?? rawValue
        if string.hasSuffix("/") {
            return String(string.dropLast())
        }
        return string
    }
}
