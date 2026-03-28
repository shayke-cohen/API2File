import type {
  AdapterCapabilityReport,
  BrowserDirectoryAccess,
  BrowserFileRecord,
  BrowserServiceManifest,
  SyncHistoryEntry
} from "../types.js";

export interface BrowserWorkspace {
  access: BrowserDirectoryAccess;
}

export interface BrowserFileSystem {
  pickDirectory(): Promise<BrowserWorkspace>;
  importSnapshot(files: FileList): Promise<BrowserWorkspace>;
  restoreDirectory(accessId: string): Promise<BrowserWorkspace | null>;
  listFiles(workspace: BrowserWorkspace): Promise<BrowserFileRecord[]>;
  readFile(workspace: BrowserWorkspace, path: string): Promise<File>;
  readText(workspace: BrowserWorkspace, path: string): Promise<string>;
  writeText(workspace: BrowserWorkspace, path: string, value: string): Promise<void>;
}

export interface BrowserCredentialStore {
  load(key: string): Promise<string | null>;
  save(key: string, value: string): Promise<void>;
  delete(key: string): Promise<void>;
  clearAll(): Promise<void>;
}

export interface BrowserSyncStateStore {
  listServices(): Promise<BrowserServiceManifest[]>;
  getService(serviceId: string): Promise<BrowserServiceManifest | null>;
  saveService(manifest: BrowserServiceManifest): Promise<void>;
  deleteService(serviceId: string): Promise<void>;
  listHistory(serviceId?: string): Promise<SyncHistoryEntry[]>;
  appendHistory(serviceId: string, entries: SyncHistoryEntry[]): Promise<void>;
  saveAuditReports(reports: AdapterCapabilityReport[]): Promise<void>;
  loadAuditReports(): Promise<AdapterCapabilityReport[]>;
  setSetting(key: string, value: string): Promise<void>;
  getSetting(key: string): Promise<string | null>;
}

export interface BrowserHTTPTransportResponse {
  ok: boolean;
  status: number;
  headers: Headers;
  text(): Promise<string>;
  json<T = unknown>(): Promise<T>;
}

export interface BrowserHTTPTransport {
  request(input: RequestInfo | URL, init?: RequestInit): Promise<BrowserHTTPTransportResponse>;
}

export interface ChangeSet {
  added: BrowserFileRecord[];
  removed: BrowserFileRecord[];
  changed: BrowserFileRecord[];
}

export interface FolderRescanChangeDetector {
  diff(previous: BrowserFileRecord[], current: BrowserFileRecord[]): ChangeSet;
}
