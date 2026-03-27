---
name: api2file
description: Guide for agents and users working in an API2File sync folder (~/API2File-Data/
  or similar). Covers how to edit synced files (CSV, JSON, Markdown, VCF, ICS, etc.)
  to push changes back to the cloud, what the hidden .*.objects.json structured files are,
  how they relate to human-facing projections, conflict handling, the Control API, and the complete
  .adapter.json schema for adding new cloud service adapters.
---

# API2File — Agent & User Guide

## What this folder is

This folder is managed by **API2File**, a bidirectional sync engine that maps cloud API data
to local files. Each subdirectory (`demo/`, `wix/`, `github/`, etc.) is one connected service.

Editing a file here automatically pushes the change back to the cloud within the service's
configured debounce window (usually 500 ms). Pulling from the cloud overwrites local files
and commits the result to git.

Each resource can have two local surfaces:

- **Canonical object files** — hidden `.*.objects.json` or `.objects/*.json` files containing structured records
- **Human-facing files** — CSV, Markdown, ICS, VCF, PDF, etc. generated for native apps and easy browsing

The design direction is that canonical object files are the local source of truth, while human-facing files are projections. Some current builds still auto-push primarily from the human-facing files, so if object-file edits do not sync automatically, run an explicit sync or edit the projected file instead.

---

## How the sync loop works

``` 
Cloud API  ←→  AdapterEngine  ←→  Canonical object files  ←→  Human-facing files  ←→  You / Agent
```

1. **Pull:** AdapterEngine calls the cloud API, writes canonical object files, applies pull transforms, and regenerates the human-facing files.
2. **Canonical edit:** If a canonical object file is edited, the engine should push its structured records to the API and regenerate the human-facing files.
3. **Human edit:** If a human-facing file is edited, the engine decodes it back into canonical records, pushes those records, and regenerates the human-facing files.
4. **State update:** On success, `.api2file/state.json` is updated and git auto-commits.

> **Current implementation note:** The codebase already writes object files and has a partial object-file push path, but automatic `.objects` file watching is still being completed. Treat the object files as the intended canonical surface, with the caveat that some builds may still require an explicit sync after editing them.

---

## Editing files to push changes

### Canonical object files (`.*.objects.json`, `.objects/*.json`)

These files store the structured record model for a resource.

- Prefer editing these files for **high-fidelity agent workflows**, complex nested data, and any task where a CSV/Markdown/ICS projection would lose fields.
- After a successful canonical edit, API2File should push the structured records to the server and regenerate the human-facing files.
- Avoid editing both a canonical object file and its projected human-facing file before the same sync cycle.

**Collection resources:** edit the JSON array inside `.{stem}.objects.json`.

**One-per-record resources:** edit the per-record JSON object in `.objects/{stem}.json`.

> If your current build does not auto-push object-file edits yet, save the file and force a sync, or make the same change in the human-facing file instead.

### Collection files (CSV, XLSX, JSON arrays, YAML)

These contain **all records in one file** — a spreadsheet or JSON array generated from the canonical object records.

| Format | Opens in | Example file |
|---|---|---|
| `.csv` | Numbers, Excel, any text editor | `tasks.csv`, `contacts.csv` |
| `.xlsx` | Numbers, Excel | `inventory.xlsx` |
| `.json` (array) | VS Code, any text editor | `bases.json` |
| `.yaml` | Any text editor | `settings.yaml` |

**To update a record:** Edit the value in the row/object and save. The engine decodes the file back into canonical structured records, diffs against the previous canonical object file, and calls `PATCH`/`PUT` on the API for only the changed records.

**To create a record:** Add a new row (CSV) or object (JSON array). Leave the `_id` column
empty or omit the `id` field — the engine treats rows without a known ID as new canonical records and
calls `POST` on the API. The response ID is stored back into the canonical object file and the projection.

**To delete a record:** Delete the row from the file (CSV) or remove the object (JSON). The
engine detects the missing ID in the canonical diff and calls `DELETE` on the API.

