# Demo Adapters — Design Specification

**Date:** 2026-03-23
**Status:** Draft

## Context

API2File's Phase 1 MVP ships with a single "demo" adapter that maps all 6 resource types from the built-in DemoAPIServer. While functional, it doesn't showcase the system's key selling points: connecting to different "services," opening files in native macOS apps (Calendar.app, Contacts.app, Numbers, Safari), and using different mapping strategies.

This spec adds 5 themed demo adapters that simulate real-world services, each highlighting different file formats and mapping strategies — all running against the single DemoAPIServer on port 8089. The goal is a compelling demo experience where a user runs one setup script and immediately sees API2File syncing to Calendar.app, Contacts.app, Numbers, Safari, and more.

## Design

### Overview

5 new adapter configs + 2 new server resource types. All adapters share the existing DemoAPIServer (`:8089`). Each adapter picks a subset of resources and maps them to formats that open naturally in macOS apps.

| Adapter | Simulates | Resources | Formats | Mapping |
|---|---|---|---|---|
| **TeamBoard** | Project management (Monday/Trello) | tasks, config | CSV, YAML | collection |
| **PeopleHub** | CRM (HubSpot) | contacts, notes | VCF, Markdown | one-per-record |
| **CalSync** | Calendar (Calendly) | events, tasks | ICS, CSV | collection |
| **PageCraft** | CMS (WordPress/Wix) | pages, notes, config | HTML, Markdown, JSON | mixed |
| **DevOps** | Infrastructure monitoring | services*, incidents* | JSON, CSV | mixed |

*= new resource types added to DemoAPIServer

### Format Coverage

| Format | Adapter | Native macOS App |
|---|---|---|
| CSV | TeamBoard, CalSync | Numbers / Excel |
| YAML | TeamBoard | Any editor |
| VCF | PeopleHub | Contacts.app |
| Markdown | PeopleHub, PageCraft | Any editor / Marked.app |
| ICS | CalSync | Calendar.app |
| HTML | PageCraft | Safari |
| JSON | PageCraft, DevOps | Any editor |
| CSV | DevOps (incidents) | Numbers / Excel |

7 of 9 text-based formats demonstrated. Raw (binary passthrough) and Text (single-content-field only) excluded — not meaningful for structured demos.

---

## DemoAPIServer Changes

### New Resource: `services`

Represents microservice health status records for the DevOps adapter.

```swift
struct DemoService: Codable {
    var id: Int
    var name: String        // "auth-service", "payment-api", "search-index"
    var status: String      // "healthy", "degraded", "down"
    var uptime: Double      // 99.95
    var lastChecked: String // "2026-03-23T10:30:00Z"
    var responseTimeMs: Int // 45
    var version: String     // "2.1.0"
}
```

**Seed data (3 records):**

| id | name | status | uptime | responseTimeMs | version |
|---|---|---|---|---|---|
| 1 | auth-service | healthy | 99.99 | 45 | 3.2.1 |
| 2 | payment-api | degraded | 98.50 | 320 | 2.0.4 |
| 3 | search-index | healthy | 99.95 | 12 | 1.8.0 |

### New Resource: `incidents`

Represents operational incident log entries for the DevOps adapter.

```swift
struct DemoIncident: Codable {
    var id: Int
    var timestamp: String   // "2026-03-23T09:15:00Z"
    var severity: String    // "info", "warning", "critical"
    var service: String     // "payment-api"
    var message: String     // "CPU spike detected"
    var resolved: Bool
}
```

**Seed data (4 records):**

| id | timestamp | severity | service | message | resolved |
|---|---|---|---|---|---|
| 1 | 2026-03-23T08:00:00Z | info | auth-service | Routine key rotation completed | true |
| 2 | 2026-03-23T09:15:00Z | warning | payment-api | Response time exceeding 300ms threshold | false |
| 3 | 2026-03-23T09:45:00Z | critical | payment-api | Database connection pool exhausted | false |
| 4 | 2026-03-23T10:00:00Z | info | search-index | Index rebuild completed successfully | true |

