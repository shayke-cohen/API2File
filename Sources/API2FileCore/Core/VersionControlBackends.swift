import Foundation
import CryptoKit

public protocol VersionControlBackend: Sendable {
    var repoPath: URL { get }
    func initRepo() throws
    func createGitignore() throws
    func commitAll(message: String) throws
    func hasChanges() throws -> Bool
    func fileHashAtHead(_ relativePath: String) throws -> String?
    func statusForFiles() throws -> [String: String]
    func diffForFile(_ relativePath: String) throws -> String
    func changeSummary() throws -> (modified: Int, added: Int, deleted: Int)
}

public struct VersionControlBackendFactory: Sendable {
    private let makeBackendClosure: @Sendable (URL) -> any VersionControlBackend

    public init(_ makeBackend: @escaping @Sendable (URL) -> any VersionControlBackend) {
        self.makeBackendClosure = makeBackend
    }

    public func makeBackend(repoPath: URL) -> any VersionControlBackend {
        makeBackendClosure(repoPath)
    }

    public static var current: VersionControlBackendFactory {
        #if os(macOS)
        return .shell
        #else
        return .embedded
        #endif
    }

    public static var shell: VersionControlBackendFactory {
        VersionControlBackendFactory { repoPath in
            #if os(macOS)
            return ShellGitBackend(repoPath: repoPath)
            #else
            return EmbeddedGitBackend(repoPath: repoPath)
            #endif
        }
    }

    public static var embedded: VersionControlBackendFactory {
        VersionControlBackendFactory { repoPath in
            EmbeddedGitBackend(repoPath: repoPath)
        }
    }
}

#if os(macOS)
final class ShellGitBackend: VersionControlBackend {
    let repoPath: URL

    init(repoPath: URL) {
        self.repoPath = repoPath
    }

