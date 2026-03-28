import assert from "node:assert/strict";
import test from "node:test";
import type {
  AdapterCapabilityReport,
  BrowserFileRecord,
  BrowserServiceManifest,
  SyncHistoryEntry
} from "../types.js";
import type {
  BrowserCredentialStore,
  BrowserFileSystem,
  BrowserHTTPTransport,
  BrowserHTTPTransportResponse,
  BrowserSyncStateStore,
  BrowserWorkspace,
  FolderRescanChangeDetector
} from "./interfaces.js";
import { sha256Hex } from "./hash.js";
import { HashFolderRescanChangeDetector } from "./folderRescanChangeDetector.js";
import { LiteSyncEngine } from "./syncEngine.js";

class MemoryCredentialStore implements BrowserCredentialStore {
  private readonly values = new Map<string, string>();
  async load(key: string): Promise<string | null> { return this.values.get(key) ?? null; }
  async save(key: string, value: string): Promise<void> { this.values.set(key, value); }
  async delete(key: string): Promise<void> { this.values.delete(key); }
  async clearAll(): Promise<void> { this.values.clear(); }
}

class MemoryStateStore implements BrowserSyncStateStore {
  readonly services = new Map<string, BrowserServiceManifest>();
  readonly history = new Map<string, SyncHistoryEntry[]>();
  readonly settings = new Map<string, string>();
  reports: AdapterCapabilityReport[] = [];

  async listServices(): Promise<BrowserServiceManifest[]> { return [...this.services.values()]; }
  async getService(serviceId: string): Promise<BrowserServiceManifest | null> { return this.services.get(serviceId) ?? null; }
  async saveService(manifest: BrowserServiceManifest): Promise<void> { this.services.set(manifest.serviceId, structuredClone(manifest)); }
  async deleteService(serviceId: string): Promise<void> { this.services.delete(serviceId); this.history.delete(serviceId); }
  async listHistory(serviceId?: string): Promise<SyncHistoryEntry[]> { return serviceId ? this.history.get(serviceId) ?? [] : [...this.history.values()].flat(); }
  async appendHistory(serviceId: string, entries: SyncHistoryEntry[]): Promise<void> {
    this.history.set(serviceId, [...entries, ...(this.history.get(serviceId) ?? [])]);
  }
  async saveAuditReports(reports: AdapterCapabilityReport[]): Promise<void> { this.reports = reports; }
  async loadAuditReports(): Promise<AdapterCapabilityReport[]> { return this.reports; }
  async setSetting(key: string, value: string): Promise<void> { this.settings.set(key, value); }
  async getSetting(key: string): Promise<string | null> { return this.settings.get(key) ?? null; }
}

class MemoryFileSystem implements BrowserFileSystem {
  readonly accessId = "memory";
  private readonly files = new Map<string, string>();
  readonly workspace: BrowserWorkspace = { access: { id: this.accessId, label: "memory", mode: "readwrite" } };

  async pickDirectory(): Promise<BrowserWorkspace> { return this.workspace; }
  async importSnapshot(): Promise<BrowserWorkspace> { return this.workspace; }
  async restoreDirectory(): Promise<BrowserWorkspace | null> { return this.workspace; }

  async listFiles(): Promise<BrowserFileRecord[]> {
    const records = await Promise.all(
      [...this.files.entries()].map(async ([path, value]) => ({
        path,
        name: path.split("/").pop() ?? path,
        size: value.length,
        modified: 1,
        hash: await sha256Hex(value),
        extension: path.split(".").pop() ?? "",
        writable: true,
        contentType: path.endsWith(".csv") ? "text/csv" : "application/json"
      }))
    );
    return records.sort((left, right) => left.path.localeCompare(right.path));
  }

  async readFile(_workspace: BrowserWorkspace, path: string): Promise<File> {
    return new File([this.require(path)], path.split("/").pop() ?? path, { type: "text/plain" });
  }

  async readText(_workspace: BrowserWorkspace, path: string): Promise<string> {
    return this.require(path);
  }