### Implementation Pattern

Both new types follow the exact existing pattern in `DemoAPIServer.swift`. The server uses explicit `if/else if` routing in `processRequest()` — it does NOT have generic resource dispatch. Each new resource requires:

1. **Model struct** — `DemoService` / `DemoIncident` with `Codable`, `Sendable`, `toDict()`, `static seedData`
2. **Stored properties** — add `private var services: [DemoService]` and `private var incidents: [DemoIncident]` arrays + ID counters
3. **Seed method** — add to `seedAll()` to populate from `seedData`
4. **Route methods** — add `routeServices()` and `routeIncidents()` methods (copy pattern from `routeTasks()`)
5. **Request dispatch** — add `else if` branches in `processRequest()` for `/api/services` and `/api/incidents` paths
6. **Public accessors** — add getters if needed for testing (following existing pattern)

---

## Adapter Configs

All configs stored in `Sources/API2FileCore/Resources/Adapters/`. All point at `http://localhost:8089`.

### 1. TeamBoard (`teamboard.adapter.json`)

**Simulates:** Project management tool (Monday.com, Trello)

| Resource | Endpoint | Format | Strategy | File |
|---|---|---|---|---|
| tasks | `/api/tasks` | CSV | collection | `tasks.csv` |
| config | `/api/config` | YAML | collection | `settings.yaml` |

- Auth: bearer, keychain key `api2file.teamboard.key`
- Sync interval: 15s
- **User story:** Open `tasks.csv` in Numbers, drag to reorder priorities, save → syncs to API. Edit `settings.yaml` for project settings.

### 2. PeopleHub (`peoplehub.adapter.json`)

**Simulates:** CRM / contact management (HubSpot)

| Resource | Endpoint | Format | Strategy | File Pattern |
|---|---|---|---|---|
| contacts | `/api/contacts` | VCF | one-per-record | `contacts/{firstName\|slugify}-{lastName\|slugify}.vcf` |
| notes | `/api/notes` | Markdown | one-per-record | `notes/{title\|slugify}.md` |

- Auth: bearer, keychain key `api2file.peoplehub.key`
- Sync interval: 20s
- Contacts idField: `id`, notes idField: `id`
- Notes use `contentField: "content"` for markdown body
- **User story:** Double-click `alice-johnson.vcf` → opens in Contacts.app. Edit contact details, save → syncs. Meeting notes as individual markdown files.

### 3. CalSync (`calsync.adapter.json`)

**Simulates:** Calendar / scheduling service (Calendly, Google Calendar)

| Resource | Endpoint | Format | Strategy | File |
|---|---|---|---|---|
| events | `/api/events` | ICS | collection | `calendar.ics` |
| tasks | `/api/tasks` | CSV | collection | `action-items.csv` |

- Auth: bearer, keychain key `api2file.calsync.key`
- Sync interval: 10s
- Events use fieldMapping for ICS property mapping: `title→SUMMARY`, `startDate→DTSTART`, `endDate→DTEND`, `location→LOCATION`
- **User story:** Double-click `calendar.ics` → opens in Calendar.app showing all events. Companion `action-items.csv` in Numbers.

### 4. PageCraft (`pagecraft.adapter.json`)

**Simulates:** CMS / website builder (WordPress, Wix)

| Resource | Endpoint | Format | Strategy | File Pattern |
|---|---|---|---|---|
| pages | `/api/pages` | HTML | one-per-record | `pages/{slug}.html` |
| notes (as blog posts) | `/api/notes` | Markdown | one-per-record | `blog/{title\|slugify}.md` |
| config | `/api/config` | JSON | collection | `site.json` |

- Auth: bearer, keychain key `api2file.pagecraft.key`
- Sync interval: 15s
- Pages use `contentField: "content"` for HTML body, filename from `slug` field
- Notes use `contentField: "content"` for markdown body
- **User story:** Open `pages/home.html` in Safari, edit in VS Code, save → page updates on "server." Blog posts as markdown. Site-wide config in `site.json`.

