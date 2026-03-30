# API2File FS

## Purpose

This document captures the current technical design and implementation status of the API2File managed filesystem work.

The goal is to move from:

- normal folders plus file watching

to:

- a true API2File-owned filesystem surface where invalid writes fail in the calling app/editor

That is the only path that can produce the desired UX:

- user edits file in a normal macOS app
- app saves into an API2File-backed filesystem
- API2File validates before commit
- save fails immediately if invalid

## Product Goal

Managed workspace mode should eventually provide:

- Finder-visible regular files for managed services
- transactional writes owned by API2File
- validation before acceptance
- optional push-before-commit behavior
- rejection surfaced back to the writing app as a save failure

This is stronger than the existing managed workspace directory behavior, which can restore rejected changes after the save but cannot fail the save syscall itself.

## Modes

API2File currently has two storage modes:

- `plain_sync`
  Human-facing files live under `~/API2File-Data/<service>/`
  File edits are detected after write by watcher/sync logic.

- `managed_workspace`
  Human-facing files live under `~/API2File-Workspace/<service>/`
  Accepted-state tracking, validation, rejection history, and managed commit logic are implemented.
  Today this is still directory-backed, not a mounted filesystem.

The true FSKit-backed filesystem is the next layer on top of `managed_workspace`.

## Current Implementation

### Core managed workspace runtime

Implemented:

- `storageMode` support in service state/config
- managed workspace root resolution
- accepted-state materialization into `~/API2File-Workspace`
- managed write validation + rejection history
- local API endpoints for workspace status/rejections
- Lite API save path that uses managed validation/commit
- bidirectional demo adapter tests against the live demo server

Important files:

- `/Users/shayco/API2File/Sources/API2FileCore/Core/ManagedWorkspaceManager.swift`
- `/Users/shayco/API2File/Sources/API2FileCore/Core/SyncEngine.swift`
- `/Users/shayco/API2File/Sources/API2FileCore/Server/LocalServer.swift`
- `/Users/shayco/API2File/Sources/API2FileCore/Core/ManagedWorkspaceFileSystemStore.swift`
- `/Users/shayco/API2File/Sources/API2FileCore/Core/ManagedWorkspaceMountHTTPCommitClient.swift`

### FSKit extension

Implemented:

- FSKit app extension target and source
- unary filesystem entry point
- path-backed probing and volume creation
- item lookup, directory enumeration, open/close, read/write, create/remove/rename
- volume activation, mount, and basic stat support

Important files:

- `/Users/shayco/API2File/Sources/API2FileFileSystemExtension/API2FileManagedWorkspaceExtension.swift`
- `/Users/shayco/API2File/Sources/API2FileFileSystemExtension/API2FileManagedWorkspaceFileSystem.swift`
- `/Users/shayco/API2File/Sources/API2FileFileSystemExtension/Info.plist`
- `/Users/shayco/API2File/Sources/API2FileFileSystemExtension/API2FileFileSystemExtension.entitlements`

### Build/signing support

Implemented:

- build-setting-driven bundle IDs for:
  - host app
  - FS extension
  - Finder extension
- build-setting-driven app-group identifiers in entitlements/plists

Important files:

- `/Users/shayco/API2File/API2File.xcodeproj/project.pbxproj`
- `/Users/shayco/API2File/Sources/API2FileApp/API2File.entitlements`
- `/Users/shayco/API2File/Sources/FinderExtension/FinderExtension.entitlements`
- `/Users/shayco/API2File/Sources/FinderExtension/Info.plist`

## What We Tried

### 1. Directory-backed managed workspace

Result:

- works for post-save validation, restore, and rejection history
- does not fail save in the writing app

Observed UX:

- invalid save appears to succeed in editor
- file is later restored to last accepted content

This is not sufficient for the target UX.

### 2. Clean FSKit test host with unique bundle IDs

We built and installed a separate test app bundle to isolate identity conflicts:

- app bundle id: `com.shayco.api2file.fskittest`
- FS extension bundle id: `com.shayco.api2file.fskittest.filesystem-extension`

We also tested the original dev identity:

- `com.shayco.api2file.dev.filesystem-extension`

### 3. Signing and registration experiments

We tested:

- Xcode-managed signed dev build
- unique-ID builds with build-time bundle-id overrides
- unsigned build + manual signing
- extension-only registration via `pluginkit`
- host-app registration via `pluginkit`
- stripping Finder extension from the clean test host
- explicit module election with `pluginkit -e use`
- System Settings enablement for both FS extension identities

### 4. Metadata experiments

We expanded FSKit metadata in the extension plist:

- `FSActivateOptionSyntax`
- `FSCheckOptionSyntax`
- `FSFormatOptionSyntax`
- `FSMediaTypes`

We also tested multiple mount invocation forms:

- plain path source
- `file://` URL source
- option-driven source path via `-o`

## Current Status

### What works

- `managed_workspace` service mode
- accepted-state workspace materialization
- managed validation and rejection tracking
- live demo adapter bidirectional tests through API paths
- FSKit extension builds and signs
- PlugInKit can see the FS extension bundle
- System Settings can show and enable the FS extension entries

### What does not work

The actual mount still fails.

Observed failure:

```text
mount: Filesystem a2fmount does not support operation mount
mount: File system named a2fmount unable to mount
```

In earlier activation states we also saw:

```text
Module com.shayco.api2file.fskittest.filesystem-extension is disabled!
mount: Unable to invoke task
```

