# API2File — Architecture

## Overview

API2File is a native macOS sync engine built in pure Swift with zero external dependencies. It uses a layered architecture: a top-level **SyncEngine** orchestrates multiple **AdapterEngine** instances (one per connected service), each interpreting a JSON config to handle API communication, data transformation, and file I/O.

The design direction is a **canonical object-file model**: every resource has a structured JSON representation stored in hidden object files, and one or more human-facing files generated from that canonical data for native desktop apps and agent workflows.

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    API2File.app                           │
│                                                          │
│  ┌──────────────┐  ┌──────────────────────────────────┐ │
│  │ Menu Bar UI  │  │         SyncEngine               │ │
│  │ (SwiftUI)    │──│  - Service discovery              │ │
│  └──────────────┘  │  - Lifecycle management           │ │
│                    │  - Pull/push orchestration         │ │
│                    └────────────┬─────────────────────┘ │
│                                 │                        │
│              ┌──────────────────┼──────────────────┐     │
│              ▼                  ▼                  ▼     │
│  ┌───────────────┐  ┌───────────────┐  ┌──────────────┐│
│  │ AdapterEngine │  │ AdapterEngine │  │AdapterEngine ││
│  │ (demo)        │  │ (monday)      │  │(github, etc) ││
│  └───────┬───────┘  └───────┬───────┘  └──────┬───────┘│
│          │                  │                  │        │
│  ┌───────▼──────────────────▼──────────────────▼──────┐ │
│  │              Shared Infrastructure                  │ │
│  │  HTTPClient · TransformPipeline · FormatConverters  │ │
│  │  FileMapper · ObjectFileManager · GitManager        │ │
│  │  KeychainManager · SyncCoordinator · FileWatcher    │ │
│  │  NetworkMonitor                                     │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### SyncEngine

**File:** `Sources/API2FileCore/Core/SyncEngine.swift`

Top-level orchestrator that manages the full sync lifecycle.

**Responsibilities:**
- Scan `~/API2File/` for services (directories containing `.api2file/adapter.json`)
- Register each service: load config, load auth from keychain, init git, register with coordinator
- Route pull and push operations to the correct AdapterEngine
- Generate CLAUDE.md agent guides for AI integration

**Key flow:**
```
start() → discoverServices() → registerService() × N → SyncCoordinator.start()
```

### AdapterEngine

**File:** `Sources/API2FileCore/Adapters/AdapterEngine.swift`

The heart of the system. Interprets adapter JSON configs to perform bidirectional sync for a single service.

**Pull flow:**
1. HTTPClient fetches data from API endpoint
2. JSONPath extracts records from response (`$.data.items[*]`)
3. Raw records are persisted to canonical object files
4. TransformPipeline applies pull transforms (pick, omit, rename, etc.)
5. FileMapper determines file paths based on mapping strategy
6. FormatConverter encodes records to the target human-facing format (CSV, JSON, ICS, etc.)
7. Human-facing files written to disk, SyncState updated

**Push flow:**
1. A canonical object file change uses its structured records directly
2. A human-facing file change is decoded back into canonical structured records
3. TransformPipeline applies push transforms
4. Diff against the previous canonical records to determine creates, updates, deletes
5. HTTPClient sends appropriate API calls (POST/PUT/DELETE)
6. Canonical object files and human-facing projections are regenerated on success

**Pagination:** Supports cursor-based, offset-based, and page-based pagination — configured per resource in the adapter JSON.

### SyncCoordinator

**File:** `Sources/API2FileCore/Core/SyncCoordinator.swift`

Manages timing and concurrency of sync operations.

- **Polling:** Triggers periodic pulls at configured intervals (per-service)
- **Debouncing:** Collapses rapid file saves into a single push (default 500ms)
- **Queue:** Prevents concurrent push/pull on the same file
- **Pause/Resume:** Supports pausing sync (e.g., during network outage)

### HTTPClient

**File:** `Sources/API2FileCore/Core/HTTPClient.swift`

Thread-safe HTTP client built on URLSession with async/await.

- Automatic retry with exponential backoff for 5xx errors
- Rate limit (429) handling via `Retry-After` header
- Auth header injection (bearer, apiKey, basic, oauth2)
- Configurable timeout (default 30s)
- Immediate failure on 401 (re-auth required)

### TransformPipeline

**File:** `Sources/API2FileCore/Adapters/TransformPipeline.swift`

Declarative data transformation engine applied before/after sync.

**Operations:**
| Op | Input | Output |
|---|---|---|
| `pick` | `{a:1, b:2, c:3}` + fields `[a,c]` | `{a:1, c:3}` |
| `omit` | `{a:1, b:2, c:3}` + fields `[b]` | `{a:1, c:3}` |
| `rename` | `{old:1}` + `old→new` | `{new:1}` |
| `flatten` | `{items:[{url:"a"},{url:"b"}]}` | `{images:["a","b"]}` |
| `keyBy` | `[{k:"a",v:1},{k:"b",v:2}]` | `{a:1, b:2}` |

