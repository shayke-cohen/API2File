import type { BrowserFileRecord } from "../types.js";
import type { ChangeSet, FolderRescanChangeDetector } from "./interfaces.js";

export class HashFolderRescanChangeDetector implements FolderRescanChangeDetector {
  diff(previous: BrowserFileRecord[], current: BrowserFileRecord[]): ChangeSet {
    const previousMap = new Map(previous.map((entry) => [entry.path, entry]));
    const currentMap = new Map(current.map((entry) => [entry.path, entry]));

    const added: BrowserFileRecord[] = [];
    const removed: BrowserFileRecord[] = [];
    const changed: BrowserFileRecord[] = [];

    for (const entry of current) {
      const old = previousMap.get(entry.path);
      if (!old) {
        added.push(entry);
      } else if (old.hash !== entry.hash) {
        changed.push(entry);
      }
    }

    for (const entry of previous) {
      if (!currentMap.has(entry.path)) {
        removed.push(entry);
      }
    }

    return { added, removed, changed };
  }
}
