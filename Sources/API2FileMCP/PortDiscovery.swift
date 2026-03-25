import Foundation

/// Discovers the running API2File.app instance by reading its server metadata file
/// and validating the process is alive and the HTTP API is responsive.
struct PortDiscovery {

    /// Discover the running API2File app and return a configured AppClient.
    /// Throws descriptive errors if the app is not running or unreachable.
    static func discover() throws -> AppClient {
        // 1. Locate server.json (env var override for testing)
        let serverFile: URL
        if let overridePath = ProcessInfo.processInfo.environment["API2FILE_SERVER_INFO_PATH"] {
            serverFile = URL(fileURLWithPath: overridePath)
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            serverFile = homeDir
                .appendingPathComponent(".api2file")
                .appendingPathComponent("server.json")
        }

        guard FileManager.default.fileExists(atPath: serverFile.path) else {
            throw DiscoveryError.noServerFile(
                "API2File is not running. Could not find \(serverFile.path). " +
                "Please launch API2File.app first."
            )
        }

        // 2. Parse server.json
        let data = try Data(contentsOf: serverFile)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DiscoveryError.invalidServerFile("server.json is not a valid JSON object.")
        }

        guard let port = json["port"] as? Int else {
            throw DiscoveryError.invalidServerFile("server.json missing 'port' field.")
        }

        // 3. Validate PID is alive (if present)
        if let pid = json["pid"] as? Int32 {
            if kill(pid, 0) != 0 {
                throw DiscoveryError.appNotRunning(
                    "API2File process (PID \(pid)) is not running. " +
                    "Please launch API2File.app and try again."
                )
            }
        }

        // 4. Build the client
        let client = AppClient(port: port)

        // 5. Health check
        do {
            let (status, _) = try client.get("/api/health")
            if status < 200 || status >= 300 {
                throw DiscoveryError.healthCheckFailed(
                    "API2File health check returned HTTP \(status). The app may be starting up."
                )
            }
        } catch let error as DiscoveryError {
            throw error
        } catch {
            throw DiscoveryError.healthCheckFailed(
                "Cannot reach API2File at http://127.0.0.1:\(port). " +
                "Error: \(error.localizedDescription). " +
                "Make sure API2File.app is running."
            )
        }

        return client
    }
}

enum DiscoveryError: Error, CustomStringConvertible {
    case noServerFile(String)
    case invalidServerFile(String)
    case appNotRunning(String)
    case healthCheckFailed(String)

    var description: String {
        switch self {
        case .noServerFile(let msg): return msg
        case .invalidServerFile(let msg): return msg
        case .appNotRunning(let msg): return msg
        case .healthCheckFailed(let msg): return msg
        }
    }
}
