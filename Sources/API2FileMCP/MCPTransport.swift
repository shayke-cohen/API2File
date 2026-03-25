import Foundation

/// Reads newline-delimited JSON-RPC messages from stdin and writes responses to stdout.
final class MCPTransport {
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    /// Read lines from stdin, parse as JSON-RPC requests, and call the handler for each.
    /// This blocks until stdin is closed (EOF).
    func run(handler: (JSONRPCRequest) -> JSONRPCResponse?) {
        // Read stdin line by line
        var buffer = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                // EOF
                break
            }
            buffer.append(chunk)

            // Process complete lines
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                // Skip empty lines
                guard !lineData.isEmpty else { continue }

                // Parse JSON-RPC request
                guard let request = try? decoder.decode(JSONRPCRequest.self, from: Data(lineData)) else {
                    // Send parse error
                    let errorResponse = JSONRPCResponse(id: nil, error: .parseError)
                    send(errorResponse)
                    continue
                }

                // Handle the request
                if let response = handler(request) {
                    send(response)
                }
                // If handler returns nil, it's a notification — no response needed
            }
        }
    }

    /// Send a JSON-RPC response as a single line to stdout, followed by a newline.
    func send(_ response: JSONRPCResponse) {
        guard let data = try? encoder.encode(response) else { return }
        var outputData = data
        outputData.append(contentsOf: [newline])
        output.write(outputData)
        // Flush stdout — on macOS FileHandle.standardOutput is unbuffered,
        // but we call synchronizeFile to be safe.
        // Note: synchronizeFile only works on file descriptors that support it;
        // for stdout connected to a pipe this is a no-op, which is fine because
        // FileHandle.write is synchronous.
        fflush(stdout)
    }

    private let newline = UInt8(ascii: "\n")
}
