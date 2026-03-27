# API2File — Testing Guide

## Test Suite Overview

**Total tests: 537** across 28 test classes.

```bash
# Run all 537 tests
swift test

# Quick check — just build
swift build
```

---

## Test Categories

### Unit Tests

Tests for individual components in isolation. No network, no filesystem side effects.

```bash
# All unit tests at once
swift test --filter "FormatConverter|TransformPipeline|Template|JSONPath|Keychain|HTTPClient|AdapterConfig|SyncState|GitManager|AgentGuide|SyncCoordinator|OAuth2Handler|NotificationManager|CollectionDiffer|ICSVCFFormat|EMLSVGWebloc"
```

| Test Class | What It Covers |
| --- | --- |
| `FormatConverterTests` | All 15 format converters (json, csv, html, md, yaml, txt, raw, ics, vcf, eml, svg, webloc, xlsx, docx, pptx) |
| `ICSVCFFormatTests` | iCalendar and vCard encode/decode edge cases |
| `EMLSVGWeblocFormatTests` | Email, SVG, and webloc format edge cases |
| `TransformPipelineTests` | pick, omit, rename, flatten, expand, keyBy, template transforms |
| `TemplateEngineTests` | Template string interpolation with filters (slugify, lower, upper, default, dateFormat) |
| `JSONPathTests` | JSONPath extraction (`$.data.items`, nested paths, arrays) |
| `AdapterConfigTests` | Full and minimal adapter config decoding, SyncState round-trip |
| `SyncStateTests` | SyncState persistence, file status tracking |
| `GlobalConfigTests` | Global config defaults, load/save, resolved sync folder |
| `SyncableFileTests` | File + metadata model |
| `SyncStatusTests` | Status enum values |
| `HTTPClientTests` | URLSession wrapper, auth headers, request building |
| `KeychainManagerTests` | Keychain save/load/delete operations |
| `GitManagerTests` | Git init, commit, gitignore creation |
| `AgentGuideGeneratorTests` | CLAUDE.md generation from adapter configs |
| `SyncCoordinatorTests` | Queue management, debounce, per-file locking |
| `OAuth2HandlerTests` | OAuth2 authorization URL building, token exchange |
| `NotificationManagerTests` | Notification posting and category setup |
| `CollectionDifferTests` | Record diffing: created, updated, deleted detection |

### Integration Tests

Tests that exercise multiple components together. May use temp directories and in-memory servers.

```bash
# All integration tests
swift test --filter "AdapterEngineIntegration|FullSyncCycle|DemoAdapterConfig|DemoAdapterPipeline|CollectionDiffE2E"
```

| Test Class | What It Covers |
| --- | --- |
| `AdapterEngineIntegrationTests` | Full pipeline: config loading, JSONPath extraction, transform pipeline, format conversion, file I/O round-trips |
| `FullSyncCycleTests` | End-to-end sync cycle with mock HTTP responses |
| `DemoAdapterConfigTests` | All 12 bundled adapter configs parse correctly |
| `DemoAdapterPipelineTests` | Adapter pipeline with demo server data through transforms and format conversion |
| `CollectionDiffE2ETests` | Collection diffing with real CSV/JSON files: edit rows, add rows, delete rows, verify correct API calls |

### E2E Tests (Live Demo Server)

Tests that start the `DemoAPIServer` on port 8089, run real HTTP requests, and verify responses. These test actual network I/O.

```bash
# All E2E tests
swift test --filter "DemoServerE2E|DemoServerAllResources|BidirectionalSync|RealSync"
```

| Test Class | What It Covers |
| --- | --- |
| `DemoServerE2ETests` | CRUD operations on demo tasks API |
| `DemoServerAllResourcesE2ETests` | All 14 resource types: tasks, contacts, events, notes, pages, config, services, incidents, logos, photos, documents, spreadsheets, reports, presentations |
| `BidirectionalSyncE2ETests` | Full round-trip: pull CSV from server, edit locally, push back, verify server state |
| `RealSyncE2ETests` | SyncEngine + DemoAPIServer + real file I/O: pull to disk, verify file contents, edit, push back |

---

## CLI Testing

The CLI tool (`api2file`) can be tested directly after building.

```bash
# Build
swift build

# Test help output
swift run api2file help

# Test init (creates ~/API2File-Data/)
swift run api2file init

# Test list (shows 5 bundled adapters)
swift run api2file list

# Test status (shows connected services)
swift run api2file status

# Test add (interactive — prompts for API key)
swift run api2file add demo

# Test sync (requires demo server running)
swift run api2file sync demo

# Test pull (requires demo server running)
swift run api2file pull demo
```

### CLI Test Checklist

