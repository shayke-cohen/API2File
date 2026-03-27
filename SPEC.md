# API2File — Product Specification

## Problem

Cloud services trap data behind web UIs and APIs. Local tools — text editors, spreadsheets, scripts, AI agents — can't access this data without writing custom integration code for each service. There's no standardized way to:

- Browse cloud data as local files
- Edit cloud data with local tools (Numbers, VS Code, Calendar.app)
- Track changes to cloud data over time
- Work offline and sync back when ready

## Solution

A native macOS application that bidirectionally syncs cloud API data to local files using a config-driven adapter system. Changes flow both ways — edit a file locally and it pushes to the API; data changes on the server sync down. Git auto-commits provide full version history.

**Core idea:** Any REST or GraphQL API can be mapped to a local folder of familiar files (CSV, JSON, ICS, VCF, etc.) via a JSON configuration — no code required.

**Canonical file model:** Each synced resource may expose a canonical structured JSON representation (`.*.objects.json` for collection resources or `.objects/*.json` for one-per-record resources) plus one or more human-facing projections such as CSV, Markdown, ICS, or VCF. The canonical file is the sync source of truth; human-facing files are optimized for native desktop apps and agent workflows. `.api2file/file-links.json` stores the explicit mapping between canonical files and their projections.

## Target Users

- **Power users** who want to manage cloud data in local tools (spreadsheets, editors)
- **AI agents** (Claude Code, etc.) that can read/write local files but not access APIs directly
- **Developers** building workflows that bridge cloud services and local automation

AI agents should prefer the canonical structured files for high-fidelity edits and use human-facing files when a native-app-oriented format is materially better for the task.

## Functional Requirements

### FR-1: Config-Driven Adapters

- Services are connected via JSON config files (`adapter.json`), not compiled code
- Config specifies: auth, API endpoints, data extraction paths, file format, sync interval
- Bundled adapter configs ship with the app; users can create custom ones
- Each service config lives at `~/API2File/{service}/.api2file/adapter.json`

### FR-2: Bidirectional Sync

**Pull (Server → Local):**
- Fetch data from REST or GraphQL APIs
- Extract records using JSONPath expressions
- Apply configurable transforms (pick, omit, rename, flatten, keyBy)
- Persist canonical structured records as object files
- Persist canonical/projection relationships in `.api2file/file-links.json`
- Generate local human-facing files in the configured format
- Support cursor, offset, and page-based pagination

**Push (Local → Server):**
- Detect file changes via FSEvents
- Debounce rapid edits (configurable, default 500ms)
- When the canonical file changes, push its structured records directly
- When a human-facing file changes, decode it back into canonical structured records first
- For rich-content resources such as Wix blog posts, use provider conversion APIs when available to translate between canonical rich-content objects and Markdown projections
- Apply push transforms
- Send creates (POST), updates (PUT), and deletes (DELETE) to API
- Regenerate human-facing files from the updated canonical records after a successful push

### FR-3: File Format Support

| Format | Standard | Native App |
|---|---|---|
| CSV | RFC 4180 | Numbers, Excel |
| JSON | RFC 8259 | Any editor |
| YAML | — | Any editor |
| ICS | RFC 5545 | Calendar.app |
| VCF | RFC 6350 | Contacts.app |
| HTML | — | Safari, browsers |
| Markdown | CommonMark | Any editor |
| Text | — | TextEdit |
| Raw | — | Varies |

All format converters are bidirectional — they encode records to files and decode files back to records.

### FR-3A: Canonical Object Files and Human Projections

- Every synced resource may have a canonical object file storing structured records as JSON
- Canonical object files are hidden from casual browsing but remain available for advanced users and AI agents
- Human-facing files are generated projections of the canonical records
- Human-facing files may be lossy or app-optimized; canonical files preserve the structured shape needed for safe push back to the API
- Editing either surface must converge through the canonical representation before pushing to the server
- Editing both the canonical file and a projection before the same sync cycle must create an explicit conflict instead of silently choosing one
- `.api2file/file-links.json` must make the mapping between canonical files and projections discoverable to the engine and AI agents

### FR-4: File Mapping Strategies

| Strategy | Behavior |
|---|---|
| `one-per-record` | Each API record → its own file. Filename from template: `{name\|slugify}.json` |
| `collection` | All records → single file. E.g., all tasks in `tasks.csv` |
| `mirror` | Preserve remote directory structure exactly |

### FR-5: Data Transforms

Declarative transform pipeline applied during pull and/or push:

| Operation | Description |
|---|---|
| `pick` | Keep only named fields |
| `omit` | Remove named fields |
| `rename` | Rename field, supports dot-path extraction (`priceData.price` → `price`) |
| `flatten` | Extract values from nested array (`media.items[*].url` → flat array) |
| `keyBy` | Convert array of `{key, value}` objects to dictionary |

