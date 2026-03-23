import Foundation
import CryptoKit

// MARK: - GitError

public enum GitError: Error, LocalizedError, Sendable {
    case gitNotInstalled
    case notARepository(String)
    case commandFailed(command: String, stderr: String, exitCode: Int32)
    case noCommitsYet

    public var errorDescription: String? {
        switch self {
        case .gitNotInstalled:
            return "git is not installed or not found in PATH."
        case .notARepository(let path):
            return "'\(path)' is not a git repository."
        case .commandFailed(let command, let stderr, let exitCode):
            return "git \(command) failed (exit \(exitCode)): \(stderr)"
        case .noCommitsYet:
            return "No commits exist in the repository yet."
        }
    }
}

// MARK: - GitManager

/// Manages a git repository using shell `git` commands.
/// All operations are serialized through the actor to ensure thread safety.
public actor GitManager {
    public let repoPath: URL

    // MARK: - Init

    public init(repoPath: URL) {
        self.repoPath = repoPath
    }

    // MARK: - Public API

    /// Initialize a git repo if it doesn't already exist.
    public func initRepo() throws {
        let gitDir = repoPath.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitDir.path) {
            return // Already initialized
        }
        _ = try runGit(["init"])
    }

    /// Create `.gitignore` with API2File internal files if it doesn't already exist.
    public func createGitignore() throws {
        let gitignorePath = repoPath.appendingPathComponent(".gitignore")

        if FileManager.default.fileExists(atPath: gitignorePath.path) {
            return // Already exists
        }

        try ".api2file/\n".write(to: gitignorePath, atomically: true, encoding: .utf8)
    }

    /// Stage all changes and commit with the given message.
    public func commitAll(message: String) throws {
        _ = try runGit(["add", "-A"])
        _ = try runGit(["commit", "-m", message])
    }

    /// Check if there are uncommitted changes (staged or unstaged).
    public func hasChanges() throws -> Bool {
        let output = try runGit(["status", "--porcelain"])
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get the SHA-256 hash of a file's content at HEAD.
    /// Returns `nil` if the file does not exist at HEAD (e.g., untracked or no commits).
    public func fileHashAtHead(_ relativePath: String) throws -> String? {
        do {
            let content = try runGit(["show", "HEAD:\(relativePath)"])
            guard let data = content.data(using: .utf8) else { return nil }
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02x", $0) }.joined()
        } catch let error as GitError {
            switch error {
            case .commandFailed(_, let stderr, _):
                // File doesn't exist at HEAD or no commits yet
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

    // MARK: - Internal Helpers

    /// Runs a git command and returns its stdout output.
    /// Throws `GitError.gitNotInstalled` if git cannot be found,
    /// or `GitError.commandFailed` if the command exits with a non-zero status.
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Find git executable
        let gitPath = Self.findGitPath()
        guard let executablePath = gitPath else {
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
            let commandDescription = arguments.joined(separator: " ")
            throw GitError.commandFailed(
                command: commandDescription,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus
            )
        }

        return stdout
    }

    /// Locates the `git` executable.
    private static func findGitPath() -> String? {
        let commonPaths = [
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: try which git
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
            // Ignore — fall through to nil
        }

        return nil
    }
}
