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

## Target Users

- **Power users** who want to manage cloud data in local tools (spreadsheets, editors)
- **AI agents** (Claude Code, etc.) that can read/write local files but not access APIs directly
- **Developers** building workflows that bridge cloud services and local automation

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
- Write to local files in the configured format
- Support cursor, offset, and page-based pagination

**Push (Local → Server):**
- Detect file changes via FSEvents
- Debounce rapid edits (configurable, default 500ms)
- Parse file back to records using format converter
- Apply push transforms
- Send creates (POST), updates (PUT), and deletes (DELETE) to API

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

## Conflict Resolution

- **Strategy:** Server always wins (source of truth)
- **Backup:** Local version saved as `{filename}.conflict.{ext}`
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

### Phase 1 — MVP (Current)

- Config-driven adapter engine with JSON configs
- Bidirectional sync: pull + push with polling and file watching
- 9 file formats: CSV, JSON, YAML, ICS, VCF, HTML, Markdown, Text, Raw
- Transform pipeline: pick, omit, rename, flatten, keyBy
- Git auto-commit per sync cycle
- macOS Keychain credential storage
- HTTPClient with retry and rate-limit handling
- Demo API server for testing
- CLAUDE.md agent guide generation
- 180+ tests (unit, integration, E2E)

### Phase 2 — Full macOS Experience

- Finder Sync Extension (file status badges)
- SwiftUI preferences window
- OAuth2 flow handler
- macOS notifications with action buttons
- Launch at login (SMAppService)
- Conflict resolution UI (diff viewer)
- Office formats: XLSX (Numbers/Excel), DOCX (Pages/Word)

### Phase 3 — Power Features

- Webhook listener for instant server-to-local sync
- Selective sync (choose resources per service)
- Community adapter repository
- AI-assisted adapter generation from API docs
