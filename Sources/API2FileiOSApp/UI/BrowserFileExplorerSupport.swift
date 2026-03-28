import Foundation

struct BrowserFileMetadata: Equatable, Hashable {
    let sizeDescription: String
    let rowCount: Int?

    var detailDescription: String {
        if let rowCount {
            return "\(sizeDescription) · \(rowCount) row\(rowCount == 1 ? "" : "s")"
        }
        return sizeDescription
    }
}

struct BrowserFileItem: Identifiable, Equatable, Hashable {
    let url: URL
    let relativePath: String
    let metadata: BrowserFileMetadata

    var id: String { relativePath }
}

struct BrowserFolderGroup: Identifiable, Equatable, Hashable {
    let name: String
    let relativePath: String
    let folders: [BrowserFolderGroup]
    let files: [BrowserFileItem]

    var id: String { relativePath.isEmpty ? "__root__" : relativePath }

    var fileCount: Int {
        files.count + folders.reduce(0) { $0 + $1.fileCount }
    }

    var nestedFolderCount: Int {
        folders.count + folders.reduce(0) { $0 + $1.nestedFolderCount }
    }
}

enum BrowserFileExplorerSupport {
    static func items(for files: [URL], root: URL) -> [BrowserFileItem] {
        files
            .map { fileURL in
                BrowserFileItem(
                    url: fileURL,
                    relativePath: relativePath(for: fileURL, in: root),
                    metadata: metadata(for: fileURL)
                )
            }
            .sorted(by: displaySort)
    }

    static func tree(for items: [BrowserFileItem]) -> BrowserFolderGroup {
        let root = MutableFolderNode(name: "Service root", relativePath: "")

        for item in items {
            let components = item.relativePath
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)

            guard components.last != nil else { continue }
            if components.count == 1 {
                root.files.append(item)
                continue
            }

            var current = root
            var traversed: [String] = []
            for folderName in components.dropLast() {
                traversed.append(folderName)
                let folderPath = traversed.joined(separator: "/")
                if let existing = current.folders[folderName] {
                    current = existing
                } else {
                    let created = MutableFolderNode(name: folderName, relativePath: folderPath)
                    current.folders[folderName] = created
                    current = created
                }
            }

            current.files.append(
                BrowserFileItem(url: item.url, relativePath: item.relativePath, metadata: item.metadata)
            )
        }

        return root.freeze()
    }

    static func metadata(for fileURL: URL) -> BrowserFileMetadata {
        let byteSize = fileSize(for: fileURL)
        return BrowserFileMetadata(
            sizeDescription: ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file),
            rowCount: rowCount(for: fileURL, byteSize: byteSize)
        )
    }

    static func relativePath(for fileURL: URL, in root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(fileURL.path.dropFirst(prefix.count))
    }

    static func displaySort(_ lhs: BrowserFileItem, _ rhs: BrowserFileItem) -> Bool {
        let lhsGuide = isGuideFile(path: lhs.relativePath)
        let rhsGuide = isGuideFile(path: rhs.relativePath)
        if lhsGuide != rhsGuide {
            return !lhsGuide
        }
        return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }

    static func isGuideFile(path: String) -> Bool {
        path.caseInsensitiveCompare("CLAUDE.md") == .orderedSame
    }

    private static func fileSize(for fileURL: URL) -> Int {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func rowCount(for fileURL: URL, byteSize: Int) -> Int? {
        guard byteSize > 0, byteSize <= 2_000_000 else { return nil }

        switch fileURL.pathExtension.lowercased() {
        case "csv", "tsv":
            guard let content = try? String(contentsOf: fileURL) else { return nil }
            let rows = content.split(whereSeparator: \.isNewline)
            guard !rows.isEmpty else { return 0 }
            return max(rows.count - 1, 0)
        case "json":
            guard let data = try? Data(contentsOf: fileURL),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            if let array = json as? [Any] {
                return array.count
            }
            return nil
        default:
            return nil
        }
    }
}

private final class MutableFolderNode {
    let name: String
    let relativePath: String
    var folders: [String: MutableFolderNode] = [:]
    var files: [BrowserFileItem] = []

    init(name: String, relativePath: String) {
        self.name = name
        self.relativePath = relativePath
    }

    func freeze() -> BrowserFolderGroup {
        BrowserFolderGroup(
            name: name,
            relativePath: relativePath,
            folders: folders.values
                .map { $0.freeze() }
                .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            files: files.sorted(by: BrowserFileExplorerSupport.displaySort)
        )
    }
}
