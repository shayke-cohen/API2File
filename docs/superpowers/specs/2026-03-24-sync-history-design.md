# Sync History & Activity Log — Design Spec

## Context

API2File currently has no persistent record of sync operations. The app only tracks current file state (`SyncState.json`) and fires ephemeral macOS notifications. When something goes wrong — or a user wants to understand what happened — there's nowhere to look. This feature adds a full audit trail of every pull, push, error, and conflict, with per-file and per-record detail.

## Requirements

- **Full audit trail**: Every sync operation (pull, push, error, conflict) is logged with timestamp, direction, duration, outcome, and per-file breakdown
- **Record-level detail**: For collection files (CSV, JSON arrays), capture created/updated/deleted record counts from CollectionDiffer
- **Global + per-service views**: Activity tab in Preferences shows all services; ServiceDetailView shows per-service history
- **Quick glance in menu bar**: Recent activity submenu for fast check without opening Preferences
- **API access**: `GET /api/services/:id/history` for programmatic consumers
- **Per-service JSON storage**: Each service stores its log in `.api2file/sync-history.json`, auto-pruned to 500 entries

## Data Model

### SyncHistoryEntry

```swift
public struct SyncHistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let serviceId: String
    public let serviceName: String   // display name, preserved for historical readability
    public let direction: SyncDirection
    public let status: SyncOutcome
    public let duration: TimeInterval
    public let files: [FileChange]
    public let summary: String
}

public enum SyncDirection: String, Codable, Sendable {
    case pull
    case push
}

public enum SyncOutcome: String, Codable, Sendable {
    case success
    case error
    case conflict
}

public struct FileChange: Codable, Identifiable, Sendable {
    public var id: String { path }  // unique within an entry
    public let path: String
    public let action: FileAction
    public let recordsCreated: Int
    public let recordsUpdated: Int
    public let recordsDeleted: Int
    public let errorMessage: String?
}

public enum FileAction: String, Codable, Sendable {
    case downloaded   // pull: file written to disk
    case uploaded     // push: single file sent to API
    case created      // push: new records created
    case updated      // push: existing records modified
    case deleted      // push: records removed
    case conflicted   // conflict detected
    case error        // operation failed for this file
}
```

### SyncHistoryLog

```swift
public struct SyncHistoryLog: Codable, Sendable {
    public var entries: [SyncHistoryEntry]
    private static let maxEntries = 500

    public mutating func append(_ entry: SyncHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }

    // load/save pattern matching SyncState
    public static func load(from url: URL) throws -> SyncHistoryLog
    public func save(to url: URL) throws
}
```

## Integration Points

### SyncEngine Changes

File: `Sources/API2FileCore/Core/SyncEngine.swift`

1. **New property**: `private var historyLogs: [String: SyncHistoryLog] = [:]`
2. **Load on service register** (`registerService`): `(try? SyncHistoryLog.load(from: historyURL)) ?? SyncHistoryLog(entries: [])` — matching the existing `SyncState` pattern. File is created on disk only when the first entry is appended.
3. **Log after pull** (`performPull`): Create entry with direction `.pull`, list of `FileChange` entries (one per file), status `.success` or `.error`
4. **Log after push** (`performPush`): For collection files, use `CollectionDiffer.DiffResult` counts. For single files, simple `.uploaded` action
5. **Log on error**: Wrap pull/push in timing + error capture, always log even on failure
6. **Save after logging**: Write `.api2file/sync-history.json` alongside state save
7. **New public accessor**: `func getHistory(serviceId:limit:) -> [SyncHistoryEntry]`
8. **Cleanup on remove**: Clear history log when service is removed

### performPull instrumentation (pseudocode)