That disablement was resolved by enabling the extension in System Settings, but the mount still does not proceed into the working FSKit path.

## Most Important Gap

`pluginkit` and System Settings recognize the FS extension bundle, but `fskitd` does not appear to treat it as a usable mountable filesystem module.

The strongest signal from logs:

- `fskitd` reports only 2 identifiers loaded
- `fskit_agent` reports 4 identifiers loaded
- `fskitd` never reaches the usual successful flow:
  - found extension for short name
  - probe starting
  - load resource
  - launch extension

Also:

- the FS extension process never launches during the failing mount attempts
- our extension-side log lines do not appear

This means the remaining blocker is not in API2File validation logic. It is in the macOS FSKit registration/activation path.

## Likely Explanations

Most likely causes, in order:

- FSKit daemon filtering rules still reject the extension even though PlugInKit sees it
- missing or incomplete FSKit metadata contract in the extension plist
- an Apple-side provisioning / capability / registration constraint not surfaced clearly by `mount`
- current FSKit limitations or bugs on this OS/Xcode combination

Based on Apple forum guidance, FSKit is still an evolving area and there are known rough edges around mounting and integration.

Relevant Apple sources:

- `https://developer.apple.com/forums/thread/799283`
- `https://developer.apple.com/forums/thread/788609`

## How To Build

Regular dev build:

```bash
xcodebuild -project API2File.xcodeproj -scheme API2File -configuration Debug build
```

Unsigned sanity build:

```bash
xcodebuild -project API2File.xcodeproj -scheme API2File -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Unique-ID experimental build:

```bash
xcodebuild \
  -project API2File.xcodeproj \
  -scheme API2File \
  -configuration Debug \
  API2FILE_HOST_BUNDLE_IDENTIFIER=com.shayco.api2file.fskittest \
  API2FILE_FS_EXTENSION_BUNDLE_IDENTIFIER=com.shayco.api2file.fskittest.filesystem-extension \
  API2FILE_FINDER_EXTENSION_BUNDLE_IDENTIFIER=com.shayco.api2file.fskittest.finder-extension \
  API2FILE_APP_GROUP_IDENTIFIER=group.com.shayco.api2file.fskittest \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## How To Test

### Managed workspace without FSKit mount

Run focused tests:

```bash
swift test --filter 'ManagedWorkspaceIntegrationTests|ManagedWorkspaceDemoAdapterBidirectionalTests|ManagedWorkspaceManagerTests|ManagedWorkspaceFileSystemStoreTests'
```

These verify:

- managed workspace materialization
- accepted writes through the app/API path
- rejection restore behavior
- live demo server push/pull behavior

### Manual managed workspace validation

Run the app:

```bash
swift run API2FileApp
```

Use demo service in managed mode and inspect:

- `~/API2File-Workspace/demo/`
- `http://localhost:21567/api/services/demo/workspace/status`
- `http://localhost:21567/api/services/demo/workspace/rejections`

Important current limitation:

- direct editor saves in the workspace are still directory-backed behavior unless the FSKit mount works

### FSKit mount attempt

Build and install the app bundle, then try:

```bash
mount -F -t a2fmount /Users/shayco/API2File-Workspace /tmp/api2file-mounted-demo
```

Variants tested:

```bash
mount -F -t a2fmount 'file:///Users/shayco/API2File-Workspace' /tmp/api2file-mounted-demo
mount -F -t a2fmount -o '-w=/Users/shayco/API2File-Workspace' none /tmp/api2file-mounted-demo
```

Current expected result:

- mount fails
- extension process does not launch

### Log inspection

Useful commands:

```bash
pluginkit -m -A -D -v | rg 'api2file|filesystem-extension'
```

```bash
/usr/bin/log show --last 2m --predicate 'process == "fskitd" OR process == "fskit_agent"' --style compact
```

```bash
swift - <<'SWIFT'
import Foundation
import FSKit
let sem = DispatchSemaphore(value: 0)
if #available(macOS 15.4, *) {
  FSClient.shared.fetchInstalledExtensions { exts, error in
    if let error { print("ERROR: \\(error)") }
    for ext in exts ?? [] { print(String(describing: ext)) }
    sem.signal()
  }
  sem.wait()
}
SWIFT
```

Important observed mismatch:

- `pluginkit` can list the API2File FS extension
- `FSClient.fetchInstalledExtensions()` still only returns Apple built-ins in our testing

## What “Done” Would Look Like

The feature is only truly complete when all of the following are true:

- `mount -F -t a2fmount ...` succeeds
- the FSKit extension process launches
- opening files through the mounted workspace behaves like a normal filesystem surface
- invalid file saves fail immediately in the writing app
- the mounted visible file stays on the last accepted version
- API2File records the detailed validation reason separately for UI/history

## Recommended Next Steps

1. File a Feedback Assistant report with:
   - exact mount command
   - `pluginkit` output
   - `fskitd` vs `fskit_agent` log divergence
   - note that PlugInKit sees the extension but `fskitd` never reaches probe/load for it

2. Compare our extension plist against a known working third-party FSKit sample or Apple sample once available.

3. If Apple confirms a current FSKit bug/limitation, keep shipping directory-backed managed workspace for validation/rejection history and treat save-failure-in-editor as blocked on OS behavior.

## Summary

API2File now has the managed-workspace core, validation pipeline, rejection history, and FSKit extension scaffolding in place.

The remaining gap is not application logic. The remaining gap is getting macOS FSKit to actually accept and mount the API2File filesystem module so save failures can be returned synchronously to normal apps/editors.
