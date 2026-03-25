# Design: Claude Code Integration with WebView + MCP Server

**Date:** 2026-03-25
**Status:** Draft

## Context

API2File syncs cloud service data (Wix, Monday, GitHub, etc.) to local files. Editing those files pushes changes back to the cloud. Currently, users edit files manually and have no way to visually verify what their changes look like on the actual site/service.

**Goal:** Give Claude Code CLI users the ability to:
1. Edit adapter files (CSV, JSON, MD, etc.) to update cloud data
2. See live results in a WebView browser window inside the app
3. Use MCP tools to navigate, screenshot, and inspect pages
4. Work with a contextual prompt that explains the full workflow

This turns API2File into a **live site content editor for Claude Code** — edit a `products.csv` → sync pushes to Wix → navigate WebView to the Wix site → screenshot to verify the product page updated.

---

## 1. Embedded MCP Server (stdio)

### Architecture

A new SPM executable target `API2FileMCP` that:
- Speaks MCP protocol (JSON-RPC 2.0) over stdin/stdout
- Communicates with the running API2File.app via HTTP to `localhost:{port}`
- Discovers the app's port from `~/.api2file/server.json`
- Has zero dependency on API2FileCore (pure Foundation + HTTP)

```
Claude Code  ──stdio──▶  api2file-mcp  ──HTTP──▶  API2File.app
                                                      │
                                                      ▼
                                                   WebView
```

### Port Discovery

On startup, API2File.app writes `~/.api2file/server.json` **after** `NWListener` reports `.ready` (ensuring the port is actually bound):
```json
{"port": 21567, "pid": 12345, "startedAt": "2026-03-25T10:00:00Z"}
```
On shutdown, it deletes the file.

**Robustness:** The MCP binary validates before connecting:

1. Read `~/.api2file/server.json` (if missing → error: "API2File app is not running")
2. Check PID is alive: `kill(pid, 0) == 0` (if dead → error: "API2File app is not running (stale server.json)")
3. Hit `GET /api/health` as final validation (if fails → error with details)

The app writes the file using `FileManager.default.homeDirectoryForCurrentUser` to resolve `~` to an absolute path. The MCP config also uses the fully resolved absolute path (not `~`).

### MCP Tools

| Tool | Args | Description |
|------|------|-------------|
| `navigate` | `{url}` | Load URL in WebView (auto-opens window) |
| `screenshot` | `{width?, height?}` | Capture WebView as base64 PNG (optional resize) |
| `get_dom` | `{selector?}` | Get page HTML (full doc or subtree via selector) |
| `click` | `{selector}` | Click a DOM element |
| `type` | `{selector, text}` | Type into an input field |
| `evaluate_js` | `{code}` | Run JavaScript in the WebView |
| `get_page_url` | `{}` | Get current URL |
| `wait_for` | `{selector, timeout?}` | Wait for element to appear |
| `back` | `{}` | Navigate back |
| `forward` | `{}` | Navigate forward |
| `reload` | `{}` | Reload current page |
| `scroll` | `{direction, amount?}` | Scroll the page (up/down/left/right) |
| `get_services` | `{}` | List connected services with status + siteUrls |
| `sync` | `{serviceId}` | Trigger sync for a service |

Each tool maps 1:1 to an HTTP endpoint on LocalServer.

### SPM Target

```
Sources/API2FileMCP/
    main.swift              -- entry point, RunLoop + stdin reader
    MCPServer.swift         -- JSON-RPC dispatch, tool registration
    MCPTransport.swift      -- stdin/stdout reader/writer
    MCPTypes.swift          -- Request, Response, Error types
    BrowserTools.swift      -- navigate, screenshot, dom, click, type, evaluate, wait
    ServiceTools.swift      -- get_services, sync
    AppClient.swift         -- HTTP client for localhost
    PortDiscovery.swift     -- reads ~/.api2file/server.json
```

Package.swift addition:
```swift
.executableTarget(
    name: "api2file-mcp",
    dependencies: [],
    path: "Sources/API2FileMCP"
),
```

### MCP Config for Claude Code

Generated at `~/.api2file/mcp.json`:
```json
{
  "mcpServers": {
    "api2file": {
      "command": "~/.api2file/bin/api2file-mcp",
      "args": []
    }
  }
}
```

---

## 2. WebView Browser Window

### Architecture

A standalone `NSWindow` with `WKWebView`, managed by `WebViewBridge` in the app target.

