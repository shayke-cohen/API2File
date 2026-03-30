import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum ManagedWorkspaceMountNodeType: Sendable {
    case file
    case directory
}

public struct ManagedWorkspaceMountEntry: Sendable, Equatable {
    public let itemID: UInt64
    public let relativePath: String
    public let name: String
    public let type: ManagedWorkspaceMountNodeType
    public let size: UInt64

    public init(
        itemID: UInt64,
        relativePath: String,
        name: String,
        type: ManagedWorkspaceMountNodeType,
        size: UInt64
    ) {
        self.itemID = itemID
        self.relativePath = relativePath
        self.name = name
        self.type = type
        self.size = size
    }
}

public struct ManagedWorkspaceMountOpenModes: OptionSet, Sendable {
    public let rawValue: Int

    public static let read = ManagedWorkspaceMountOpenModes(rawValue: 1 << 0)
    public static let write = ManagedWorkspaceMountOpenModes(rawValue: 1 << 1)

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public protocol ManagedWorkspaceMountCommitClient: Sendable {
    func commit(relativePath: String, data: Data, sourceApplication: String?) async throws
    func remove(relativePath: String, sourceApplication: String?) async throws
}

public actor ManagedWorkspaceFileSystemStore {
    private enum NodeKind {
        case file
        case directory
    }

    private struct NodeState {
        var relativePath: String
        var kind: NodeKind
        var stagedData: Data?
        var dirty: Bool
        var writeOpen: Bool
        var ephemeral: Bool
        var commitPath: String?
    }

    private let workspaceRoot: URL
    private let commitClient: ManagedWorkspaceMountCommitClient
    private let sourceApplication: String?

    private var nextItemID: UInt64 = 10
    private var itemIDsByPath: [String: UInt64] = ["": 2]
    private var pathsByItemID: [UInt64: String] = [2: ""]
    private var statesByPath: [String: NodeState] = [:]

    public init(
        workspaceRoot: URL,
        commitClient: ManagedWorkspaceMountCommitClient,
        sourceApplication: String? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.commitClient = commitClient
        self.sourceApplication = sourceApplication
    }

    public func entry(for relativePath: String) throws -> ManagedWorkspaceMountEntry {
        let normalized = normalize(relativePath)
        if normalized.isEmpty {
            return try entryForResolvedPath("")
        }

        if let state = statesByPath[normalized] {
            return try entry(for: state, relativePath: normalized)
        }

        let url = workspaceRoot.appendingPathComponent(normalized)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw posixError(ENOENT, "File not found.")
        }
        return try entryForResolvedPath(normalized, isDirectory: isDirectory.boolValue)
    }

    public func entry(forItemID itemID: UInt64) throws -> ManagedWorkspaceMountEntry {
        guard let path = pathsByItemID[itemID] else {
            throw posixError(ENOENT, "Item not found.")
        }
        return try entry(for: path)
    }

