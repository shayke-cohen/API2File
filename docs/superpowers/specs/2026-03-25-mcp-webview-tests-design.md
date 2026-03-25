# Design: MCP + WebView + E2E Tests

**Date:** 2026-03-25
**Status:** Draft

## Context

We just built a full Claude Code integration: MCP server binary, WebView browser window, LocalServer browser routes, adapter enable/disable, demo HTML pages. There are 0 tests for any of it. The existing test suite (537 tests, 28 classes) uses XCTest with DemoAPIServer on random ports and temp directories. We follow those exact patterns.

## Test Layers

### 0. Prerequisite: PortDiscovery env var override

Before integration/E2E tests can work, `Sources/API2FileMCP/PortDiscovery.swift` must be modified to read `API2FILE_SERVER_INFO_PATH` from the environment, falling back to `~/.api2file/server.json`. This prevents tests from interfering with a running app instance.

### 1. MCP Protocol Tests

**File:** `Tests/API2FileCoreTests/MCP/MCPProtocolTests.swift`

Tests the MCP binary's JSON-RPC protocol behavior. Since the binary is a separate SPM target (not importable via `@testable`), these spawn it as a `Process` and validate responses. No app servers needed — tests the binary in isolation.

**Tests:**
- `testInitializeHandshake` — Send `initialize` request, verify protocol version and capabilities
- `testToolsList` — Send `tools/list`, verify each expected tool name is present (navigate, screenshot, get_dom, click, type, evaluate_js, get_page_url, wait_for, back, forward, reload, scroll, get_services, sync)
- `testInitializedNotification` — Send `initialized` notification, verify no response (it's a notification)
- `testPingReturnsEmptyResult` — Send `ping`, verify empty result
- `testUnknownMethod` — Send unknown method, verify JSON-RPC error -32601
- `testMalformedJSON` — Send garbage input, verify graceful handling
- `testToolCallWithoutApp` — Call `navigate` when no app is running, verify error message contains "not running"

**Pattern:** Uses `MCPTestHarness` (see below) to spawn `api2file-mcp` as a `Process`, pipe stdin/stdout, send JSON lines, read responses.

### 2. Browser Route Tests

**File:** `Tests/API2FileCoreTests/Server/BrowserRouteTests.swift`

Tests LocalServer's `/api/browser/*` HTTP routes using a mock `BrowserControlDelegate`.

**Setup:**
- Create a `MockBrowserDelegate` class implementing `BrowserControlDelegate`
- Start a real `LocalServer` on a random port with a real `SyncEngine` (minimal config, temp dir)
- Inject the mock delegate via `setBrowserDelegate()`

**Tests:**
- `testNavigateReturnsURL` — POST `/api/browser/navigate` with URL, mock returns it, verify HTTP 200 + JSON
- `testNavigateAutoOpens` — POST navigate when `isBrowserOpen` returns false, verify `openBrowser()` was called first
- `testScreenshotReturnsBase64` — POST `/api/browser/screenshot`, mock returns PNG data, verify base64 in response
- `testDOMReturnsHTML` — POST `/api/browser/dom`, verify HTML in response
- `testDOMWithSelector` — POST with selector param, verify selector passed to delegate
- `testClickNotFound` — Mock throws `BrowserError.elementNotFound`, verify HTTP 404
- `testWaitForTimeout` — Mock throws `BrowserError.timeout`, verify HTTP 408
- `testNoDelegateReturns503` — Don't set delegate, call any browser route, verify HTTP 503
- `testScrollDirections` — Test all 4 directions return 200
- `testBackForwardReload` — Test navigation control routes
- `testBrowserStatus` — GET `/api/browser/status` returns open/closed + URL
- `testEvaluateJSReturnsResult` — POST with code, verify result in response
- `testTypeMissingParams` — POST `/api/browser/type` without selector, verify 400
- `testGetURL` — GET `/api/browser/url` returns current URL from delegate

**Additional error-path tests:**
- `testNavigateInvalidURL` — Mock throws `BrowserError.navigationFailed`, verify HTTP 400
- `testEvaluateJSFails` — Mock throws `BrowserError.evaluationFailed`, verify HTTP 400
- `testWindowNotOpen` — Mock throws `BrowserError.windowNotOpen`, verify HTTP 503
- `testBrowserOpenRoute` — POST `/api/browser/open`, verify 200

**MockBrowserDelegate:**

Note: Since `BrowserControlDelegate` methods are `@MainActor`, the test class should be annotated `@MainActor` so mock configuration and assertions don't need explicit `MainActor.run {}` wrappers.

```swift
@MainActor
final class MockBrowserDelegate: BrowserControlDelegate {
    var navigateCalls: [(String)] = []
    var screenshotData: Data = Data()  // set per test
    var domHTML: String = "<html></html>"
    var currentURL: String? = nil
    var isOpen: Bool = true
    var errorToThrow: BrowserError? = nil
    // ... implement all protocol methods, recording calls and returning configured values
}
```

### 3. MCP Integration Tests

**File:** `Tests/API2FileCoreTests/Integration/MCPIntegrationTests.swift`

Tests the full MCP binary → LocalServer → DemoAPIServer pipeline. No mock delegates — uses real HTTP but no WebView (browser routes return 503 since no delegate is set in headless mode).

**Setup:**
- Start DemoAPIServer on random port
- Start LocalServer on random port pointing to a temp sync folder with demo adapter config
- Build and spawn `api2file-mcp` process
- Write `~/.api2file/server.json` pointing to the LocalServer port (use temp path override or env var)

**Tests:**
- `testGetServices` — Call `get_services` tool, verify demo service returned with status
- `testSyncTriggers` — Call `sync` tool with demo service ID, verify 200 response
- `testNavigateWithoutWebView` — Call `navigate`, verify error about browser not available (503)
- `testScreenshotWithoutWebView` — Same, verify clear error
- `testFullToolRoundtrip` — Initialize → tools/list → call get_services → call sync → verify responses

**Port Discovery Override:** To avoid conflicting with a running app, the MCP binary reads from `~/.api2file/server.json`. Tests write a temp `server.json` to a custom location. We'll add an env var `API2FILE_SERVER_INFO_PATH` to `PortDiscovery.swift` that overrides the default path.

### 4. E2E Tests (MCP + App + Demo Server)

**File:** `Tests/API2FileCoreTests/Integration/MCPBrowserE2ETests.swift`

Full pipeline test: DemoAPIServer running → LocalServer with browser delegate mock → MCP binary → edit file → sync → navigate → screenshot → verify.

Since we can't run WKWebView in a headless test process (it needs a running NSApplication), we use a **BrowserSimulator** — a mock delegate that fakes navigation by tracking URLs and returning canned HTML/screenshots.

**BrowserSimulator:**
```swift
@MainActor
final class BrowserSimulator: BrowserControlDelegate {
    var currentURL: String?
    var demoServerPort: UInt16

    // navigate() → HTTP GET the URL from DemoAPIServer, store the HTML
    // getDOM() → return the stored HTML
    // screenshot() → return a 1x1 PNG pixel (valid PNG data)
    // click/type/evaluateJS → record calls, return OK
}
```

This lets us test the full flow without an actual macOS window.

**Tests:**
- `testEditTaskAndVerifyInHTML` — Edit tasks.csv in temp dir → call `sync` via MCP → call `navigate` to demo HTML page → call `get_dom` → parse HTML, verify updated task appears
- `testCreateContactAndVerify` — Create a VCF file → sync → navigate to contacts page → get_dom → verify contact name in HTML
- `testGetServicesReturnsSiteUrl` — Call get_services, verify `siteUrl` field present for demo
- `testNavigateToSiteUrl` — Get services → extract siteUrl → navigate to it → screenshot → verify non-empty PNG
- `testScrollAndScreenshot` — Navigate → scroll down → screenshot → verify returns data
- `testEvaluateJSOnDemoPage` — Navigate to demo page → evaluate `document.title` → verify title

### 5. Adapter Enable/Disable Tests

**File:** `Tests/API2FileCoreTests/Models/AdapterEnableDisableTests.swift`

**Tests:**
- `testEnabledDefaultsToTrue` — Decode adapter JSON without `enabled` field, verify `enabled` is nil (treated as true)
- `testEnabledFalseDecodes` — Decode JSON with `"enabled": false`, verify it decodes
- `testSiteUrlDecodes` — Decode JSON with `"siteUrl"`, verify field
- `testBackwardCompatibility` — Decode all 12 bundled adapter JSONs, verify none fail (existing configs have no `enabled`/`siteUrl`)

### 6. Manual E2E Script

**File:** `scripts/e2e-claude-code.sh`

A shell script for human-run E2E testing with real Claude Code:

```bash
#!/bin/bash
# E2E test: Claude Code + API2File MCP + Demo Server
# Requires: claude CLI installed, ANTHROPIC_API_KEY set

set -e

echo "Building..."
swift build

echo "Starting demo server..."
swift run api2file-demo &
DEMO_PID=$!

echo "Starting app (headless mode)..."
# Start just the sync engine + local server, no UI
swift run api2file &
APP_PID=$!
sleep 3

echo "Launching Claude Code with MCP..."
echo "Ask Claude Code to: 'List services, navigate to demo dashboard, take a screenshot, edit a task, sync and verify'"
claude --mcp-config ~/.api2file/mcp.json

# Cleanup
kill $DEMO_PID $APP_PID 2>/dev/null
```

## Files Summary

### New test files:
| File | Tests | Type |
|------|-------|------|
| `Tests/API2FileCoreTests/MCP/MCPUnitTests.swift` | 6 | Unit |
| `Tests/API2FileCoreTests/Server/BrowserRouteTests.swift` | 14 | Unit |
| `Tests/API2FileCoreTests/Models/AdapterEnableDisableTests.swift` | 4 | Unit |
| `Tests/API2FileCoreTests/Integration/MCPIntegrationTests.swift` | 5 | Integration |
| `Tests/API2FileCoreTests/Integration/MCPBrowserE2ETests.swift` | 6 | E2E |
| `scripts/e2e-claude-code.sh` | — | Manual |

### Modified files:
| File | Changes |
|------|---------|
| `Sources/API2FileMCP/PortDiscovery.swift` | Add `API2FILE_SERVER_INFO_PATH` env var override |
| `TESTING.md` | Add MCP/Browser/E2E test documentation |

### Test helpers:
| Helper | Location |
|--------|----------|
| `MockBrowserDelegate` | Inline in `BrowserRouteTests.swift` |
| `BrowserSimulator` | Inline in `MCPBrowserE2ETests.swift` |
| `MCPTestHarness` | Shared helper in `MCP/MCPTestHarness.swift` |

### MCPTestHarness specification

Shared helper used by MCP Protocol, Integration, and E2E tests.

**Binary path resolution:** Runs `swift build --product api2file-mcp` in `setUpWithError()` (once per class via a static flag). Locates binary at `{projectRoot}/.build/debug/api2file-mcp` by traversing from `#file` path.

**Public API:**
```swift
class MCPTestHarness {
    init(binaryPath: URL)
    func start(env: [String: String] = [:]) throws    // spawn Process, set up pipes
    func sendRequest(_ json: [String: Any]) throws -> [String: Any]  // write to stdin, read response from stdout
    func sendNotification(_ json: [String: Any]) throws  // write without expecting response
    func stop()   // SIGTERM + waitUntilExit
}
```

**Timeout:** `sendRequest` waits up to 10 seconds for a response. Throws `XCTFail` on timeout.

**Cleanup:** `stop()` is called in `tearDown()`. Kills process if still alive.

### BrowserSimulator note

`BrowserSimulator.navigate()` uses `URLSession.shared.data(from:)` with async/await (never semaphore-based synchronous calls, which would deadlock on `@MainActor`).

**Total new tests: ~39**

## Verification

```bash
# Run all new tests
swift test --filter "MCPUnit|BrowserRoute|AdapterEnableDisable|MCPIntegration|MCPBrowserE2E"

# Run just unit tests (fast, no servers)
swift test --filter "MCPUnit|BrowserRoute|AdapterEnableDisable"

# Run integration + E2E (needs build, spawns servers)
swift test --filter "MCPIntegration|MCPBrowserE2E"

# Full suite including existing 537 tests
swift test
```
