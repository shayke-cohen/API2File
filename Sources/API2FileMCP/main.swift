import Foundation

// API2File MCP Server
// Speaks MCP protocol (JSON-RPC 2.0) over stdin/stdout.
// Communicates with the running API2File.app via HTTP on localhost.
// Zero dependencies on API2FileCore — pure Foundation.

let server = MCPServer()
server.run()
