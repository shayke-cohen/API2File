import Foundation
import XCTest

/// Shared test helper that spawns the api2file-mcp binary and communicates via stdin/stdout.
/// Uses readabilityHandler for non-blocking pipe reads to avoid deadlocks.
final class MCPTestHarness {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let lock = NSLock()
    private var receivedLines: [String] = []
    private var partialLine = ""

    private let responseTimeout: TimeInterval = 10.0
    private var nextId = 1

    let binaryPath: URL

    init(binaryPath: URL) {
        self.binaryPath = binaryPath
    }

    /// Locate the built api2file-mcp binary. Builds it if needed.
    static func locateBinary() throws -> URL {
        let projectRoot = findProjectRoot()
        let binaryPath = projectRoot.appendingPathComponent(".build/debug/api2file-mcp")

        if !FileManager.default.fileExists(atPath: binaryPath.path) {
            let buildProcess = Process()
            buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            buildProcess.arguments = ["build", "--product", "api2file-mcp"]
            buildProcess.currentDirectoryURL = projectRoot
            let buildPipe = Pipe()
            buildProcess.standardOutput = buildPipe
            buildProcess.standardError = buildPipe
            try buildProcess.run()
            buildProcess.waitUntilExit()
            guard buildProcess.terminationStatus == 0 else {
                let output = String(data: buildPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw MCPHarnessError.buildFailed("swift build failed: \(output)")
            }
        }

        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            throw MCPHarnessError.binaryNotFound(binaryPath.path)
        }

        return binaryPath
    }

    /// Start the MCP binary process with optional environment variables.
    func start(env: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = binaryPath

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Set up non-blocking read on stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            self?.lock.lock()
            self?.partialLine += str
            // Split into complete lines
            while let range = self?.partialLine.range(of: "\n") {
                let line = String(self!.partialLine[self!.partialLine.startIndex..<range.lowerBound])
                self?.partialLine = String(self!.partialLine[range.upperBound...])
                if !line.isEmpty {
                    self?.receivedLines.append(line)
                }
            }
            self?.lock.unlock()
        }

        // Discard stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        // Brief pause to let process initialize
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Send a JSON-RPC request and wait for a response (with timeout).
    func sendRequest(_ params: [String: Any]) throws -> [String: Any] {
        let id = nextId
        nextId += 1

        var request = params
        request["jsonrpc"] = "2.0"
        request["id"] = id

        try writeLine(request)
        return try waitForResponse(timeout: responseTimeout)
    }

    /// Send a JSON-RPC notification (no response expected).
    func sendNotification(_ params: [String: Any]) throws {
        var notification = params
        notification["jsonrpc"] = "2.0"
        try writeLine(notification)
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Send raw text to stdin (for malformed JSON tests).
    func sendRaw(_ text: String) throws {
        guard let stdinPipe else { throw MCPHarnessError.notStarted }
        stdinPipe.fileHandleForWriting.write((text + "\n").data(using: .utf8)!)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Read any available response without blocking (for notification tests).
    func readAvailable() -> [String: Any]? {
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock()
        defer { lock.unlock() }

        guard !receivedLines.isEmpty else { return nil }
        let line = receivedLines.removeFirst()
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }

    /// Stop the MCP binary process.
    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            stdinPipe?.fileHandleForWriting.closeFile()
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        lock.lock()
        receivedLines.removeAll()
        partialLine = ""
        lock.unlock()
    }

    // MARK: - Private

    private func writeLine(_ json: [String: Any]) throws {
        guard let stdinPipe else { throw MCPHarnessError.notStarted }
        let data = try JSONSerialization.data(withJSONObject: json)
        guard var line = String(data: data, encoding: .utf8) else {
            throw MCPHarnessError.encodingFailed
        }
        line += "\n"
        stdinPipe.fileHandleForWriting.write(line.data(using: .utf8)!)
    }

    private func waitForResponse(timeout: TimeInterval) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            lock.lock()
            if !receivedLines.isEmpty {
                let line = receivedLines.removeFirst()
                lock.unlock()

                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json
                }
                // Not valid JSON, keep waiting
                continue
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw MCPHarnessError.timeout
    }

    static func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let packageSwift = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: packageSwift.path) {
                return dir
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

enum MCPHarnessError: Error, LocalizedError {
    case buildFailed(String)
    case binaryNotFound(String)
    case encodingFailed
    case notStarted
    case timeout

    var errorDescription: String? {
        switch self {
        case .buildFailed(let msg): return "MCP binary build failed: \(msg)"
        case .binaryNotFound(let path): return "MCP binary not found at \(path)"
        case .encodingFailed: return "Failed to encode JSON"
        case .notStarted: return "MCP harness not started"
        case .timeout: return "MCP response timed out after 10s"
        }
    }
}
