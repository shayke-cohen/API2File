import Foundation

public actor ManagedWorkspaceManager {
    private let workspaceRoot: URL
    private let rejectionsRoot: URL

    public init(storageLocations: StorageLocations, config: GlobalConfig) {
        self.workspaceRoot = config.resolvedManagedWorkspaceFolder(using: storageLocations)
        self.rejectionsRoot = storageLocations.applicationSupportDirectory
            .appendingPathComponent("API2File", isDirectory: true)
            .appendingPathComponent("ManagedWorkspace", isDirectory: true)
            .appendingPathComponent("RejectedProposals", isDirectory: true)
    }

    public func rootURL() -> URL {
        workspaceRoot
    }

    public func serviceRootURL(serviceId: String) -> URL {
        workspaceRoot.appendingPathComponent(serviceId, isDirectory: true)
    }

    public func health(for serviceId: String) -> ManagedRuntimeHealth {
        let root = serviceRootURL(serviceId: serviceId)
        let exists = FileManager.default.fileExists(atPath: root.path)
        if exists {
            return ManagedRuntimeHealth(
                isAvailable: true,
                status: "materialized",
                detail: "Managed workspace is materialized under \(root.path)"
            )
        }
        return ManagedRuntimeHealth(
            isAvailable: true,
            status: "pending",
            detail: "Managed workspace root will be created on first successful sync."
        )
    }

    public func ensureServiceRoot(serviceId: String) throws -> URL {
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let root = serviceRootURL(serviceId: serviceId)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public func synchronizeVisibleFiles(serviceId: String, acceptedRoot: URL) throws {
        let serviceRoot = try ensureServiceRoot(serviceId: serviceId)
        let acceptedFiles = enumerateVisibleFiles(in: acceptedRoot)
        let currentFiles = enumerateVisibleFiles(in: serviceRoot)

        let acceptedRelativePaths = Set(acceptedFiles.map(\.relativePath))
        let currentRelativePaths = Set(currentFiles.map(\.relativePath))

        for file in acceptedFiles {
            let destination = serviceRoot.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existingData = try? Data(contentsOf: destination)
            if existingData != file.data {
                try file.data.write(to: destination, options: .atomic)
            }
        }

        let stalePaths = currentRelativePaths.subtracting(acceptedRelativePaths).sorted { $0.count > $1.count }
        for stalePath in stalePaths {
            let staleURL = serviceRoot.appendingPathComponent(stalePath)
            try? FileManager.default.removeItem(at: staleURL)
        }

        pruneEmptyDirectories(root: serviceRoot)
    }

    public func restoreAcceptedFile(serviceId: String, filePath: String, acceptedRoot: URL) throws {
        let serviceRoot = try ensureServiceRoot(serviceId: serviceId)
        let acceptedURL = acceptedRoot.appendingPathComponent(filePath)
        let workspaceURL = serviceRoot.appendingPathComponent(filePath)

        if FileManager.default.fileExists(atPath: acceptedURL.path) {
            let data = try Data(contentsOf: acceptedURL)
            try FileManager.default.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: workspaceURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
    }

    public func recordRejectedProposal(_ proposal: RejectedManagedProposal) throws {
        let fileURL = rejectionLogURL(serviceId: proposal.serviceId)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var proposals = try loadRejectedProposals(serviceId: proposal.serviceId)
        proposals.insert(proposal, at: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposals).write(to: fileURL, options: .atomic)
    }

    public func loadRejectedProposals(serviceId: String, limit: Int? = nil) throws -> [RejectedManagedProposal] {
        let fileURL = rejectionLogURL(serviceId: serviceId)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let proposals = try decoder.decode([RejectedManagedProposal].self, from: data)
        if let limit {
            return Array(proposals.prefix(limit))
        }
        return proposals
    }

    private func rejectionLogURL(serviceId: String) -> URL {
        rejectionsRoot.appendingPathComponent(serviceId, isDirectory: true).appendingPathComponent("rejections.json")
    }

    private func enumerateVisibleFiles(in root: URL) -> [(relativePath: String, data: Data)] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [(String, Data)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let resolvedFileURL = fileURL.resolvingSymlinksInPath()
            let relativePath = resolvedFileURL.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
            guard !relativePath.contains("/.") else { continue }
            guard !relativePath.hasPrefix(".") else { continue }
            guard let data = try? Data(contentsOf: resolvedFileURL) else { continue }
            files.append((relativePath, data))
        }
        return files
    }

    private func pruneEmptyDirectories(root: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        var directories: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                directories.append(url)
            }
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path), children.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}
