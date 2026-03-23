import Foundation
import API2FileCore

// API2File Demo — Standalone demo server for testing
// Usage: swift run api2file-demo [port]

let port: UInt16 = CommandLine.arguments.count > 1
    ? UInt16(CommandLine.arguments[1]) ?? 8089
    : 8089

print("""
╔══════════════════════════════════════════════════════╗
║           API2File Demo Server                       ║
║                                                      ║
║  A local REST API for testing API2File sync.         ║
║  No account needed — everything runs locally.        ║
╚══════════════════════════════════════════════════════╝
""")

let server = DemoAPIServer(port: port)

Task {
    do {
        try await server.start()
    } catch {
        print("Failed to start demo server: \(error)")
        exit(1)
    }
}

print("")
print("Try it:")
print("  curl http://localhost:\(port)/api/tasks | jq .")
print("  curl -X POST http://localhost:\(port)/api/tasks -H 'Content-Type: application/json' -d '{\"name\":\"Test\",\"status\":\"todo\"}'")
print("")
print("Press Ctrl+C to stop.")
print("")

// Keep the process running
dispatchMain()