> **IMPORTANT — never modify the `_id` column.** It is the link between the local row and
> the remote record. Changing or clearing it causes the engine to treat the row as a new
> record and create a duplicate on the server.

> **XLSX / DOCX / PPTX:** The file must be fully saved and closed before the sync engine can
> read it. Office apps write to a temp file and swap atomically on close.

---

### One-per-record files (MD, HTML, VCF, ICS, JSON objects, SVG, EML, WEBLOC, TXT)

Each file is one record. The filename encodes the record identity (e.g. `alice-smith.vcf`,
`meeting-notes.md`). These files are human-facing projections of the canonical per-record JSON object.

**To update:** Edit and save the file. The engine decodes it back into the canonical record, looks up the remote ID from `.api2file/state.json`, and calls `PATCH`/`PUT`.

**To create:** Create a new file with the correct extension in the resource's directory.
Use the same naming convention as existing files (slugified title/name). The engine
creates the corresponding canonical record and calls `POST` on the next sync cycle.

**To delete:** Delete the file. The engine calls `DELETE` after a 5-second grace period.

---

### Read-only resources

Some resources have `"readOnly": true` in their config (e.g. `repos.csv`, `notifications.csv`,
`members.csv`). Local edits to these files are silently ignored — changes are never pushed.
The CLAUDE.md in each service folder marks read-only resources explicitly.

---

## The hidden `.*.objects.json` files

You will see hidden files like `.tasks.objects.json`, `.config.objects.json`, `.deck.objects.json`
alongside your synced files. These files store the structured canonical record model for the resource.

### What they are

After every successful pull, the engine writes the structured API records (before any human-facing
projection encoding) to these hidden JSON files. They serve as the canonical local representation
used for diffing, regeneration, and high-fidelity edits.

Example — `.tasks.objects.json` contains the last-known server state:
```json
[
  { "id": 1, "name": "Buy groceries", "status": "todo", "assignee": "Alice" },
  { "id": 2, "name": "Fix login bug", "status": "in-progress", "assignee": "Bob" }
]
```

When you change `tasks.csv`, the engine re-reads it, updates the canonical `.tasks.objects.json`,
and pushes only the diff (e.g. `PATCH /tasks/1 { "status": "done" }`).

### When they are updated

- After every successful **pull** from the cloud
- After every successful **push** to the cloud
- After any successful regeneration from a human-facing file edit

### What happens if they get out of sync

If a `.*.objects.json` file is corrupted or deleted, the engine falls back to a full re-sync
on the next cycle. You can force this by running:

```bash
curl -X POST localhost:21567/api/services/<serviceId>/sync
```

Or via the menu bar app: click the service → Sync Now.

### How to edit them safely

- Prefer canonical object-file edits for complex or nested data where the human-facing file is lossy
- Preserve record IDs unless you intentionally want to create a new record
- Do not edit both the canonical file and its projection before the same sync cycle
- If a build still treats object files as internal cache for automatic watching, run an explicit sync after saving

---

## Conflict handling

The **server is always the source of truth**. If the cloud record changed between your last pull
and your push:

1. The push may fail or the server returns the updated record.
2. The engine writes a `.conflict` file next to the affected file (e.g. `tasks.conflict.csv`).
3. Open both files, merge manually, delete the `.conflict` file, and save the merged version.
4. Force a sync to push the resolved version.

---

## Control API

The sync engine runs a local HTTP server on port **21567**.

```bash
# List all services and their status
curl localhost:21567/api/services

# Force immediate sync for a service
curl -X POST localhost:21567/api/services/<serviceId>/sync

# List conflicts for a service
curl localhost:21567/api/services/<serviceId>/conflicts

# Pull only (no push)
curl -X POST localhost:21567/api/services/<serviceId>/pull
```

---

## Format-specific constraints

| Format | Constraint |
|---|---|
| CSV | Never modify the `_id` column — it links rows to remote records |
| JSON (collection) | Never modify the `_id` field in object entries |
| XLSX / DOCX / PPTX | Must be fully saved and closed before sync reads the file |
| VCF | One file per contact; filename must be unique |
| ICS | One file per event; filename must be unique |
| Raw (PNG, PDF…) | Binary files are checksummed; edit by replacing the file entirely |

