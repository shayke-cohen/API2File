# API2File — Architecture

## Overview

API2File is a native Apple-platform sync engine built in pure Swift. It uses a layered architecture: a top-level **SyncEngine** orchestrates multiple **AdapterEngine** instances (one per connected service), each interpreting a JSON config to handle API communication, data transformation, and file I/O.

The design direction is a **canonical object-file model**: every resource has a structured JSON representation stored in hidden object files, and one or more human-facing files generated from that canonical data for native desktop apps and agent workflows.

Each service now also maintains a derived SQLite mirror at `.api2file/cache/service.sqlite`. The database is regenerated from canonical object files after successful pull/push work and is exposed as a read-only query surface for local tools and MCP agents, including record-resolution helpers that map SQL hits back to canonical and projection files.

On macOS, the app exposes two complementary desktop surfaces: a menu bar app with a single Dashboard shell for file browsing, local SQLite exploration, activity review, and settings; and a Finder-facing workflow where synced files can be opened directly in API2File, badged through Finder Sync, and previewed through a Quick Look extension with text-first custom previews plus metadata fallback for binary and Office-style files.

The repo now also contains an experimental browser-native product line in [`website/`](/Users/shayco/API2File/website). Lite is intentionally separate from the Swift runtime: it preserves adapter JSON and canonical/projection concepts, but re-implements the runtime in TypeScript around browser capabilities like File System Access, IndexedDB, and `fetch`.

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│          API2File macOS / iOS apps + extensions         │
│                                                          │
│  ┌──────────────┐  ┌──────────────────────────────────┐ │
│  │ SwiftUI UI   │  │         SyncEngine               │ │
│  │ (macOS/iOS)  │──│  - Service discovery              │ │
│  │ Dashboard /  │  │  - Finder state publishing        │ │
│  │ Finder / QL  │  │  - Lifecycle management           │ │
│  └──────────────┘  │  - Pull/push orchestration         │ │
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
│  │  FileMapper · ObjectFileManager · SQLiteMirror      │ │
│  │  GitManager                                         │ │
│  │  KeychainManager · SyncCoordinator · FileWatcher    │ │
│  │  PlatformServices · StorageLocations ·             │ │
│  │  VersionControlBackend · NetworkMonitor            │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Core Components

### Dashboard Shell

**Files:** `Sources/API2FileApp/UI/DashboardRootView.swift`, `Sources/API2FileApp/UI/Dashboard2View.swift`, `Sources/API2FileApp/UI/SQLExplorerPane.swift`, `Sources/API2FileApp/UI/PreferencesView.swift`

The macOS dashboard is a single root shell that hosts three inner sections:

- **File Explorer** — a workspace-first browser for synced files, service selection, sync actions, and in-app editing/preview launch points
- **Data Explorer** — a SQLite-backed view over `.api2file/cache/service.sqlite`
- **Activity** — recent pull/push history for the selected service set

The dashboard also owns the general settings sheet instead of using a separate top-level preferences-style dashboard screen.

## Browser-Native Lite

Lite is a research-first browser runtime, not a parity promise. Its current implementation centers on:

- a Vite + TypeScript app shell in [`website/src/app.ts`](/Users/shayco/API2File/website/src/app.ts)
- browser runtime contracts in [`website/src/runtime/interfaces.ts`](/Users/shayco/API2File/website/src/runtime/interfaces.ts)
- IndexedDB-backed credential and sync state stores
- File System Access based folder access plus snapshot fallback
- a config-driven Lite sync engine with verified demo collection pull/push round-trip
- a static adapter audit that flags likely browser blockers such as unsupported formats, media flows, OAuth2, and cross-origin risk

The Lite runtime currently prioritizes:

- collection resources and browser-friendly text formats (`csv`, `json`, `md`, `html`, `yaml`, `txt`)
- aggressive in-tab sync while the page is open
- folder rescans via file hashing instead of native file watchers
- browser storage for credentials and service manifests

It intentionally does not yet promise:

- native-style background sync when the tab is closed
- full parity for media-heavy adapters or Office/binary formats
- automatic support for credentialed third-party APIs until live CORS behavior is proven

The Lite sync path is implemented in [`website/src/runtime/syncEngine.ts`](/Users/shayco/API2File/website/src/runtime/syncEngine.ts) and the adapter compatibility audit in [`website/src/runtime/adapterAudit.ts`](/Users/shayco/API2File/website/src/runtime/adapterAudit.ts).

### SyncEngine

**File:** `Sources/API2FileCore/Core/SyncEngine.swift`

Top-level orchestrator that manages the full sync lifecycle.

**Responsibilities:**
- Scan the configured sync root for services (directories containing `.api2file/adapter.json`)
- Register each service: load config, load auth from keychain, init git, register with coordinator
- Route pull and push operations to the correct AdapterEngine
- Generate CLAUDE.md agent guides for AI integration
- Consume injected platform services instead of directly assuming macOS-only paths, watchers, and git behavior

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

