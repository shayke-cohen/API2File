# API2File

Bidirectional sync engine that bridges cloud APIs and local files. Edit a CSV in Numbers, save it, and it pushes to your API. Data changes on the server sync down to local files. Git auto-commits provide version history.

Think **Dropbox, but for APIs** — config-driven, format-aware, zero external dependencies.

## Features

- **Config-driven adapters** — connect any REST/GraphQL API via JSON config, no code required
- **Bidirectional sync** — pull (server to file) and push (file to server) with debouncing
- **10 file formats** — JSON, CSV, YAML, ICS (Calendar.app), VCF (Contacts.app), HTML, Markdown, Text, Raw, and more
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

### Build

```bash
swift build
```

### Run the Demo

```bash
# Set up demo environment
./scripts/demo-setup.sh

# Start the demo server (runs on port 8089)
swift run api2file-demo

# In another terminal — verify the API works
curl -s http://localhost:8089/api/tasks | python3 -m json.tool
```

The demo server provides a tasks API with seed data. The adapter config at `~/API2File/demo/.api2file/adapter.json` maps it to a local `tasks.csv` file.

### Test the Sync

**Pull** (API to local file):
```bash
# After sync runs, check the CSV
cat ~/API2File/demo/tasks.csv
```

**Push** (local edit to API):
1. Edit `~/API2File/demo/tasks.csv` (e.g., change a task name)
2. Save the file
3. Wait for the sync interval (10s) or trigger manually
4. Verify the change hit the API:
   ```bash
   curl -s http://localhost:8089/api/tasks/1 | python3 -m json.tool
   ```

**Git history**:
```bash
cd ~/API2File/demo && git log --oneline
```

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
└── {other-services}/
```

## License

MIT