- [ ] `help` prints usage with all 7 commands
- [ ] `init` creates `~/API2File-Data/.api2file.json` with defaults
- [ ] `init` (second time) warns "already exists"
- [ ] `list` shows demo, monday, wix, github, airtable
- [ ] `add demo` writes adapter config, saves Keychain key, inits git
- [ ] `add unknown` prints error with available services
- [ ] `status` shows service name, resource count, file count, last sync
- [ ] `sync` with demo server running pulls files and reports count
- [ ] `pull` fetches data without full sync engine startup

---

## Collection Diff Testing

The `CollectionDiffer` is tested at both unit and integration levels.

### Unit tests (`CollectionDifferTests`)

```bash
swift test --filter CollectionDiffer
```

Covers:

- Empty old + new records (no changes)
- Detect new records (no ID or new ID)
- Detect updated records (same ID, different fields)
- Detect deleted records (ID in old, missing in new)
- Mixed create + update + delete in one diff
- Type normalization (Int "1" vs String "1")
- DiffResult.summary formatting
- DiffResult.isEmpty

### Integration tests (`CollectionDiffE2ETests`)

```bash
swift test --filter CollectionDiffE2E
```

Covers:

- CSV file edit -> diff -> verify correct create/update/delete lists
- JSON array edit -> diff -> verify
- Round-trip: pull collection, edit, diff, push individual operations

---

## Media Sync Testing

The media sync feature handles binary file download/upload via `pullMediaFiles()` and `pushMediaFile()` in `AdapterEngine`.

### What to test

- **Pull with `"type": "media"`:** Adapter fetches a list of file metadata from the API, then downloads each file's binary content from the URL in the `mediaConfig.urlField` field.
- **Filename resolution:** Files are named using the `mediaConfig.filenameField` from the API response.
- **Hash-based skip:** When `hashField` is configured, unchanged files can be skipped on subsequent pulls.
- **Push via signed URL:** `pushMediaFile()` calls the create endpoint to get an upload URL, then PUTs the binary data to it.
- **Mirror strategy:** Media resources use `"strategy": "mirror"` so files land in the configured directory preserving their original filenames.

### Manual verification (Wix)

After syncing a Wix service with media configured:

```bash
# Verify media directory exists with downloaded files
ls ~/API2File-Data/wix/media/

# Check that files are valid binaries (not JSON)
file ~/API2File-Data/wix/media/*

# Verify file sizes are reasonable (not 0 bytes)
du -sh ~/API2File-Data/wix/media/*
```

### Adapter config reference

The Wix adapter (`~/API2File-Data/wix/.api2file/adapter.json`) includes a `media` resource with `"type": "media"` and a `mediaConfig` block specifying `urlField`, `filenameField`, `idField`, `sizeField`, and `hashField`.

---

## Manual Testing — Quick Start (Demo Mode)

### 1. Build the project

```bash
swift build
```

### 2. Run the setup script

```bash
./scripts/demo-setup.sh
```

This creates `~/API2File-Data/demo/` with the adapter config and initializes git.

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
  -d @~/API2File-Data/demo/.api2file/adapter.json | jq .
```

### 5. Test the sync flow manually

**Pull (server -> local file):**

```bash
# After sync, check the CSV file
cat ~/API2File-Data/demo/tasks.csv

# Open in Numbers (macOS)
open ~/API2File-Data/demo/tasks.csv
```

Expected CSV content:

```csv
_id,assignee,dueDate,name,priority,status
1,Alice,2026-03-25,Buy groceries,medium,todo
2,Bob,2026-03-24,Fix login bug,high,in-progress
3,Alice,2026-03-20,Write docs,low,done
```

**Push (local edit -> server):**

1. Open `~/API2File-Data/demo/tasks.csv` in Numbers or a text editor
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
cd ~/API2File-Data/demo && git log --oneline
# Should show sync commits
```

**CLAUDE.md:**

```bash
cat ~/API2File-Data/CLAUDE.md
cat ~/API2File-Data/demo/CLAUDE.md
```

---

## Full Showcase (6 Demo Adapters)

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

This creates 6 service directories under `~/API2File-Data/`:

| Service | Simulates | Formats |
| --- | --- | --- |
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
# After sync: open ~/API2File-Data/calsync/calendar.ics  -> Calendar.app
```

**PageCraft** (HTML + Markdown + JSON):

```bash
curl -s http://localhost:8089/api/pages | jq .
# After sync: open ~/API2File-Data/pagecraft/pages/home.html  -> Safari
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

The demo server also exposes additional resources for Office format testing:

```bash
# Spreadsheet data (XLSX)
curl -s http://localhost:8089/api/spreadsheets | jq '.[].name'

# Report documents (DOCX)
curl -s http://localhost:8089/api/reports | jq '.[].name'

# Presentation slides (PPTX)
curl -s http://localhost:8089/api/presentations | jq '.[].name'
```

### 4. Native app integration

After a sync cycle, try opening files in their native macOS apps:

```bash
open ~/API2File-Data/calsync/calendar.ics                # Calendar.app
open ~/API2File-Data/peoplehub/contacts/                  # VCF files -> Contacts.app
open ~/API2File-Data/teamboard/tasks.csv                  # Numbers
open ~/API2File-Data/pagecraft/pages/home.html            # Safari
open ~/API2File-Data/devops/incidents.csv                 # Numbers
open ~/API2File-Data/mediamanager/logos/app-icon.svg       # Preview (SVG)
open ~/API2File-Data/mediamanager/photos/red-swatch.png    # Preview (PNG)
open ~/API2File-Data/mediamanager/documents/q1-report.pdf  # Preview (PDF)
```

### 5. Clean up

```bash
rm -rf ~/API2File-Data/teamboard ~/API2File-Data/peoplehub ~/API2File-Data/calsync ~/API2File-Data/pagecraft ~/API2File-Data/devops ~/API2File-Data/mediamanager
```

---

## Testing the macOS App

### 1. Build and launch

```bash
# Debug build + run
swift run API2FileApp

# Or build the .app bundle
swift build -c release
open build/API2File.app
```

### 2. Test Add Service flow

1. Click the cloud icon in the menu bar
2. Click **"Add Service..."** -- a wizard window should open
3. Select **Demo Tasks API** -- enter any value as the API key -> Connect
4. Verify: Demo API appears in the menu bar dropdown with green status

### 3. Test Wix/Airtable extra fields

1. Open Add Service -> select **Wix**
2. Verify: both "Site ID" and "Site URL" fields appear below the API key field
3. Verify: after sync, 14 top-level resources are pulled, including contacts, blog posts, products, groups, comments, bookings services, appointments, collections, and media-backed directories
4. Verify: `~/API2File-Data/wix/media/`, `~/API2File-Data/wix/pdf-viewer/`, `~/API2File-Data/wix/wix-video/`, and `~/API2File-Data/wix/wix-music-podcasts/` exist with downloaded binary files
5. Verify: `~/API2File-Data/wix/.api2file/file-links.json` exists and links `blog/*.md` files to matching `.objects/*.json` canonical files
6. Verify: pulled Wix blog Markdown files contain body content, not just frontmatter
7. Open Add Service -> select **Airtable**
8. Verify: "Base ID" and "Table Name" fields appear

### 4. Test Service Detail View

1. Open **Preferences -> Services** tab
2. Click on a connected service in the sidebar
3. Verify: detail view shows status, last sync time, file count, resource list
4. Test actions: Sync Now, Open Folder, Update Key, Disconnect

### 5. Test per-service sync

1. In the menu bar, hover over a service name to open its submenu
2. Click **Sync Now** -- service should sync independently
3. Verify: last sync time updates

### 6. Test service removal

1. Open Preferences -> Services -> click a service -> **Disconnect...**
2. Confirm the dialog
3. Verify: service disappears from the list; files at `~/API2File-Data/{service}/` are preserved

---

## Running Tests (Quick Reference)

```bash
# All tests (537)
swift test

# Just the E2E tests with demo server
swift test --filter DemoServerE2E

# Just adapter config parsing tests
swift test --filter DemoAdapterConfig

# Just unit tests (all)
swift test --filter "FormatConverter|TransformPipeline|Template|JSONPath|Keychain|HTTPClient|AdapterConfig|SyncState|GitManager|AgentGuide|SyncCoordinator|OAuth2Handler|NotificationManager|CollectionDiffer"

# Just integration tests
swift test --filter "AdapterEngineIntegration|FullSyncCycle|CollectionDiffE2E"

# Just bidirectional sync E2E
swift test --filter "BidirectionalSync|RealSync"

# Focused live Wix blog markdown/Ricos tests
swift test --filter WixLiveE2ETests/testBlogPosts_Pull_WritesMarkdownBodyFromContentText
swift test --filter WixLiveE2ETests/testBlogPosts_Update_MarkdownBodyPush_ReflectedOnServer
swift test --filter WixLiveE2ETests/testBlogPosts_Update_MarkdownStructurePush_PreservesRichContentNodes

# Just collection diffing
swift test --filter "CollectionDiffer|CollectionDiffE2E"

# Just format converters
swift test --filter "FormatConverter|ICSVCFFormat|EMLSVGWebloc"
```

---

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
rm -rf ~/API2File-Data/demo
./scripts/demo-setup.sh
```