### 5. DevOps (`devops.adapter.json`)

**Simulates:** Infrastructure monitoring / ops dashboard

| Resource | Endpoint | Format | Strategy | File Pattern |
|---|---|---|---|---|
| services | `/api/services` | JSON | one-per-record | `services/{name\|slugify}.json` |
| incidents | `/api/incidents` | CSV | collection | `incidents.csv` |

- Auth: bearer, keychain key `api2file.devops.key`
- Sync interval: 10s
- Services: full JSON per service (status, uptime, response time, version)
- Incidents: CSV spreadsheet with timestamp, severity, service, message, resolved columns
- **Note:** Text format was considered for incidents but `TextFormat` only supports single-record single-field encoding. CSV is the correct choice for multi-record tabular data.
- **User story:** Each microservice has a status JSON file. `incidents.csv` is an ops log viewable in Numbers. Update a service status JSON → pushes health update to API.

---

## Adapter Config Reference

### Format Enum Values

The `FileFormat` enum raw values used in adapter JSON configs (these are the exact strings, not aliases):

| Format | JSON value | Notes |
|---|---|---|
| CSV | `"csv"` | |
| JSON | `"json"` | |
| YAML | `"yaml"` | |
| ICS | `"ics"` | |
| VCF | `"vcf"` | |
| HTML | `"html"` | |
| Markdown | `"md"` | NOT `"markdown"` |
| Text | `"txt"` | NOT `"text"` |
| Raw | `"raw"` | |

### Config Structure Notes

- **`sync`** is per-resource (on `ResourceConfig`), not per-adapter. Each resource in the `resources` array must have its own `sync.interval` and `sync.debounceMs`.
- **`formatOptions.fieldMapping`** lives under `fileMapping.formatOptions.fieldMapping`, not directly under `fileMapping`.
- **`config` resource** is a singleton (single object, not an array). With `dataPath: "$"` and `collection` strategy, the engine wraps it as `[dict]` automatically. This works correctly.
- **ICS default field mapping** (`title→SUMMARY`, `startDate→DTSTART`, etc.) matches `ICSFormat.defaultMapping` exactly, so CalSync does NOT need explicit `formatOptions.fieldMapping` — the defaults work.
- **VCF default field mapping** (`firstName→FN_FIRST`, `lastName→FN_LAST`, `email→EMAIL`, `phone→TEL`, `company→ORG`) matches `DemoContact` fields exactly, so PeopleHub does NOT need explicit `formatOptions.fieldMapping`.

### Example: CalSync Adapter Config (Complete JSON)

This is the reference pattern all 5 configs follow:

```json
{
  "service": "calsync",
  "displayName": "CalSync — Calendar & Scheduling",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.calsync.key",
    "setup": {
      "instructions": "Demo adapter — uses local DemoAPIServer. No real auth needed."
    }
  },
  "globals": {
    "baseUrl": "http://localhost:8089",
    "headers": {
      "Content-Type": "application/json"
    }
  },
  "resources": [
    {
      "name": "events",
      "description": "Calendar events — opens in Calendar.app",
      "pull": {
        "method": "GET",
        "url": "http://localhost:8089/api/events",
        "dataPath": "$"
      },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/events" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/events/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/events/{id}" }
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": ".",
        "filename": "calendar.ics",
        "format": "ics",
        "idField": "id"
      },
      "sync": {
        "interval": 10,
        "debounceMs": 500
      }
    },
    {
      "name": "action-items",
      "description": "Tasks as action items — opens in Numbers",
      "pull": {
        "method": "GET",
        "url": "http://localhost:8089/api/tasks",
        "dataPath": "$"
      },
      "push": {
        "create": { "method": "POST", "url": "http://localhost:8089/api/tasks" },
        "update": { "method": "PUT", "url": "http://localhost:8089/api/tasks/{id}" },
        "delete": { "method": "DELETE", "url": "http://localhost:8089/api/tasks/{id}" }
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": ".",
        "filename": "action-items.csv",
        "format": "csv",
        "idField": "id"
      },
      "sync": {
        "interval": 10,
        "debounceMs": 500
      }
    }
  ]
}
```