### SQLiteMirror

**File:** `Sources/API2FileCore/Core/SQLiteMirror.swift`

Maintains a per-service SQLite database under `.api2file/cache/service.sqlite`.

- Regenerates from canonical object files plus `.api2file/file-links.json`
- Creates one query table per resource with scalar columns plus `_json_payload`
- Adds metadata columns such as `_remote_id`, `_projection_path`, `_object_path`, `_last_synced_at`, and `_status`
- Rejects mutating SQL; the mirror is analysis-only in v1
- Powers the dashboard Data Explorer, local control API, and MCP SQL/search tools

### Finder Sync Extension

**File:** `Sources/FinderExtension/FinderSync.swift`

Finder Sync publishes the synced-folder presence into Finder itself.

- Registers badges for synced, modified, syncing, conflict, and error states
- Exposes contextual actions such as force-sync and view-on-server
- Resolves service IDs from selected paths and talks to the local control API
- Watches the sync root through the shared state/bookmark model rather than re-implementing sync logic

### Quick Look Extension

**File:** `Sources/QuickLookExtension/PreviewProvider.swift`

Quick Look preview support is file-type-aware but intentionally pragmatic.

- CSV gets a table-style preview
- Markdown gets a lightweight rendered preview
- JSON, YAML, TXT, ICS, VCF, and EML get text-first previews
- Images, HTML, PDF, SVG, audio, and movie files can pass through to system preview behavior when appropriate
- Binary, archive, and Office-style files fall back to a metadata card rather than attempting a lossy custom renderer

### FileLinkManager

**File:** `Sources/API2FileCore/Core/FileLinkManager.swift`

Persists `.api2file/file-links.json`, which records the relationship between:

- the human-facing projection path
- the canonical object-file path
- the resource name and remote ID

This explicit link index lets the engine route edits on either surface back to the same canonical record safely.

### PlatformServices and StorageLocations

**Files:** `Sources/API2FileCore/Core/PlatformServices.swift`, `Sources/API2FileCore/Core/StorageLocations.swift`

Platform-specific dependencies are injected into `SyncEngine` through `PlatformServices`.

- `StorageLocations` centralizes the sync root, adapters directory, and app support paths
- `PlatformServices` bundles the adapter store, keychain, notifications, watchers, and version-control backend factory
- macOS uses shell git and filesystem watchers, while iOS swaps in sandbox-aware storage and an embedded history backend

### GitManager

**File:** `Sources/API2FileCore/Core/GitManager.swift`

Wraps the configured version-control backend for per-service history.

- `initRepo()` — initialize history in service directory
- `createGitignore()` — exclude `.api2file/` from tracking
- `commitAll(message:)` — stage all + commit
- `hasChanges()` / `fileHashAtHead()` — change detection

Each service directory is an independent history repository via the active backend.

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
Write human-facing files to ~/API2File-Data/{service}/{path}
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
- **Derived agent artifacts** are optional hidden files under `.api2file/derived/` for browser-rendered context, manifests, and other read-only sidecars
- A resource may map to more than one local file surface, but only the canonical structured representation is authoritative
- Editing both the canonical and projected files before the same sync cycle should be treated as a conflict, not a merge heuristic
- `.api2file/file-links.json` explicitly links projections to canonical object files
- Wix blog Markdown is a projection of canonical `richContent` / Ricos data, not a raw storage format

For Wix specifically, the adapter now also classifies each resource as one of:

- `full_crud`
- `partial_writable`
- `read_only`

That capability class is treated as part of the adapter contract and is validated both by config tests and by the live Wix contract matrix.

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
    ├── capabilityClass → full_crud / partial_writable / read_only
    └── sync    → When to sync (interval, debounce)
```

Adding a new service requires only a JSON file — no Swift code, no recompilation.

Wix CMS is a good example of why this matters: the bundled adapter uses collection metadata, not site-specific name filters, to decide which generic `cms/*.csv` files are writable. `collections.json` remains the read-only catalog, while only true `NATIVE` collections with write-capable metadata are surfaced as writable CSV projections.

Wix site snapshots are the main exception to the pure adapter-only model. The `site-urls` resource is still adapter-defined and writes the canonical URL catalog, but rendered HTML and PNG snapshots are generated after pull via an optional browser-backed snapshot service injected through `PlatformServices`. Those artifacts are hidden, linked from `.api2file/file-links.json`, and excluded from push/object-file flows.

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
                     ├── Workspace folder / service instance ID
                     ├── ExtraFields (Wix: Site ID + Site URL, Airtable: Base ID + Table Name)
                     └── Placeholder substitution + instance-specific keychain key in adapter config JSON
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