**Also includes:**
- **JSONPath** — simple path-based extraction (`$.data.boards[0].name`, `$[*]`)
- **TemplateEngine** — mustache-style templates with filters (`{name|slugify}`, `{field|lower}`, `{field|default:fallback}`)

### FormatConverters

**Directory:** `Sources/API2FileCore/Adapters/Formats/`

Protocol-based, pluggable format system. Each converter implements `FormatConverter`:

```swift
protocol FormatConverter {
    func encode(records: [[String: Any]], options: FormatOptions?) throws -> Data
    func decode(data: Data, options: FormatOptions?) throws -> [[String: Any]]
}
```

**Implementations:**

| Converter | Standard | Notes |
|---|---|---|
| CSVFormat | RFC 4180 | `id` → `_id` column mapping, header-based column matching |
| JSONFormat | — | Single object or array serialization |
| YAMLFormat | — | Simple flat key-value (no external deps) |
| ICSFormat | RFC 5545 | iCalendar events with DTSTART/DTEND, VEVENT components |
| VCFFormat | RFC 6350 | vCard contacts with FN, N, EMAIL, TEL properties |
| HTMLFormat | — | Table generation from records |
| MarkdownFormat | — | Markdown table output |
| TextFormat | — | Line-based or delimited plain text |
| RawFormat | — | Binary passthrough |

All converters are zero-dependency pure Swift.

### FileMapper

**File:** `Sources/API2FileCore/Adapters/FileMapper.swift`

Maps API records to filesystem paths based on the adapter's `fileMapping` config.

**Strategies:**
- `one-per-record` — each record gets its own file, named via template (`{name|slugify}.json`)
- `collection` — all records written to a single file (`tasks.csv`)
- `mirror` — preserves remote directory structure

### ObjectFileManager

**File:** `Sources/API2FileCore/Adapters/ObjectFileManager.swift`

Maintains the hidden structured JSON files that sit next to user-facing files.

- `collection` resources use `.{stem}.objects.json`
- `one-per-record` resources use `.objects/{stem}.json`
- Stores the canonical local record model used for diffing, regeneration, and high-fidelity agent edits
- Maps between canonical object-file paths and user-facing projection paths
- Object-file edits are watched and pushed through the same sync engine as human-facing files

### FileLinkManager

**File:** `Sources/API2FileCore/Core/FileLinkManager.swift`

Persists `.api2file/file-links.json`, which records the relationship between:

- the human-facing projection path
- the canonical object-file path
- the resource name and remote ID

This explicit link index lets the engine route edits on either surface back to the same canonical record safely.

### GitManager

**File:** `Sources/API2FileCore/Core/GitManager.swift`

Wraps shell `git` commands for version history.

- `initRepo()` — initialize git in service directory
- `createGitignore()` — exclude `.api2file/` from tracking
- `commitAll(message:)` — stage all + commit
- `hasChanges()` / `fileHashAtHead()` — change detection

Each service directory is an independent git repository.

### KeychainManager

**File:** `Sources/API2FileCore/Core/KeychainManager.swift`

Secure credential storage using macOS Security framework.

- Keys namespaced with `com.api2file.` prefix
- Supports simple tokens and OAuth2 token sets (access + refresh + expiry)
- CRUD operations: save, load, delete

### AgentGuideGenerator

**File:** `Sources/API2FileCore/Core/AgentGuideGenerator.swift`

Auto-generates `CLAUDE.md` files from adapter configs so AI agents (Claude Code, etc.) can understand and interact with synced files without any manual setup.

Generates both root-level overview and per-service guides with resource inventory, editable fields, format instructions, and sync behavior.

The guide content should steer agents toward the canonical object files for high-fidelity edits while still documenting the human-facing files used with native desktop apps.

## Data Flow

### Pull Cycle (Server → Local)

