# Inverse Transform Pipeline — Bidirectional Push via Object Files

**Date:** 2026-03-24
**Status:** Approved

## Problem

API2File transforms API responses into local files using pull transforms (`flatten`, `pick`, `omit`, `rename`, `keyBy`). When users edit those files and push back, the reverse transformation is never applied. This means edited files send malformed or incomplete data to the API (e.g., flattened fields aren't re-nested, omitted fields are lost).

## Solution

Persist raw API objects as hidden files on disk. These serve as both:

1. The raw record store for reverse-transform support on push
2. An agent-editable interface — agents edit structured JSON, the system regenerates human-friendly files and pushes

Two editing surfaces per resource:

- **User files** (e.g., `tasks.csv`, `john-doe.vcf`) — human-friendly, transformed
- **Object files** (e.g., `.tasks.objects.json`, `.objects/john-doe.json`) — raw API objects, agent-friendly

## Object File Layout

**Collection strategy:**

```text
demo/
  tasks.csv                    ← user edits (transformed)
  .tasks.objects.json          ← agent edits (raw API objects array)
```

**One-per-record strategy:**

```text
demo/contacts/
  john-doe.vcf                 ← user edits
  jane-smith.vcf
  .objects/
    john-doe.json              ← agent edits
    jane-smith.json
```

## Flows

### Pull (API → Files)

```text
API → fetch records → write object file (raw) → apply pull transforms → write user file
```

### Push — User Edits File

```text
detect file change → decode file → read object file (raw records)
  → apply inverse transforms (merge edits into raw) → push to API
  → update object file
```

### Push — Agent Edits Object File

```text
detect object file change → read raw records → push to API
  → apply pull transforms → regenerate user file
```

## Inverse Transform Operations

Applied in reverse order of pull transforms:

| Pull Op | Inverse Logic |
| ------- | ------------- |
| `rename(from, to)` | Rename `to` back to `from` (reconstruct dot-path nesting) |
| `omit(fields)` | Restore `fields` from raw object record |
| `pick(fields)` | Restore all non-`fields` keys from raw object record |
| `flatten(path, to, select)` | Take value at `to`, place back at original `path` structure |
| `keyBy(path, key, value, to)` | Convert dict back to `[{key, value}]` array at `path` |

## pushMode Config

Optional field on `FileMappingConfig`:

- `auto-reverse` — system computes inverse transforms (default when pull transforms + idField present)
- `read-only` — no push allowed
- `custom` — use explicit push transforms

## Loop Prevention

Track suppressed paths in SyncEngine. Before writing a regenerated file, add its path to `suppressedPaths`. Skip suppressed paths in file change handler, then remove them.

## Edge Cases

- **New user file (no object file):** Apply mechanical inverse transforms → push create → write object file from API response → regenerate user file with server fields
- **New record in object file:** Push create → regenerate user file
- **Deleted record:** Delete API call → remove from object file → remove user file
- **Read-only:** Push blocked for both surfaces
