import API2FileCore
import FSKit
import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#endif

@available(macOS 26.0, *)
@objc
final class API2FileManagedWorkspaceFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let logger = Logger(subsystem: "com.shayco.api2file.dev", category: "FSKitExtension")
    private let storageLocations = StorageLocations.current

    func didFinishLoading() {
        logger.notice("FSKit extension finished loading")
    }

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        logger.notice("probeResource resourceType=\(String(describing: type(of: resource)))")
        guard let pathResource = resource as? FSPathURLResource else {
            logger.error("probeResource rejected non-path resource")
            replyHandler(.notRecognized, nil)
            return
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pathResource.url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            logger.error("probeResource rejected missing directory path=\(pathResource.url.path, privacy: .public)")
            replyHandler(.notRecognized, nil)
            return
        }

        let name = pathResource.url.lastPathComponent.isEmpty ? "API2File Managed Workspace" : pathResource.url.lastPathComponent
        logger.notice("probeResource accepted path=\(pathResource.url.path, privacy: .public)")
        replyHandler(.usable(name: name, containerID: FSContainerIdentifier(uuid: UUID())), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        logger.notice("loadResource resourceType=\(String(describing: type(of: resource)))")
        guard let pathResource = resource as? FSPathURLResource else {
            logger.error("loadResource rejected non-path resource")
            replyHandler(nil, posixError(EINVAL, "API2File mount requires a path URL resource."))
            return
        }

        let syncRoot = storageLocations.syncRootDirectory
        let config = GlobalConfig.loadOrDefault(syncFolder: syncRoot)
        let serverBaseURL = URL(string: "http://127.0.0.1:\(config.serverPort)")!
        let volume = API2FileManagedWorkspaceVolume(
            workspaceRoot: pathResource.url,
            serverBaseURL: serverBaseURL
        )
        logger.notice("loadResource returning volume for path=\(pathResource.url.path, privacy: .public)")
        replyHandler(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        logger.notice("unloadResource resourceType=\(String(describing: type(of: resource)))")
    }

    private func posixError(_ code: Int32, _ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}

@available(macOS 26.0, *)
final class API2FileManagedWorkspaceVolume: FSVolume, FSVolume.Operations, FSVolume.OpenCloseOperations, FSVolume.ReadWriteOperations {
    private let logger = Logger(subsystem: "com.shayco.api2file.dev", category: "FSKitVolume")
    private let workspaceRoot: URL
    private let store: ManagedWorkspaceFileSystemStore
    private let rootItem = API2FileManagedWorkspaceItem(
        relativePath: "",
        itemID: 2,
        type: .directory
    )

    init(workspaceRoot: URL, serverBaseURL: URL) {
        self.workspaceRoot = workspaceRoot
        self.store = ManagedWorkspaceFileSystemStore(
            workspaceRoot: workspaceRoot,
            commitClient: ManagedWorkspaceMountHTTPCommitClient(baseURL: serverBaseURL),
            sourceApplication: "API2File FS Mount"
        )
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: FSFileName(string: "API2File Workspace")
        )
        self.name = FSFileName(string: "API2File Workspace")
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsSparseFiles = true
        capabilities.supportsFastStatFS = true
        capabilities.supportsOpenDenyModes = false
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "a2fmount")
        let directorySize = (try? directorySize(root: workspaceRoot)) ?? 0
        stats.blockSize = 4096
        stats.ioSize = 4096
        stats.totalBytes = directorySize
        stats.usedBytes = directorySize
        stats.totalFiles = 1
        return stats
    }

    func mount(options: FSTaskOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        logger.notice("mount path=\(self.workspaceRoot.path, privacy: .public)")
        replyHandler(nil)
    }

    func unmount(replyHandler: @escaping () -> Void) {
        logger.notice("unmount path=\(self.workspaceRoot.path, privacy: .public)")
        replyHandler()
    }

    func synchronize(flags: FSSyncFlags, replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }

    func activate(options: FSTaskOptions, replyHandler: @escaping (FSItem?, (any Error)?) -> Void) {
        logger.notice("activate path=\(self.workspaceRoot.path, privacy: .public)")
        replyHandler(rootItem, nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler: @escaping ((any Error)?) -> Void) {
        logger.notice("deactivate path=\(self.workspaceRoot.path, privacy: .public)")
        replyHandler(nil)
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem else {
            replyHandler(nil, posixError(ENOENT, "Unknown item."))
            return
        }

        Task {
            do {
                let entry = try await store.entry(for: item.relativePath)
                replyHandler(self.attributes(for: item, entry: entry), nil)
            } catch {
                replyHandler(nil, error)
            }
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem else {
            replyHandler(nil, posixError(ENOENT, "Unknown item."))
            return
        }

        if newAttributes.isValid(.size), item.type == .file {
            Task {
                do {
                    try await store.setFileSize(at: item.relativePath, size: Int(newAttributes.size))
                    let entry = try await store.entry(for: item.relativePath)
                    var consumed = newAttributes.consumedAttributes
                    consumed.insert(.size)
                    newAttributes.consumedAttributes = consumed
                    replyHandler(self.attributes(for: item, entry: entry), nil)
                } catch {
                    replyHandler(nil, error)
                }
            }
            return
        }

        replyHandler(nil, posixError(EINVAL, "Only file size changes are supported by the managed mount."))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? API2FileManagedWorkspaceItem else {
            replyHandler(nil, nil, posixError(ENOENT, "Unknown directory."))
            return
        }

        let childName = name.string ?? name.debugDescription
        Task {
            do {
                let entry = try await store.lookupChild(named: childName, inDirectory: directory.relativePath)
                let item = API2FileManagedWorkspaceItem(entry: entry)
                replyHandler(item, FSFileName(string: entry.name), nil)
            } catch {
                replyHandler(nil, nil, error)
            }
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
        replyHandler(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, posixError(EINVAL, "Symbolic links are not supported by the managed mount."))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? API2FileManagedWorkspaceItem else {
            replyHandler(nil, nil, posixError(ENOENT, "Unknown directory."))
            return
        }

        let childName = name.string ?? name.debugDescription
        let childPath = join(directory.relativePath, childName)
        Task {
            do {
                let entry: ManagedWorkspaceMountEntry
                switch type {
                case .file:
                    entry = try await store.createFile(at: childPath)
                case .directory:
                    entry = try await store.createDirectory(at: childPath)
                default:
                    throw self.posixError(EINVAL, "Unsupported item type.")
                }
                replyHandler(API2FileManagedWorkspaceItem(entry: entry), FSFileName(string: entry.name), nil)
            } catch {
                replyHandler(nil, nil, error)
            }
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, nil, posixError(ENOTSUP, "Symbolic links are not supported by the managed mount."))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        replyHandler(nil, posixError(ENOTSUP, "Hard links are not supported by the managed mount."))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler: @escaping ((any Error)?) -> Void) {
        guard let directory = directory as? API2FileManagedWorkspaceItem else {
            replyHandler(posixError(ENOENT, "Unknown directory."))
            return
        }

        let childName = name.string ?? name.debugDescription
        let childPath = join(directory.relativePath, childName)
        Task {
            do {
                try await store.removeItem(at: childPath)
                replyHandler(nil)
            } catch {
                replyHandler(error)
            }
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard let sourceDirectory = sourceDirectory as? API2FileManagedWorkspaceItem,
              let destinationDirectory = destinationDirectory as? API2FileManagedWorkspaceItem else {
            replyHandler(nil, posixError(ENOENT, "Unknown directory."))
            return
        }

        let sourcePath = join(sourceDirectory.relativePath, sourceName.string ?? sourceName.debugDescription)
        let destinationPath = join(destinationDirectory.relativePath, destinationName.string ?? destinationName.debugDescription)

        Task {
            do {
                try await store.renameItem(from: sourcePath, to: destinationPath)
                replyHandler(FSFileName(string: destinationName.string ?? destinationName.debugDescription), nil)
            } catch {
                replyHandler(nil, error)
            }
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let directory = directory as? API2FileManagedWorkspaceItem else {
            replyHandler(verifier, posixError(ENOENT, "Unknown directory."))
            return
        }

        Task {
            do {
                let entries = try await store.enumerateDirectory(at: directory.relativePath)
                let startIndex = Int(cookie.rawValue)
                for (index, entry) in entries.enumerated().dropFirst(startIndex) {
                    let item = API2FileManagedWorkspaceItem(entry: entry)
                    let packed = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: item.fsItemType,
                        itemID: FSItem.Identifier(rawValue: entry.itemID) ?? .invalid,
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                        attributes: attributes.map { _ in self.attributes(for: item, entry: entry) }
                    )
                    if !packed { break }
                }
                replyHandler(FSDirectoryVerifier(1), nil)
            } catch {
                replyHandler(verifier, error)
            }
        }
    }

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem, item.type == .file else {
            replyHandler(posixError(EISDIR, "Only files can be opened."))
            return
        }

        Task {
            do {
                try await store.openFile(at: item.relativePath, modes: mapModes(modes))
                replyHandler(nil)
            } catch {
                replyHandler(error)
            }
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler: @escaping ((any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem else {
            replyHandler(posixError(ENOENT, "Unknown item."))
            return
        }

        Task {
            do {
                try await store.closeFile(at: item.relativePath, keeping: mapModes(modes))
                replyHandler(nil)
            } catch {
                replyHandler(error)
            }
        }
    }

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem, item.type == .file else {
            replyHandler(0, posixError(EISDIR, "Only files can be read."))
            return
        }

        Task {
            do {
                let data = try await store.readFile(at: item.relativePath, offset: Int(offset), length: length)
                try buffer.withUnsafeMutableBytes { rawBuffer in
                    guard rawBuffer.count >= data.count else {
                        throw self.posixError(EIO, "FSKit read buffer is too small.")
                    }
                    data.copyBytes(to: rawBuffer.bindMemory(to: UInt8.self))
                }
                replyHandler(data.count, nil)
            } catch {
                replyHandler(0, error)
            }
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? API2FileManagedWorkspaceItem, item.type == .file else {
            replyHandler(0, posixError(EISDIR, "Only files can be written."))
            return
        }

        Task {
            do {
                let written = try await store.writeFile(at: item.relativePath, offset: Int(offset), contents: contents)
                replyHandler(written, nil)
            } catch {
                replyHandler(0, error)
            }
        }
    }

    private func attributes(for item: API2FileManagedWorkspaceItem, entry: ManagedWorkspaceMountEntry) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.type = item.fsItemType
        attributes.mode = item.type == .directory ? 0o755 : 0o644
        attributes.linkCount = item.type == .directory ? 2 : 1
        attributes.size = entry.size
        attributes.allocSize = entry.size
        attributes.fileID = FSItem.Identifier(rawValue: item.itemID) ?? .invalid
        attributes.parentID = FSItem.Identifier(rawValue: item.parentItemID) ?? .parentOfRoot
        let now = Date()
        let timespec = makeTimespec(from: now)
        attributes.accessTime = timespec
        attributes.modifyTime = timespec
        attributes.changeTime = timespec
        attributes.birthTime = timespec
        return attributes
    }

    private func makeTimespec(from date: Date) -> timespec {
        let timeInterval = date.timeIntervalSince1970
        let seconds = Int(timeInterval)
        let nanoseconds = Int((timeInterval - Double(seconds)) * 1_000_000_000)
        return timespec(tv_sec: seconds, tv_nsec: nanoseconds)
    }

    private func mapModes(_ modes: FSVolume.OpenModes) -> ManagedWorkspaceMountOpenModes {
        var mapped: ManagedWorkspaceMountOpenModes = []
        if modes.contains(.read) {
            mapped.insert(.read)
        }
        if modes.contains(.write) {
            mapped.insert(.write)
        }
        return mapped
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        if lhs.isEmpty { return rhs }
        return lhs + "/" + rhs
    }

    private func directorySize(root: URL) throws -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += UInt64(values?.fileSize ?? 0)
        }
        return total
    }

    private func posixError(_ code: Int32, _ description: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: description
        ])
    }
}

@available(macOS 26.0, *)
final class API2FileManagedWorkspaceItem: FSItem {
    let relativePath: String
    let itemID: UInt64
    let type: ManagedWorkspaceMountNodeType

    init(relativePath: String, itemID: UInt64, type: ManagedWorkspaceMountNodeType) {
        self.relativePath = relativePath
        self.itemID = itemID
        self.type = type
        super.init()
    }

    convenience init(entry: ManagedWorkspaceMountEntry) {
        self.init(relativePath: entry.relativePath, itemID: entry.itemID, type: entry.type)
    }

    var fsItemType: FSItem.ItemType {
        switch type {
        case .file:
            return .file
        case .directory:
            return .directory
        }
    }

    var parentItemID: UInt64 {
        guard let slash = relativePath.lastIndex(of: "/") else { return 2 }
        let parentPath = String(relativePath[..<slash])
        return UInt64(parentPath.hashValue.magnitude) | 0x1000
    }
}