---

## Adding a new cloud adapter

Connect any REST or GraphQL API by creating an `.adapter.json` file in
`Sources/API2FileCore/Resources/Adapters/` (for the app bundle) or by dropping one into
a service's `.api2file/adapter.json` (for a running instance).

### Minimal template

```json
{
  "service": "myservice",
  "displayName": "My Service",
  "version": "1.0",
  "auth": {
    "type": "bearer",
    "keychainKey": "api2file.myservice.key",
    "setup": { "instructions": "Get a token from myservice.com/settings/tokens" }
  },
  "globals": { "baseUrl": "https://api.myservice.com" },
  "resources": [
    {
      "name": "items",
      "pull": { "method": "GET", "url": "{baseUrl}/items", "dataPath": "$.items" },
      "push": {
        "create": { "method": "POST", "url": "{baseUrl}/items" },
        "update": { "method": "PUT",  "url": "{baseUrl}/items/{id}" },
        "delete": { "method": "DELETE", "url": "{baseUrl}/items/{id}" }
      },
      "fileMapping": {
        "strategy": "collection",
        "directory": ".",
        "filename": "items.csv",
        "format": "csv",
        "idField": "id"
      },
      "sync": { "interval": 60, "debounceMs": 500 }
    }
  ]
}
```

---

### Auth types

**`bearer`** — `Authorization: Bearer {token}`
```json
"auth": { "type": "bearer", "keychainKey": "api2file.myservice.key" }
```

**`apiKey`** — token in a custom header (configure in `globals.headers`)
```json
"auth": { "type": "apiKey", "keychainKey": "api2file.wix.key" },
"globals": { "headers": { "wix-site-id": "YOUR_SITE_ID_HERE" } }
```

**`basic`** — HTTP Basic auth (`Authorization: Basic base64(user:pass)`)
```json
"auth": { "type": "basic", "keychainKey": "api2file.myservice.key" }
```

**`oauth2`** — PKCE browser flow
```json
"auth": {
  "type": "oauth2",
  "keychainKey": "api2file.myservice.token",
  "authorizeUrl": "https://auth.myservice.com/authorize",
  "tokenUrl": "https://auth.myservice.com/token",
  "scopes": ["read", "write"],
  "callbackPort": 9876
}
```

---

### Pull config fields

| Field | Notes |
|---|---|
| `method` | HTTP method; default `GET` |
| `url` | Supports `{baseUrl}` and `{parentField}` substitution |
| `type` | `rest` (default), `graphql`, `media` |
| `query` | GraphQL query string |
| `body` | JSON request body (for POST-based list endpoints like Wix) |
| `dataPath` | JSONPath to records array, e.g. `$.data` or `$` |
| `updatedSinceField` | URL param for incremental date filter, e.g. `"since"` |
| `updatedSinceBodyPath` | Body field path for incremental filter |
| `pagination` | See Pagination section |
| `mediaConfig` | See Media sync section |

**GraphQL pull (Monday.com):**
```json
"pull": {
  "url": "https://api.monday.com/v2",
  "type": "graphql",
  "query": "{ boards(limit:50) { id name items_page(limit:200) { items { id name column_values { title text } } } } }",
  "dataPath": "$.data.boards"
}
```

**POST-based query (Wix):**
```json
"pull": {
  "method": "POST",
  "url": "https://www.wixapis.com/contacts/v4/contacts/query",
  "body": { "query": { "paging": { "limit": 100 } } },
  "dataPath": "$.contacts",
  "updatedSinceBodyPath": "query.filter.updatedDate.$gt"
}
```

---

### Pagination

| Type | When to use | Key fields |
|---|---|---|
| `page` | Page-number APIs (GitHub) | `pageSize` |
| `offset` | Offset-based APIs (Airtable) | `pageSize` |
| `cursor` | Cursor APIs, including GraphQL (Monday.com) | `nextCursorPath`, `queryTemplate` |
| `body` | Cursor goes in JSON request body (Wix) | `nextCursorPath`, `cursorField`, `limitField` |

