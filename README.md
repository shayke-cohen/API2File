# API2File

Native Apple-platform app that bidirectionally syncs cloud API data to local files. Like Dropbox but for APIs -- edit a CSV in Numbers and it pushes to Monday.com; change data on Wix and it appears as local files. Config-driven adapters mean no code is needed to add new cloud services.

Pure Swift core with native macOS and iOS apps.

## Key Features

- **15 file format converters** -- CSV, JSON, HTML, Markdown, YAML, ICS, VCF, EML, SVG, WEBLOC, XLSX, DOCX, PPTX, Text, Raw
- **Config-driven adapter system** -- connect any REST/GraphQL API via `.adapter.json`, no code required
- **Canonical object files + projections** -- hidden structured JSON files stay high-fidelity while CSV/Markdown/ICS/etc. stay human-friendly
- **Read-only SQLite mirror per service** -- query synced data locally at `.api2file/cache/service.sqlite`
- **Media sync** -- generic binary file download/upload for any cloud storage API (images, videos, documents)
- **Bidirectional sync** with smart collection diffing -- pull from API, push local edits back
- **macOS menu bar app + dashboard** -- always-on sync with a unified dashboard for File Explorer, Data Explorer, Activity, and settings
- **Finder-aware desktop flow** -- Finder Sync badges/context actions, document opening into API2File, and Quick Look previews for synced file types
- **Universal iOS app** -- browse, preview, edit, import, and share synced files from iPhone and iPad
- **Web dashboard** at `localhost:8089` -- visual overview served by the demo server
- **Browser-native Lite prototype** in [`website/`](/Users/shayco/API2File/website) -- experimental no-install sync runtime using File System Access API + IndexedDB
- **CLI tool** (`api2file`) -- init, add, sync, pull, status, list
- **MCP query tools** -- list tables, describe schema, run read-only SQL, search records, jump from record IDs to canonical/projection files, and query-open the first match
- **Dashboard workspace** -- one native macOS shell for file browsing, SQLite-backed data exploration, and sync activity
- **Global Data Explorer** -- browse a service's SQLite tables in one screen inside the macOS app
- **Auto-generated CLAUDE.md** -- agent guide placed in the sync folder for AI tools
- **Git auto-commit** -- every sync cycle committed with descriptive messages
- **macOS Keychain** for secure credential storage
- **Demo server** with 14 resource types (tasks, contacts, events, notes, pages, config, services, incidents, logos, photos, documents, spreadsheets, reports, presentations)
- **12 bundled adapters** -- 5 cloud (Demo, Monday.com, Wix, GitHub, Airtable) + 7 demo-themed (TeamBoard, PeopleHub, CalSync, PageCraft, DevOps, MediaManager, Wix-Demo)
- **500+ tests** -- unit, integration, end-to-end, and iOS state coverage

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

The app appears as a cloud icon in the menu bar. Open the Dashboard to browse synced files, inspect the SQLite mirror, review activity, and manage settings from one workspace.

### 6. Build the iOS app

```bash
xcodebuild -project API2File.xcodeproj -scheme API2FileiOS -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### 7. Build the macOS app and extensions

```bash
xcodebuild -project API2File.xcodeproj -scheme API2File build
xcodebuild -project API2File.xcodeproj -scheme API2FileFinderExtension build
xcodebuild -project API2File.xcodeproj -scheme API2FileQuickLookExtension build
```

### 8. Run tests

```bash
swift test
```

## Browser-Native Lite

Experimental browser-native work lives in [`website/`](/Users/shayco/API2File/website). This is a separate TypeScript/Vite product line, not a port of the Swift macOS app. The Lite runtime:

- runs in the browser against a user-picked folder
- stores service credentials and sync state in IndexedDB
- performs aggressive in-tab sync plus folder rescans
- keeps the existing adapter JSON format as its configuration source
- includes a compatibility audit and a verified demo collection round-trip

Typical commands:

```bash
cd website
npm install
npm run dev
npm run test
```

If package installation is unavailable, you can still type-check the web app from the repo root with:

```bash
tsc -p website/tsconfig.json
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
    App/                  API2FileApp.swift, API2FileAppDelegate.swift
    UI/                   MenuBarView, DashboardRootView, Dashboard2View,
                          SQLExplorerPane, PreferencesView, ServiceDetailView,
                          AddServiceView
  FinderExtension/        Finder Sync badges and contextual actions
  QuickLookExtension/     macOS Quick Look preview extension for synced files
  API2FileMCP/            MCP bridge executable for browser/webview control
  API2FileiOSApp/         iPhone + iPad app (SwiftUI)
    App/                  API2FileiOSApp.swift, IOSAppState.swift
    UI/                   Services, browser, activity, settings, file detail
  API2FileCLI/            CLI tool (api2file)
  API2FileDemo/           Demo server entry point (api2file-demo)