```swift
let startTime = Date()
do {
    let files = try await engine.pullAll()
    // ... existing file write + state update logic ...
    let fileChanges = files.map { FileChange(path: $0.relativePath, action: .downloaded, ...) }
    let entry = SyncHistoryEntry(
        direction: .pull, status: .success,
        duration: Date().timeIntervalSince(startTime),
        files: fileChanges,
        summary: "pulled \(files.count) files"
    )
    historyLogs[serviceId]?.append(entry)
    // save history
} catch {
    let entry = SyncHistoryEntry(
        direction: .pull, status: .error,
        duration: Date().timeIntervalSince(startTime),
        files: [], summary: "pull failed: \(error.localizedDescription)"
    )
    historyLogs[serviceId]?.append(entry)
    // save history
    throw error
}
```

### performPush instrumentation (pseudocode)

```swift
let startTime = Date()
// For collection files after diff:
let fileChange = FileChange(
    path: filePath, action: .uploaded,
    recordsCreated: diff.created.count,
    recordsUpdated: diff.updated.count,
    recordsDeleted: diff.deleted.count,
    errorMessage: nil
)
let entry = SyncHistoryEntry(
    direction: .push, status: .success,
    duration: Date().timeIntervalSince(startTime),
    files: [fileChange],
    summary: "pushed \(filePath) (\(diff.summary))"
)
historyLogs[serviceId]?.append(entry)
```

## UI Components

### A. Preferences → Activity Tab

File: `Sources/API2FileApp/UI/PreferencesView.swift`

New third tab in the TabView:

```swift
ActivityTab(appState: appState)
    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
```

**ActivityTab layout:**
- Top bar: service filter dropdown (All / specific service) + direction filter (All / Pull / Push)
- Scrollable list of `SyncHistoryEntry` rows
- Each row shows: timestamp (relative), direction icon (↓ blue for pull, ↑ green for push), service name, summary, status badge (green checkmark / red X / yellow warning)
- Click row to expand: shows per-file breakdown table with columns: File, Action, Records (+/-/~), Error
- Empty state: "No sync activity yet"

### B. ServiceDetailView → Recent Activity Section

File: `Sources/API2FileApp/UI/ServiceDetailView.swift`

New section between "Resources" and "Error" sections:

```swift
// Recent Activity (after Resources section)
Divider().padding(.bottom, 6)
Text("Recent Activity")
    .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
ForEach(recentHistory.prefix(10)) { entry in
    SyncHistoryRow(entry: entry, showServiceName: false)
}
if recentHistory.count > 10 {
    Button("View All...") { /* navigate to Activity tab filtered */ }
}
```

### C. Menu Bar → Recent Activity Submenu

File: `Sources/API2FileApp/UI/MenuBarView.swift`

New menu item between "Sync Now" and "Pause Syncing":

```swift
Menu("Recent Activity") {
    if recentActivity.isEmpty {
        Text("No recent activity")
    } else {
        ForEach(recentActivity.prefix(5)) { entry in
            Text("\(entry.direction == .pull ? "↓" : "↑") \(entry.serviceId) — \(entry.summary) — \(entry.timestamp.formatted(.relative(presentation: .named)))")
        }
    }
}
```

### D. Shared SyncHistoryRow Component

File: `Sources/API2FileApp/UI/SyncHistoryRow.swift` (new file)

Reusable row component used by both ActivityTab and ServiceDetailView:
- Compact mode (menu bar, service detail): single line with icon + summary + timestamp
- Expanded mode (activity tab): expandable with file breakdown

## AppState Changes

File: `Sources/API2FileApp/App/API2FileApp.swift`

1. **New published property**: `@Published var recentActivity: [SyncHistoryEntry] = []`
2. **On-demand fetching** (not polling): Activity is fetched when the Activity tab or ServiceDetailView appears (via SwiftUI `.task` modifier), and after each sync completes. No 5-second polling — avoids crossing actor boundary for 500 entries when nothing changed.
3. **New method**: `func refreshHistory(serviceId: String? = nil)` — calls through to engine, updates `recentActivity`
4. **New accessor on SyncEngine**: `getHistory(serviceId:limit:) -> [SyncHistoryEntry]` returns entries, optionally filtered
5. **Post-sync refresh**: `syncService()` and `syncNow()` call `refreshHistory()` after sync completes

