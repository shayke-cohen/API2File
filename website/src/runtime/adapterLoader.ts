import type { AdapterConfig, AdapterTemplate } from "../types.js";

const adapterFiles = [
  "airtable.adapter.json",
  "calsync.adapter.json",
  "demo.adapter.json",
  "devops.adapter.json",
  "github.adapter.json",
  "mediamanager.adapter.json",
  "monday.adapter.json",
  "pagecraft.adapter.json",
  "peoplehub.adapter.json",
  "teamboard.adapter.json",
  "wix-demo.adapter.json",
  "wix.adapter.json"
];

export async function loadAdapterTemplates(): Promise<AdapterTemplate[]> {
  const templates = await Promise.all(
    adapterFiles.map(async (file) => {
      const sourcePath = `/Sources/API2FileCore/Resources/Adapters/${file}`;
      const response = await fetch(sourcePath);
      if (!response.ok) {
        throw new Error(`Failed to load adapter template: ${file}`);
      }
      const rawJson = await response.text();
      const config = JSON.parse(rawJson) as AdapterConfig;
      return {
        config,
        rawJson,
        sourcePath
      } satisfies AdapterTemplate;
    })
  );

  return templates
    .sort((left, right) => left.config.displayName.localeCompare(right.config.displayName));
}
