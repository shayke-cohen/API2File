# API2File

Native macOS app that bidirectionally syncs cloud API data to local files. Like Dropbox but for APIs -- edit a CSV in Numbers and it pushes to Monday.com; change data on Wix and it appears as local files. Config-driven adapters mean no code is needed to add new cloud services.

Zero external dependencies. Pure Swift, macOS native frameworks only.

## Key Features

- **15 file format converters** -- CSV, JSON, HTML, Markdown, YAML, ICS, VCF, EML, SVG, WEBLOC, XLSX, DOCX, PPTX, Text, Raw
- **Config-driven adapter system** -- connect any REST/GraphQL API via `.adapter.json`, no code required
- **Media sync** -- generic binary file download/upload for any cloud storage API (images, videos, documents)
- **Bidirectional sync** with smart collection diffing -- pull from API, push local edits back
- **macOS menu bar app** (MenuBarExtra) -- always-on sync with per-service controls
- **Web dashboard** at `localhost:8089` -- visual overview served by the demo server
- **CLI tool** (`api2file`) -- init, add, sync, pull, status, list
- **Auto-generated CLAUDE.md** -- agent guide placed in the sync folder for AI tools
- **Git auto-commit** -- every sync cycle committed with descriptive messages
- **macOS Keychain** for secure credential storage
- **Demo server** with 14 resource types (tasks, contacts, events, notes, pages, config, services, incidents, logos, photos, documents, spreadsheets, reports, presentations)
- **5 bundled cloud adapters** -- Demo, Monday.com, Wix, GitHub, Airtable
- **537 tests** -- unit, integration, and end-to-end coverage

## Quick Start

### Prerequisites

- macOS 13+
- Swift 5.9+
- Xcode Command Line Tools

### 1. Build

```bash
swift build
```

### 2. Start the demo server

```bash
swift run api2file-demo
```

The demo API runs on port 8089 with seed data for all 14 resource types.

### 3. Open the web dashboard

```bash
open http://localhost:8089/
```

### 4. Set up via CLI

```bash
swift run api2file init          # creates ~/API2File-Data/ with global config
swift run api2file add demo      # configures the demo adapter, stores key in Keychain
swift run api2file sync demo     # pulls data from the demo server to local files
swift run api2file status        # shows all services and their sync state
```

### 5. Run the menu bar app

```bash
swift run API2FileApp
```

The app appears as a cloud icon in the menu bar. Click it to see connected services, trigger syncs, and open preferences.

### 6. Run tests

```bash
swift test    # 537 tests
```

## Architecture

```text
Sources/
  API2FileCore/           Core library (no UI)
    Adapters/             AdapterEngine, FileMapper, TransformPipeline
      Formats/            15 format converters (CSV, JSON, ICS, VCF, XLSX, DOCX, PPTX...)
    Core/                 SyncEngine, SyncCoordinator, CollectionDiffer, HTTPClient,
                          GraphQLClient, GitManager, KeychainManager, FileWatcher,
                          ConfigWatcher, NetworkMonitor, OAuth2Handler,
                          NotificationManager, AgentGuideGenerator
    Models/               AdapterConfig, GlobalConfig, SyncState, FileFormat
    Server/               DemoAPIServer, LocalServer (control API on port 21567), MockServer
    Resources/
      Adapters/           12 bundled .adapter.json files
      Web/                dashboard.html
  API2FileApp/            macOS menu bar app (SwiftUI)
    App/                  API2FileApp.swift (entry point)
    UI/                   MenuBarView, PreferencesView, ServiceDetailView, AddServiceView
  API2FileCLI/            CLI tool (api2file)
  API2FileDemo/           Demo server entry point (api2file-demo)

Tests/
  API2FileCoreTests/
    Adapters/             FormatConverter, TransformPipeline, ICS/VCF, EML/SVG/WEBLOC tests
    Core/                 HTTPClient, GitManager, KeychainManager, SyncCoordinator,
                          CollectionDiffer, OAuth2Handler, NotificationManager, AgentGuide tests
    Models/               AdapterConfig, SyncState parsing tests
    Integration/          AdapterEngine, FullSyncCycle, DemoServer E2E,
                          BidirectionalSync E2E, CollectionDiff E2E, RealSync E2E
```

