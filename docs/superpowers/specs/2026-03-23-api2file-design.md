# API2File — Design Specification

**Date:** 2026-03-23
**Status:** Draft

## Overview

API2File is a native macOS application that bidirectionally syncs cloud API data to local files. It acts as a bridge between cloud services (Wix, Monday.com, Netlify, etc.) and the local filesystem, enabling users and AI agents to interact with cloud data through familiar file operations.

Think Dropbox, but instead of syncing files to files, it syncs API data to files — and back.

## Problem

Cloud services trap data behind web UIs and APIs. Local AI agents (Claude Code, etc.) and power users can't access this data without writing custom scripts for each service. There's no standardized way to:

- Browse cloud data as local files
- Edit cloud data with local tools (editors, scripts, AI agents)
- Track changes to cloud data over time
- Work offline and sync back when ready

## Solution

A native macOS menu bar app with a config-driven adapter system that maps any REST/GraphQL API to a local folder structure. Changes flow bidirectionally — edit a file locally and it pushes to the API; data changes on the server sync down to local files. Git auto-commits provide version history.

---

## Architecture

### High-Level Components

```
┌─────────────────────────────────────────────┐
│              API2File.app                     │
│                                              │
│  ┌──────────────┐  ┌─────────────────────┐  │
│  │  Menu Bar UI  │  │  Finder Extension   │  │
│  │  (SwiftUI)    │  │  (Finder Sync)      │  │
│  └──────┬───────┘  └────────┬────────────┘  │
│         │                    │               │
│  ┌──────▼────────────────────▼──────────┐   │
│  │          Sync Engine (Core)           │   │
│  │  ┌─────────┐ ┌──────────┐ ┌───────┐  │   │
│  │  │ File    │ │ Conflict │ │ Git   │  │   │
│  │  │ Watcher │ │ Resolver │ │ Mgr   │  │   │
│  │  └─────────┘ └──────────┘ └───────┘  │   │
│  └──────────────────┬───────────────────┘   │
│                     │                        │
│  ┌──────────────────▼───────────────────┐   │
│  │        Adapter Engine                 │   │
│  │  Interprets .adapter.json configs     │   │
│  └──┬──────────┬──────────┬─────────┘   │
│     │          │          │              │
│  ┌──▼──┐  ┌───▼──┐  ┌───▼────┐         │
│  │ Wix │  │Mon.  │  │Netlify │  ...     │
│  │.json│  │.json │  │.json   │         │
│  └─────┘  └──────┘  └────────┘         │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │  Keychain Manager                 │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

### Technology

- **Language:** Swift (pure — no Node.js sidecar)
- **UI:** SwiftUI (menu bar, preferences, conflict resolver)
- **File watching:** FSEvents (macOS native)
- **HTTP:** URLSession with async/await
- **Auth storage:** macOS Keychain (via Security framework)
- **Git:** libgit2 (via SwiftGit2) or shell `git` commands
- **Finder integration:** Finder Sync Extension (separate target)
- **Launch at login:** SMAppService (modern macOS API)

---

## Adapter System (Config-Driven)

The core innovation: service adapters are JSON config files, not compiled code. A generic adapter engine interprets these configs to handle auth, API calls, pagination, data transformation, and file mapping.

Each service's config lives at `~/API2File/{service}/.api2file/adapter.json`. Bundled adapter configs ship inside the app at `Resources/Adapters/{service}.adapter.json` and are copied to the service folder on first connection.

### Adapter Config Schema

```json
{
  "service": "<service-id>",
  "displayName": "<human name>",
  "version": "1.0",

  "auth": {
    "type": "bearer | oauth2 | apiKey | basic",
    "keychainKey": "api2file.<service>.<key-name>",
    "setup": {
      "instructions": "Human-readable setup instructions",
      "url": "URL to get the API key/token"
    },
    // OAuth2 specific:
    "authorizeUrl": "...",
    "tokenUrl": "...",
    "refreshUrl": "...",
    "scopes": ["..."],
    "callbackPort": 21568
  },

  "globals": {
    "baseUrl": "https://api.example.com",
    "headers": { "custom-header": "value" },
    "method": "GET"
  },

  "resources": [
    {
      "name": "<resource-name>",
      "description": "...",

      "pull": {
        "method": "GET | POST",
        "url": "{baseUrl}/path",
        "type": "rest | graphql",
        "query": "GraphQL query string",
        "body": {},
        "dataPath": "$.jsonpath.to.data",
        "pagination": {
          "type": "cursor | offset | page",
          "nextCursorPath": "$.path.to.cursor",
          "pageSize": 50
        }
      },

      "push": {
        "create": { "method": "POST", "url": "...", "bodyWrapper": "key" },
        "update": { "method": "PATCH | PUT", "url": ".../{id}" },
        "delete": { "method": "DELETE", "url": ".../{id}" },
        "type": "fileUpload",
        "steps": []
      },

      "fileMapping": {
        "strategy": "one-per-record | collection | mirror",
        "directory": "path/template/{name}",
        "filename": "{field|filter}.ext",
        "format": "json | yaml | markdown | html | text | raw",
        "idField": "id",
        "contentField": "field for html/text format",
        "readOnly": false,
        "preserveExtension": false,
        "transforms": {
          "pull": [
            { "op": "pick | omit | rename | flatten | expand | keyBy | expandKeyBy | format | template", "...": "..." }
          ],
          "push": []
        }
      },

      "children": [],

      "sync": {
        "interval": 60,
        "debounceMs": 500
      }
    }
  ]
}
```

### File Mapping Strategies

| Strategy | Use Case | Example |
|---|---|---|
| `one-per-record` | Each API entity → its own file | Wix products → `products/dog-food.json` |
| `collection` | All entities → one file (CSV, JSON array) | Monday board → `boards/marketing.csv` |
| `mirror` | Preserve server file structure exactly | Web hosting files → `files/index.html` |

### File Formats

The adapter chooses the most natural format per resource type. Users interact with familiar files that open in default macOS apps — double-click to edit, save to sync.

**Phase 1 — Text-based formats (no conversion libraries needed):**

| Data Shape | Format | Opens Natively In | Example Use |
| --- | --- | --- | --- |
| Tabular data | `.csv` | Numbers, Excel, VS Code | Monday boards, form submissions |
| Rich text | `.md` | Any editor, Marked.app | Blog posts, docs, descriptions |
| Web content | `.html` | Safari, any browser | Site pages, email templates |
| Structured objects | `.json` | VS Code, any editor | Products, orders, configs |
| Config / settings | `.yaml` | Any editor | CI/CD pipelines, app config |
| Plain text | `.txt` | TextEdit | Notes, logs, plain content |
| Calendar events | `.ics` | **Calendar.app** | Bookings, schedules, meetings |
| Contacts | `.vcf` | **Contacts.app** | CRM contacts, leads, customers |
| Vector graphics | `.svg` | Preview, any browser | Logos, icons, design assets |
| Email content | `.eml` | **Mail.app** | Email drafts, campaign templates |
| Web bookmarks | `.webloc` | Finder → Safari | Links, saved URLs |
| Translations | `.strings` | Xcode | i18n / localization files |
| Tab-separated | `.tsv` | Numbers, Excel | Data exports, analytics |
| Images / media | `.jpg`, `.png`, `.gif`, `.pdf` | Preview.app, Finder | Product photos, assets |

**Phase 2 — Office formats (require Swift conversion libraries):**

| Data Shape | Format | Opens Natively In | Example Use | Library |
| --- | --- | --- | --- | --- |
| Rich spreadsheets | `.xlsx` | **Numbers, Excel** | Boards with types, colors, multiple sheets | CoreXLSX + custom writer |
| Documents | `.docx` | **Pages, Word** | Proposals, contracts, wiki pages | Custom OOXML generator |
| Presentations | `.pptx` | **Keynote, PowerPoint** | Pitch decks, reports | Custom OOXML generator |

**Format conversion architecture:** API data (JSON) flows through a **format layer** in the adapter engine that converts between the internal representation and the user-facing file format. The adapter config specifies format + options:

```json
{
  "fileMapping": {
    "format": "xlsx",
    "formatOptions": {
      "sheetMapping": "groups",
      "columnTypes": {
        "date": "date",
        "price": "currency:USD",
        "status": "enum:Done|Working|Stuck"
      }
    }
  }
}
```

For `.ics` and `.vcf`, the engine maps API fields to standard vCard/iCalendar properties:

```json
{
  "fileMapping": {
    "format": "vcf",
    "formatOptions": {
      "fieldMapping": {
        "FN": "{firstName} {lastName}",
        "EMAIL": "{email}",
        "TEL": "{phone}",
        "ORG": "{company}"
      }
    }
  }
}
```

### Internal Files — All Hidden

All API2File internal data lives under hidden `.api2file/` directories:
- `.api2file/adapter.json` — adapter config
- `.api2file/state.json` — sync state, file-to-server-ID mapping, checksums
- `.api2file/logs/` — error/debug logs

User-facing files contain **only** the actual content — no `_syncMeta`, no internal IDs. The sync engine maps between file paths and server records via the hidden state file.

### Transform Operations

| Operation | Purpose | Example |
|---|---|---|
| `pick` | Keep only specified fields | `{ "op": "pick", "fields": ["id", "name", "price"] }` |
| `omit` | Remove specified fields | `{ "op": "omit", "fields": ["_internal", "metadata"] }` |
| `rename` | Rename a field (supports dot paths) | `{ "op": "rename", "from": "priceData.price", "to": "price" }` |
| `flatten` | Flatten nested array to simple values | `{ "op": "flatten", "path": "media.items", "to": "images", "select": "url" }` |
| `expand` | Reverse of flatten | `{ "op": "expand", "path": "images", "to": "media.items", "wrap": { "url": "$value" } }` |
| `keyBy` | Convert array of objects to keyed map | `{ "op": "keyBy", "path": "columns", "key": "id", "value": "text" }` |
| `template` | Format a field using a template string | `{ "op": "template", "field": "summary", "template": "{name} - ${price}" }` |

### Filename Filters

Template variables in `filename` support filters:
- `{name|slugify}` — lowercase, replace spaces with hyphens
- `{field|default:fallback}` — use fallback if field is empty
- `{date|dateFormat:yyyy-MM-dd}` — format dates
- `{name|lower}` / `{name|upper}` — case conversion

### Auth Types

| Type | Flow |
|---|---|
| `bearer` | Read token from Keychain, inject as `Authorization: Bearer <token>` |
| `apiKey` | Read key from Keychain, inject as configured header |
| `oauth2` | Built-in OAuth2 flow: open browser → user authorizes → callback server catches code → exchange for token → store in Keychain → auto-refresh |
| `basic` | Read username/password from Keychain, inject as `Authorization: Basic <base64>` |

### Sync Metadata — Hidden, Not In User Files

All sync metadata lives in `.api2file/state.json` — user files are 100% clean content. See the State Tracking section under Sync Engine for the canonical schema.

This means a product file contains only:

```json
{
  "name": "Premium Dog Food",
  "price": 29.99,
  "stock": 150
}
```

No internal metadata. Open in any editor, edit, save.

---

## Sync Engine

### Three Sync Triggers

1. **Local file change** (FSEvents) — debounced 500ms → push to API
2. **Poll timer** (per adapter, default 60s) — pull from API → update local
3. **Webhook** (Phase 3) — instant push notification from cloud → pull

### Pull Flow (Server → Local)

1. Adapter engine fetches current state from API (using ETags for efficiency)
2. Compare remote data hash with local file content hash
3. If different AND local file unchanged since last sync → overwrite local file
4. If different AND local file also changed → **conflict** → server wins, backup local as `.conflict` file
5. If same → no-op
6. Git auto-commit with message: `sync: pull {service} — updated {N} files`

### Push Flow (Local → Server)

1. FSEvents detects file modification in `~/API2File/{service}/`
2. Debounce 500ms to batch rapid saves
3. Validate file format (parse JSON, check required fields)
4. Adapter engine reads file, applies push transforms, calls API
5. On success → update `.api2file/state.json`, git commit: `sync: push {service} — {filename}`
6. On failure → mark file status as "error", retry with exponential backoff (1s, 5s, 15s), notify user after 3 failures

### Conflict Resolution

- **Strategy:** Server always wins (source of truth)
- **Backup:** Local version saved as `{filename}.conflict.{ext}` alongside the server version
- **Notification:** macOS notification with "View Conflict" action
- **Git:** Both versions committed — server version in main file, local version in `.conflict` file
- **Recovery:** User reviews `.conflict` file, merges manually, deletes `.conflict` when done
- **Multiple conflicts:** New conflicts overwrite previous `.conflict` files (old ones preserved in git history)

### Delete Propagation

| Direction | Behavior |
| --- | --- |
| Local file deleted | Queue a server-side delete. Apply after a 5-second grace period (allows undo via Cmd+Z in Finder). Adapter can override via `"deletePolicy": "propagate"` (default), `"ignore"`, or `"confirm"` (notify user first). |
| Server record deleted | Remove local file on next pull. Git preserves the file in history for recovery. |
| Read-only resource | Local file deletion is restored on next sync (file reappears). No server-side effect. |
| Entire service folder deleted | Treated as "disconnect service" — stop syncing, do NOT delete server data. Require explicit reconnect. |

### Sync Coordination

The `SyncCoordinator` manages concurrent operations:

- **Per-file lock:** Only one operation (push or pull) per file at a time
- **Push priority:** If a local change is queued while a pull is in progress for the same file, the push runs after the pull completes (local intent preserved)
- **Debounce:** Multiple rapid saves to the same file within 500ms are collapsed into one push
- **Queue persistence:** Pending operations saved to `.api2file/queue.json` — survives app restart
- **Offline queue:** When network is down, local changes queue up. Only the latest state per file is kept (10 edits to the same file = 1 queued push)

### Initial Sync (First Connection)

When a service is first connected:

1. App creates the service directory and `.api2file/` internals
2. Runs `git init` in the service directory
3. Creates `.gitignore` with: `.api2file/` (sync state is not version-controlled)
4. Pulls all resources defined in the adapter config
5. For large datasets (1000+ records), syncs in batches with progress shown in menu bar
6. If interrupted (network drop, app quit), resumes from last successful batch on next launch
7. First git commit: `sync: initial pull from {service} — {N} files`

### CSV Bidirectional Sync

CSV files (used for tabular data like Monday.com boards) have special handling:

- **Row identity:** An `_id` column is always present as the first column. It maps rows to server records. Users should not delete this column.
- **Column matching:** Columns are matched by header name, not position. Reordering columns is safe.
- **New columns:** Extra columns added locally that don't exist on the server are preserved locally but not pushed.
- **Missing columns:** If a server-side column is missing from the CSV, it's not modified on push.
- **Encoding:** Always UTF-8, LF line endings, RFC 4180 quoting. The app normalizes on read if the editor saved differently.
- **Type coercion:** Values are strings. The adapter config can specify column types for validation, but the file is always plain CSV.

### Git Initialization

- Each service folder is an independent git repository
- Initialized on first service connection
- `.gitignore` contains: `.api2file/` (state and logs are not tracked)
- The root `~/API2File/` is NOT a git repo — only service subdirectories are
- If a git repo already exists in the directory (user-created), the app reuses it rather than re-initializing

### State Tracking

Internal state per file stored in `~/API2File/{service}/.api2file/state.json`:

```json
{
  "files": {
    "products/premium-dog-food.json": {
      "remoteId": "abc-123",
      "lastSyncedHash": "sha256:...",
      "lastRemoteETag": "W/\"xyz\"",
      "lastSyncTime": "2026-03-23T10:30:00Z",
      "status": "synced"
    }
  }
}
```

Status values: `synced`, `syncing`, `modified`, `conflict`, `error`

---

## Folder Structure

```
~/API2File/
├── .api2file.json                     # Global config (hidden)
├── .api2file/                         # Global internals (hidden)
│   └── logs/
├── CLAUDE.md                          # ← Root agent guide (auto-generated)
│
├── monday/
│   ├── .api2file/                     #    (all dot-files hidden by default in Finder)
│   │   ├── adapter.json               #    adapter config
│   │   └── state.json                 #    sync state
│   ├── .git/
│   ├── CLAUDE.md                      # ← Monday-specific agent guide (auto-generated)
│   └── boards/
│       ├── marketing-campaign.csv     # ← Opens in Numbers/Excel!
│       ├── dev-sprint-42.csv
│       └── hiring-pipeline.csv
│
├── wix/
│   ├── .api2file/
│   │   ├── adapter.json
│   │   └── state.json
│   ├── .git/
│   ├── CLAUDE.md                      # ← Wix-specific agent guide (auto-generated)
│   ├── products/
│   │   ├── premium-dog-food.json      # ← Clean JSON, no internal metadata
│   │   └── basic-cat-food.json
│   ├── pages/
│   │   ├── home.html                  # ← Opens in browser
│   │   └── about.html
│   └── orders/                        # ← Read-only
│       ├── 1001-john.json
│       └── 1002-jane.json
│
└── netlify/
    ├── .api2file/
    │   ├── adapter.json
    │   └── state.json
    ├── .git/
    ├── CLAUDE.md                      # ← Netlify-specific agent guide (auto-generated)
    └── sites/
        └── my-blog/
            ├── index.html             # ← Edit locally → auto-deploys
            ├── about.html
            └── css/
                └── style.css
