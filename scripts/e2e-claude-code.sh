#!/bin/bash
# E2E test: Claude Code + API2File MCP + Demo Server
# Requires: claude CLI installed, ANTHROPIC_API_KEY set
#
# This script starts the demo server and CLI, generates an MCP config,
# then opens Claude Code. Ask it to:
#   "List services, navigate to the demo dashboard, take a screenshot,
#    edit a task, sync and verify the change."

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

cleanup() {
    echo ""
    echo "Cleaning up..."
    [ -n "$DEMO_PID" ] && kill "$DEMO_PID" 2>/dev/null || true
    [ -n "$CLI_PID" ] && kill "$CLI_PID" 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

# Check prerequisites
if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "Warning: ANTHROPIC_API_KEY not set. Claude Code may prompt for it."
fi

echo "=== Building API2File ==="
swift build 2>&1 | tail -3

echo ""
echo "=== Starting Demo Server (port 8089) ==="
swift run api2file-demo &
DEMO_PID=$!
sleep 2

echo "=== Starting CLI (sync engine + local server) ==="
swift run api2file &
CLI_PID=$!
sleep 3

echo "=== Generating MCP config ==="
MCP_BINARY="$PROJECT_DIR/.build/debug/api2file-mcp"
MCP_CONFIG="$HOME/.api2file/mcp.json"
mkdir -p "$HOME/.api2file"
cat > "$MCP_CONFIG" << EOF
{
  "mcpServers": {
    "api2file": {
      "command": "$MCP_BINARY",
      "args": []
    }
  }
}
EOF
echo "MCP config: $MCP_CONFIG"
echo "MCP binary: $MCP_BINARY"

echo ""
echo "=== Launching Claude Code ==="
echo "Suggested prompts:"
echo "  1. What services are connected? (uses get_services)"
echo "  2. Navigate to the demo dashboard and take a screenshot"
echo "  3. Edit tasks.csv to mark the first task as done, sync, and verify"
echo ""

cd "$HOME/API2File-Data"
claude --mcp-config "$MCP_CONFIG"