## File Format Mapping

| Format   | Extension | Opens In              | Use Case                     |
|----------|-----------|-----------------------|------------------------------|
| CSV      | `.csv`    | Numbers, Excel        | Tabular data                 |
| JSON     | `.json`   | Any editor            | Structured objects           |
| HTML     | `.html`   | Safari, browsers      | Web content                  |
| Markdown | `.md`     | Any editor            | Documentation, blog posts    |
| YAML     | `.yaml`   | Any editor            | Config, settings             |
| ICS      | `.ics`    | Calendar.app          | Events, schedules            |
| VCF      | `.vcf`    | Contacts.app          | Contacts, leads              |
| EML      | `.eml`    | Mail.app              | Email messages               |
| SVG      | `.svg`    | Preview, browsers     | Vector graphics              |
| WEBLOC   | `.webloc` | Safari                | Web bookmarks                |
| XLSX     | `.xlsx`   | Numbers, Excel        | Spreadsheets with formatting |
| DOCX     | `.docx`   | Pages, Word           | Word documents               |
| PPTX     | `.pptx`   | Keynote, PowerPoint   | Slide presentations          |
| Text     | `.txt`    | TextEdit              | Plain content                |
| Raw      | (any)     | Varies                | Binary passthrough (PNG, PDF)|
| Media    | (any)     | Preview, Finder       | Cloud media (PNG, JPG, MP4)  |

## Bundled Adapters

| Adapter | Auth | Resources | File Formats |
| --- | --- | --- | --- |
| **Demo** | None needed | tasks, contacts, events, notes, pages, config, services, incidents, logos, photos, documents, spreadsheets, reports, presentations | CSV, VCF, ICS, MD, HTML, JSON, SVG, XLSX, DOCX, PPTX, Raw |
| **Monday.com** | Bearer token | boards with items | CSV |
| **Wix** | API key + Site ID | contacts, products, blog posts, CMS (projects, todos, orders, events, blog tags), members, site properties, media | CSV, Markdown, JSON, Raw |
| **GitHub** | Personal access token | repos, issues, notifications | CSV |
| **Airtable** | Personal access token + Base/Table ID | records, bases | JSON |

## Sync Folder Structure

Default sync folder: `~/API2File-Data/` (configurable in `GlobalConfig`).

```text
~/API2File-Data/
  .api2file.json              Global config
  CLAUDE.md                   Auto-generated agent guide
  demo/
    .api2file/
      adapter.json            Service config
      state.json              Sync state
    .git/                     Auto-committed history
    CLAUDE.md                 Service-specific agent guide
    tasks.csv                 Tasks spreadsheet (Numbers)
    incidents.csv             Incident log (Numbers)
    config.json               Site config (editor)
    inventory.xlsx            Product inventory (Numbers/Excel)
    deck.pptx                 Slide deck (Keynote/PowerPoint)
    contacts/
      alice-smith.vcf         Contact card (Contacts.app)
    events/
      team-standup.ics        Calendar event (Calendar.app)
    notes/
      meeting-notes.md        Markdown note (editor)
    pages/
      home.html               Web page (Safari)
    services/
      auth-service.json       Microservice status (editor)
    logos/
      app-icon.svg            Vector logo (Preview)
    photos/
      red-swatch.png          Image (Preview)
    documents/
      q1-report.pdf           PDF document (Preview)
    reports/
      monthly-summary.docx    Word document (Pages/Word)
  wix/
    .api2file/
      adapter.json            Service config (11 resources)
      state.json              Sync state
    .git/                     Auto-committed history
    CLAUDE.md                 Service-specific agent guide
    contacts.csv              CRM contacts (Numbers)
    products.csv              Store products (Numbers)
    members.csv               Site members (Numbers, read-only)
    site-properties.json      Site settings (editor, read-only)
    blog/
      my-post.md              Blog post (editor)
    cms/
      projects.csv            CMS projects (Numbers)
      todos.csv               CMS todos (Numbers)
      orders.csv              Store orders (Numbers, read-only)
      events.csv              CMS events (Numbers)
      blog-tags.csv           Blog tags (Numbers, read-only)
    media/
      photo.jpg               Downloaded media file (Preview)
      document.pdf            Downloaded document (Preview)
```