```

Each service gets its own git repository for clean history.

---

## macOS Integration

### Menu Bar App

- **Icon:** Cloud with bidirectional arrows (system SF Symbol: `arrow.triangle.2.circlepath.icloud`)
- **Status colors:** Green (all synced), Blue (syncing), Orange (conflicts), Red (errors)
- **Menu items:**
  - Per-service status with last sync time and resource counts
  - "Add Service..." — walks through adapter setup
  - "Preferences..." — opens preferences window
  - "Open ~/API2File" — opens Finder
  - "Pause/Resume All Syncing"
  - "Sync Now" — force immediate sync cycle for all services
  - Quit

### Finder Sync Extension

- Separate Xcode target using `FIFinderSyncProtocol`
- Monitors `~/API2File/` directory
- Badge overlays:
  - ✓ Green checkmark — synced
  - ↻ Blue arrows — syncing
  - ⚠ Orange warning — conflict
  - ✗ Red X — error
- Context menu items: "View on Server", "Force Sync", "View Conflict"
- Communicates with main app via `CFMessagePort` or `DistributedNotificationCenter`

### Notifications

- Conflict detected → actionable notification: "Tap to resolve"
- Sync error after retries → "Monday.com sync failed: 401 — tap to re-authenticate"
- New service connected → "Wix connected — syncing 12 products"
- Uses `UNUserNotificationCenter` with action buttons

### Preferences Window

SwiftUI window with tabs:
- **General:** Sync folder path, launch at login, git settings, notification preferences
- **Services:** List of connected services, per-service config, add/remove
- **Advanced:** Log level, sync intervals, conflict strategy override

### Launch at Login

- Registered via `SMAppService.mainApp.register()` (macOS 13+)
- Background sync continues as menu bar app

---

## AI Agent Integration (CLAUDE.md)

Each service folder includes an auto-generated `CLAUDE.md` file that teaches AI agents (Claude Code, etc.) how to interact with the synced files. Claude Code auto-reads `CLAUDE.md` in any directory, so this is zero-config — the agent instantly knows what files exist, how to edit them, and what constraints apply.

### Auto-Generation

The `CLAUDE.md` is generated from the adapter config and regenerated whenever the config or resource structure changes. It includes:

- **Resource inventory:** What folders/files exist and what they represent
- **Editable vs. read-only fields:** Which columns/fields the agent can modify
- **File format instructions:** How to parse and edit each format (CSV, JSON, HTML, etc.)
- **CRUD operations:** How to create, update, and delete records via file operations
- **Sync behavior:** Poll interval, conflict strategy, what happens on save
- **Control API reference:** curl commands for triggering sync, checking status
- **Constraints and gotchas:** Don't modify `_id`, encoding requirements, etc.

### Root CLAUDE.md

A root-level `~/API2File/CLAUDE.md` provides an overview of all connected services and how API2File works:

```markdown
# API2File — Cloud Data as Local Files

