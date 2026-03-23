# API2File — Manual Testing Guide

## Quick Start (Demo Mode)

### 1. Build the project
```bash
swift build
```

### 2. Run the setup script
```bash
./scripts/demo-setup.sh
```
This creates `~/API2File/demo/` with the adapter config and initializes git.

### 3. Test the Demo API server directly
In a terminal, start a quick test:
```bash
# List tasks (3 seed tasks)
curl -s http://localhost:8089/api/tasks | jq .

# Create a task
curl -s -X POST http://localhost:8089/api/tasks \
  -H "Content-Type: application/json" \
  -d '{"name":"New task","status":"todo","priority":"high","assignee":"You"}' | jq .

# Update a task
curl -s -X PUT http://localhost:8089/api/tasks/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"Buy organic groceries","status":"done"}' | jq .

# Delete a task
curl -s -X DELETE http://localhost:8089/api/tasks/3 | jq .
```

### 4. Test the Control API
```bash
# Health check
curl -s http://localhost:21567/api/health | jq .

# List connected services
curl -s http://localhost:21567/api/services | jq .

# Trigger sync for demo service
curl -s -X POST http://localhost:21567/api/services/demo/sync | jq .

# Validate an adapter config
curl -s -X POST http://localhost:21567/api/adapters/validate \
  -H "Content-Type: application/json" \
  -d @~/API2File/demo/.api2file/adapter.json | jq .
```

### 5. Test the sync flow manually

**Pull (server → local file):**
```bash
# After sync, check the CSV file
cat ~/API2File/demo/tasks.csv

# Open in Numbers (macOS)
open ~/API2File/demo/tasks.csv
```

Expected CSV content:
```csv
_id,assignee,dueDate,name,priority,status
1,Alice,2026-03-25,Buy groceries,medium,todo
2,Bob,2026-03-24,Fix login bug,high,in-progress
3,Alice,2026-03-20,Write docs,low,done
```

**Push (local edit → server):**
1. Open `~/API2File/demo/tasks.csv` in Numbers or a text editor
2. Change "Buy groceries" to "Buy organic groceries"
3. Save the file
4. Wait 10 seconds (sync interval) or trigger manually:
   ```bash
   curl -s -X POST http://localhost:21567/api/services/demo/sync
   ```
5. Verify the change hit the API:
   ```bash
   curl -s http://localhost:8089/api/tasks/1 | jq .name
   # Should return: "Buy organic groceries"
   ```

**Git history:**
```bash
cd ~/API2File/demo && git log --oneline
# Should show sync commits
```

**CLAUDE.md:**
```bash
cat ~/API2File/CLAUDE.md
cat ~/API2File/demo/CLAUDE.md
```

## Running Tests

```bash
# All tests (184+)
swift test

# Just the E2E tests with demo server
swift test --filter DemoServerE2E

# Just unit tests
swift test --filter "FormatConverter|TransformPipeline|Template|JSONPath|Keychain|HTTPClient|AdapterConfig|SyncState|GitManager|AgentGuide|SyncCoordinator"

# Just integration tests
swift test --filter "AdapterEngineIntegration|FullSyncCycle"
```

## Troubleshooting

**Port in use:**
If port 8089 (demo API) or 21567 (control API) is in use:
```bash
lsof -i :8089
lsof -i :21567
# Kill the process or change ports in the config
```

**Keychain issues:**
```bash
# Check if token exists
security find-generic-password -a "com.api2file.api2file.demo.key" -w 2>/dev/null

# Re-set token
security add-generic-password -a "com.api2file.api2file.demo.key" -s "com.api2file.api2file.demo.key" -w "demo-token" -U
```

**Clean restart:**
```bash
rm -rf ~/API2File/demo
./scripts/demo-setup.sh
```