```
BrowserWindow (NSWindow)
├── toolbarStack (NSStackView, horizontal)
│   ├── backButton (NSButton)
│   ├── forwardButton (NSButton)
│   ├── reloadButton (NSButton)
│   └── addressBar (NSTextField, editable)
└── webView (WKWebView, fills remaining space)
```

**Why AppKit (not SwiftUI):** WKWebView needs direct reference for `evaluateJavaScript`, `takeSnapshot`, etc. NSViewRepresentable wrapping makes this harder. The existing codebase already uses NSWindow for the Add Service panel.

### Key Files

- `Sources/API2FileApp/Browser/WebViewBridge.swift` — `@MainActor` class, owns NSWindow + WKWebView, implements `BrowserControlDelegate`
- `Sources/API2FileApp/Browser/BrowserViewController.swift` — `NSViewController`, layout + WKNavigationDelegate

### WebViewBridge API

```swift
@MainActor
final class WebViewBridge: ObservableObject, BrowserControlDelegate {
    func openWindow()
    func navigate(to url: String) async throws -> String
    func captureScreenshot() async throws -> Data
    func getDOM() async throws -> String
    func click(selector: String) async throws
    func type(selector: String, text: String) async throws
    func evaluateJS(_ code: String) async throws -> String
    func getCurrentURL() async -> String?
    func waitFor(selector: String, timeout: TimeInterval) async throws
    func isBrowserOpen() async -> Bool
}
```

### Live Reload

When files change after sync, the WebView auto-refreshes — but only when relevant:

- `AppState` already refreshes services every 5 seconds
- During refresh, if any service's `lastSyncTime` changed, check if the current WebView URL matches that service's `siteUrl` domain (or is a localhost URL for demo)
- Only reload if there's a match — avoids constant reloading from unrelated services
- No plumbing changes to SyncEngine needed

### Screenshot Reliability

`WKWebView.takeSnapshot` can return blank images if the page hasn't finished rendering. The `captureScreenshot` implementation must wait for `WKNavigationDelegate.webView(_:didFinish:)` before capturing. If no navigation is in progress, capture immediately.

---

## 3. LocalServer Extensions

### BrowserControlDelegate Protocol

Defined in `API2FileCore` (no AppKit/WebKit imports needed):

```swift
// Drop Sendable — @MainActor classes with WKWebView/NSWindow can't conform.
// The actor boundary is crossed safely via `await` on async methods.
public protocol BrowserControlDelegate: AnyObject {
    @MainActor func navigate(to url: String) async throws -> String
    @MainActor func captureScreenshot() async throws -> Data
    @MainActor func getDOM() async throws -> String
    @MainActor func click(selector: String) async throws
    @MainActor func type(selector: String, text: String) async throws
    @MainActor func evaluateJS(_ code: String) async throws -> String
    @MainActor func getCurrentURL() async -> String?
    @MainActor func waitFor(selector: String, timeout: TimeInterval) async throws
    @MainActor func openBrowser() async throws
    @MainActor func isBrowserOpen() async -> Bool
}

// Error types for browser operations:
public enum BrowserError: Error {
    case windowNotOpen
    case elementNotFound(selector: String)
    case timeout(selector: String, seconds: TimeInterval)
    case evaluationFailed(String)
    case navigationFailed(String)
}

// LocalServer stores it as nonisolated(unsafe) to cross actor boundary:
// private nonisolated(unsafe) var browserDelegate: BrowserControlDelegate?
```

### New HTTP Routes

Added to `LocalServer.routeRequest()`:

| Method | Path | Body | Response |
|--------|------|------|----------|
| POST | `/api/browser/open` | `{}` | `{"status":"ok"}` |
| POST | `/api/browser/navigate` | `{"url":"..."}` | `{"status":"ok","url":"..."}` |
| POST | `/api/browser/screenshot` | `{}` | `{"image":"<base64>","width":W,"height":H}` |
| POST | `/api/browser/dom` | `{}` | `{"html":"<!DOCTYPE..."}` |
| POST | `/api/browser/click` | `{"selector":"..."}` | `{"status":"ok"}` |
| POST | `/api/browser/type` | `{"selector":"...","text":"..."}` | `{"status":"ok"}` |
| POST | `/api/browser/evaluate` | `{"code":"..."}` | `{"result":"..."}` |
| GET | `/api/browser/url` | — | `{"url":"..."}` |
| POST | `/api/browser/wait` | `{"selector":"...","timeout":5000}` | `{"status":"ok"}` |
| GET | `/api/browser/status` | — | `{"open":true,"url":"..."}` |

**Auto-open:** `navigate` auto-opens the browser window if not already open.