This directory syncs cloud service data to local files.
Edit files here → changes push to the cloud automatically.

## Connected Services
- `monday/` — Monday.com boards (CSV files)
- `wix/` — Wix site data (JSON, HTML)
- `netlify/` — Netlify site files (HTML, CSS, images)

## How it works
- Files sync bidirectionally with cloud APIs
- Changes are git-committed automatically
- Server is source of truth for conflicts
- See each service's CLAUDE.md for details

## Control API (localhost:21567)
- GET /api/services — list all services + status
- POST /api/services/:id/sync — force sync
- GET /api/services/:id/conflicts — list conflicts
```

### Per-Service CLAUDE.md

Each service folder (`~/API2File/monday/CLAUDE.md`, `~/API2File/wix/CLAUDE.md`) contains detailed instructions specific to that service's resources, fields, and file formats. See the adapter engine section for generation details.

### Keeping It Current

- Regenerated on: adapter config change, resource structure change, initial sync completion
- Git-committed alongside data changes
- Includes a timestamp: `<!-- Generated by API2File at 2026-03-23T10:30:00Z -->`

---

## Local REST Server

API2File runs a lightweight local HTTP server (default port `21567`) with two roles:

### Control API (for AI agents & scripts)

Exposes sync state and operations programmatically. AI agents like Claude Code can query status, trigger syncs, and validate adapters without touching the UI.

```
GET  /api/services                         → List all connected services + sync status
GET  /api/services/:id/status              → Detailed status for one service (files, last sync, errors)
POST /api/services/:id/sync                → Trigger immediate sync (pull + push)
GET  /api/services/:id/conflicts           → List unresolved conflicts with diff
POST /api/services/:id/conflicts/:file/resolve  → Resolve conflict (accept server or local)

