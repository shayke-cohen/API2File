# API2File — Design Specification

**Date:** 2026-03-23
**Status:** Implemented — Phase 2 Complete

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

Each service's config lives at `~/API2File-Data/{service}/.api2file/adapter.json`. Bundled adapter configs ship inside the app at `Resources/Adapters/{service}.adapter.json` and are copied to the service folder on first connection.

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
        "type": "rest | graphql | media",
        "query": "GraphQL query string",
        "body": {},
        "dataPath": "$.jsonpath.to.data",
        "pagination": {
          "type": "cursor | offset | page",
          "nextCursorPath": "$.path.to.cursor",
          "pageSize": 50
        },
        "mediaConfig": {
          "urlField": "url",
          "filenameField": "displayName",
          "idField": "id",
          "sizeField": "sizeInBytes",
          "hashField": "hash"
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

### File Formats — 15 Implemented

All 15 format converters are implemented with bidirectional encode/decode. The `FormatConverterFactory` dispatches by the `FileFormat` enum.

| # | Data Shape | Format | Opens Natively In | Example Use |
| --- | --- | --- | --- | --- |
| 1 | Structured objects | `.json` | VS Code, any editor | Products, orders, configs |
| 2 | Tabular data | `.csv` | Numbers, Excel, VS Code | Monday boards, form submissions |
| 3 | Web content | `.html` | Safari, any browser | Site pages, email templates |
| 4 | Rich text | `.md` | Any editor, Marked.app | Blog posts, docs, descriptions |
| 5 | Config / settings | `.yaml` | Any editor | CI/CD pipelines, app config |
| 6 | Plain text | `.txt` | TextEdit | Notes, logs, plain content |
| 7 | Binary passthrough | `.raw` | Depends on content | Images, PDFs, any binary |
| 8 | Calendar events | `.ics` | **Calendar.app** | Bookings, schedules, meetings |
| 9 | Contacts | `.vcf` | **Contacts.app** | CRM contacts, leads, customers |
| 10 | Email content | `.eml` | **Mail.app** | Email drafts, campaign templates |
| 11 | Vector graphics | `.svg` | Preview, any browser | Logos, icons, design assets |
| 12 | Web bookmarks | `.webloc` | Finder -> Safari | Links, saved URLs |
| 13 | Rich spreadsheets | `.xlsx` | **Numbers, Excel** | Boards with types, colors (pure Swift OOXML via ZIPHelper) |
| 14 | Documents | `.docx` | **Pages, Word** | Proposals, contracts (pure Swift OOXML via ZIPHelper) |
| 15 | Presentations | `.pptx` | **Keynote, PowerPoint** | Pitch decks, reports (pure Swift OOXML via ZIPHelper) |

**Not yet implemented:** `.strings`, `.tsv` — planned for Phase 3.

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

### Media Sync

When a resource's pull config sets `"type": "media"`, the adapter engine switches from the standard JSON-to-format pipeline to a binary file download mode via `pullMediaFiles()`. Instead of extracting structured records and converting them through format converters, the engine:

1. Fetches the file listing from the API (standard REST call with `dataPath` extraction)
2. For each record, reads the download URL from `mediaConfig.urlField` and the filename from `mediaConfig.filenameField`
3. Downloads the binary content directly from the URL (CDN URLs typically don't require auth headers)
4. Writes the raw bytes to `{directory}/{filename}` using the `mirror` strategy

**`MediaConfig` fields:**

| Field | Required | Description |
|---|---|---|
| `urlField` | Yes | JSON field containing the download URL |
| `filenameField` | Yes | JSON field containing the filename |
| `idField` | No | JSON field for the file's unique ID (default: `"id"`) |
| `sizeField` | No | JSON field for file size in bytes (progress reporting) |
| `hashField` | No | JSON field for file hash/ETag (skip-if-unchanged optimization) |

**Push flow:** `pushMediaFile()` uploads binary files via a two-step signed-URL process:

1. POST to the create endpoint with `mimeType` and `fileName` to get a signed upload URL
2. PUT the binary data to the signed URL with the correct `Content-Type` header

**Example (Wix Media Manager):**

```json
{
  "name": "media",
  "pull": {
    "method": "POST",
    "url": "https://www.wixapis.com/site-media/v1/files/search",
    "dataPath": "$.files",
    "type": "media",
    "mediaConfig": {
      "urlField": "url",
      "filenameField": "displayName",
      "idField": "id",
      "sizeField": "sizeInBytes",
      "hashField": "hash"
    }
  },
  "push": {
    "create": {
      "method": "POST",
      "url": "https://www.wixapis.com/site-media/v1/files/generate-upload-url"
    }
  },
  "fileMapping": {
    "strategy": "mirror",
    "directory": "media",
    "format": "raw",
    "idField": "id"
  }
}
```

This works with any cloud storage API — Google Drive, Dropbox, S3, Azure Blob — as long as the API returns a list of files with download URLs.

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

1. FSEvents detects file modification in `~/API2File-Data/{service}/`
2. Debounce 500ms to batch rapid saves
3. Validate file format (parse JSON, check required fields)
4. Adapter engine reads file, applies push transforms, calls API
   - For media resources, `pushMediaFile()` handles binary uploads via a two-step signed-URL flow (generate upload URL, then PUT binary data)
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

### Collection Diffing

When a collection-strategy file (CSV, JSON array, XLSX, YAML) is edited locally, the `CollectionDiffer` computes a precise diff between the previously synced version and the current version. This determines which individual records to create, update, or delete via the API — avoiding a full-collection overwrite.

`CollectionDiffer.diff(old:new:idField:)` returns a `DiffResult` containing:

- **created** — records with no matching ID in the old set (or missing ID entirely)
- **updated** — records with the same ID but changed field values
- **deleted** — IDs present in the old set but absent in the new set

Field comparison normalizes types (Int vs String "1") and ignores the ID field itself. The `DiffResult.summary` provides a human-readable string like "2 created, 1 updated, 3 deleted".

### Git Initialization

- Each service folder is an independent git repository
- Initialized on first service connection
- `.gitignore` contains: `.api2file/` (state and logs are not tracked)
- The root `~/API2File-Data/` is NOT a git repo — only service subdirectories are
- If a git repo already exists in the directory (user-created), the app reuses it rather than re-initializing

### State Tracking

Internal state per file stored in `~/API2File-Data/{service}/.api2file/state.json`:

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

The sync root defaults to `~/API2File-Data/` (configurable via global config or CLI `api2file init`).

```
~/API2File-Data/
├── .api2file.json                     # Global config (hidden)
├── .api2file/                         # Global internals (hidden)
│   └── logs/
├── CLAUDE.md                          # ← Root agent guide (auto-generated)
│
├── demo/                              # ← Local demo service (no cloud account needed)
│   ├── .api2file/
│   │   ├── adapter.json
│   │   └── state.json
│   ├── .git/
│   ├── CLAUDE.md
│   └── tasks.csv                      # ← Opens in Numbers/Excel
│
├── monday/
│   ├── .api2file/
│   │   ├── adapter.json
│   │   └── state.json
│   ├── .git/
│   ├── CLAUDE.md
│   └── boards/
│       ├── marketing-campaign.csv
│       └── dev-sprint-42.csv
│
├── wix/
│   ├── .api2file/
│   │   ├── adapter.json               # 11 resources configured
│   │   └── state.json
│   ├── .git/
│   ├── CLAUDE.md
│   ├── contacts.csv                   # ← CRM contacts (Numbers)
│   ├── products.csv                   # ← Store products (Numbers)
│   ├── members.csv                    # ← Site members (read-only)
│   ├── site-properties.json           # ← Site settings (read-only)
│   ├── blog/
│   │   └── my-post.md                 # ← Blog post (editor)
│   ├── cms/
│   │   ├── projects.csv               # ← CMS projects
│   │   ├── todos.csv                  # ← CMS todos
│   │   ├── orders.csv                 # ← Store orders (read-only)
│   │   ├── events.csv                 # ← CMS events
│   │   └── blog-tags.csv              # ← Blog tags (read-only)
│   └── media/                         # ← Binary files via media sync
│       ├── photo.jpg
│       └── document.pdf
│
├── github/
│   ├── .api2file/
│   │   ├── adapter.json
│   │   └── state.json
│   ├── .git/
│   ├── repos.csv
│   ├── issues.csv
│   └── notifications.csv
│
└── airtable/
    ├── .api2file/
    │   ├── adapter.json
    │   └── state.json
    ├── .git/
    ├── bases.json
    └── records/
        └── rec123.json
```

Each service gets its own git repository for clean history.

---

## CLI Tool

The `api2file` command-line tool (`API2FileCLI` target) provides headless access to all core operations. It uses `~/API2File-Data/` as the default sync folder.

```text
USAGE: api2file <command> [arguments]

COMMANDS:
  help              Show help message
  init              Initialize ~/API2File-Data/ with global config
  list              List available bundled adapters
  status            Show all services and their sync status
  add <service>     Set up a new service (demo/monday/wix/github/airtable)
  sync [service]    Trigger immediate sync (all or specific service)
  pull [service]    Pull from API to local files
```

### Bundled Adapters (via CLI `add`)

| ID | Service | Description |
| --- | --- | --- |
| `demo` | Demo Tasks API | Local demo server — no account needed |
| `monday` | Monday.com | Boards and items as CSV files |
| `wix` | Wix | Contacts, products, blog posts, CMS collections, members, site properties, media (11 resources) |
| `github` | GitHub | Repos, issues, gists, notifications |
| `airtable` | Airtable | Records and bases as JSON files |

The `add` command writes the adapter config to `.api2file/adapter.json`, saves the API key to macOS Keychain, and initializes a git repository in the service directory.

---

## Web Dashboard

A single-page HTML dashboard is bundled at `Resources/Web/dashboard.html`. It provides a visual overview of all connected services and their sync status, with live-updating cards for each resource. The dashboard is served by the demo server and includes:

- Real-time service status with color-coded indicators (green/yellow/red)
- Per-resource cards showing record counts, formats, and last sync time
- Search/filter across all resources
- Sync-now buttons for individual resources
- Dark theme matching macOS system appearance

---

## macOS Integration

### Menu Bar App

- **Icon:** Cloud with bidirectional arrows (system SF Symbol: `arrow.triangle.2.circlepath.icloud`)
- **Status colors:** Green (all synced), Blue (syncing), Orange (conflicts), Red (errors)
- **Menu items:**
  - Per-service status with last sync time and resource counts
  - "Add Service..." — walks through adapter setup
  - "Preferences..." — opens preferences window
  - "Open ~/API2File-Data" — opens Finder
  - "Pause/Resume All Syncing"
  - "Sync Now" — force immediate sync cycle for all services
  - Quit

### Finder Sync Extension

- Separate Xcode target using `FIFinderSyncProtocol`
- Monitors `~/API2File-Data/` directory
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

A root-level `~/API2File-Data/CLAUDE.md` provides an overview of all connected services and how API2File works:

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

Each service folder (`~/API2File-Data/monday/CLAUDE.md`, `~/API2File-Data/wix/CLAUDE.md`) contains detailed instructions specific to that service's resources, fields, and file formats. See the adapter engine section for generation details.

### Keeping It Current

- Regenerated on: adapter config change, resource structure change, initial sync completion
- Git-committed alongside data changes
- Includes a timestamp: `<!-- Generated by API2File at 2026-03-23T10:30:00Z -->`

---

## Local REST Server

API2File runs a lightweight local HTTP server (default port `21567`) with two roles:

### Control API (for AI agents & scripts) — Implemented

Exposes sync state and operations programmatically via `LocalServer` (NWListener on port 21567). AI agents like Claude Code can query status, trigger syncs, and validate adapters without touching the UI.

**Implemented endpoints:**

```text
GET  /api/health                           → Health check (returns {"status":"ok","version":"1.0"})
GET  /api/services                         → List all connected services + sync status
GET  /api/services/:id/status              → Detailed status for one service (files, last sync, errors)
POST /api/services/:id/sync                → Trigger immediate sync (pull + push)
POST /api/adapters/validate                → Validate an adapter config JSON (body) — returns valid/invalid + errors
```

**Not yet implemented (planned):**

```text
GET  /api/services/:id/conflicts           → List unresolved conflicts with diff
POST /api/services/:id/conflicts/:file/resolve  → Resolve conflict (accept server or local)
GET  /api/files                            → List all synced files across services with status
GET  /api/logs                             → Recent sync log entries
POST /api/adapters/dry-run                 → Preview what would sync without writing files
```

Example AI agent workflow:

```bash
# Check status before editing
curl localhost:21567/api/services/monday/status

# Edit files locally...

# Trigger sync after changes
curl -X POST localhost:21567/api/services/monday/sync
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

All errors logged to `~/API2File-Data/.api2file/logs/api2file-{date}.log` with 7-day rotation.

---

## Swift Package Structure (Actual)

The project uses Swift Package Manager with five targets.

```text
API2File/
├── Package.swift
├── Sources/
│   ├── API2FileApp/                        # macOS menu bar app target
│   │   ├── App/
│   │   │   └── API2FileApp.swift           # @main entry, MenuBarExtra
│   │   └── UI/
│   │       ├── MenuBarView.swift           # Menu bar dropdown
│   │       ├── PreferencesView.swift       # Settings window (SwiftUI tabs)
│   │       ├── ServiceDetailView.swift     # Per-service detail + actions
│   │       └── AddServiceView.swift        # New service wizard
│   │
│   ├── API2FileCLI/                        # CLI tool target
│   │   └── main.swift                      # help, init, list, status, add, sync, pull
│   │
│   ├── API2FileCore/                       # Shared library target
│   │   ├── Core/
│   │   │   ├── SyncEngine.swift            # Top-level orchestrator
│   │   │   ├── SyncCoordinator.swift       # Queue, scheduling, debounce
│   │   │   ├── CollectionDiffer.swift      # Diff old vs new records for push
│   │   │   ├── FileWatcher.swift           # FSEvents wrapper
│   │   │   ├── GitManager.swift            # Git operations via Process
│   │   │   ├── KeychainManager.swift       # macOS Keychain CRUD
│   │   │   ├── OAuth2Handler.swift         # OAuth2 authorization code flow
│   │   │   ├── NotificationManager.swift   # UNUserNotificationCenter wrapper
│   │   │   ├── NetworkMonitor.swift        # NWPathMonitor wrapper
│   │   │   ├── ConfigWatcher.swift         # Watch adapter config for changes
│   │   │   └── AgentGuideGenerator.swift   # Auto-generates CLAUDE.md
│   │   ├── Adapters/
│   │   │   ├── AdapterEngine.swift         # Config interpreter + pull/push pipeline
│   │   │   ├── TransformPipeline.swift     # pick, omit, rename, flatten, expand, keyBy, template
│   │   │   ├── FileMapper.swift            # File naming + directory mapping + slugify
│   │   │   └── Formats/                    # 15 file format converters
│   │   │       ├── FormatConverter.swift    # Protocol + FormatConverterFactory
│   │   │       ├── JSONFormat.swift
│   │   │       ├── CSVFormat.swift
│   │   │       ├── HTMLFormat.swift
│   │   │       ├── MarkdownFormat.swift
│   │   │       ├── YAMLFormat.swift
│   │   │       ├── TextFormat.swift
│   │   │       ├── RawFormat.swift
│   │   │       ├── ICSFormat.swift         # iCalendar (Calendar.app)
│   │   │       ├── VCFFormat.swift         # vCard (Contacts.app)
│   │   │       ├── EMLFormat.swift         # Email (Mail.app)
│   │   │       ├── SVGFormat.swift         # Vector graphics
│   │   │       ├── WeblocFormat.swift      # macOS web bookmarks
│   │   │       ├── XLSXFormat.swift        # Excel via pure Swift OOXML
│   │   │       ├── DOCXFormat.swift        # Word via pure Swift OOXML
│   │   │       ├── PPTXFormat.swift        # PowerPoint via pure Swift OOXML
│   │   │       └── ZIPHelper.swift         # ZIP archive builder for OOXML
│   │   ├── Models/
│   │   │   ├── AdapterConfig.swift         # Full Codable config (auth, resources, transforms, FileFormat enum)
│   │   │   ├── SyncState.swift             # Per-file sync state persistence
│   │   │   ├── SyncStatus.swift            # Status enum (synced, syncing, modified, conflict, error)
│   │   │   ├── SyncableFile.swift          # File + metadata model
│   │   │   └── GlobalConfig.swift          # .api2file.json model
│   │   ├── Server/
│   │   │   ├── LocalServer.swift           # HTTP control server (NWListener, port 21567)
│   │   │   ├── MockServer.swift            # Mock cloud API simulator
│   │   │   └── DemoAPIServer.swift         # Full REST API with 14 resource types + seed data
│   │   └── Resources/
│   │       ├── Web/
│   │       │   └── dashboard.html          # Single-page web dashboard
│   │       └── Adapters/                   # 12 bundled adapter configs
│   │           ├── demo.adapter.json
│   │           ├── monday.adapter.json
│   │           ├── wix.adapter.json
│   │           ├── wix-demo.adapter.json
│   │           ├── github.adapter.json
│   │           ├── airtable.adapter.json
│   │           ├── teamboard.adapter.json
│   │           ├── peoplehub.adapter.json
│   │           ├── calsync.adapter.json
│   │           ├── pagecraft.adapter.json
│   │           ├── devops.adapter.json
│   │           └── mediamanager.adapter.json
│   │
│   ├── API2FileDemo/                       # Standalone demo server target
│   │   └── main.swift                      # Runs DemoAPIServer on port 8089
│   │
│   └── FinderExtension/                    # Finder Sync Extension target
│       └── FinderSync.swift
│
└── Tests/
    └── API2FileCoreTests/
        ├── Models/
        │   ├── AdapterConfigTests.swift
        │   └── SyncStateTests.swift        # + GlobalConfigTests, SyncableFileTests, SyncStatusTests
        ├── Core/
        │   ├── HTTPClientTests.swift
        │   ├── KeychainManagerTests.swift
        │   ├── GitManagerTests.swift
        │   ├── AgentGuideGeneratorTests.swift
        │   ├── SyncCoordinatorTests.swift
        │   ├── OAuth2HandlerTests.swift
        │   ├── NotificationManagerTests.swift
        │   └── CollectionDifferTests.swift
        ├── Adapters/
        │   ├── FormatConverterTests.swift  # All 15 formats
        │   ├── TransformPipelineTests.swift # + TemplateEngineTests, JSONPathTests
        │   ├── ICSVCFFormatTests.swift
        │   └── EMLSVGWeblocFormatTests.swift
        └── Integration/
            ├── AdapterEngineIntegrationTests.swift
            ├── FullSyncCycleTests.swift
            ├── DemoAdapterConfigTests.swift
            ├── DemoAdapterPipelineTests.swift
            ├── DemoServerE2ETests.swift
            ├── DemoServerAllResourcesE2ETests.swift
            ├── BidirectionalSyncE2ETests.swift
            ├── RealSyncE2ETests.swift
            └── CollectionDiffE2ETests.swift
```

---

## Phasing

### Phase 1 — MVP (Core Sync Engine) -- COMPLETE

- Sync engine: FSEvents (local changes) + polling (remote changes)
- Generic adapter engine interpreting `.api2file/adapter.json` configs
- Bundled demo adapter + Monday.com adapter
- Git auto-commit after each sync cycle
- Basic menu bar icon with service status
- CLI tool (`api2file`) with help, init, list, status, add, sync, pull commands
- macOS Keychain for credential storage
- Local REST control server (port 21567): health, services, sync, validate
- Demo API server (port 8089): full CRUD with 14 resource types
- Collection diffing for granular push (create/update/delete individual records)
- **Formats:** json, csv, html, md, yaml, txt, raw (7 formats)

### Phase 2 — Full macOS Experience + Rich Formats -- COMPLETE

- Finder Sync Extension (file badges via `FIFinderSyncProtocol`)
- Preferences window (SwiftUI with General/Services/Advanced tabs)
- Service detail view with Sync Now, Open Folder, Update Key, Disconnect
- OAuth2 flow handler (`OAuth2Handler` with local callback server)
- Bundled adapters: wix, wix-demo, github, airtable, teamboard, peoplehub, calsync, pagecraft, devops, mediamanager (12 total)
- macOS notifications via `NotificationManager` (UNUserNotificationCenter)
- "Add Service" wizard with per-service extra fields (Site ID, Base ID, etc.)
- Config watcher for live adapter config reloading
- Web dashboard (single-page HTML with live status)
- **Formats:** ics, vcf, eml, svg, webloc (5 formats)
- **Office formats:** xlsx, docx, pptx — pure Swift OOXML via ZIPHelper (3 formats)
- **Total: 15 format converters implemented**

### Phase 3 — Power Features (Future)

- Webhook listener with ngrok/Cloudflare tunnel auto-config
- Selective sync (choose which resources to sync per service)
- Conflict resolution UI (diff viewer)
- Community adapter repository
- AI-assisted adapter generation ("paste API docs -> get adapter config")
- Control API: conflicts endpoint, files listing, logs endpoint, dry-run
- Launch at login via SMAppService
- **Formats:** `.strings`, `.tsv`

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
| File formats | Adapter decides per resource | 15 formats: json, csv, html, md, yaml, txt, raw, ics, vcf, eml, svg, webloc, xlsx, docx, pptx |
| OOXML approach | Pure Swift via ZIPHelper | Zero external dependencies for xlsx/docx/pptx; generates valid Office Open XML archives |
| Distribution | Direct (notarized), not App Store | Non-sandboxed for full filesystem + Keychain + FSEvents access |
| Git backend | Shell `git` via `Process` | More reliable than SwiftGit2; requires Xcode CLI Tools (standard on dev Macs) |
| Sync folder | `~/API2File-Data/` | Avoids confusion with the source repo (`~/API2File/`); configurable via GlobalConfig |

---

## Known Limitations

| Area | Limitation | Notes |
| --- | --- | --- |
| Control API | Only 5 of 10 planned endpoints implemented | Missing: conflicts, files listing, logs, dry-run |
| Conflict resolution | No UI — server-wins with `.conflict` file backup only | Phase 3 will add a diff viewer |
| Launch at login | `SMAppService` call not wired up yet | Manual launch only |
| Finder Extension | Badge protocol implemented but IPC not connected | Extension exists as separate target but doesn't communicate with main app yet |
| Webhook sync | Not implemented | Polling only; webhooks are Phase 3 |
| Selective sync | Not implemented | All resources in an adapter sync — no per-resource toggle |
| `.strings` / `.tsv` | Format converters not implemented | Planned for Phase 3 |
| Offline queue | Designed but not persistence-tested at scale | Queue logic in SyncCoordinator; no `.api2file/queue.json` file written yet |
| Demo server | In-memory only — data resets on restart | Intentional for testing; not a production limitation |
