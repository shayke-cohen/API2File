import assert from "node:assert/strict";
import test from "node:test";
import { HashFolderRescanChangeDetector } from "./folderRescanChangeDetector.js";

test("folder rescan detector reports added changed and removed files", () => {
  const detector = new HashFolderRescanChangeDetector();
  const previous = [
    { path: "demo/tasks.csv", hash: "a", name: "tasks.csv", size: 10, modified: 1, extension: "csv", writable: true, contentType: "text/csv" },
    { path: "demo/config.json", hash: "b", name: "config.json", size: 10, modified: 1, extension: "json", writable: true, contentType: "application/json" }
  ];
  const current = [
    { path: "demo/tasks.csv", hash: "c", name: "tasks.csv", size: 10, modified: 2, extension: "csv", writable: true, contentType: "text/csv" },
    { path: "demo/notes.md", hash: "d", name: "notes.md", size: 10, modified: 2, extension: "md", writable: true, contentType: "text/markdown" }
  ];

  const diff = detector.diff(previous, current);
  assert.equal(diff.changed[0].path, "demo/tasks.csv");
  assert.equal(diff.added[0].path, "demo/notes.md");
  assert.equal(diff.removed[0].path, "demo/config.json");
});
