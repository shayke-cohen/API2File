import type {
  AdapterConfig,
  BrowserFileRecord,
  BrowserServiceManifest,
  DataRecord,
  EndpointConfig,
  ResourceConfig,
  SyncHistoryEntry,
  SyncResult
} from "../types.js";
import type {
  BrowserCredentialStore,
  BrowserFileSystem,
  BrowserHTTPTransport,
  BrowserSyncStateStore,
  BrowserWorkspace,
  FolderRescanChangeDetector
} from "./interfaces.js";
import { canonicalPathForProjectedPath, decodeRecordsFromFile, encodeRecordsForFile, projectedPathForRecord } from "./formats.js";
import { extractJsonPath } from "./jsonPath.js";

interface SyncEngineDeps {
  fileSystem: BrowserFileSystem;
  credentialStore: BrowserCredentialStore;
  syncStateStore: BrowserSyncStateStore;
  httpTransport: BrowserHTTPTransport;
  changeDetector: FolderRescanChangeDetector;
}

export class LiteSyncEngine {
  constructor(private readonly deps: SyncEngineDeps) {}

  async connectService(
    workspace: BrowserWorkspace,
    adapter: AdapterConfig,
    rawAdapterJson: string,
    credentials: string,
    setupValues: Record<string, string>
  ): Promise<BrowserServiceManifest> {
    const serviceRoot = adapter.service;
    const adapterJsonPath = `${serviceRoot}/.api2file/adapter.json`;
    await this.deps.fileSystem.writeText(workspace, adapterJsonPath, rawAdapterJson);
    await this.deps.credentialStore.save(adapter.auth.keychainKey, credentials);

    const manifest: BrowserServiceManifest = {
      serviceId: adapter.service,
      displayName: adapter.displayName,
      adapter,
      folderAccessId: workspace.access.id,
      folderAccessLabel: workspace.access.label,
      credentialsKey: adapter.auth.keychainKey,
      setupValues,
      lastConnectedAt: new Date().toISOString(),
      autoSync: true,
      syncIntervalSeconds: Math.min(...adapter.resources.map((resource) => resource.sync?.interval ?? 60)),
      fileHashes: {}
    };
    await this.deps.syncStateStore.saveService(manifest);
    await this.deps.syncStateStore.appendHistory(adapter.service, [
      this.entry("info", `Connected ${adapter.displayName} to ${workspace.access.label}.`)
    ]);
    return manifest;
  }

  async syncService(manifest: BrowserServiceManifest, workspace: BrowserWorkspace): Promise<SyncResult> {
    const beforeScan = await this.deps.fileSystem.listFiles(workspace);
    const previousHashes = Object.entries(manifest.fileHashes).map(([path, hash]) => {
      const current = beforeScan.find((entry) => entry.path === path);
      return current ? { ...current, hash } : null;
    }).filter((entry): entry is BrowserFileRecord => Boolean(entry));

    const diff = this.deps.changeDetector.diff(previousHashes, beforeScan);
    const history: SyncHistoryEntry[] = [];
    const pushedResources = await this.pushLocalChanges(manifest, workspace, diff.changed, history);
    const pulledFiles = await this.pullAllResources(manifest, workspace, history);
    const afterScan = await this.deps.fileSystem.listFiles(workspace);

    manifest.fileHashes = Object.fromEntries(afterScan.map((entry) => [entry.path, entry.hash]));
    manifest.lastSyncAt = new Date().toISOString();
    await this.deps.syncStateStore.saveService(manifest);
    await this.deps.syncStateStore.appendHistory(manifest.serviceId, history);

    return { serviceId: manifest.serviceId, pulledFiles, pushedResources, history };
  }