**Error codes** (extend `HTTPResponse.statusText` for these):

- 400: Invalid request body
- 404: Element not found (click/type)
- 408: Timeout (wait_for)
- 503: Browser delegate not set / app not ready

### Actor ↔ MainActor Bridge

`LocalServer` (actor) holds `BrowserControlDelegate?`. `WebViewBridge` (@MainActor) conforms to it. All calls cross isolation boundaries via `await`. This is the same pattern used for the deletion confirmation handler.

---

## 4. Claude Code Launch from Menu Bar

### Menu Bar Item

New item in `MenuBarView.swift` between "Open Logs" and "Preferences":

```
Open Browser           ← opens WebView window
Open Claude Code...    ← detects terminal, launches claude
```

### Terminal Detection

Check for terminal apps in order: iTerm2 → Warp → Terminal.app. Use `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` to detect.

### Launch Flow

1. Check if `claude` CLI is installed (`which claude`)
2. If not: show alert with install instructions (link to claude.ai/download) or offer to run `npm install -g @anthropic-ai/claude-code`
3. Generate MCP config at `~/.api2file/mcp.json`
4. Open preferred terminal with: `claude --mcp-config ~/.api2file/mcp.json`
5. The MCP config points to the `api2file-mcp` binary

### MCP Binary Distribution

**Development:** The binary is at `$(swift build --show-bin-path)/api2file-mcp`. The generated MCP config points directly there.

**Release:** The binary is embedded in the `.app` bundle at `Contents/MacOS/api2file-mcp` (added via a Copy Files build phase or by placing it alongside the main executable in the SPM build output). On first launch, the app copies it to `~/.api2file/bin/api2file-mcp` (like adapter seeding). On app updates, re-copy if the bundled version is newer.

**MCP config always uses the resolved absolute path** (e.g., `/Users/shay/.api2file/bin/api2file-mcp`), never `~`.

---

## 5. Claude Code Context: System Prompt

This is the key piece that makes Claude Code effective. When Claude Code launches with the API2File MCP, it needs a **system prompt** that explains:

### What it should know:
- **What adapter files are:** CSV/JSON/MD etc. that map to cloud API records
- **How editing works:** Edit file → FileWatcher detects → push to API → data updates on the cloud
- **What the `_id` column means:** Never modify it, it links rows to remote records
- **What services are connected:** Use `get_services` to discover them
- **What URLs to navigate to:** Each service has a site URL (Wix site, GitHub repo page, etc.)

### Workflow it should follow:
1. `get_services` → see what's connected and their site URLs
2. Read the adapter files in `~/API2File-Data/{serviceId}/`
3. Edit files to make changes (CSV rows, MD content, JSON objects)
4. `sync({serviceId})` → push changes to the cloud
5. `navigate({siteUrl})` → open the site in the WebView
6. `screenshot()` → capture what the page looks like
7. `get_dom()` → inspect the page structure if needed
8. Iterate: make more edits, sync, verify visually

### How the prompt is delivered:

The system prompt lives as a **CLAUDE.md** file that is generated into the data folder (`~/API2File-Data/CLAUDE.md`). This is automatically picked up by Claude Code when launched from that directory. Additionally, the MCP server's tool descriptions are rich enough to guide usage.

The CLAUDE.md extends the existing SKILL.md (which already documents file editing, formats, etc.) with:
- MCP tool descriptions and examples
- Per-service site URLs and what to look for
- Visual verification workflow
- Common patterns (e.g., "to update a Wix product price, edit products.csv, sync, navigate to the product page, screenshot")

---

## 6. Demo Adapter Enhancement

### Extend API2FileDemo (port 8089)

Add an HTML visualization page that renders the demo data:

- `GET /` → Dashboard page showing all demo resources (tasks table, contacts list, events calendar, etc.)
- `GET /tasks` → Tasks table view
- `GET /contacts` → Contacts card view
- `GET /events` → Events list view
- etc.

The pages read directly from the in-memory store that the demo REST API uses, so changes via API2File sync are immediately reflected.

### Demo Adapter URL

Add a `siteUrl` field to the adapter config schema:
```json
{
  "service": "demo",
  "siteUrl": "http://localhost:8089",
  ...
}
```

This lets Claude Code know where to navigate to see the demo data.

---

## 7. Adapter Enable/Disable

### Persistence

Add `enabled` and `siteUrl` fields to `AdapterConfig`. Both must be **optional with defaults** for backward compatibility (existing adapter.json files must still decode):