  async writeText(_workspace: BrowserWorkspace, path: string, value: string): Promise<void> {
    this.files.set(path, value);
  }

  seed(path: string, value: string): void {
    this.files.set(path, value);
  }

  value(path: string): string {
    return this.require(path);
  }

  private require(path: string): string {
    const value = this.files.get(path);
    if (value === undefined) {
      throw new Error(`Missing memory file: ${path}`);
    }
    return value;
  }
}

class MemoryResponse implements BrowserHTTPTransportResponse {
  constructor(
    readonly ok: boolean,
    readonly status: number,
    private readonly payload: unknown
  ) {}

  headers = new Headers();
  async text(): Promise<string> { return typeof this.payload === "string" ? this.payload : JSON.stringify(this.payload); }
  async json<T = unknown>(): Promise<T> { return this.payload as T; }
}

class DemoTransport implements BrowserHTTPTransport {
  tasks = [{ id: "1", name: "Buy milk", status: "todo" }];

  async request(input: RequestInfo | URL, init?: RequestInit): Promise<BrowserHTTPTransportResponse> {
    const url = String(input);
    const method = init?.method ?? "GET";
    if (url.endsWith("/api/tasks") && method === "GET") {
      return new MemoryResponse(true, 200, this.tasks);
    }
    if (url.endsWith("/api/tasks/1") && method === "PUT") {
      const body = JSON.parse(String(init?.body ?? "{}"));
      this.tasks = this.tasks.map((task) => (task.id === "1" ? { ...task, ...body } : task));
      return new MemoryResponse(true, 200, this.tasks[0]);
    }
    if (url.endsWith("/api/tasks") && method === "POST") {
      const body = JSON.parse(String(init?.body ?? "{}"));
      this.tasks.push(body);
      return new MemoryResponse(true, 201, body);
    }
    if (url.endsWith("/api/tasks/1") && method === "DELETE") {
      this.tasks = this.tasks.filter((task) => task.id !== "1");
      return new MemoryResponse(true, 204, {});
    }
    return new MemoryResponse(false, 404, { error: `${method} ${url}` });
  }
}

test("lite sync engine performs a demo collection pull and push round-trip", async () => {
  const fileSystem = new MemoryFileSystem();
  const stateStore = new MemoryStateStore();
  const transport = new DemoTransport();
  const engine = new LiteSyncEngine({
    fileSystem,
    credentialStore: new MemoryCredentialStore(),
    syncStateStore: stateStore,
    httpTransport: transport,
    changeDetector: new HashFolderRescanChangeDetector() as FolderRescanChangeDetector
  });

  const rawAdapterJson = JSON.stringify({
    service: "demo",
    displayName: "Demo",
    version: "1.0",
    auth: { type: "bearer", keychainKey: "demo.key" },
    resources: [
      {
        name: "tasks",
        pull: { method: "GET", url: "http://localhost:8089/api/tasks", dataPath: "$" },
        push: {
          create: { method: "POST", url: "http://localhost:8089/api/tasks" },
          update: { method: "PUT", url: "http://localhost:8089/api/tasks/{id}" },
          delete: { method: "DELETE", url: "http://localhost:8089/api/tasks/{id}" }
        },
        fileMapping: { strategy: "collection", directory: ".", filename: "tasks.csv", format: "csv", idField: "id" },
        sync: { interval: 10 }
      }
    ]
  });

  const manifest = await engine.connectService(fileSystem.workspace, JSON.parse(rawAdapterJson), rawAdapterJson, "demo-token", {});
  await engine.syncService(manifest, fileSystem.workspace);

  assert.match(fileSystem.value("demo/tasks.csv"), /Buy milk/);
  assert.match(fileSystem.value("demo/.tasks.objects.json"), /Buy milk/);

  fileSystem.seed("demo/tasks.csv", "id,name,status\n1,Buy oats,todo");
  await engine.syncService((await stateStore.getService("demo"))!, fileSystem.workspace);

  assert.equal(transport.tasks[0]?.name, "Buy oats");
  assert.match(fileSystem.value("demo/.tasks.objects.json"), /Buy oats/);
});
