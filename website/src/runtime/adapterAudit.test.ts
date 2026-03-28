import assert from "node:assert/strict";
import test from "node:test";
import type { AdapterTemplate } from "../types.js";
import { buildAdapterCapabilityReport } from "./adapterAudit.js";

test("adapter audit treats localhost demo as browser-friendly", () => {
  const template: AdapterTemplate = {
    sourcePath: "demo.adapter.json",
    rawJson: "{}",
    config: {
      service: "demo",
      displayName: "Demo",
      version: "1.0",
      auth: { type: "bearer", keychainKey: "demo" },
      resources: [
        {
          name: "tasks",
          pull: { url: "http://localhost:8089/api/tasks", dataPath: "$" },
          push: { create: { url: "http://localhost:8089/api/tasks" } },
          fileMapping: { strategy: "collection", directory: ".", filename: "tasks.csv", format: "csv", idField: "id" }
        }
      ]
    }
  };

  const report = buildAdapterCapabilityReport(template);
  assert.equal(report.pullSupported, true);
  assert.equal(report.pushSupported, true);
  assert.equal(report.corsBlocked, false);
});

test("adapter audit marks media-heavy adapters as limited", () => {
  const template: AdapterTemplate = {
    sourcePath: "media.adapter.json",
    rawJson: "{}",
    config: {
      service: "media",
      displayName: "Media",
      version: "1.0",
      auth: { type: "bearer", keychainKey: "media" },
      resources: [
        {
          name: "assets",
          pull: {
            url: "https://example.com/api/assets",
            mediaConfig: { urlField: "url", filenameField: "name" }
          },
          fileMapping: { strategy: "collection", directory: ".", filename: "assets.bin", format: "raw" }
        }
      ]
    }
  };

  const report = buildAdapterCapabilityReport(template);
  assert.equal(report.mediaSupported, false);
  assert.equal(report.pullSupported, false);
});