## Local Server API

File: `Sources/API2FileCore/Server/LocalServer.swift`

New route:

```text
GET /api/services/:id/history?limit=50
```

Response: JSON array of SyncHistoryEntry objects serialized via `JSONEncoder` with `.iso8601` date strategy. Default limit 50, max 500.

**Required change to HTTPRequest**: The existing `parse(from:)` method discards query strings (line 287). Add a `queryItems: [String: String]` property to `HTTPRequest` and parse query parameters from the raw path before stripping them. This is a small internal change to a private struct.

Add route matching in `routeRequest`:

```swift
if method == "GET", let serviceId = matchRoute(path: path, pattern: "/api/services/", suffix: "/history") {
    let limit = Int(request.queryItems["limit"] ?? "") ?? 50
    return await handleGetHistory(serviceId: serviceId, limit: min(limit, 500))
}
```

**Serialization**: Use `JSONEncoder` with `dateEncodingStrategy = .iso8601` for this endpoint (first endpoint to use Codable directly — cleaner than manual dict building for nested types). This is an intentional pattern evolution from the existing `JSONSerialization` approach.

## Notes

- **Preferences window size**: Increase from `(600, 400)` to `(600, 500)` to accommodate the Activity tab's scrollable content.
- **Pruning efficiency**: Use `entries.removeLast(entries.count - Self.maxEntries)` instead of `Array(entries.prefix(...))` to avoid allocation.

## File Changes Summary

| File | Change |
|------|--------|
| `Sources/API2FileCore/Models/SyncHistoryEntry.swift` | **NEW** — SyncHistoryEntry, FileChange, enums |
| `Sources/API2FileCore/Models/SyncHistoryLog.swift` | **NEW** — SyncHistoryLog with load/save/append/prune |
| `Sources/API2FileCore/Core/SyncEngine.swift` | **MODIFY** — add historyLogs, instrument pull/push, add getHistory accessor |
| `Sources/API2FileApp/UI/PreferencesView.swift` | **MODIFY** — add Activity tab |
| `Sources/API2FileApp/UI/ActivityTab.swift` | **NEW** — global activity view with filters and expandable rows |
| `Sources/API2FileApp/UI/SyncHistoryRow.swift` | **NEW** — shared row component |
| `Sources/API2FileApp/UI/ServiceDetailView.swift` | **MODIFY** — add Recent Activity section |
| `Sources/API2FileApp/UI/MenuBarView.swift` | **MODIFY** — add Recent Activity submenu |
| `Sources/API2FileApp/App/API2FileApp.swift` | **MODIFY** — add recentActivity to AppState, refresh loop |
| `Sources/API2FileCore/Server/LocalServer.swift` | **MODIFY** — add /history endpoint |
| `Tests/API2FileCoreTests/Models/SyncHistoryLogTests.swift` | **NEW** — unit tests for log model |

## Storage

- Location: `<service-dir>/.api2file/sync-history.json`
- Format: JSON object with `entries` array (`{"entries": [...]}`) — matches Codable encoding of `SyncHistoryLog`, newest first
- Max entries: 500 per service (oldest auto-pruned on append)
- In-memory log is initialized on service register (empty if file doesn't exist); written to disk on first append
- File is deleted when service is removed (alongside state.json)

## Verification

1. **Unit tests**: SyncHistoryLog append/prune/load/save, SyncHistoryEntry encoding/decoding
2. **Build**: `swift build` compiles without errors
3. **Manual test with demo service**:
   - Start app → connect demo service → verify initial pull creates history entry
   - Edit a CSV file → verify push creates entry with record counts
   - Check `.api2file/sync-history.json` has correct entries
   - Open Preferences → Activity tab shows entries
   - Check ServiceDetailView shows recent activity
   - Menu bar Recent Activity submenu shows entries
   - `curl localhost:21567/api/services/demo/history` returns JSON
4. **Error case**: Disconnect network → trigger sync → verify error entry is logged
5. **Pruning**: Verify log stays under 500 entries after many syncs