```
API Response (JSON)
    │
    ▼
JSONPath extraction ($.data.items[*])
    │
    ▼
Write canonical object files (`.*.objects.json` / `.objects/*.json`)
    │
    ▼
TransformPipeline (pick, omit, rename, flatten, keyBy)
    │
    ▼
FileMapper (determine human-facing file paths)
    │
    ▼
FormatConverter.encode() (records → CSV/JSON/ICS/VCF/...)
    │
    ▼
Write human-facing files to ~/API2File/{service}/{path}
    │
    ▼
Update .api2file/state.json (hash, remoteId, timestamp)
    │
    ▼
GitManager.commitAll("sync: pull {service} — updated canonical + projected files")
```

### Push Cycle (Local → Server)

```
FileWatcher detects change (FSEvents)
    │
    ▼
Debounce (500ms)
    │
    ▼
If human-facing file changed:
FormatConverter.decode() (CSV/JSON/ICS/VCF/... → records)
    │
    ▼
Normalize into canonical object records
    │
    ├── For Wix Markdown rich content: call Wix Ricos conversion APIs when available
    │   (`/ricos/v1/ricos-document/convert/from-ricos`, `/convert/to-ricos`)
    │
    ▼
TransformPipeline (push transforms)
    │
    ▼
Diff against previous canonical records
    │
    ▼
HTTPClient → POST/PUT/DELETE to API
    │
    ▼
Rewrite canonical object files
    │
    ▼
Regenerate human-facing projections
    │
    ▼
Update .api2file/state.json
    │
    ▼
GitManager.commitAll("sync: push {service} — canonical + projections updated")
```

## Canonical vs Projection Files

- **Canonical object files** preserve the structured record shape needed for safe sync back to the server
- **Human-facing files** are projections optimized for native apps like Numbers, Calendar, Contacts, Preview, Pages, and editors
- A resource may map to more than one local file surface, but only the canonical structured representation is authoritative
- Editing both the canonical and projected files before the same sync cycle should be treated as a conflict, not a merge heuristic
- `.api2file/file-links.json` explicitly links projections to canonical object files
- Wix blog Markdown is a projection of canonical `richContent` / Ricos data, not a raw storage format

## Config-Driven Design

The adapter system is the core architectural decision. Instead of writing code per service, everything is driven by `adapter.json` configs:

```
adapter.json
├── auth        → How to authenticate (bearer, apiKey, basic, oauth2)
├── globals     → Shared baseUrl, headers
└── resources[] → What to sync
    ├── pull    → How to fetch (URL, method, JSONPath, pagination)
    ├── push    → How to create/update/delete (endpoints per operation)
    ├── fileMapping → How to write files (strategy, format, transforms)
    └── sync    → When to sync (interval, debounce)
```

Adding a new service requires only a JSON file — no Swift code, no recompilation.

## Concurrency Model

- **Swift async/await** throughout the codebase
- **Actor isolation** for thread-safe shared state (SyncState, SyncCoordinator)
- **URLSession** for non-blocking HTTP
- **FSEvents** for efficient file system monitoring
- **NWPathMonitor** for network state tracking

## State Management

All sync state lives in `.api2file/state.json` per service:

```json
{
  "files": {
    "tasks.csv": {
      "remoteId": "collection",
      "lastSyncedHash": "sha256:abc123...",
      "lastSyncTime": "2026-03-23T10:30:00Z",
      "status": "synced"
    }
  }
}
```

User-facing files contain zero metadata — only actual content. The state file maps between file paths and server records.

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Zero dependencies | Pure Swift + macOS frameworks | No dependency management, no version conflicts, smaller binary |
| Config over code | JSON adapter configs | Users and AI agents can create adapters without Swift knowledge |
| Server wins | Conflict resolution strategy | Simple, predictable, no data loss (local backup + git history) |
| Git per service | Separate repo per folder | Clean history, independent sync cycles, easy rollback |
| Hidden state | `.api2file/state.json` | User files stay 100% clean content |
| Shell git | `Process` + `git` CLI | More reliable than SwiftGit2, standard on dev Macs |
| Keychain auth | macOS Security framework | Secure, native, survives app reinstalls |
| Menu bar app | `MenuBarExtra` (SwiftUI) | Lightweight, always accessible, no dock clutter |
| NSWindow for modals | `NSHostingController` in standalone window | Menu bar apps can't present sheets; standalone window works from any call site |

## macOS App Architecture

### UI Layer

```
API2FileApp.swift
├── AppState (@MainActor, ObservableObject)
│   ├── services: [ServiceInfo]
│   ├── syncEngine: SyncEngine (actor)
│   ├── openAddServiceWindow() → NSWindow + NSHostingController
│   ├── syncService(serviceId:) / removeService(serviceId:)
│   └── updateAPIKey(serviceId:newKey:)
├── MenuBarExtra → MenuBarView
│   ├── Service submenus (Sync Now, Open Folder, status)
│   └── Global controls (Add Service, Sync Now, Pause)
└── Settings → PreferencesView
    ├── GeneralTab (config bindings)
    └── ServicesTab (NavigationSplitView)
        ├── Sidebar: service list with context menus
        └── Detail: ServiceDetailView
            ├── Info: status, last sync, file count, resources
            ├── Actions: Sync, Open Folder, Update Key, Disconnect
            └── Sheets: re-auth, disconnect confirmation
```

### AddServiceView Flow

```
selectService → enterCredentials → connecting → done
                     │
                     ├── API key (SecureField)
                     ├── ExtraFields (Wix: Site ID + Site URL, Airtable: Base ID + Table Name)
                     └── Placeholder substitution in adapter config JSON
```

### Bundled Adapter Configs

Located at `Sources/API2FileCore/Resources/Adapters/`:

| Adapter | API Type | Auth | Key Resources |
| --- | --- | --- | --- |
| `demo.adapter.json` | REST (localhost) | Bearer | 11 resources across all formats |
| `monday.adapter.json` | GraphQL | Bearer | boards with items → CSV |
| `wix.adapter.json` | REST (POST queries + media pulls) | API key + Site ID header | contacts, blog, products, media assets, bookings, groups, comments, collections |
| `github.adapter.json` | REST | Bearer (PAT) | repos, issues, gists, notifications, starred |
| `airtable.adapter.json` | REST | Bearer (PAT) | records, bases |
| 6 demo adapters | REST (localhost) | Bearer | teamboard, peoplehub, calsync, pagecraft, devops, mediamanager |