website/                  Browser-native Lite prototype (Vite + TypeScript)
  src/                    Browser runtime, audit harness, sync engine, UI shell

Tests/
  API2FileCoreTests/
    Adapters/             FormatConverter, TransformPipeline, ICS/VCF, EML/SVG/WEBLOC tests
    Core/                 HTTPClient, GitManager, KeychainManager, SyncCoordinator,
                          CollectionDiffer, OAuth2Handler, NotificationManager, AgentGuide tests
    Models/               AdapterConfig, SyncState parsing tests
    Integration/          AdapterEngine, FullSyncCycle, DemoServer E2E,
                          BidirectionalSync E2E, CollectionDiff E2E, RealSync E2E
  API2FileiOSTests/       iOS app state and persistence tests
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

### Cloud Adapters

| Adapter | File | Auth | Resources | File Formats |
| --- | --- | --- | --- | --- |
| **Demo** | `demo.adapter.json` | None | tasks, contacts, events, notes, pages, config, services, incidents, logos, photos, documents, spreadsheets, reports, presentations, emails, bookmarks, settings, snippets | CSV, VCF, ICS, MD, HTML, JSON, SVG, XLSX, DOCX, PPTX, EML, WEBLOC, YAML, TXT, Raw |
| **Monday.com** | `monday.adapter.json` | Bearer token | boards (with items via GraphQL) | CSV |
| **Wix** | `wix.adapter.json` | API key + Site ID header | contacts, blog-posts, products, orders, coupons, pricing-plans, gift-cards, forms (+ submissions child), members, site-properties, site-urls, media, pro-gallery, pdf-viewer, wix-video, wix-music-podcasts, bookings-services, bookings-appointments, groups, comments, events, events-rsvps, events-tickets, restaurant-menus, restaurant-reservations, restaurant-orders, bookings, collections (+ items child) | CSV, MD, JSON, Raw |
| **GitHub** | `github.adapter.json` | Bearer (PAT) | repos, issues, gists, notifications, starred | CSV, JSON |
| **Airtable** | `airtable.adapter.json` | Bearer (PAT) + Base/Table ID | records, bases | JSON |

### Demo-Themed Adapters

These adapters point at the local demo server (`localhost:8089`) and showcase real-world adapter patterns without needing external credentials.

| Adapter | File | Theme | Resources |
| --- | --- | --- | --- |
| **TeamBoard** | `teamboard.adapter.json` | Project management | tasks (CSV), config (YAML) |
| **PeopleHub** | `peoplehub.adapter.json` | CRM / contacts | contacts (VCF), notes (MD) |
| **CalSync** | `calsync.adapter.json` | Calendar | events (ICS), action-items (CSV) |
| **PageCraft** | `pagecraft.adapter.json` | CMS | pages (HTML), blog-posts (MD), config (JSON) |
| **DevOps** | `devops.adapter.json` | Infrastructure monitoring | services (JSON per record), incidents (CSV) |
| **MediaManager** | `mediamanager.adapter.json` | Digital assets | logos (SVG), photos (PNG raw), documents (PDF raw) |
| **Wix Demo** | `wix-demo.adapter.json` | Wix mock | contacts (CSV), blog-posts (MD), products (CSV), media/pro-gallery/pdf-viewer/video/audio (Raw), bookings-services (CSV), bookings-appointments (CSV), groups (CSV), comments (CSV), bookings (JSON), collections (JSON + items CSV) |

