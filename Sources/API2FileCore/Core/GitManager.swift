import Foundation

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
    private let backend: any VersionControlBackend

    // MARK: - Init

    public init(repoPath: URL, backendFactory: VersionControlBackendFactory = .current) {
        self.repoPath = repoPath
        self.backend = backendFactory.makeBackend(repoPath: repoPath)
    }

    // MARK: - Public API

    /// Initialize a git repo if it doesn't already exist.
    public func initRepo() throws {
        try backend.initRepo()
    }

    /// Create `.gitignore` with API2File internal files if it doesn't already exist.
    public func createGitignore() throws {
        try backend.createGitignore()
    }

    /// Stage all changes and commit with the given message.
    public func commitAll(message: String) throws {
        try backend.commitAll(message: message)
    }

    /// Check if there are uncommitted changes (staged or unstaged).
    public func hasChanges() throws -> Bool {
        try backend.hasChanges()
    }

    /// Get the SHA-256 hash of a file's content at HEAD.
    /// Returns `nil` if the file does not exist at HEAD (e.g., untracked or no commits).
    public func fileHashAtHead(_ relativePath: String) throws -> String? {
        try backend.fileHashAtHead(relativePath)
    }

    /// Per-file git status from `git status --porcelain`.
    /// Returns a dictionary mapping relative file paths to their status code (e.g. "M", "A", "??", "D").
    public func statusForFiles() throws -> [String: String] {
        try backend.statusForFiles()
    }

    /// Get the unified diff for a specific file (unstaged changes).
    /// Returns empty string if no diff or file is untracked.
    public func diffForFile(_ relativePath: String) throws -> String {
        try backend.diffForFile(relativePath)
    }

    /// Get a short summary of changes: modified count, added count, deleted count.
    public func changeSummary() throws -> (modified: Int, added: Int, deleted: Int) {
        try backend.changeSummary()
    }
}
