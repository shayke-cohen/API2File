#!/bin/bash
# API2File Demo Setup
# Sets up everything needed to test API2File with the demo tasks server.

set -e

SYNC_DIR="$HOME/API2File"
DEMO_DIR="$SYNC_DIR/demo"

echo "=== API2File Demo Setup ==="
echo ""

# 1. Create sync directory
echo "1. Creating sync directory at $SYNC_DIR..."
mkdir -p "$DEMO_DIR/.api2file"

# 2. Copy demo adapter config
echo "2. Installing demo adapter config..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cat > "$DEMO_DIR/.api2file/adapter.json" << 'ADAPTER'
{
  "service": "demo",
  "displayName": "Demo Tasks API",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.demo.key",
    "setup": {
      "instructions": "No auth needed — this is a local demo server. Set any value."
    }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": {
      "Content-Type": "application/json"
    }
  },
  "resources": [
    {
      "name": "tasks",
      "description": "Demo task list — a simple todo list for testing API2File",
      "pull": {
        "method": "GET",
        "url": "http://localhost:8089/api/tasks",
        "dataPath": "$"
      },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/tasks" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/tasks/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/tasks/{id}" }
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": ".",
        "filename": "tasks.csv",
        "format": "csv",
        "idField": "id"
      },
      "sync": { "interval": 10, "debounceMs": 500 }
    }
  ]
}
ADAPTER

# 3. Create global config
echo "3. Creating global config..."
cat > "$SYNC_DIR/.api2file.json" << 'CONFIG'
{
  "syncFolder": "~/API2File",
  "gitAutoCommit": true,
  "commitMessageFormat": "sync: {service} — {summary}",
  "defaultSyncInterval": 60,
  "showNotifications": true,
  "finderBadges": true,
  "serverPort": 21567,
  "launchAtLogin": false
}
CONFIG

# 4. Set a dummy auth token
echo "4. Setting demo auth token in Keychain..."
security add-generic-password -a "com.api2file.api2file.demo.key" -s "com.api2file.api2file.demo.key" -w "demo-token" -U 2>/dev/null || true

# 5. Init git
echo "5. Initializing git in demo service folder..."
cd "$DEMO_DIR"
if [ ! -d ".git" ]; then
    git init -q
    echo ".api2file/" > .gitignore
    git add .gitignore
    git commit -q -m "init: demo service"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Start the demo API server (in a separate terminal):"
echo "     cd $(dirname "$SCRIPT_DIR") && swift run API2FileApp"
echo ""
echo "  2. Or test the API manually:"
echo "     curl http://localhost:8089/api/tasks"
echo ""
echo "  3. Your sync folder is at: $SYNC_DIR"
echo "     After sync, tasks will appear at: $DEMO_DIR/tasks.csv"
echo ""
echo "  4. Edit tasks.csv in Numbers/Excel, save → changes push to the API"
echo ""