## Sync Folder Structure

Default sync folder: `~/API2File-Data/` (configurable in `GlobalConfig`).

```text
~/API2File-Data/
  .api2file.json              Global config
  CLAUDE.md                   Auto-generated agent guide
  demo/
    .api2file/
      adapter.json            Service config
      file-links.json         Canonical/projection path links
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
      adapter.json            Service config (28 top-level resources)
      file-links.json         Canonical/projection path links
      state.json              Sync state
      derived/
        site-snapshots/
          manifest.json       Agent snapshot manifest
          home.rendered.html  Hidden browser-rendered DOM snapshot
          home.png            Hidden browser screenshot snapshot
    .git/                     Auto-committed history
    CLAUDE.md                 Service-specific agent guide
    contacts.csv              CRM contacts (Numbers)
    products.csv              Store products (Numbers)
    orders.csv                Store orders (Numbers)
    forms.csv                 Form schemas (Numbers)
    members.csv               Site members (Numbers)
    site-properties.json      Site properties snapshot (editor)
    site/
      site-urls.json          Published/editor URL catalog (editor)
    groups.csv                Groups directory (Numbers)
    comments.csv              Comments feed (Numbers)
    collections.json          CMS collection catalog (editor)
    forms/
      contact-form-submissions.csv
    blog/
      my-post.md              Blog post (Markdown projection of Wix Ricos content)
      .objects/
        my-post.json          Canonical blog record with richContent JSON
    bookings/
      services.csv            Booking services (Numbers)
      appointments.csv        Appointment calendar export (read-only)
      one-on-one-consultation.json
    cms/
      products/
        items.csv             CMS collection items (Numbers)
    media/
      homepage-hero.png       Downloaded media file (Preview)
    pro-gallery/
      gallery-shot.png        Gallery image (Preview)
    pdf-viewer/
      pricing-guide.pdf       PDF asset (Preview)
    wix-video/
      launch-teaser.mp4       Video asset (QuickTime)
    wix-music-podcasts/
      podcast-intro.mp3       Audio asset (Music/QuickTime)
```

## Canonical Files

API2File now keeps a hidden structured JSON representation next to synced files:

- collection resources: `.{stem}.objects.json`
- one-per-record resources: `.objects/{stem}.json`
- link metadata: `.api2file/file-links.json`

The object file is the canonical local record. Human-facing files like `contacts.csv` or `blog/my-post.md` are editable projections regenerated from that canonical state.

Some services can also emit hidden, read-only derived artifacts for agents. Wix now generates browser-rendered site snapshots under `.api2file/derived/site-snapshots/` after pull. Those files are agent context only and are not editable sync surfaces.

For Wix blog posts specifically, the Markdown file is a projection of Wix `richContent` / Ricos data. API2File uses Wix's official Ricos conversion API when available so Markdown pull/push preserves headings, lists, and other rich-content structure more accurately than a plain-text projection.

Wix also uses explicit resource capability classes in the bundled adapter and live suite:

- `full_crud`: create, update, and delete are expected to work live
- `partial_writable`: writable, but narrower than full CRUD or missing one propagation leg
- `read_only`: pull/sync only

Generic Wix CMS CSVs are metadata-driven rather than site-specific. API2File treats `collections.json` as a read-only catalog and only exposes `cms/*.csv` as writable when the collection metadata says it is a true `NATIVE` collection with `INSERT`, `UPDATE`, and `REMOVE` data operations. Wix app/system collections stay on their dedicated surfaces like blog posts, products, bookings services, and other product APIs.

## CLI Reference