### FR-6: Authentication

| Type | Mechanism |
|---|---|
| Bearer | Token from Keychain → `Authorization: Bearer <token>` |
| API Key | Key from Keychain → custom header |
| Basic | Username/password from Keychain → `Authorization: Basic <base64>` |
| OAuth2 | Full flow: authorize → token exchange → Keychain storage → auto-refresh |

All credentials stored in macOS Keychain with `com.api2file.` namespace.

### FR-7: Git Version History

- Each service directory is an independent git repository
- Auto-commit after every sync cycle with descriptive messages:
  - `sync: pull {service} — updated N files`
  - `sync: push {service} — {filename}`
- `.api2file/` directory excluded via `.gitignore`
- Preserves file history for recovery and auditing

### FR-8: AI Agent Integration

- Auto-generate `CLAUDE.md` files from adapter configs
- Root-level guide: overview of all connected services
- Per-service guide: resource inventory, editable fields, format instructions, sync behavior
- Regenerated on config or structure changes
- Zero-config for Claude Code — it auto-reads `CLAUDE.md` in any directory

### FR-9: Error Handling

| Scenario | Behavior |
|---|---|
| API 401 | Pause service, notify user to re-authenticate |
| API 429 | Respect `Retry-After`, exponential backoff |
| API 5xx | Retry 3x with backoff (1s, 5s, 15s), then error state |
| Network offline | Queue local changes, auto-resume on reconnect |
| Conflict | Server wins, backup local as `.conflict` file, git commit both |
| Invalid file | Don't push, mark as error, notify user |

### FR-10: Demo Mode

- Built-in REST API server (port 8089) with in-memory task data
- 3 seed tasks with various statuses
- Full CRUD endpoints: GET/POST/PUT/DELETE `/api/tasks`
- Bundled `demo.adapter.json` config
- Setup script for zero-friction onboarding

### FR-11: macOS Menu Bar App

- Native SwiftUI menu bar app (`LSUIElement` — no dock icon)
- Service list with status indicators and per-service sync controls
- **Add Service wizard** — guided 3-step flow: select service → enter credentials → connected
  - Service-specific extra fields (Wix Site ID, Airtable Base ID/Table Name)
  - API key securely stored in macOS Keychain
- **Service detail view** — NavigationSplitView in Preferences showing resources, last sync time, file count, error details
- **Service management** — disconnect services, update API keys, per-service sync
- **Onboarding** — empty state guidance when no services are connected
- **Preferences** — General tab (sync folder, git, notifications, interval) and Services tab (detail view)
- **.app bundle** — distributable as a standalone macOS application

### FR-12: Bundled External Adapters

Five bundled adapter configs for real external services:

| Service | Auth | Resources | Formats |
| --- | --- | --- | --- |
| Monday.com | Bearer token (GraphQL) | boards with items | CSV |
| Wix | API key + Site ID header | contacts, products, blog posts, bookings, collections | CSV, Markdown, JSON |
| GitHub | Bearer token (PAT) | repos, issues, gists, notifications, starred | CSV, JSON |
| Airtable | Bearer token (PAT) | records, bases | JSON |

Plus 6 demo-based adapters (TeamBoard, PeopleHub, CalSync, PageCraft, DevOps, MediaManager) showcasing all supported file formats.

Wix blog posts are exposed locally as Markdown projections, but the underlying canonical object preserves Wix `richContent` / Ricos data. When available, API2File should use Wix's Rich Content conversion APIs for Markdown pull/push instead of relying only on local best-effort conversion.

## Non-Functional Requirements

### NFR-1: Zero External Dependencies

Pure Swift using only macOS native frameworks:
- Foundation, Security (Keychain), Network (NWPathMonitor)
- URLSession for HTTP, FSEvents for file watching
- No package manager dependencies, no Node.js sidecar

### NFR-2: Performance

- Polling interval: configurable per service (default 10-60s)
- File change debounce: configurable (default 500ms)
- Pagination for large datasets (cursor, offset, page-based)
- Content-hash comparison to skip unchanged files

### NFR-3: Security

- Credentials never stored in files — macOS Keychain only
- Sync state files (`.api2file/`) excluded from git
- No sensitive data in user-facing files
- Keychain entries namespaced to prevent collisions

### NFR-4: Reliability

- Exponential backoff for transient failures
- Sync state persisted to disk — survives app restart
- Git history enables recovery from any state
- Network monitoring pauses sync during outages

## Sync State Model

All state per service in `.api2file/state.json`:

```json
{
  "files": {
    "tasks.csv": {
      "remoteId": "collection",
      "lastSyncedHash": "sha256:...",
      "lastSyncTime": "2026-03-23T10:30:00Z",
      "status": "synced"
    }
  }
}
```