```swift
// In AdapterConfig.swift
public var enabled: Bool?    // defaults to true when nil
public var siteUrl: String?  // URL for the service's web UI
```

```json
// ~/API2File-Data/{serviceId}/.api2file/adapter.json
{
  "service": "wix",
  "enabled": true,
  "siteUrl": "https://www.wix.com/dashboard/{siteId}",
  ...
}
```

When `enabled: false`:
- SyncEngine skips this service during sync cycles
- Service is hidden from the menu bar service list
- Service still appears in Preferences → Services tab with a toggle

### UI

In `PreferencesView` → Services tab:
- Add a toggle switch per service (enabled/disabled)
- Disabled services show grayed out with "Disabled" label
- Toggle writes to the service's `adapter.json` and reloads the SyncEngine

In `MenuBarView`:
- Filter out disabled services from the list

---

## 8. App Icon

### Design

A simple, recognizable icon for the macOS app:
- Cloud with a file/document emerging from it (matches the cloud↔file sync concept)
- Blue gradient to match macOS aesthetic
- Add to `Sources/API2FileApp/Assets.xcassets/AppIcon.appiconset/`

### Sizes needed (macOS)
- 16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024

The icon will show in:
- Activity Monitor / Force Quit
- Dock (when windows are open)
- Finder (app info)
- Spotlight

---

## 9. Files to Modify

### New files:
| File | Purpose |
|------|---------|
| `Sources/API2FileMCP/main.swift` | MCP server entry point |
| `Sources/API2FileMCP/MCPServer.swift` | JSON-RPC dispatch |
| `Sources/API2FileMCP/MCPTransport.swift` | stdin/stdout I/O |
| `Sources/API2FileMCP/MCPTypes.swift` | Protocol types |
| `Sources/API2FileMCP/BrowserTools.swift` | WebView tool handlers |
| `Sources/API2FileMCP/ServiceTools.swift` | Service tool handlers |
| `Sources/API2FileMCP/AppClient.swift` | HTTP client |
| `Sources/API2FileMCP/PortDiscovery.swift` | Port discovery |
| `Sources/API2FileApp/Browser/WebViewBridge.swift` | WebView controller bridge |
| `Sources/API2FileApp/Browser/BrowserViewController.swift` | NSViewController + WKWebView |
| `Sources/API2FileCore/Server/BrowserControlDelegate.swift` | Protocol definition |
| `Sources/API2FileApp/Assets.xcassets/AppIcon.appiconset/` | App icon images |

### Modified files:
| File | Changes |
|------|---------|
| `Package.swift` | Add API2FileMCP target |
| `Sources/API2FileCore/Server/LocalServer.swift` | Add browserDelegate, /api/browser/* routes |
| `Sources/API2FileApp/App/API2FileApp.swift` | WebViewBridge creation, port discovery file, live reload |
| `Sources/API2FileApp/UI/MenuBarView.swift` | Add "Open Browser" and "Open Claude Code" items |
| `Sources/API2FileCore/Models/AdapterConfig.swift` | Add `enabled` and `siteUrl` fields |
| `Sources/API2FileCore/Core/SyncEngine.swift` | Skip disabled adapters |
| `Sources/API2FileApp/UI/PreferencesView.swift` | Add enable/disable toggles |
| `Sources/API2FileCore/Resources/Adapters/demo.adapter.json` | Add siteUrl |
| `Sources/API2FileDemo/` | Add HTML visualization pages |
| `Sources/API2FileCore/Resources/SKILL.md` | Add MCP tools documentation |

---

## 10. Verification Plan

### Unit tests:
- MCP protocol parsing (JSON-RPC request/response)
- Port discovery (file exists, file missing, stale PID)
- Browser HTTP endpoint routing

### Integration test:
1. Build and run `API2FileApp`
2. Verify `~/.api2file/server.json` is created
3. Build `api2file-mcp` and run it manually, send `initialize` over stdin
4. Send `tools/list` → verify all tools appear
5. Send `tools/call` with `navigate` → verify WebView opens
6. Send `tools/call` with `screenshot` → verify base64 PNG returned
7. Edit a demo file → trigger sync → verify WebView refreshes

### End-to-end test with Claude Code:
1. Launch API2File.app
2. Start demo server (`swift run api2file-demo`)
3. Click "Open Claude Code" in menu bar
4. In Claude Code: "Show me what services are connected"
5. "Navigate to the demo dashboard"
6. "Take a screenshot"
7. "Update the first task in tasks.csv to 'done' status"
8. "Sync the demo service and take a screenshot to verify"