```text
api2file <command> [arguments]

Commands:
  init              Initialize ~/API2File-Data/ with global config
  list              List available bundled adapters
  add <service> [id] Set up a new service instance (demo/monday/wix/github/airtable)
  status            Show all services and their sync status
  sync [service]    Trigger immediate sync (all or specific service)
  pull [service]    Pull from API to local files (all or specific service)
  help              Show help message

Examples:
  api2file init
  api2file add demo
  api2file add wix wix-client-a
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

Connect any REST or GraphQL API by dropping an `.adapter.json` file into `Sources/API2FileCore/Resources/Adapters/`. The engine loads it automatically at startup.

### Minimal example

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

---

### Top-level fields

| Field | Type | Description |
| --- | --- | --- |
| `service` | string | Adapter/template ID. Installed service instances can use a different folder/instance ID, such as `api2file add wix wix-client-a`. |
| `displayName` | string | Human-readable name shown in the menu bar app |
| `version` | string | Adapter schema version (currently `"1.0"`) |
| `auth` | object | Auth config (see below) |
| `globals` | object | Shared `baseUrl`, `headers`, and default `method` |
| `resources` | array | One entry per synced resource |

Multiple service instances can reuse the same adapter template. Each installed instance gets its own service folder and instance-specific keychain key, while the bundled adapter template stays shared.

---

### Auth

**`bearer`** — `Authorization: Bearer {token}` header

```json
"auth": {
  "type": "bearer",
  "keychainKey": "api2file.github.key",
  "setup": {
    "instructions": "Go to github.com → Settings → Personal Access Tokens → Generate.",
    "url": "https://github.com/settings/tokens"
  }
}
```

**`apiKey`** — API key passed as a custom header (set key name in `globals.headers`)

```json
"auth": {
  "type": "apiKey",
  "keychainKey": "api2file.wix.key",
  "setup": {
    "instructions": "Go to dev.wix.com → API Keys → Generate. Use Add Service to fill Site ID and Site URL."
  }
},
"globals": {
  "headers": {
    "wix-site-id": "YOUR_SITE_ID_HERE"
  }
}
```

**`basic`** — HTTP Basic auth (`Authorization: Basic base64(user:pass)`)

```json
"auth": {
  "type": "basic",
  "keychainKey": "api2file.myservice.key",
  "setup": { "instructions": "Enter username:password" }
}
```

**`oauth2`** — PKCE flow with a local callback server

```json
"auth": {
  "type": "oauth2",
  "keychainKey": "api2file.myservice.token",
  "authorizeUrl": "https://auth.example.com/authorize",
  "tokenUrl": "https://auth.example.com/token",
  "refreshUrl": "https://auth.example.com/token",
  "scopes": ["read", "write"],
  "callbackPort": 9876
}
```

---

### Pull config

| Field | Type | Description |
| --- | --- | --- |
| `method` | string | HTTP method, default `GET` |
| `url` | string | Endpoint URL; supports `{baseUrl}` and `{parentField}` substitution |
| `type` | string | `"rest"` (default), `"graphql"`, or `"media"` |
| `query` | string | GraphQL query string (when `type = "graphql"`) |
| `body` | object | JSON request body (for POST-based queries like Wix) |
| `dataPath` | string | JSONPath to the records array in the response, e.g. `$.data` or `$` |
| `pagination` | object | Pagination config (see below) |
| `mediaConfig` | object | Media sync config (see below) |
| `updatedSinceField` | string | URL query param for incremental sync date filter (e.g. `"since"`) |
| `updatedSinceBodyPath` | string | Dot-path in request body for date filter (e.g. `"query.filter.updatedDate.$gt"`) |
| `updatedSinceDateFormat` | string | `"iso8601"` (default) or `"epoch"` |

#### REST pull — simple GET

```json
"pull": {
  "method": "GET",
  "url": "https://api.github.com/issues?filter=assigned&state=open",
  "dataPath": "$",
  "updatedSinceField": "since"
}
```

#### REST pull — POST-based query (Wix style)

```json
"pull": {
  "method": "POST",
  "url": "https://www.wixapis.com/contacts/v4/contacts/query",
  "body": { "query": { "paging": { "limit": 100 } } },
  "dataPath": "$.contacts",
  "updatedSinceBodyPath": "query.filter.updatedDate.$gt"
}
```

#### GraphQL pull (Monday.com style)

```json
"pull": {
  "url": "https://api.monday.com/v2",
  "type": "graphql",
  "query": "{ boards(limit: 50) { id name items_page(limit: 200) { items { id name column_values { id title text } } } } }",
  "dataPath": "$.data.boards"
}
```

---

### Pagination

| `type` | How it works | Extra fields |
| --- | --- | --- |
| `page` | Adds `?page=N` to URL | `pageSize`, `paramNames.page`, `paramNames.limit` |
| `offset` | Adds `?offset=N` to URL (Airtable uses `?offset=cursor`) | `pageSize`, `paramNames.offset` |
| `cursor` | Extracts cursor from response, passes in next request | `nextCursorPath`, `pageSize`, `paramNames.cursor` |
| `body` | Cursor and limit go in the JSON request body (Wix) | `nextCursorPath`, `cursorField`, `limitField`, `pageSize` |

#### Page pagination (GitHub)

```json
"pagination": {
  "type": "page",
  "pageSize": 50
}
```

#### Offset pagination (Airtable)

```json
"pagination": {
  "type": "offset",
  "pageSize": 100
}
```

#### Cursor pagination (Monday.com GraphQL)

```json
"pagination": {
  "type": "cursor",
  "pageSize": 200,
  "queryTemplate": "{ boards { items_page(limit: {limit}, after: \"{cursor}\") { cursor items { id name } } } }",
  "nextCursorPath": "$.data.boards[0].items_page.cursor"
}
```

#### Body pagination (Wix)

```json
"pagination": {
  "type": "body",
  "pageSize": 100,
  "limitField": "query.paging.limit",
  "cursorField": "query.paging.cursor",
  "nextCursorPath": "$.pagingMetadata.cursors.next"
}
```

---

### Push config

```json
"push": {
  "create": { "method": "POST", "url": "{baseUrl}/items", "bodyWrapper": "item" },
  "update": { "method": "PATCH", "url": "{baseUrl}/items/{id}", "bodyWrapper": "item" },
  "delete": { "method": "DELETE", "url": "{baseUrl}/items/{id}" }
}
```

| Field | Description |
| --- | --- |
| `method` | HTTP method |
| `url` | URL with `{id}` substitution from idField |
| `bodyWrapper` | Wrap the pushed object in a key, e.g. `"item"` → `{ "item": {...} }` |
| `bodyType` | Special body override; `"close"` sends `{ "state": "closed" }` |
| `type` | `"graphql"` — use `mutation` field instead of HTTP body |
| `mutation` | GraphQL mutation string (Monday.com style) |

#### GraphQL push (Monday.com)

```json
"push": {
  "create": {
    "url": "https://api.monday.com/v2",
    "type": "graphql",
    "mutation": "mutation($boardId: ID!, $itemName: String!) { create_item(board_id: $boardId, item_name: $itemName) { id } }"
  },
  "update": {
    "url": "https://api.monday.com/v2",
    "type": "graphql",
    "mutation": "mutation($boardId: ID!, $itemId: ID!, $columnValues: JSON) { change_multiple_column_values(board_id: $boardId, item_id: $itemId, column_values: $columnValues) { id } }"
  },
  "delete": {
    "url": "https://api.monday.com/v2",
    "type": "graphql",
    "mutation": "mutation($itemId: ID!) { delete_item(item_id: $itemId) { id } }"
  }
}
```

---

### File mapping

| Field | Type | Description |
| --- | --- | --- |
| `strategy` | string | `"collection"`, `"one-per-record"`, or `"mirror"` |
| `directory` | string | Relative path under the service folder; `"."` = root |
| `filename` | string | Filename template; supports `{field\|slugify}` substitution |
| `format` | string | File format (see format table below) |
| `idField` | string | Field used as the record's unique key |
| `contentField` | string | Field that contains the file's body (MD, HTML, SVG, TXT) |
| `readOnly` | bool | If true, local edits are not pushed back |
| `transforms` | object | `pull` and/or `push` transform pipelines |
| `pushMode` | string | `"auto-reverse"`, `"read-only"`, `"custom"`, `"passthrough"` |

#### Strategies

- `collection` — all records go into a single file (CSV sheet, JSON array)
- `one-per-record` — one file per record; `filename` is a template using record fields
- `mirror` — preserve remote directory structure (used for media/binary sync)

#### Filename templates — use `{fieldName}` or `{fieldName|slugify}`

```text
"{slug}.html"                        → home.html
"{firstName|slugify}-{lastName|slugify}.vcf"  → alice-smith.vcf
"{title|slugify}.md"                 → meeting-notes.md
"{name|slugify}.json"                → auth-service.json
```

---

### File formats

| Format | `format` value | Extension | Opens in |
| --- | --- | --- | --- |
| JSON | `json` | `.json` | Any editor |
| CSV | `csv` | `.csv` | Numbers, Excel |
| Markdown | `md` | `.md` | Any editor |
| HTML | `html` | `.html` | Safari, browsers |
| YAML | `yaml` | `.yaml` | Any editor |
| Plain text | `txt` | `.txt` | TextEdit |
| Calendar | `ics` | `.ics` | Calendar.app |
| Contact card | `vcf` | `.vcf` | Contacts.app |
| Email | `eml` | `.eml` | Mail.app |
| Vector graphic | `svg` | `.svg` | Preview, browsers |
| Web bookmark | `webloc` | `.webloc` | Safari |
| Spreadsheet | `xlsx` | `.xlsx` | Numbers, Excel |
| Word document | `docx` | `.docx` | Pages, Word |
| Presentation | `pptx` | `.pptx` | Keynote, PowerPoint |
| Binary passthrough | `raw` | (any) | Varies (PNG, PDF…) |

---

### Transforms

Transforms run as a pipeline on the JSON records — `pull` transforms run before writing the file, `push` transforms reconstruct the API payload from the edited file.

| Op | Fields | Description |
| --- | --- | --- |
| `pick` | `fields: [...]` | Keep only listed fields, drop everything else |
| `omit` | `fields: [...]` | Drop listed fields, keep the rest |
| `rename` | `from`, `to` | Rename a field |
| `flatten` | `path`, `to` | Merge a nested object into the parent; `to` prefix is added to keys |
| `keyBy` | `path`, `key`, `value`, `to` | Convert an array to an object keyed by a field |
| `wrap` | `wrap: {key: value}` | Wrap the whole record in a parent key (push only) |
| `addField` | `field`, `template` | Add a computed field using a string template |

**Example — flatten nested objects, keep fields (GitHub repos):**

```json
"transforms": {
  "pull": [
    { "op": "flatten", "path": "owner", "to": "" },
    { "op": "pick", "fields": ["id", "name", "full_name", "login", "description", "html_url", "language"] }
  ]
}
```

**Example — flatten and omit (Wix contacts):**

```json
"transforms": {
  "pull": [
    { "op": "flatten", "path": "info.name", "to": "" },
    { "op": "flatten", "path": "info.emails", "to": "emails" },
    { "op": "omit", "fields": ["info", "revision", "source", "lastActivity"] }
  ]
}
```

**Example — keyBy array to object (Monday.com column values):**

```json
"transforms": {
  "pull": [
    { "op": "keyBy", "path": "column_values", "key": "title", "value": "text", "to": "columns" },
    { "op": "omit", "fields": ["column_values"] }
  ]
}
```

When `pull` transforms are defined and `idField` is set, the engine auto-computes the inverse push transforms (`pushMode: "auto-reverse"`). Override with explicit push transforms or `"pushMode": "read-only"` to disable.

---

### Media sync

Set `"type": "media"` on the pull config to download binary files (images, videos, PDFs) directly from URLs in the API response.

```json
{
  "name": "media",
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

`mediaConfig` fields: `urlField` (download URL), `filenameField` (local filename), `idField` (for change detection), `sizeField` (optional, for progress), `hashField` (optional, skip-if-unchanged).

Upload uses a two-step signed-URL flow: call `push.create` to get a pre-signed URL, then PUT the binary.

---

### Hierarchical resources (children)

Use `children` to sync sub-resources that depend on parent records. The parent is fetched first; children are then synced for each parent, with `{id}` substituted from the parent record.

```json
{
  "name": "collections",
  "pull": { "url": "{baseUrl}/cms/v2/collections", "dataPath": "$.collections" },
  "fileMapping": { "strategy": "collection", "directory": ".", "filename": "collections.json", "format": "json", "idField": "id" },
  "children": [
    {
      "name": "items",
      "pull": {
        "method": "POST",
        "url": "{baseUrl}/cms/v3/items/query",
        "body": { "dataCollectionId": "{id}", "query": { "paging": { "limit": 50 } } },
        "dataPath": "$.dataItems"
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": "cms/{displayName|slugify}",
        "filename": "items.csv",
        "format": "csv",
        "idField": "id"
      }
    }
  ]
}
```

The child `directory` template can reference parent fields: `"cms/{displayName|slugify}"`.

---

### Sync config

```json
"sync": {
  "interval": 60,
  "debounceMs": 500,
  "fullSyncEvery": 10
}
```

| Field | Default | Description |
| --- | --- | --- |
| `interval` | 60 | Pull interval in seconds |
| `debounceMs` | 500 | Wait after a file change before pushing (milliseconds) |
| `fullSyncEvery` | 10 | Full re-sync every N intervals (catches deletions) |

---

### Writing a new adapter — step by step

1. **Create** `Sources/API2FileCore/Resources/Adapters/myservice.adapter.json`
2. **Set** `service` to a lowercase identifier (`myservice`). This becomes the folder name.
3. **Choose auth type.** Use `bearer` for token-based APIs, `apiKey` when the token goes in a header, `oauth2` for browser-flow APIs.
4. **Set `globals.baseUrl`** and any required headers (e.g. `Accept`, `Content-Type`, custom API version headers).
5. **Add resources.** For each resource:
   - Set `pull.url` pointing to the list endpoint
   - Set `pull.dataPath` to the JSONPath that extracts the records array
   - Choose a `fileMapping.strategy` (`collection` for spreadsheet-like data, `one-per-record` for documents/contacts/events)
   - Choose a `format` matching how users will interact with the data
   - Set `idField` to the unique key field
   - Add `push` endpoints if the resource is writable
6. **Add transforms** if the API response has nested objects — `flatten` nested structs, `pick`/`omit` to trim fields, `keyBy` to normalize arrays into objects.
7. **Add pagination** if the API pages results.
8. **Register** in the CLI by adding the service name to `AddServiceCommand` in `API2FileCLI/`.
9. **Test** with `swift run api2file add myservice && swift run api2file sync myservice`.

**Quick decision guide:**

| Situation | Pattern to use |
| --- | --- |
| Table data (tasks, products) | `strategy: collection`, `format: csv` |
| Documents / blog posts | `strategy: one-per-record`, `format: md` or `html` |
| Contacts | `strategy: one-per-record`, `format: vcf` |
| Calendar events | `strategy: one-per-record` or `collection`, `format: ics` |
| Config / settings (single object) | `strategy: collection`, `format: json` or `yaml` |
| Files / media | `type: media` on pull, `strategy: mirror`, `format: raw` |
| API returns nested objects | `flatten` transform on pull |
| API requires wrapped body on push | `bodyWrapper` on push endpoints |
| Read-only resource | `"readOnly": true` on fileMapping |
| Sub-resources per parent | `children` array on the parent resource |

## Known Limitations

- **OAuth2** flow is implemented but not tested with a real browser redirect
- **Real cloud APIs** (Monday.com, Wix, GitHub, Airtable) are not integration-tested -- they require live API keys
- **Quick Look preview** currently focuses on text-like synced files and metadata fallback for office/binary formats, not bespoke renderers for every file type
- **Notifications** are implemented in NotificationManager but not wired into SyncEngine events
- **CLI target** (`API2FileCLI`) exists as source but is not declared in `Package.swift` -- build it manually or use the menu bar app

## License

MIT