```json
// Page (GitHub)
"pagination": { "type": "page", "pageSize": 50 }

// Cursor (Monday.com GraphQL)
"pagination": {
  "type": "cursor",
  "pageSize": 200,
  "queryTemplate": "{ boards { items_page(limit: {limit}, after: \"{cursor}\") { cursor items { id name } } } }",
  "nextCursorPath": "$.data.boards[0].items_page.cursor"
}

// Body (Wix)
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
  "create": { "method": "POST",   "url": "{baseUrl}/items",      "bodyWrapper": "item" },
  "update": { "method": "PATCH",  "url": "{baseUrl}/items/{id}", "bodyWrapper": "item" },
  "delete": { "method": "DELETE", "url": "{baseUrl}/items/{id}" }
}
```

`bodyWrapper` wraps the payload: `"item"` → `{ "item": { ...fields... } }`.

**GraphQL mutations (Monday.com):**
```json
"push": {
  "create": {
    "url": "https://api.monday.com/v2",
    "type": "graphql",
    "mutation": "mutation($boardId:ID!, $itemName:String!) { create_item(board_id:$boardId, item_name:$itemName) { id } }"
  }
}
```

---

### File mapping

| Field | Description |
|---|---|
| `strategy` | `collection` (all records in one file), `one-per-record` (one file each), `mirror` (binary/media) |
| `directory` | Path under the service folder; `"."` = root |
| `filename` | Template: `"{slug}.html"`, `"{firstName\|slugify}-{lastName\|slugify}.vcf"` |
| `format` | `json`, `csv`, `md`, `html`, `yaml`, `txt`, `ics`, `vcf`, `eml`, `svg`, `webloc`, `xlsx`, `docx`, `pptx`, `raw` |
| `idField` | Field used as the record's unique key |
| `contentField` | Field for the file body (MD, HTML, SVG, TXT) |
| `readOnly` | If true, local edits are not pushed |

---

### Transform operations

```json
"transforms": {
  "pull": [
    { "op": "flatten", "path": "owner", "to": "" },
    { "op": "pick",    "fields": ["id", "name", "login", "html_url"] }
  ]
}
```

| Op | Params | Description |
|---|---|---|
| `pick` | `fields` | Keep only these fields |
| `omit` | `fields` | Drop these fields |
| `rename` | `from`, `to` | Rename a field |
| `flatten` | `path`, `to` | Merge nested object into parent |
| `keyBy` | `path`, `key`, `value`, `to` | Convert array → keyed object |

When `pull` transforms + `idField` are set, the engine auto-computes the inverse push transforms
(`pushMode: "auto-reverse"`). Set `"readOnly": true` to disable push entirely.

---

### Media sync

Download binary files (images, PDFs, videos) from URLs in the API response:

```json
"pull": {
  "url": "{baseUrl}/files",
  "dataPath": "$.files",
  "type": "media",
  "mediaConfig": {
    "urlField": "url",
    "filenameField": "displayName",
    "idField": "id",
    "hashField": "hash"
  }
},
"fileMapping": { "strategy": "mirror", "directory": "media", "format": "raw", "idField": "id" }
```

Upload uses a two-step signed-URL flow: call `push.create` to get a presigned URL, then PUT the binary.

---

### Hierarchical resources (children)

```json
{
  "name": "collections",
  "pull": { "url": "{baseUrl}/cms/v2/collections", "dataPath": "$.collections" },
  "fileMapping": { "strategy": "collection", "directory": ".", "filename": "collections.json", "format": "json", "idField": "id" },
  "children": [{
    "name": "items",
    "pull": {
      "method": "POST",
      "url": "{baseUrl}/cms/v3/items/query",
      "body": { "dataCollectionId": "{id}", "query": { "paging": { "limit": 50 } } },
      "dataPath": "$.dataItems"
    },
    "fileMapping": { "strategy": "collection", "directory": "cms/{displayName|slugify}", "filename": "items.csv", "format": "csv", "idField": "id" }
  }]
}
```