    public func enumerateDirectory(at relativePath: String) throws -> [ManagedWorkspaceMountEntry] {
        let normalized = normalize(relativePath)
        if !normalized.isEmpty {
            let directoryEntry = try entry(for: normalized)
            guard directoryEntry.type == .directory else {
                throw posixError(ENOTDIR, "Not a directory.")
            }
        }

        var children: [String: ManagedWorkspaceMountEntry] = [:]
        let directoryURL = workspaceRoot.appendingPathComponent(normalized, isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: []
        ) {
            for url in urls {
                let childPath = normalize(pathJoin(normalized, url.lastPathComponent))
                children[url.lastPathComponent] = try? entryForResolvedPath(childPath)
            }
        }

        for (path, state) in statesByPath {
            guard parentPath(of: path) == normalized else { continue }
            children[basename(of: path)] = try entry(for: state, relativePath: path)
        }

        return children.values.sorted { lhs, rhs in
            if lhs.type == rhs.type {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.type == .directory
        }
    }

    public func lookupChild(named name: String, inDirectory relativePath: String) throws -> ManagedWorkspaceMountEntry {
        let candidate = normalize(pathJoin(normalize(relativePath), name))
        return try entry(for: candidate)
    }

    public func createFile(at relativePath: String) throws -> ManagedWorkspaceMountEntry {
        let normalized = normalize(relativePath)
        let parent = parentPath(of: normalized)
        _ = try entry(for: parent)
        guard !exists(at: normalized) else {
            throw posixError(EEXIST, "Item already exists.")
        }

        statesByPath[normalized] = NodeState(
            relativePath: normalized,
            kind: .file,
            stagedData: Data(),
            dirty: false,
            writeOpen: false,
            ephemeral: true,
            commitPath: nil
        )
        return try entry(for: normalized)
    }

    public func createDirectory(at relativePath: String) throws -> ManagedWorkspaceMountEntry {
        let normalized = normalize(relativePath)
        let parent = parentPath(of: normalized)
        _ = try entry(for: parent)
        guard !exists(at: normalized) else {
            throw posixError(EEXIST, "Item already exists.")
        }

        statesByPath[normalized] = NodeState(
            relativePath: normalized,
            kind: .directory,
            stagedData: nil,
            dirty: false,
            writeOpen: false,
            ephemeral: true,
            commitPath: nil
        )
        return try entry(for: normalized)
    }

    public func openFile(at relativePath: String, modes: ManagedWorkspaceMountOpenModes) throws {
        let normalized = normalize(relativePath)
        var state = try fileState(for: normalized)
        if modes.contains(.write) {
            state.writeOpen = true
            if state.stagedData == nil {
                state.stagedData = try fileData(for: normalized)
            }
        }
        statesByPath[normalized] = state
    }

    public func readFile(at relativePath: String, offset: Int, length: Int) throws -> Data {
        let normalized = normalize(relativePath)
        let data: Data
        if let state = statesByPath[normalized], let stagedData = state.stagedData {
            data = stagedData
        } else {
            data = try fileData(for: normalized)
        }

        guard offset >= 0, length >= 0 else {
            throw posixError(EINVAL, "Invalid read range.")
        }
        guard offset < data.count else { return Data() }
        let upperBound = min(data.count, offset + length)
        return data.subdata(in: offset..<upperBound)
    }

    public func writeFile(at relativePath: String, offset: Int, contents: Data) throws -> Int {
        let normalized = normalize(relativePath)
        guard offset >= 0 else {
            throw posixError(EINVAL, "Invalid write offset.")
        }

        var state = try fileState(for: normalized)
        if state.stagedData == nil {
            state.stagedData = try fileData(for: normalized)
        }
        var staged = state.stagedData ?? Data()
        if offset > staged.count {
            staged.append(Data(repeating: 0, count: offset - staged.count))
        }
        if offset + contents.count > staged.count {
            staged.append(Data(repeating: 0, count: offset + contents.count - staged.count))
        }
        staged.replaceSubrange(offset..<(offset + contents.count), with: contents)
        state.stagedData = staged
        state.dirty = true
        state.writeOpen = true
        statesByPath[normalized] = state
        return contents.count
    }

    public func setFileSize(at relativePath: String, size: Int) throws {
        let normalized = normalize(relativePath)
        guard size >= 0 else {
            throw posixError(EINVAL, "Invalid file size.")
        }

        var state = try fileState(for: normalized)
        if state.stagedData == nil {
            state.stagedData = try fileData(for: normalized)
        }
        var staged = state.stagedData ?? Data()
        if size < staged.count {
            staged.removeSubrange(size..<staged.count)
        } else if size > staged.count {
            staged.append(Data(repeating: 0, count: size - staged.count))
        }
        state.stagedData = staged
        state.dirty = true
        statesByPath[normalized] = state
    }

    public func closeFile(at relativePath: String, keeping modes: ManagedWorkspaceMountOpenModes) async throws {
        let normalized = normalize(relativePath)
        guard var state = statesByPath[normalized] else { return }
        state.writeOpen = modes.contains(.write)
        statesByPath[normalized] = state

        guard state.dirty, !state.writeOpen else { return }
        guard let stagedData = state.stagedData else { return }
        guard let commitPath = state.commitPath else { return }

        do {
            try await commitClient.commit(relativePath: commitPath, data: stagedData, sourceApplication: sourceApplication)
            statesByPath[normalized]?.dirty = false
            statesByPath[normalized]?.stagedData = nil
            statesByPath[normalized]?.ephemeral = false
            statesByPath[normalized]?.commitPath = commitPath

            if normalized != commitPath {
                statesByPath.removeValue(forKey: normalized)
                itemIDsByPath.removeValue(forKey: normalized)
                if let itemID = pathsByItemID.first(where: { $0.value == normalized })?.key {
                    pathsByItemID.removeValue(forKey: itemID)
                }
            }
        } catch {
            statesByPath[normalized]?.dirty = true
            throw error
        }
    }

    public func removeItem(at relativePath: String) async throws {
        let normalized = normalize(relativePath)
        if let state = statesByPath[normalized], state.ephemeral {
            removeEphemeralTree(at: normalized)
            return
        }

        guard exists(at: normalized) else {
            throw posixError(ENOENT, "Item not found.")
        }
        try await commitClient.remove(relativePath: normalized, sourceApplication: sourceApplication)
        removeEphemeralTree(at: normalized)
    }

    public func renameItem(from sourcePath: String, to destinationPath: String) async throws {
        let source = normalize(sourcePath)
        let destination = normalize(destinationPath)
        guard source != destination else { return }

        if !exists(at: source) {
            throw posixError(ENOENT, "Source item not found.")
        }

        if let existing = statesByPath[destination], existing.ephemeral {
            removeEphemeralTree(at: destination)
        }

        var state = statesByPath[source] ?? NodeState(
            relativePath: source,
            kind: isDirectoryOnDisk(at: source) ? .directory : .file,
            stagedData: nil,
            dirty: false,
            writeOpen: false,
            ephemeral: false,
            commitPath: source
        )
        state.relativePath = destination
        state.commitPath = shouldTreatAsTemporary(path: destination) ? nil : destination

        statesByPath.removeValue(forKey: source)
        statesByPath[destination] = state
        let itemID = assignItemID(for: source)
        itemIDsByPath.removeValue(forKey: source)
        itemIDsByPath[destination] = itemID
        pathsByItemID[itemID] = destination

        if state.kind == .file, state.dirty, !state.writeOpen, let stagedData = state.stagedData, let commitPath = state.commitPath {
            try await commitClient.commit(relativePath: commitPath, data: stagedData, sourceApplication: sourceApplication)
            statesByPath[destination]?.dirty = false
            statesByPath[destination]?.stagedData = nil
            statesByPath[destination]?.ephemeral = false
        }
    }

    private func entryForResolvedPath(_ relativePath: String, isDirectory: Bool? = nil) throws -> ManagedWorkspaceMountEntry {
        if let state = statesByPath[relativePath] {
            return try entry(for: state, relativePath: relativePath)
        }

        let normalized = normalize(relativePath)
        if normalized.isEmpty {
            let itemID = assignItemID(for: normalized)
            return ManagedWorkspaceMountEntry(itemID: itemID, relativePath: normalized, name: "", type: .directory, size: 0)
        }

        let url = workspaceRoot.appendingPathComponent(normalized)
        let resolvedIsDirectory = isDirectory ?? isDirectoryOnDisk(at: normalized)
        let size: UInt64
        if resolvedIsDirectory {
            size = 0
        } else {
            let data = try Data(contentsOf: url)
            size = UInt64(data.count)
        }
        let itemID = assignItemID(for: normalized)
        return ManagedWorkspaceMountEntry(
            itemID: itemID,
            relativePath: normalized,
            name: basename(of: normalized),
            type: resolvedIsDirectory ? .directory : .file,
            size: size
        )
    }

    private func entry(for state: NodeState, relativePath: String) throws -> ManagedWorkspaceMountEntry {
        let itemID = assignItemID(for: relativePath)
        let type: ManagedWorkspaceMountNodeType = state.kind == .directory ? .directory : .file
        let size = UInt64(state.stagedData?.count ?? (type == .directory ? 0 : (try? fileData(for: relativePath).count) ?? 0))
        return ManagedWorkspaceMountEntry(
            itemID: itemID,
            relativePath: relativePath,
            name: basename(of: relativePath),
            type: type,
            size: size
        )
    }

    private func fileState(for relativePath: String) throws -> NodeState {
        let normalized = normalize(relativePath)
        if let state = statesByPath[normalized] {
            guard state.kind == .file else {
                throw posixError(EISDIR, "Is a directory.")
            }
            return state
        }
        guard exists(at: normalized) else {
            throw posixError(ENOENT, "File not found.")
        }
        guard !isDirectoryOnDisk(at: normalized) else {
            throw posixError(EISDIR, "Is a directory.")
        }
        return NodeState(
            relativePath: normalized,
            kind: .file,
            stagedData: nil,
            dirty: false,
            writeOpen: false,
            ephemeral: false,
            commitPath: normalized
        )
    }

    private func fileData(for relativePath: String) throws -> Data {
        let normalized = normalize(relativePath)
        if let state = statesByPath[normalized], let stagedData = state.stagedData {
            return stagedData
        }
        return try Data(contentsOf: workspaceRoot.appendingPathComponent(normalized))
    }

    private func exists(at relativePath: String) -> Bool {
        let normalized = normalize(relativePath)
        if normalized.isEmpty { return true }
        if statesByPath[normalized] != nil { return true }
        return FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent(normalized).path)
    }