GET  /api/files                            → List all synced files across services with status
GET  /api/files/:service/:path             → Status of a specific file

GET  /api/logs                             → Recent sync log entries (filterable by service, level)
GET  /api/health                           → Service health check

POST /api/adapters/validate                → Validate an adapter config JSON (body) — returns errors/warnings
POST /api/adapters/dry-run                 → Run a pull against real API but don't write files — preview what would sync
```

Example AI agent workflow:
```bash
# Check status before editing
curl localhost:21567/api/services/monday/status

# Edit files locally...

# Trigger sync after changes
curl -X POST localhost:21567/api/services/monday/sync

# Verify no conflicts
curl localhost:21567/api/services/monday/conflicts
```

### Mock API Server (for adapter development & testing)

When developing new adapter configs, the mock server simulates cloud API responses without hitting real services.

```
POST /api/mock/start                       → Start mock server for an adapter config
     body: { "adapter": "<adapter config JSON>", "port": 8080 }
     Returns: mock server URL + auto-generated sample data

POST /api/mock/scenario                    → Configure test scenarios
     body: { "scenario": "rate-limit" }    → Simulate 429 responses
     body: { "scenario": "error-500" }     → Simulate server errors
     body: { "scenario": "slow" }          → Add 5s latency
     body: { "scenario": "pagination", "totalRecords": 500 }