  private async pushLocalChanges(
    manifest: BrowserServiceManifest,
    workspace: BrowserWorkspace,
    changedFiles: BrowserFileRecord[],
    history: SyncHistoryEntry[]
  ): Promise<string[]> {
    const pushed = new Set<string>();

    for (const resource of manifest.adapter.resources) {
      const resourceChanges = changedFiles.filter((file) => this.belongsToResource(manifest.serviceId, resource, file.path));
      if (!resourceChanges.length) {
        continue;
      }
      if (resource.fileMapping.strategy !== "collection") {
        history.push(this.entry("warn", `Lite push currently prioritizes collection resources; skipped ${resource.name}.`));
        continue;
      }
      if (!resource.push) {
        continue;
      }

      const projectedPath = `${manifest.serviceId}/${projectedPathForRecord(resource.fileMapping, {})}`;
      const canonicalPath = `${manifest.serviceId}/${canonicalPathForProjectedPath(resource.fileMapping, projectedPathForRecord(resource.fileMapping, {}))}`;
      const sourcePath = resourceChanges.some((file) => file.path === projectedPath) ? projectedPath : canonicalPath;
      const rawText = await this.deps.fileSystem.readText(workspace, sourcePath);
      const previousCanonical = await this.tryReadRecords(workspace, canonicalPath);
      const localRecords = decodeRecordsFromFile(resource.fileMapping.format, rawText, resource.fileMapping, previousCanonical);
      await this.pushRecordDiff(resource, manifest.adapter, manifest.credentialsKey, previousCanonical, localRecords);
      await this.deps.fileSystem.writeText(workspace, canonicalPath, JSON.stringify(localRecords, null, 2));
      await this.deps.fileSystem.writeText(
        workspace,
        projectedPath,
        encodeRecordsForFile(resource.fileMapping.format, localRecords, resource.fileMapping)
      );
      pushed.add(resource.name);
      history.push(this.entry("info", `Pushed ${resource.name} from ${sourcePath}.`));
    }

    return Array.from(pushed);
  }

  private async pullAllResources(
    manifest: BrowserServiceManifest,
    workspace: BrowserWorkspace,
    history: SyncHistoryEntry[]
  ): Promise<string[]> {
    const pulledFiles: string[] = [];

    for (const resource of manifest.adapter.resources) {
      if (!resource.pull) {
        continue;
      }
      if (!["csv", "json", "md", "html", "yaml", "txt"].includes(resource.fileMapping.format)) {
        history.push(this.entry("warn", `Skipped ${resource.name}; format ${resource.fileMapping.format} is not enabled in Lite yet.`));
        continue;
      }

      const records = await this.fetchRecords(resource, manifest.adapter, manifest.credentialsKey);
      if (!records.length && resource.fileMapping.strategy !== "collection") {
        history.push(this.entry("warn", `No records returned for ${resource.name}.`));
      }

      if (resource.fileMapping.strategy === "collection") {
        const relativePath = projectedPathForRecord(resource.fileMapping, {});
        const projectedPath = `${manifest.serviceId}/${relativePath}`;
        const canonicalPath = `${manifest.serviceId}/${canonicalPathForProjectedPath(resource.fileMapping, relativePath)}`;
        await this.deps.fileSystem.writeText(workspace, projectedPath, encodeRecordsForFile(resource.fileMapping.format, records, resource.fileMapping));
        await this.deps.fileSystem.writeText(workspace, canonicalPath, JSON.stringify(records, null, 2));
        pulledFiles.push(projectedPath, canonicalPath);
      } else {
        for (const record of records) {
          const relativePath = projectedPathForRecord(resource.fileMapping, record);
          const projectedPath = `${manifest.serviceId}/${relativePath}`;
          const canonicalPath = `${manifest.serviceId}/${canonicalPathForProjectedPath(resource.fileMapping, relativePath)}`;
          const projectedText = encodeRecordsForFile(resource.fileMapping.format, [record], resource.fileMapping);
          await this.deps.fileSystem.writeText(workspace, projectedPath, projectedText);
          await this.deps.fileSystem.writeText(workspace, canonicalPath, JSON.stringify(record, null, 2));
          pulledFiles.push(projectedPath, canonicalPath);
        }
      }

      history.push(this.entry("info", `Pulled ${records.length} record(s) for ${resource.name}.`));
    }

    return pulledFiles;
  }