The child `directory` template resolves parent fields: `"cms/{displayName|slugify}"` → `cms/my-collection/`.

---

### Step-by-step: adding a new adapter

1. Create `Sources/API2FileCore/Resources/Adapters/myservice.adapter.json`
2. Set `service` (lowercase ID), `displayName`, `version: "1.0"`
3. Choose auth type; set `globals.baseUrl` and required headers
4. Add resources — for each: `pull.url`, `pull.dataPath`, `fileMapping.strategy`, `format`, `idField`
5. Add `push` endpoints if writable; use `bodyWrapper` if the API expects a wrapper key
6. Add `transforms` for nested API responses
7. Add `pagination` if the endpoint pages results
8. Test: `swift run api2file add myservice && swift run api2file sync myservice`

**Quick decision guide:**

| Data type | Strategy | Format |
|---|---|---|
| Table / list (tasks, products) | `collection` | `csv` |
| Documents / blog posts | `one-per-record` | `md` or `html` |
| Contacts | `one-per-record` | `vcf` |
| Calendar events | `one-per-record` | `ics` |
| Config / single-object settings | `collection` | `json` or `yaml` |
| Binary media (images, PDFs) | `mirror` + `type:media` | `raw` |
| Sub-resources per parent | `children` on the parent | — |

---

## MCP Browser Tools

API2File includes an MCP server that gives you browser control through a WebView window.
Use these tools to navigate to service websites and verify that your file edits are reflected.

### Available tools

| Tool | Description |
|------|-------------|
| `navigate` | Open a URL in the browser (auto-opens the window). Use `get_services` to find service site URLs. |
| `screenshot` | Capture the browser as a PNG image. Use after navigating to verify changes visually. |
| `get_dom` | Get the page HTML. Optionally pass a CSS `selector` to get a subtree. |
| `click` | Click a DOM element by CSS selector. |
| `type` | Type text into an input field by CSS selector. |
| `evaluate_js` | Run arbitrary JavaScript in the page. |
| `get_page_url` | Get the current URL. |
| `wait_for` | Wait for an element to appear (by CSS selector, with timeout). |
| `back` / `forward` / `reload` | Browser navigation. |
| `scroll` | Scroll the page (direction: up/down/left/right, optional pixel amount). |
| `get_services` | List all connected services with status and site URLs. |
| `sync` | Trigger an immediate sync for a service (by serviceId). |

### Edit → Sync → Verify workflow

This is the core loop for updating content through API2File:

```
1. get_services          → see what's connected + their siteUrls
2. Read/edit files       → modify CSV rows, MD content, JSON objects
3. sync({serviceId})     → push changes to the cloud API
4. navigate({siteUrl})   → open the service's web UI
5. screenshot()          → capture what the page looks like
6. get_dom({selector})   → inspect specific page elements if needed
7. Iterate               → make more edits, sync again, verify
```

### Common patterns

**Update a task status (CSV):**
```
1. Edit tasks.csv — change the "status" column of the target row
2. sync("demo")
3. navigate("http://localhost:8089/tasks")
4. screenshot()
```

**Update a Wix product price:**
```
1. Edit wix/products.csv — change the "price" column
2. sync("wix")
3. navigate("https://yoursite.wixsite.com/products")
4. screenshot()
```

**Create a new blog post (Markdown):**
```
1. Create wix/blog-posts/my-new-post.md with title and content
2. sync("wix")
3. navigate("https://yoursite.wixsite.com/blog/my-new-post")
4. screenshot()
```

### Important notes

- Always use `sync` after editing files — changes won't appear on the site until synced
- The `screenshot` tool waits for the page to finish loading before capturing
- Use `wait_for` before `screenshot` if the page has lazy-loaded content
- Use `get_dom` with a selector to check if specific content exists without a full screenshot
- The `_id` column in CSV files must never be modified — it links rows to remote records