POST /api/mock/stop                        → Stop mock server
```

The mock server auto-generates realistic sample data based on the adapter config's resource definitions and transform schemas. It supports:

- **Response recording:** Record real API responses once (`/api/mock/record`), replay them offline
- **Scenario injection:** Simulate edge cases (rate limits, errors, timeouts, large pagination)
- **Adapter validation:** Run a full sync cycle against the mock to verify the adapter config works before connecting to a real API
- **Integration test harness:** Used by the project's own test suite for end-to-end testing

---

## Error Handling

| Scenario | Behavior |
|---|---|
| API returns 401 | Invalidate token, pause service, notify user to re-authenticate |
| API returns 429 | Respect `Retry-After`, exponential backoff, queue operations |
| API returns 5xx | Retry 3x with backoff (1s, 5s, 15s), then error state + notify |
| Network offline | Detect via `NWPathMonitor`, pause syncing, queue local changes, auto-resume |
| Conflict detected | Server wins, backup local as `.conflict`, git commit, notify |
| Invalid local file | Don't push, mark as error, notify "Fix syntax in {file}" |
| Git operation fails | Log warning, continue syncing (git is non-blocking) |
| Adapter config invalid | Skip service, show error in menu bar |
| Disk full | Detect before write, pause sync, notify |

All errors logged to `~/API2File/.api2file/logs/api2file-{date}.log` with 7-day rotation.

---

## Xcode Project Structure

```
API2File/
├── API2File.xcodeproj
├── API2File/                           # Main app target (menu bar app)
│   ├── App/
│   │   ├── API2FileApp.swift           # @main entry, MenuBarExtra
│   │   └── AppDelegate.swift           # Lifecycle, launchd
│   ├── UI/
│   │   ├── MenuBarView.swift           # Menu bar dropdown
│   │   ├── PreferencesView.swift       # Settings window
│   │   ├── ServiceConfigView.swift     # Per-service setup
│   │   ├── AddServiceView.swift        # New service wizard
│   │   └── ConflictResolverView.swift  # Conflict diff viewer
│   ├── Core/
│   │   ├── SyncEngine.swift            # Top-level orchestrator
│   │   ├── SyncCoordinator.swift       # Queue, scheduling, debounce
│   │   ├── FileWatcher.swift           # FSEvents wrapper
│   │   ├── GitManager.swift            # Git operations
│   │   ├── ConflictResolver.swift      # Conflict detection + backup
│   │   ├── KeychainManager.swift       # Credentials CRUD
│   │   ├── NetworkMonitor.swift        # NWPathMonitor wrapper
│   │   └── AgentGuideGenerator.swift  # Auto-generates CLAUDE.md from adapter config
│   ├── Adapters/
│   │   ├── AdapterEngine.swift         # Config interpreter
│   │   ├── AdapterConfig.swift         # Codable config models
│   │   ├── HTTPClient.swift            # URLSession wrapper
│   │   ├── GraphQLClient.swift         # GraphQL support
│   │   ├── OAuth2Handler.swift         # OAuth2 flow
│   │   ├── TransformPipeline.swift     # Data transformation ops
│   │   ├── PaginationHandler.swift     # Cursor/offset/page
│   │   ├── FileMapper.swift            # File naming + directory mapping
│   │   └── Formats/                    # File format converters
│   │       ├── FormatConverter.swift    # Protocol + factory
│   │       ├── CSVFormat.swift         # CSV read/write
│   │       ├── ICSFormat.swift         # iCalendar read/write
│   │       ├── VCFFormat.swift         # vCard read/write
│   │       ├── EMLFormat.swift         # Email read/write
│   │       ├── XLSXFormat.swift        # Excel (Phase 2)
│   │       └── DOCXFormat.swift        # Word (Phase 2)
│   ├── Server/                            # Local REST server
│   │   ├── LocalServer.swift              # HTTP server (NWListener or SwiftNIO)
│   │   ├── ControlAPI.swift               # /api/* routes — status, sync, conflicts
│   │   ├── MockServer.swift               # Mock cloud API simulator
│   │   ├── MockDataGenerator.swift        # Auto-generate sample data from adapter config
│   │   └── ResponseRecorder.swift         # Record/replay real API responses
│   ├── Models/
│   │   ├── ServiceState.swift             # Per-service runtime state
│   │   ├── SyncStatus.swift               # File sync status enum
│   │   ├── SyncableFile.swift             # File + metadata model
│   │   └── GlobalConfig.swift             # .api2file.json model
│   └── Resources/
│       └── Adapters/                      # Bundled adapter configs
│           ├── monday.adapter.json
│           ├── wix.adapter.json
│           └── netlify.adapter.json
├── FinderExtension/                       # Finder Sync Extension target
│   ├── FinderSync.swift
│   └── Info.plist
├── Tests/
│   ├── Core/
│   │   ├── SyncEngineTests.swift
│   │   ├── FileWatcherTests.swift
│   │   ├── GitManagerTests.swift
│   │   └── ConflictResolverTests.swift
│   ├── Adapters/
│   │   ├── AdapterEngineTests.swift
│   │   ├── TransformPipelineTests.swift
│   │   ├── PaginationHandlerTests.swift
│   │   └── OAuth2HandlerTests.swift
│   ├── Server/
│   │   ├── ControlAPITests.swift
│   │   └── MockServerTests.swift
│   └── Integration/
│       └── FullSyncCycleTests.swift       # Uses MockServer as test harness
└── Package.swift
```

---

## Phasing

### Phase 1 — MVP (Core Sync Engine)

- Sync engine: FSEvents (local changes) + polling (remote changes)
- Generic adapter engine interpreting `.api2file/adapter.json` configs
- One bundled adapter: Monday.com (simplest API, bearer auth)
- Git auto-commit after each sync cycle
- Basic menu bar icon with service status
- CLI for manual sync trigger and service setup
- macOS Keychain for credential storage
- **Local REST server:** Control API (status, trigger sync, validate adapters) + mock server for testing
- **Formats:** csv, json, html, md, txt, yaml, raw (binary passthrough)

### Phase 2 — Full macOS Experience + Rich Formats

- Finder Sync Extension (file badges)
- Preferences window (SwiftUI)
- OAuth2 flow handler (for Wix and similar)
- Bundled Wix + Netlify adapters
- macOS notifications with actions
- Launch at login via SMAppService
- Conflict resolution UI (diff viewer)
- "Add Service" wizard
- **Formats:** ics (Calendar.app), vcf (Contacts.app), eml (Mail.app), svg, webloc, strings, tsv
- **Office formats:** xlsx (Numbers/Excel), docx (Pages/Word) — via OOXML generation

### Phase 3 — Power Features

- Webhook listener with ngrok/Cloudflare tunnel auto-config
- Selective sync (choose which resources to sync per service)
- Adapter validation tool (test config against live API)
- Community adapter repository
- AI-assisted adapter generation ("paste API docs → get adapter config")
- **Formats:** pptx (Keynote/PowerPoint), additional Office format polish

---

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Pure Swift | Native macOS integration (menu bar, Finder, Keychain, launchd) is the killer feature |
| Adapter approach | Config-driven JSON | Zero per-service code; users/AI can create adapters by writing config |
| Conflict strategy | Server wins + local backup | Simple, predictable, safe — no data loss via `.conflict` files + git history |
| Version control | Auto git commit per sync | Free history, AI agents understand git natively, easy rollback |
| Auth storage | macOS Keychain | Secure, native, survives reinstalls |
| File watching | FSEvents | macOS native, efficient, battle-tested |
| Git per service | Separate repo per service folder | Clean history, independent sync cycles |
| Sync meta | Hidden `.api2file/state.json` per service | User files stay 100% clean; all sync mapping centralized |
| File formats | Adapter decides per resource | 20+ formats: csv, xlsx, json, html, md, ics, vcf, docx, eml, svg, and more |
| Distribution | Direct (notarized), not App Store | Non-sandboxed for full filesystem + Keychain + FSEvents access |
| Git backend | Shell `git` via `Process` | More reliable than SwiftGit2; requires Xcode CLI Tools (standard on dev Macs) |