    func initRepo() throws {
        let gitDir = repoPath.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            return
        }
        _ = try runGit(["init"])
    }

    func createGitignore() throws {
        let gitignorePath = repoPath.appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignorePath.path) {
            return
        }
        try ".api2file/\n".write(to: gitignorePath, atomically: true, encoding: .utf8)
    }

    func commitAll(message: String) throws {
        _ = try runGit(["add", "-A"])
        _ = try runGit(["commit", "-m", message])
    }

    func hasChanges() throws -> Bool {
        let output = try runGit(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fileHashAtHead(_ relativePath: String) throws -> String? {
        do {
            let content = try runGit(["show", "HEAD:\(relativePath)"])
            guard let data = content.data(using: .utf8) else { return nil }
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch let error as GitError {
            switch error {
            case .commandFailed(_, let stderr, _):
                if stderr.contains("does not exist") ||
                    stderr.contains("not a tree object") ||
                    stderr.contains("unknown revision") ||
                    stderr.contains("bad revision") ||
                    stderr.contains("invalid object name") {
                    return nil
                }
                throw error
            default:
                throw error
            }
        }
    }

    func statusForFiles() throws -> [String: String] {
        let output = try runGit(["status", "--porcelain"])
        var result: [String: String] = [:]
        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let status = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
            let file = String(line.dropFirst(3))
            result[file] = status
        }
        return result
    }

    func diffForFile(_ relativePath: String) throws -> String {
        do {
            return try runGit(["diff", "--", relativePath])
        } catch {
            do {
                return try runGit(["diff", "--no-index", "/dev/null", relativePath])
            } catch {
                return ""
            }
        }
    }

    func changeSummary() throws -> (modified: Int, added: Int, deleted: Int) {
        let statuses = try statusForFiles()
        var modified = 0
        var added = 0
        var deleted = 0
        for status in statuses.values {
            switch status {
            case "M", "MM":
                modified += 1
            case "A", "??":
                added += 1
            case "D":
                deleted += 1
            default:
                modified += 1
            }
        }
        return (modified, added, deleted)
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        guard let executablePath = Self.findGitPath() else {
            throw GitError.gitNotInstalled
        }

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = repoPath
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw GitError.commandFailed(
                command: arguments.joined(separator: " "),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )
        }

        return stdout
    }

    private static func findGitPath() -> String? {
        let commonPaths = [
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
        ]

        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "git"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    return path
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}
#endif

final class EmbeddedGitBackend: VersionControlBackend {
    let repoPath: URL

    private struct CommitRecord: Codable, Sendable {
        let id: String
        let message: String
        let timestamp: Date
        let files: [String: String]
    }

    private struct Manifest: Codable, Sendable {
        var commits: [CommitRecord] = []
    }

    private let ignoredComponents: Set<String> = [".git", ".api2file", ".api2file-git"]

    init(repoPath: URL) {
        self.repoPath = repoPath
    }

    func initRepo() throws {
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoPath.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            try saveManifest(Manifest())
        }
    }

    func createGitignore() throws {
        let gitignorePath = repoPath.appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignorePath.path) {
            return
        }
        try ".api2file/\n.api2file-git/\n".write(to: gitignorePath, atomically: true, encoding: .utf8)
    }

    func commitAll(message: String) throws {
        let currentFiles = try workingTreeFiles()
        var manifest = try loadManifest()
        let commitID = UUID().uuidString
        let snapshotDir = snapshotsDirectory.appendingPathComponent(commitID, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        var snapshotMap: [String: String] = [:]
        for (relativePath, fileURL) in currentFiles {
            let targetURL = snapshotDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: targetURL)
                try FileManager.default.copyItem(at: fileURL, to: targetURL)
                snapshotMap[relativePath] = relativePath
            }
        }

        manifest.commits.append(CommitRecord(
            id: commitID,
            message: message,
            timestamp: Date(),
            files: snapshotMap
        ))
        try saveManifest(manifest)
    }

    func hasChanges() throws -> Bool {
        !(try statusForFiles()).isEmpty
    }

    func fileHashAtHead(_ relativePath: String) throws -> String? {
        guard let fileURL = try headSnapshotFile(relativePath: relativePath),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func statusForFiles() throws -> [String: String] {
        let currentFiles = try workingTreeFiles()
        let headFiles = try headSnapshotFiles()
        let paths = Set(currentFiles.keys).union(headFiles.keys)
        var result: [String: String] = [:]

        for path in paths.sorted() {
            let currentURL = currentFiles[path]
            let headURL = headFiles[path]

            switch (currentURL, headURL) {
            case let (current?, head?):
                let currentHash = try Data(contentsOf: current).sha256Hex
                let headHash = try Data(contentsOf: head).sha256Hex
                if currentHash != headHash {
                    result[path] = "M"
                }
            case (.some, nil):
                result[path] = "??"
            case (nil, .some):
                result[path] = "D"
            case (nil, nil):
                break
            }
        }

        return result
    }

    func diffForFile(_ relativePath: String) throws -> String {
        let headURL = try headSnapshotFile(relativePath: relativePath)
        let currentURL = repoPath.appendingPathComponent(relativePath)
        let oldData = headURL.flatMap { try? Data(contentsOf: $0) }
        let newData = try? Data(contentsOf: currentURL)

        guard oldData != nil || newData != nil else { return "" }

        let header = [
            "--- a/\(relativePath)",
            "+++ b/\(relativePath)"
        ]

        if let oldData, let newData,
           let oldText = String(data: oldData, encoding: .utf8),
           let newText = String(data: newData, encoding: .utf8) {
            if oldText == newText { return "" }
            let oldLines = oldText.components(separatedBy: .newlines)
            let newLines = newText.components(separatedBy: .newlines)
            let removed = oldLines.map { "-\($0)" }
            let added = newLines.map { "+\($0)" }
            return (header + removed + added).joined(separator: "\n")
        }

        if oldData == nil {
            return (header + ["+Binary file added"]).joined(separator: "\n")
        }
        if newData == nil {
            return (header + ["-Binary file deleted"]).joined(separator: "\n")
        }
        return (header + ["Binary content changed"]).joined(separator: "\n")
    }

    func changeSummary() throws -> (modified: Int, added: Int, deleted: Int) {
        let statuses = try statusForFiles()
        var modified = 0
        var added = 0
        var deleted = 0
        for status in statuses.values {
            switch status {
            case "M":
                modified += 1
            case "A", "??":
                added += 1
            case "D":
                deleted += 1
            default:
                modified += 1
            }
        }
        return (modified, added, deleted)
    }

    private var metadataDirectory: URL {
        repoPath.appendingPathComponent(".api2file-git", isDirectory: true)
    }

    private var manifestURL: URL {
        metadataDirectory.appendingPathComponent("manifest.json")
    }

    private var snapshotsDirectory: URL {
        metadataDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    private func loadManifest() throws -> Manifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return Manifest()
        }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func saveManifest(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func headCommit() throws -> CommitRecord? {
        try loadManifest().commits.last
    }

    private func headSnapshotFiles() throws -> [String: URL] {
        guard let commit = try headCommit() else { return [:] }
        let snapshotDir = snapshotsDirectory.appendingPathComponent(commit.id, isDirectory: true)
        return commit.files.mapValues { snapshotDir.appendingPathComponent($0) }
    }

    private func headSnapshotFile(relativePath: String) throws -> URL? {
        try headSnapshotFiles()[relativePath]
    }

    private func workingTreeFiles() throws -> [String: URL] {
        guard FileManager.default.fileExists(atPath: repoPath.path) else { return [:] }

        let enumerator = FileManager.default.enumerator(
            at: repoPath,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        var result: [String: URL] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            let relativePath = fileURL.path.replacingOccurrences(of: repoPath.path + "/", with: "")
            if relativePath.isEmpty { continue }
            let components = Set(relativePath.split(separator: "/").map(String.init))
            if !components.isDisjoint(with: ignoredComponents) {
                if (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator?.skipDescendants()
                }
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isRegularFile == true {
                result[relativePath] = fileURL
            }
        }
        return result
    }
}
