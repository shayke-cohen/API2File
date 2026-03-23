# API2File

Bidirectional sync engine that bridges cloud APIs and local files. Edit a CSV in Numbers, save it, and it pushes to your API. Data changes on the server sync down to local files. Git auto-commits provide version history.

Think **Dropbox, but for APIs** — config-driven, format-aware, zero external dependencies.

## Features

- **Config-driven adapters** — connect any REST/GraphQL API via JSON config, no code required
- **Bundled adapters** — Monday.com, Wix, GitHub, Airtable out of the box, plus 6 demo adapters
- **macOS menu bar app** — always-on sync with per-service controls, preferences, and service detail view
- **Bidirectional sync** — pull (server to file) and push (file to server) with debouncing
- **10+ file formats** — JSON, CSV, YAML, ICS (Calendar.app), VCF (Contacts.app), HTML, Markdown, SVG, Text, Raw, and more
- **Transform pipeline** — declarative data transforms: pick, omit, rename, flatten, keyBy
- **Git auto-commit** — every sync cycle is committed with descriptive messages
- **Keychain auth** — secure credential storage via macOS Keychain
- **Pagination** — cursor, offset, and page-based pagination out of the box
- **Demo server** — built-in REST API for testing without external services
- **180+ tests** — unit, integration, and end-to-end test coverage
- **Zero dependencies** — pure Swift, macOS native frameworks only

## Quick Start

### Prerequisites

- macOS 13+
- Swift 5.9+
- Xcode Command Line Tools

### Build & Run

```bash
# Build the app
swift build

# Build the .app bundle (release)
swift build -c release
# The .app bundle is at build/API2File.app — copy to /Applications/ to launch from Spotlight
```

### Launch the App

```bash
# Option 1: Run directly
swift run API2FileApp

# Option 2: Open the .app bundle
open build/API2File.app

# Option 3: If installed to Applications
open /Applications/API2File.app
```

The app runs as a **menu bar icon** (cloud icon, top-right of screen). Click it to see connected services, sync controls, and add new services.

### Add a Service

1. Click the cloud icon in the menu bar
2. Click **"Add Service..."**
3. Choose a service (Demo, Monday.com, Wix, GitHub, or Airtable)
4. Enter your API key (and any extra fields like Wix Site ID or Airtable Base ID)
5. Click **Connect** — data syncs to `~/API2File/{service}/`

### Bundled Adapters

| Service | Auth | Resources | File Formats |
|---|---|---|---|
| **Demo** | None needed | tasks, contacts, events, notes, pages, etc. | CSV, VCF, ICS, MD, HTML, JSON, SVG, PNG, PDF |
| **Monday.com** | Bearer token | boards with items | CSV |
| **Wix** | API key + Site ID | contacts, products, blog posts, bookings, collections | CSV, Markdown, JSON |
| **GitHub** | Personal access token | repos, issues, gists, notifications, starred | CSV, JSON |
| **Airtable** | Personal access token + Base/Table ID | records, bases | JSON |

### Run the Demo (No Account Needed)

```bash
# Start the demo server (port 8089)
swift run api2file-demo

# In the app, add the "Demo Tasks API" service with any API key
# Files appear at ~/API2File/demo/
```

### Manage Services

- **Preferences → Services tab** — click a service to see detail view with resources, last sync time, file count
- **Service detail** — Sync Now, Open Folder, Update API Key, Disconnect
- **Menu bar** — each service has a submenu with quick sync and folder access
- **Per-service sync** — click the service submenu → Sync Now (or use Sync Now for all)

## How It Works

```
┌──────────────┐     pull      ┌──────────────┐     write      ┌──────────────┐
│  Cloud API   │ ────────────> │ Adapter      │ ─────────────> │ Local Files  │
│  (REST/GQL)  │               │ Engine       │                │ (CSV, JSON…) │
│              │ <──────────── │              │ <───────────── │              │
└──────────────┘     push      └──────────────┘   file watch   └──────────────┘
                                      │
                                      ▼
                               ┌──────────────┐
                               │ Git Manager  │
                               │ (auto-commit)│
                               └──────────────┘
```

1. **Discovery** — SyncEngine scans `~/API2File/` for `.api2file/adapter.json` files
2. **Pull** — HTTPClient fetches API data, TransformPipeline applies transforms, FormatConverter writes files
3. **Watch** — FileWatcher detects local edits via FSEvents
4. **Push** — FormatConverter reads files back to records, AdapterEngine pushes to API
5. **Commit** — GitManager auto-commits each sync cycle

## Adapter Config

Connect any API by creating a JSON config file. No code changes needed.

