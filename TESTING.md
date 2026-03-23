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

## Full Showcase (5 Demo Adapters)

The showcase sets up 6 themed adapters, each simulating a real-world service with different file formats.

### 1. Build and start the demo server

```bash
swift build
swift run api2file-demo
```

### 2. Set up all 6 adapters

In another terminal:
```bash
./scripts/demo-all-setup.sh
```

This creates 6 service directories under `~/API2File/`:

| Service | Simulates | Formats |
|---|---|---|
| `teamboard/` | Project management | CSV + YAML |
| `peoplehub/` | CRM & contacts | VCF + Markdown |
| `calsync/` | Calendar | ICS + CSV |
| `pagecraft/` | CMS / website | HTML + Markdown + JSON |
| `devops/` | Infrastructure | JSON + CSV |
| `mediamanager/` | Digital assets | SVG + PNG + PDF |

### 3. Test each adapter

**TeamBoard** (CSV + YAML):
```bash
curl -s http://localhost:8089/api/tasks | jq .
curl -s http://localhost:8089/api/config | jq .
```

**PeopleHub** (VCF + Markdown):
```bash
curl -s http://localhost:8089/api/contacts | jq .
curl -s http://localhost:8089/api/notes | jq .
```

**CalSync** (ICS + CSV):
```bash
curl -s http://localhost:8089/api/events | jq .
# After sync: open ~/API2File/calsync/calendar.ics  → Calendar.app
```

**PageCraft** (HTML + Markdown + JSON):
```bash
curl -s http://localhost:8089/api/pages | jq .
# After sync: open ~/API2File/pagecraft/pages/home.html  → Safari
```

**DevOps** (JSON + CSV):
```bash
# Services — one JSON file per microservice
curl -s http://localhost:8089/api/services | jq .

# Incidents — CSV spreadsheet
curl -s http://localhost:8089/api/incidents | jq .
```

**MediaManager** (SVG + PNG + PDF):
```bash
# SVG logos — vector graphics
curl -s http://localhost:8089/api/logos | jq '.[].name'

# PNG photos — base64-encoded images
curl -s http://localhost:8089/api/photos | jq '.[].name'

# PDF documents — base64-encoded PDFs
curl -s http://localhost:8089/api/documents | jq '.[].name'
```

### 4. Native app integration

After a sync cycle, try opening files in their native macOS apps:
```bash
open ~/API2File/calsync/calendar.ics                # Calendar.app
open ~/API2File/peoplehub/contacts/                  # VCF files → Contacts.app
open ~/API2File/teamboard/tasks.csv                  # Numbers
open ~/API2File/pagecraft/pages/home.html            # Safari
open ~/API2File/devops/incidents.csv                 # Numbers
open ~/API2File/mediamanager/logos/app-icon.svg       # Preview (SVG)
open ~/API2File/mediamanager/photos/red-swatch.png    # Preview (PNG)
open ~/API2File/mediamanager/documents/q1-report.pdf  # Preview (PDF)
```

### 5. Clean up

```bash
rm -rf ~/API2File/teamboard ~/API2File/peoplehub ~/API2File/calsync ~/API2File/pagecraft ~/API2File/devops ~/API2File/mediamanager
```

---

## Running Tests

```bash
# All tests (284+)
swift test

# Just the E2E tests with demo server
swift test --filter DemoServerE2E

# Just adapter config parsing tests
swift test --filter DemoAdapterConfig

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