## CLI Reference

```text
api2file <command> [arguments]

Commands:
  init              Initialize ~/API2File-Data/ with global config
  list              List available bundled adapters
  add <service>     Set up a new service (demo/monday/wix/github/airtable)
  status            Show all services and their sync status
  sync [service]    Trigger immediate sync (all or specific service)
  pull [service]    Pull from API to local files (all or specific service)
  help              Show help message

Examples:
  api2file init
  api2file add demo
  api2file add github
  api2file status
  api2file sync
  api2file sync github
  api2file pull monday
```

## Testing

537 tests across four categories:

| Category | What it covers | Filter |
| --- | --- | --- |
| Unit | Format converters, transforms, HTTP client, config parsing, git, keychain, agent guide, sync coordinator, collection differ, OAuth2, notifications | `--filter "FormatConverter\|TransformPipeline\|HTTPClient\|AdapterConfig\|SyncState\|GitManager\|AgentGuide\|SyncCoordinator\|CollectionDiffer\|OAuth2\|Notification\|ICS\|VCF\|EML\|SVG\|Webloc"` |
| Integration | AdapterEngine pipeline, full sync cycle | `--filter "AdapterEngineIntegration\|FullSyncCycle\|DemoAdapterPipeline"` |
| E2E | Demo server all resources, bidirectional sync, collection diffing | `--filter "DemoServerE2E\|BidirectionalSync\|CollectionDiff\|DemoAdapterConfig"` |
| Real sync | End-to-end with live demo server (requires `api2file-demo` running) | `--filter RealSyncE2E` |

```bash
swift test                              # all 537 tests
swift test --filter FormatConverter      # just format converters
swift test --filter DemoServerE2E        # E2E with demo server
```

## Adapter Config Format

Connect any REST or GraphQL API by creating an `.adapter.json` file:

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
        "filename": "items.csv",
        "format": "csv",
        "idField": "id"
      },
      "sync": { "interval": 30, "debounceMs": 500 }
    }
  ]
}
```

**File mapping strategies:** `collection` (all records in one file), `one-per-record` (each record its own file), `mirror` (preserve remote directory structure).

**Auth types:** `bearer`, `apiKey`, `basic`, `oauth2`.

**Transform operations:** `pick`, `omit`, `rename`, `flatten`, `keyBy` -- applied via a declarative pipeline before writing files.

**Media sync:** Set `"type": "media"` on a pull config along with a `mediaConfig` to download binary files from URLs in the API response. `MediaConfig` maps response fields to download URLs and filenames:

```json
{
  "pull": {
    "url": "{baseUrl}/files/search",
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
    "create": { "method": "POST", "url": "{baseUrl}/files/generate-upload-url" }
  },
  "fileMapping": {
    "strategy": "mirror",
    "directory": "media",
    "format": "raw",
    "idField": "id"
  }
}
```

The engine calls `pullMediaFiles()` to download each file's binary content directly from the URL, and `pushMediaFile()` to upload via a two-step signed-URL flow.

## Known Limitations

- **OAuth2** flow is implemented but not tested with a real browser redirect
- **Real cloud APIs** (Monday.com, Wix, GitHub, Airtable) are not integration-tested -- they require live API keys
- **Finder extension** is scaffold only -- badges and context menus are not functional
- **Notifications** are implemented in NotificationManager but not wired into SyncEngine events
- **CLI target** (`API2FileCLI`) exists as source but is not declared in `Package.swift` -- build it manually or use the menu bar app

## License

MIT
