import Foundation

/// Stored relationship between a user-facing file and its canonical/derived siblings.
public struct FileLinkEntry: Codable, Sendable, Equatable {
    public let resourceName: String
    public let mappingStrategy: MappingStrategy
    public var remoteId: String?
    public var userPath: String
    public var canonicalPath: String
    public var derivedPaths: [String]
    public var updatedAt: Date

    public init(
        resourceName: String,
        mappingStrategy: MappingStrategy,
        remoteId: String? = nil,
        userPath: String,
        canonicalPath: String,
        derivedPaths: [String] = [],
        updatedAt: Date = Date()
    ) {
        self.resourceName = resourceName
        self.mappingStrategy = mappingStrategy
        self.remoteId = remoteId
        self.userPath = userPath
        self.canonicalPath = canonicalPath
        self.derivedPaths = derivedPaths
        self.updatedAt = updatedAt
    }
}

public struct FileLinkIndex: Codable, Sendable, Equatable {
    public var links: [FileLinkEntry]

    public init(links: [FileLinkEntry] = []) {
        self.links = links
    }
}

/// Persists explicit file-to-file relationships in `.api2file/file-links.json`.
public enum FileLinkManager {
    public static func linksFileURL(in serviceDir: URL) -> URL {
        serviceDir.appendingPathComponent(".api2file/file-links.json")
    }

    public static func load(from serviceDir: URL) throws -> FileLinkIndex {
        let url = linksFileURL(in: serviceDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileLinkIndex()
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FileLinkIndex.self, from: data)
    }

    public static func save(_ index: FileLinkIndex, to serviceDir: URL) throws {
        let url = linksFileURL(in: serviceDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func upsert(_ entry: FileLinkEntry, in serviceDir: URL) throws {
        var index = try load(from: serviceDir)
        let normalized = normalizedEntry(entry)

        if let existingIndex = index.links.firstIndex(where: { matches($0, normalized) }) {
            index.links[existingIndex] = merged(index.links[existingIndex], with: normalized)
        } else {
            index.links.append(normalized)
        }

        index.links.sort { lhs, rhs in
            if lhs.userPath == rhs.userPath {
                return lhs.canonicalPath < rhs.canonicalPath
            }
            return lhs.userPath < rhs.userPath
        }

        try save(index, to: serviceDir)
    }

    public static func replace(_ entry: FileLinkEntry, in serviceDir: URL) throws {
        var index = try load(from: serviceDir)
        let normalized = normalizedEntry(entry)

        if let existingIndex = index.links.firstIndex(where: { matches($0, normalized) }) {
            index.links[existingIndex] = normalized
        } else {
            index.links.append(normalized)
        }

        index.links.sort { lhs, rhs in
            if lhs.userPath == rhs.userPath {
                return lhs.canonicalPath < rhs.canonicalPath
            }
            return lhs.userPath < rhs.userPath
        }

        try save(index, to: serviceDir)
    }

    public static func removeLinks(referencingAny paths: [String], in serviceDir: URL) throws {
        let normalizedPaths = Set(paths.map(normalizePath))
        guard !normalizedPaths.isEmpty else { return }

        var index = try load(from: serviceDir)
        index.links.removeAll { link in
            normalizedPaths.contains(normalizePath(link.userPath)) ||
            normalizedPaths.contains(normalizePath(link.canonicalPath)) ||
            !normalizedPaths.isDisjoint(with: Set(link.derivedPaths.map(normalizePath)))
        }
        try save(index, to: serviceDir)
    }

    public static func linkForUserPath(_ userPath: String, in serviceDir: URL) throws -> FileLinkEntry? {
        let normalizedUserPath = normalizePath(userPath)
        return try load(from: serviceDir).links.first { normalizePath($0.userPath) == normalizedUserPath }
    }

    public static func linkForCanonicalPath(_ canonicalPath: String, in serviceDir: URL) throws -> FileLinkEntry? {
        let normalizedCanonicalPath = normalizePath(canonicalPath)
        return try load(from: serviceDir).links.first { normalizePath($0.canonicalPath) == normalizedCanonicalPath }
    }

    private static func matches(_ existing: FileLinkEntry, _ incoming: FileLinkEntry) -> Bool {
        if let remoteId = incoming.remoteId, !remoteId.isEmpty,
           let existingRemoteId = existing.remoteId, !existingRemoteId.isEmpty,
           existing.resourceName == incoming.resourceName && existingRemoteId == remoteId {
            return true
        }

        if normalizePath(existing.userPath) == normalizePath(incoming.userPath) {
            return true
        }

        if normalizePath(existing.canonicalPath) == normalizePath(incoming.canonicalPath) {
            return true
        }

        let existingDerived = Set(existing.derivedPaths.map(normalizePath))
        let incomingDerived = Set(incoming.derivedPaths.map(normalizePath))
        return !existingDerived.isDisjoint(with: incomingDerived)
    }

    private static func merged(_ existing: FileLinkEntry, with incoming: FileLinkEntry) -> FileLinkEntry {
        let derived = Array(Set(existing.derivedPaths.map(normalizePath) + incoming.derivedPaths.map(normalizePath))).sorted()
        return FileLinkEntry(
            resourceName: incoming.resourceName,
            mappingStrategy: incoming.mappingStrategy,
            remoteId: normalizedRemoteId(incoming.remoteId) ?? normalizedRemoteId(existing.remoteId),
            userPath: normalizePath(incoming.userPath),
            canonicalPath: normalizePath(incoming.canonicalPath),
            derivedPaths: derived,
            updatedAt: incoming.updatedAt
        )
    }

    private static func normalizedEntry(_ entry: FileLinkEntry) -> FileLinkEntry {
        FileLinkEntry(
            resourceName: entry.resourceName,
            mappingStrategy: entry.mappingStrategy,
            remoteId: normalizedRemoteId(entry.remoteId),
            userPath: normalizePath(entry.userPath),
            canonicalPath: normalizePath(entry.canonicalPath),
            derivedPaths: Array(Set(entry.derivedPaths.map(normalizePath))).sorted(),
            updatedAt: entry.updatedAt
        )
    }

    private static func normalizedRemoteId(_ remoteId: String?) -> String? {
        guard let remoteId else { return nil }
        let trimmed = remoteId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizePath(_ path: String) -> String {
        path.replacingOccurrences(of: "//", with: "/")
    }
}