    private func isDirectoryOnDisk(at relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(
            atPath: workspaceRoot.appendingPathComponent(normalize(relativePath)).path,
            isDirectory: &isDirectory
        )
        return isDirectory.boolValue
    }

    private func assignItemID(for relativePath: String) -> UInt64 {
        if let itemID = itemIDsByPath[relativePath] {
            return itemID
        }
        let itemID = nextItemID
        nextItemID += 1
        itemIDsByPath[relativePath] = itemID
        pathsByItemID[itemID] = relativePath
        return itemID
    }

    private func removeEphemeralTree(at relativePath: String) {
        let normalized = normalize(relativePath)
        let prefixes = statesByPath.keys.filter { $0 == normalized || $0.hasPrefix(normalized + "/") }
        for key in prefixes {
            statesByPath.removeValue(forKey: key)
            if let itemID = itemIDsByPath.removeValue(forKey: key) {
                pathsByItemID.removeValue(forKey: itemID)
            }
        }
    }

    private func normalize(_ relativePath: String) -> String {
        relativePath
            .split(separator: "/")
            .filter { $0 != "." && !$0.isEmpty }
            .joined(separator: "/")
    }

    private func parentPath(of relativePath: String) -> String {
        let normalized = normalize(relativePath)
        guard let slash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slash])
    }

    private func basename(of relativePath: String) -> String {
        let normalized = normalize(relativePath)
        guard let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    private func pathJoin(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        return lhs + "/" + rhs
    }

    private func shouldTreatAsTemporary(path: String) -> Bool {
        let name = basename(of: path).lowercased()
        if name.hasPrefix(".") || name.hasSuffix(".tmp") || name.hasSuffix(".temp") {
            return true
        }
        if name.contains("temporary") || name.contains("lock") || name.contains("swp") {
            return true
        }
        return false
    }

    private func posixError(_ code: Int32, _ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}