Status values: `synced`, `syncing`, `modified`, `conflict`, `error`

User files contain zero sync metadata — only actual content.
Canonical object files live alongside user-facing files and store the structured record model used for diffing, regeneration, and high-fidelity agent edits.
`.api2file/file-links.json` records the path-level linkage between canonical files and their human-facing projections.

## Conflict Resolution

- **Strategy:** Server always wins (source of truth)
- **Local source of truth:** The canonical object file is the authoritative local representation
- **Backup:** Local version saved as `{filename}.conflict.{ext}` and, when needed, a matching canonical conflict artifact
- **Git:** Both versions committed — server version in main file, local in `.conflict`
- **Recovery:** User reviews `.conflict` file, merges manually, deletes when done

## Adapter Config Schema

```json
{
  "service": "string",
  "displayName": "string",
  "version": "string",
  "auth": {
    "type": "bearer | oauth2 | apiKey | basic",
    "keychainKey": "string",
    "setup": { "instructions": "string", "url": "string" }
  },
  "globals": {
    "baseUrl": "string",
    "headers": { "key": "value" },
    "method": "string"
  },
  "resources": [
    {
      "name": "string",
      "description": "string",
      "pull": {
        "method": "GET | POST",
        "url": "string (supports {baseUrl} template)",
        "type": "rest | graphql",
        "query": "string (GraphQL)",
        "dataPath": "string (JSONPath)",
        "pagination": {
          "type": "cursor | offset | page",
          "nextCursorPath": "string",
          "pageSize": "number"
        }
      },
      "push": {
        "create": { "method": "POST", "url": "string" },
        "update": { "method": "PUT | PATCH", "url": "string" },
        "delete": { "method": "DELETE", "url": "string" }
      },
      "fileMapping": {
        "strategy": "one-per-record | collection | mirror",
        "directory": "string",
        "filename": "string (template with filters)",
        "format": "csv | json | yaml | ics | vcf | html | markdown | text | raw",
        "idField": "string",
        "contentField": "string",
        "transforms": {
          "pull": [{ "op": "pick | omit | rename | flatten | keyBy", "...": "..." }],
          "push": [{ "op": "...", "...": "..." }]
        }
      },
      "sync": {
        "interval": "number (seconds)",
        "debounceMs": "number (milliseconds)"
      }
    }
  ]
}
```

## Filename Template Filters

| Filter | Input | Output |
|---|---|---|
| `slugify` | `My Project Name` | `my-project-name` |
| `lower` | `Hello` | `hello` |
| `upper` | `Hello` | `HELLO` |
| `default:val` | `""` (empty) | `val` |

Usage: `{name|slugify}.json`, `{field|default:untitled}.csv`

## Runtime Folder Structure

```
~/API2File/
├── CLAUDE.md                     # Root agent guide (auto-generated)
├── {service}/
│   ├── .api2file/
│   │   ├── adapter.json          # Service config
│   │   └── state.json            # Sync state
│   ├── .git/                     # Independent git repo
│   ├── .gitignore                # Excludes .api2file/
│   ├── CLAUDE.md                 # Service-specific agent guide
│   └── {synced files}            # CSV, JSON, ICS, VCF, etc.
```

## Roadmap

### Phase 1 — MVP (Complete)

- Config-driven adapter engine with JSON configs
- Bidirectional sync: pull + push with polling and file watching
- 10+ file formats: CSV, JSON, YAML, ICS, VCF, HTML, Markdown, SVG, Text, Raw
- Transform pipeline: pick, omit, rename, flatten, keyBy
- Git auto-commit per sync cycle
- macOS Keychain credential storage
- HTTPClient with retry and rate-limit handling
- Demo API server for testing
- CLAUDE.md agent guide generation
- 180+ tests (unit, integration, E2E)

### Phase 2 — Full macOS Experience (Current)

- macOS menu bar app with SwiftUI
- SwiftUI preferences window with General and Services tabs
- Service detail view (NavigationSplitView) with resources, status, actions
- Add Service wizard with service-specific extra fields
- Service management: disconnect, update API key, per-service sync
- Bundled external adapters: Monday.com, Wix, GitHub, Airtable
- .app bundle for distribution
- macOS notifications with action buttons
- Empty state onboarding guidance
- Finder Sync Extension (file status badges) — planned
- OAuth2 flow handler — backend complete, UI planned
- Launch at login (SMAppService) — setting exists, integration planned
- Conflict resolution UI (diff viewer) — planned
- Office formats: XLSX (Numbers/Excel), DOCX (Pages/Word) — planned

### Phase 3 — Power Features

- Webhook listener for instant server-to-local sync
- Selective sync (choose resources per service)
- Community adapter repository
- AI-assisted adapter generation from API docs