---

## File Layout at Runtime

After setup, `~/API2File/` looks like:

```
~/API2File/
├── teamboard/
│   ├── .api2file/adapter.json
│   ├── tasks.csv
│   └── settings.yaml
│
├── peoplehub/
│   ├── .api2file/adapter.json
│   ├── contacts/
│   │   ├── alice-johnson.vcf       # from seed: firstName="Alice", lastName="Johnson"
│   │   └── bob-smith.vcf           # from seed: firstName="Bob", lastName="Smith"
│   └── notes/
│       ├── meeting-notes.md        # from seed: title="Meeting Notes"
│       └── ideas.md                # from seed: title="Ideas"
│
├── calsync/
│   ├── .api2file/adapter.json
│   ├── calendar.ics
│   └── action-items.csv
│
├── pagecraft/
│   ├── .api2file/adapter.json
│   ├── pages/
│   │   ├── home.html
│   │   └── about.html
│   ├── blog/
│   │   ├── meeting-notes.md        # from seed: title="Meeting Notes"
│   │   └── ideas.md                # from seed: title="Ideas"
│   └── site.json
│
└── devops/
    ├── .api2file/adapter.json
    ├── services/
    │   ├── auth-service.json
    │   ├── payment-api.json
    │   └── search-index.json
    └── incidents.csv
```

---

## Setup Script

Create `scripts/demo-all-setup.sh` that:

1. Starts DemoAPIServer if not already running
2. For each of the 5 adapters:
   a. Creates `~/API2File/{service}/.api2file/` directory
   b. Copies the adapter config JSON
   c. Adds dummy keychain entry (`security add-generic-password`)
   d. Initializes git repo with `.gitignore` excluding `.api2file/`
3. Prints summary with:
   - List of services set up
   - Example commands to try (e.g., `open ~/API2File/calsync/calendar.ics`)
   - How to trigger sync

The existing `demo-setup.sh` remains unchanged (single adapter quick start). The new script is the "full showcase."

---

## Testing

### Unit Tests
- **Adapter config parsing:** Load each `.adapter.json` and verify it parses to valid `AdapterConfig` with correct resources, formats, and mapping strategies.

### Integration Tests
- **Pull verification per adapter:** For each adapter, run a pull against the DemoAPIServer and verify:
  - Correct number of files created
  - Correct file names (template interpolation)
  - Correct format (parse the output to verify it's valid CSV/ICS/VCF/JSON/etc.)
  - Correct content (spot-check key fields)

### E2E Tests
- **New resources:** Extend `DemoServerE2ETests` with tests for `/api/services` and `/api/incidents` CRUD.
- **Bidirectional:** For at least 2 adapters, test full round-trip: pull → edit file → push → verify API state.

### Manual Testing
- Update `TESTING.md` with:
  - `demo-all-setup.sh` quick start
  - Per-adapter manual test walkthroughs
  - Native app verification (open `.ics` in Calendar, `.vcf` in Contacts, etc.)

---

## Files to Create/Modify

### New Files
- `Sources/API2FileCore/Resources/Adapters/teamboard.adapter.json`
- `Sources/API2FileCore/Resources/Adapters/peoplehub.adapter.json`
- `Sources/API2FileCore/Resources/Adapters/calsync.adapter.json`
- `Sources/API2FileCore/Resources/Adapters/pagecraft.adapter.json`
- `Sources/API2FileCore/Resources/Adapters/devops.adapter.json`
- `scripts/demo-all-setup.sh`
- `Tests/API2FileCoreTests/Integration/DemoAdapterConfigTests.swift`

### Modified Files
- `Sources/API2FileCore/Server/DemoAPIServer.swift` — add `DemoService` and `DemoIncident` models + seed data
- `Tests/API2FileCoreTests/Integration/DemoServerE2ETests.swift` — add tests for services/incidents endpoints
- `TESTING.md` — add multi-adapter demo walkthrough