```json
{
  "service": "my-service",
  "displayName": "My Service",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.my-service.key"
  },
  "globals": {
    "baseUrl": "https://api.example.com"
  },
  "resources": [
    {
      "name": "items",
      "pull": {
        "url": "{baseUrl}/items",
        "dataPath": "$.data[*]"
      },
      "push": {
        "create": { "method": "POST", "url": "{baseUrl}/items" },
        "update": { "method": "PUT", "url": "{baseUrl}/items/{id}" },
        "delete": { "method": "DELETE", "url": "{baseUrl}/items/{id}" }
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": ".",
        "filename": "items.csv",
        "format": "csv",
        "idField": "id"
      },
      "sync": { "interval": 30, "debounceMs": 500 }
    }
  ]
}
```

### File Mapping Strategies

| Strategy | Description | Example |
|---|---|---|
| `one-per-record` | Each record becomes its own file | `products/dog-food.json` |
| `collection` | All records in one file | `tasks.csv` |
| `mirror` | Preserve remote directory structure | `files/index.html` |

### Supported Formats

| Format | Extension | Opens In | Use Case |
|---|---|---|---|
| CSV | `.csv` | Numbers, Excel | Tabular data |
| JSON | `.json` | Any editor | Structured objects |
| YAML | `.yaml` | Any editor | Config, settings |
| ICS | `.ics` | Calendar.app | Events, schedules |
| VCF | `.vcf` | Contacts.app | Contacts, leads |
| HTML | `.html` | Safari, browsers | Web content |
| Markdown | `.md` | Any editor | Documentation |
| Text | `.txt` | TextEdit | Plain content |
| Raw | (any) | Varies | Binary passthrough |

### Auth Types

| Type | Header |
|---|---|
| `bearer` | `Authorization: Bearer <token>` |
| `apiKey` | Custom header with API key |
| `basic` | `Authorization: Basic <base64>` |
| `oauth2` | OAuth2 flow with token refresh |

### Transform Operations

| Operation | Purpose |
|---|---|
| `pick` | Keep only specified fields |
| `omit` | Remove specified fields |
| `rename` | Rename fields (supports dot-path extraction) |
| `flatten` | Flatten nested arrays to simple values |
| `keyBy` | Convert key-value arrays to dictionaries |

## Running Tests

```bash
# All tests
swift test

# Unit tests only
swift test --filter "FormatConverter|TransformPipeline|HTTPClient|AdapterConfig|SyncState"

# Integration tests
swift test --filter "AdapterEngineIntegration|FullSyncCycle"

# E2E tests (requires demo server)
swift test --filter DemoServerE2E
```

## Project Structure

```
Sources/
├── API2FileCore/          # Core library
│   ├── Adapters/          # Adapter engine, file mapper, transforms
│   │   └── Formats/       # Format converters (CSV, JSON, ICS, VCF…)
│   ├── Core/              # Sync engine, HTTP client, git, keychain
│   ├── Models/            # Config, state, and file models
│   ├── Server/            # Demo API server, local control server
│   └── Resources/         # Bundled adapter configs
├── API2FileApp/           # macOS menu bar app (SwiftUI)
└── API2FileDemo/          # CLI demo server entry point

Tests/
└── API2FileCoreTests/
    ├── Adapters/          # Format converter & transform tests
    ├── Core/              # HTTP client, git, sync coordinator tests
    ├── Models/            # Config & state parsing tests
    └── Integration/       # E2E and full sync cycle tests
```

## macOS App

API2File runs as a **menu bar app** — no dock icon, always accessible from the system tray.

### Menu Bar

- Cloud icon shows sync status (synced, syncing, error, paused)
- Per-service submenus with Sync Now, Open Folder, last sync time, file count
- Global controls: Sync Now (all), Pause/Resume, Add Service

### Preferences (two tabs)

- **General** — sync folder, git auto-commit, sync interval, notifications, server port
- **Services** — sidebar/detail view with NavigationSplitView
  - Click a service to see: status, last sync time, file count, resource list, error details
  - Actions: Sync Now, Open Folder, Update API Key, Disconnect

### Add Service Wizard

- 5 bundled services with guided setup
- Service-specific extra fields (Wix Site ID, Airtable Base ID + Table Name)
- API key stored securely in macOS Keychain

## Folder Layout at Runtime

```
~/API2File/
├── CLAUDE.md              # Auto-generated agent guide
├── demo/
│   ├── .api2file/
│   │   ├── adapter.json   # Service config
│   │   └── state.json     # Sync state
│   ├── .git/
│   ├── CLAUDE.md          # Service-specific agent guide
│   └── tasks.csv          # Synced data file
├── github/                # GitHub repos, issues, gists
├── wix/                   # Wix contacts, products, blog
├── airtable/              # Airtable records
└── {other-services}/
```

## License

MIT
