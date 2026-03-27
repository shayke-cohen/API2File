# API2File Repo Guide

This repository contains the API2File product code, not just a synced data folder. Use this file as the working guide for agents and contributors operating on the codebase itself.

## Start Here

- Read [README.md](/Users/shayco/API2File/README.md) for the product surface area and main commands.
- Read [ARCHITECTURE.md](/Users/shayco/API2File/ARCHITECTURE.md) for the system model and core components.
- Read [TESTING.md](/Users/shayco/API2File/TESTING.md) before changing sync behavior, adapters, or guide generation.
- Treat [Package.swift](/Users/shayco/API2File/Package.swift) and the current source tree as the source of truth when prose docs drift.

## What This Repo Builds

- `API2FileCore`: sync engine, adapters, format converters, servers, models.
- `API2FileApp`: macOS menu bar app.
- `API2FileCLI`: `api2file` command line tool.
- `API2FileDemo`: local demo API server.
- `API2FileMCP`: MCP bridge for browser/webview control.

Key directories:

- `Sources/API2FileCore/Adapters`: adapter engine, transforms, format converters.
- `Sources/API2FileCore/Core`: sync engine, coordinator, git/keychain/network/watcher logic, guide generation.
- `Sources/API2FileCore/Resources/Adapters`: bundled `.adapter.json` configs.
- `Sources/API2FileApp/UI`: SwiftUI screens for menu bar, preferences, service detail, add-service flow.
- `Tests/API2FileCoreTests`: unit, integration, MCP, server, and end-to-end coverage.
- `demo/`: sample synced folder content and generated service guide examples.

## CLAUDE.md In This Repo

- Root [CLAUDE.md](/Users/shayco/API2File/CLAUDE.md) is a generated-style guide for an API2File sync folder, not a contributor guide for the codebase.
- Service guides like [demo/CLAUDE.md](/Users/shayco/API2File/demo/CLAUDE.md) represent what the app writes into synced service folders.
- The generation logic lives in [AgentGuideGenerator.swift](/Users/shayco/API2File/Sources/API2FileCore/Core/AgentGuideGenerator.swift).
- If you change generated guide content, also review [SyncEngine.swift](/Users/shayco/API2File/Sources/API2FileCore/Core/SyncEngine.swift) and the agent-guide-related tests referenced in [TESTING.md](/Users/shayco/API2File/TESTING.md).
- Do not treat generated `CLAUDE.md` text as authoritative for implementation details when the code says otherwise.

## Common Commands

```bash
swift build
swift test
swift run API2FileApp
swift run api2file-demo
swift run api2file help
swift run api2file sync demo
```

Useful targeted checks:

```bash
swift test --filter AgentGuide
swift test --filter AdapterEngineIntegration
swift test --filter DemoServerE2E
swift test --filter RealSyncE2E
```

## Runtime Facts

- Demo API server: `http://localhost:8089/`
- Control API: `http://localhost:21567/`
- Generated sync-folder guides currently use `CLAUDE.md` filenames.
- Service state lives under `.api2file/`; service folders are independent git repos.

## Working Agreements

- Preserve the config-driven architecture. New services should usually be expressed through adapter config and shared engine behavior, not one-off service code.
- Keep format converters bidirectional when changing encoding/decoding behavior.
- When changing sync semantics, think through pull, push, diffing, conflict handling, and generated guide text together.
- Prefer updating tests alongside behavior changes, especially for adapter parsing, sync state, guide generation, and end-to-end flows.
- If docs disagree, update the docs you touched or note the mismatch clearly in your handoff.

## Documentation Expectations

- Update [README.md](/Users/shayco/API2File/README.md) for user-visible product or command changes.
- Update [ARCHITECTURE.md](/Users/shayco/API2File/ARCHITECTURE.md) for structural or subsystem changes.
- Update [TESTING.md](/Users/shayco/API2File/TESTING.md) when test commands, coverage areas, or manual verification steps change.
- Update generated-guide logic and examples when changing how synced-folder instructions should read.
