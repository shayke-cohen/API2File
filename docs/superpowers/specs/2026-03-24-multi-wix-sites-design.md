# Multi-Wix-Sites Support — Design Spec

**Date:** 2026-03-24
**Status:** Approved

---

## Context

API2File currently supports one instance per service type: the "Add Service" wizard always creates a folder named after the adapter's `service` field (e.g., `wix/`). The Keychain entry is similarly shared per service type (`api2file.wix.key`). Users who manage multiple Wix sites — whether under the same Wix account (same API key, different site IDs) or different accounts (separate API keys) — have no way to connect more than one.

The fix is small because the sync engine is already instance-agnostic: it discovers any directory containing `.api2file/adapter.json` and treats it as an independent service. The only gaps are in the wizard (which hardcodes the directory name) and Keychain key management.

---

## Goals

- Support N Wix site instances synced simultaneously, each in its own top-level folder (`wix-my-store/`, `wix-client-b/`, etc.)
- Same-account sites share a Keychain entry (user enters API key once)
- Different-account sites get their own Keychain entry
- Each instance has a user-friendly display name shown in the menu bar
- Backward compatible: existing `wix/` directory continues to work unchanged

---

## Design

### 1. `wix.adapter.json` — new `display-name` setup field + `instanceName` placeholder

Add `display-name` as the **first** entry in `setupFields`:

```json
{
  "key": "display-name",
  "label": "Site Name",
  "placeholder": "My Store",
  "templateKey": "YOUR_INSTANCE_NAME_HERE",
  "helpText": "Shown in the menu bar to identify this site"
}
```

Add to the template root:

```json
"instanceName": "YOUR_INSTANCE_NAME_HERE"
```

This field is substituted at wizard time, giving each instance a human-readable label stored in its own `adapter.json`.

### 2. `AdapterConfig.swift` — add `instanceName: String?`

```swift
public let instanceName: String?   // optional per-instance display name override
```

Decoded from `adapter.json`. When present, used instead of `displayName` in `ServiceInfo`.

### 3. `SyncEngine.swift` — use `instanceName` in `ServiceInfo`

In `registerService(_:)`, line 220, change:

```swift
displayName: config.displayName,
```

to:

```swift
displayName: config.instanceName ?? config.displayName,
```

### 4. `AgentGuideGenerator.swift` — add `serviceId` parameter to `generateServiceGuide`

`generateServiceGuide(config:serverPort:)` currently uses `config.service` ("wix") in the Control API curl examples (lines 106–107). With multiple instances, the actual service ID is the directory name ("wix-my-store"), not `config.service`.

**Change the signature** to:

```swift
public static func generateServiceGuide(
    serviceId: String,
    config: AdapterConfig,
    serverPort: Int
) -> String
```

**Update the Control API lines** from:

```swift
lines.append("curl localhost:\(serverPort)/api/services/\(config.service)/sync")
lines.append("curl localhost:\(serverPort)/api/services/\(config.service)/status")
```

to:

```swift
lines.append("curl localhost:\(serverPort)/api/services/\(serviceId)/sync")
lines.append("curl localhost:\(serverPort)/api/services/\(serviceId)/status")
```

**Update `config.displayName` references** (lines 55, 57, 58, 68) to use `config.instanceName ?? config.displayName` so per-instance guides say "My Store" instead of "Wix — Website & Business Platform".

**Update `writeGuides`** call site (line 147) to pass `serviceId`:

```swift
let serviceGuide = generateServiceGuide(serviceId: serviceId, config: config, serverPort: serverPort)
```

### 5. `AddServiceView.swift` — wizard changes

**Rendering order:** `display-name` must be rendered **above** the generic `setupFields` ForEach loop as a plain `TextField` (not in the loop — the loop still renders remaining fields like `wix-site-id`). This avoids double-rendering and puts the friendly name first.

**Directory name generation:**

```swift
let instanceName = extraFieldValues["display-name"]?.trimmingCharacters(in: .whitespaces)
// slugify: lowercase, spaces→dashes, strip non-alphanumeric except dashes, max 50 chars
// empty result → fall back to service type
let slug = instanceName.flatMap { slugify($0, fallback: template.config.service) }
           ?? template.config.service
let baseSlug = template.config.service + (slug == template.config.service ? "" : "-" + slug)
let directoryName = deduplicateDirectory(base: baseSlug, in: syncFolder)
```

`slugify(_:fallback:)`: trim → lowercase → replace spaces with dashes → strip non-`[a-z0-9-]` → collapse consecutive dashes → truncate to 50 chars → if empty, return fallback.

`deduplicateDirectory(base:in:)`: if `base` folder exists on disk, try `base-2`, `base-3`, up to 99, then return `base` (worst case, directory creation will fail with a clear error).

**API key reuse toggle:**

```swift
@State private var reuseExistingKey: Bool = false

// When user selects a template (in the selectService Button action):
Task {
    let keychain = KeychainManager()
    let hasKey = await keychain.load(key: template.config.auth.keychainKey) != nil
    await MainActor.run { reuseExistingKey = hasKey }
}
```