  private async fetchRecords(resource: ResourceConfig, adapter: AdapterConfig, credentialsKey: string): Promise<DataRecord[]> {
    if (!resource.pull) {
      return [];
    }

    const headers = await this.headersForAdapter(adapter, credentialsKey);
    const method = resource.pull.method ?? adapter.globals?.method ?? "GET";
    const init: RequestInit = { method, headers };

    if (resource.pull.type === "graphql") {
      init.method = "POST";
      init.body = JSON.stringify({ query: resource.pull.query ?? "" });
      headers.set("Content-Type", "application/json");
    } else if (resource.pull.body) {
      init.body = JSON.stringify(resource.pull.body);
      headers.set("Content-Type", "application/json");
    }

    const response = await this.deps.httpTransport.request(resource.pull.url, init);
    if (!response.ok) {
      throw new Error(`Pull failed for ${resource.name}: HTTP ${response.status}`);
    }

    const json = await response.json<unknown>();
    const extracted = extractJsonPath(json as never, resource.pull.dataPath);
    if (Array.isArray(extracted)) {
      return extracted as DataRecord[];
    }
    if (extracted && typeof extracted === "object") {
      return [extracted as DataRecord];
    }
    return [];
  }

  private async pushRecordDiff(
    resource: ResourceConfig,
    adapter: AdapterConfig,
    credentialsKey: string,
    previousRecords: DataRecord[],
    localRecords: DataRecord[]
  ): Promise<void> {
    if (!resource.push) {
      return;
    }

    const idField = resource.fileMapping.idField ?? "id";
    const previousById = new Map(previousRecords.map((record) => [String(record[idField] ?? ""), record]));
    const localById = new Map(localRecords.map((record) => [String(record[idField] ?? ""), record]));
    const headers = await this.headersForAdapter(adapter, credentialsKey);
    headers.set("Content-Type", "application/json");

    for (const record of localRecords) {
      const id = String(record[idField] ?? "");
      const previous = previousById.get(id);
      if (!previous) {
        await this.postEndpoint(resource.push.create, record, headers);
      } else if (JSON.stringify(previous) !== JSON.stringify(record)) {
        await this.postEndpoint(resource.push.update, record, headers);
      }
    }

    for (const record of previousRecords) {
      const id = String(record[idField] ?? "");
      if (!localById.has(id)) {
        await this.postEndpoint(resource.push.delete, record, headers);
      }
    }
  }

  private async postEndpoint(endpoint: EndpointConfig | undefined, record: DataRecord, headers: Headers): Promise<void> {
    if (!endpoint) {
      return;
    }

    const url = endpoint.url.replace(/\{([^}]+)\}/g, (_, key: string) => String(record[key] ?? ""));
    const method = endpoint.method ?? "POST";
    let body: unknown = record;
    if (endpoint.bodyWrapper) {
      body = { [endpoint.bodyWrapper]: record };
    }
    const response = await this.deps.httpTransport.request(url, {
      method,
      headers,
      body: method === "DELETE" ? undefined : JSON.stringify(body)
    });
    if (!response.ok) {
      throw new Error(`Push failed for ${url}: HTTP ${response.status}`);
    }
  }

  private async tryReadRecords(workspace: BrowserWorkspace, path: string): Promise<DataRecord[]> {
    try {
      return JSON.parse(await this.deps.fileSystem.readText(workspace, path)) as DataRecord[];
    } catch {
      return [];
    }
  }

  private belongsToResource(serviceId: string, resource: ResourceConfig, path: string): boolean {
    const baseDir = resource.fileMapping.directory === "." ? `${serviceId}/` : `${serviceId}/${resource.fileMapping.directory}/`;
    return path.startsWith(baseDir) && !path.includes("/.api2file/");
  }

  private async headersForAdapter(adapter: AdapterConfig, credentialsKey: string): Promise<Headers> {
    const headers = new Headers(adapter.globals?.headers ?? {});
    const credential = await this.deps.credentialStore.load(credentialsKey);
    if (credential) {
      switch (adapter.auth.type) {
        case "bearer":
        case "oauth2":
          headers.set("Authorization", `Bearer ${credential}`);
          break;
        case "apiKey":
          headers.set("Authorization", credential);
          break;
        case "basic":
          headers.set("Authorization", `Basic ${credential}`);
          break;
      }
    }
    return headers;
  }

  private entry(level: SyncHistoryEntry["level"], message: string): SyncHistoryEntry {
    return { timestamp: new Date().toISOString(), level, message };
  }
}