Show the toggle in the credentials step only when `reuseExistingKey` is true (i.e., an existing key was found). Use the service display name in the label:

> ☑ Reuse existing \{template.config.displayName\} API key

When checked, hide the `SecureField("API Key or Token")`.

**Reset on Back:** In the `Back` button action, reset `reuseExistingKey = false` so re-selecting a different adapter starts clean.

**`canConnect` updated:**

```swift
private var canConnect: Bool {
    guard let template = selectedTemplate else { return false }
    // API key required only when NOT reusing an existing key
    if !reuseExistingKey && apiKey.isEmpty { return false }
    for field in template.config.setupFields ?? [] {
        if field.key == "display-name" { continue }  // optional — omitting falls back to service type
        if (extraFieldValues[field.key] ?? "").isEmpty { return false }
    }
    return true
}
```

**`onComplete` must use `directoryName`:**

```swift
// BEFORE (wrong — always "wix"):
let completedServiceId = template.config.service
onComplete?(completedServiceId)

// AFTER:
onComplete?(directoryName)   // e.g., "wix-my-store"
```

**Keychain and adapter.json at connect time:**

```swift
if reuseExistingKey {
    // No new keychain entry; adapter.json keeps template's keychainKey unchanged
} else {
    // Use the same "api2file." prefix convention as the template (api2file.wix.key).
    // KeychainManager adds "com.api2file." internally — this is consistent with
    // existing keys (both become "com.api2file.api2file.*.key" in the Keychain).
    let instanceKey = "api2file.\(directoryName).key"
    await keychain.save(key: instanceKey, value: apiKey)
    do {
        try patchKeychainKey(in: adapterJSONPath, newKey: instanceKey)
    } catch {
        await MainActor.run {
            self.error = "Could not write auth config: \(error.localizedDescription)"
            step = .enterCredentials
        }
        return
    }
}
```

`patchKeychainKey(in:newKey:) throws`: load written `adapter.json` as `Data` → decode via `JSONSerialization` into `[String: Any]` → navigate to `auth` dict → replace `keychainKey` value → re-encode with `.prettyPrinted` → write back atomically. Key ordering is not guaranteed to match the original template — acceptable since the file is machine-written. If `JSONSerialization` fails to parse, throw the error.

**Done screen:**

```swift
let resolvedFolder = GlobalConfig().resolvedSyncFolder.path
let label = extraFieldValues["display-name"] ?? selectedTemplate?.config.displayName ?? ""
Text("\(label) is now syncing to \(resolvedFolder)/\(directoryName)/")
```

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/API2FileCore/Resources/Adapters/wix.adapter.json` | Add `display-name` setup field; add `instanceName` placeholder |
| `Sources/API2FileCore/Models/AdapterConfig.swift` | Add `instanceName: String?` property |
| `Sources/API2FileCore/Core/SyncEngine.swift` | Use `instanceName ?? displayName` in `ServiceInfo` construction |
| `Sources/API2FileCore/Core/AgentGuideGenerator.swift` | Add `serviceId` param to `generateServiceGuide`; use `serviceId` in Control API paths; use `instanceName ?? displayName` in guide text |
| `Sources/API2FileApp/UI/AddServiceView.swift` | Directory slug, reuse toggle + reset on Back, `canConnect` update, keychain patch, `onComplete` fix, done screen |

No changes to: `SyncCoordinator`, `AdapterEngine`, `KeychainManager`, `FileMapper`, or any adapter resource logic.

---

## Backward Compatibility

Existing `wix/` instances:

- Their `adapter.json` has no `instanceName` → decodes as `nil` → `ServiceInfo.displayName` falls back to `config.displayName` — identical to today.
- Their Keychain entry `api2file.wix.key` continues to be used — no migration needed.
- `generateServiceGuide` will now receive `serviceId: "wix"` (same as `config.service`) — output unchanged.

---

## Verification

1. **Build** — `swift build` succeeds with no errors.

2. **Add second Wix site (same account)**:
   - Open Add Service → select Wix → enter "Client B" as site name, enter a different site ID → toggle "Reuse existing Wix API key" ON → Connect.
   - Verify: `~/API2File-Data/wix-client-b/` created; `.api2file/adapter.json` contains correct site ID and `instanceName: "Client B"`.
   - Verify: `auth.keychainKey` in new adapter.json = `"api2file.wix.key"` (shared key unchanged).
   - Verify: menu bar shows the original site as "Wix — Website & Business Platform" (no instanceName) and new site as "Client B".

3. **Add third Wix site (different account)**:
   - Toggle OFF "Reuse existing API key" → enter new API key.
   - Verify: `api2file.wix-site-name.key` Keychain entry created.
   - Verify: new `adapter.json` has `auth.keychainKey: "api2file.wix-site-name.key"`.

4. **Slug deduplication** — add two sites both named "My Store" → folders `wix-my-store/` and `wix-my-store-2/` created.

5. **Existing wix/ instance** — existing directory still syncs; CLAUDE.md still reads "Wix — Website & Business Platform".

6. **Empty display name** — leave Site Name blank → directory defaults to `wix/` (or next deduplicated name if `wix/` exists).
