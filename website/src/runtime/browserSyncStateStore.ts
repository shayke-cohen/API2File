import type { AdapterCapabilityReport, BrowserServiceManifest, SyncHistoryEntry } from "../types.js";
import type { BrowserSyncStateStore } from "./interfaces.js";
import { deleteRecord, getRecord, listRecords, putRecord } from "./idb.js";

interface HistoryRow {
  serviceId: string;
  entries: SyncHistoryEntry[];
}

interface AuditRow {
  key: "reports";
  reports: AdapterCapabilityReport[];
}

interface SettingRow {
  key: string;
  value: string;
}

export class IndexedDbSyncStateStore implements BrowserSyncStateStore {
  async listServices(): Promise<BrowserServiceManifest[]> {
    const services = await listRecords<BrowserServiceManifest>("services");
    return services.sort((left, right) => left.serviceId.localeCompare(right.serviceId));
  }

  async getService(serviceId: string): Promise<BrowserServiceManifest | null> {
    return getRecord<BrowserServiceManifest>("services", serviceId);
  }

  async saveService(manifest: BrowserServiceManifest): Promise<void> {
    await putRecord("services", manifest);
  }

  async deleteService(serviceId: string): Promise<void> {
    await deleteRecord("services", serviceId);
    await deleteRecord("history", serviceId);
  }

  async listHistory(serviceId?: string): Promise<SyncHistoryEntry[]> {
    if (serviceId) {
      return (await getRecord<HistoryRow>("history", serviceId))?.entries ?? [];
    }

    const rows = await listRecords<HistoryRow>("history");
    return rows.flatMap((row) => row.entries).sort((left, right) => right.timestamp.localeCompare(left.timestamp));
  }

  async appendHistory(serviceId: string, entries: SyncHistoryEntry[]): Promise<void> {
    const existing = (await getRecord<HistoryRow>("history", serviceId)) ?? { serviceId, entries: [] };
    await putRecord<HistoryRow>("history", {
      serviceId,
      entries: [...entries, ...existing.entries].slice(0, 150)
    });
  }

  async saveAuditReports(reports: AdapterCapabilityReport[]): Promise<void> {
    await putRecord<AuditRow>("audit", { key: "reports", reports });
  }

  async loadAuditReports(): Promise<AdapterCapabilityReport[]> {
    return (await getRecord<AuditRow>("audit", "reports"))?.reports ?? [];
  }

  async setSetting(key: string, value: string): Promise<void> {
    await putRecord<SettingRow>("settings", { key, value });
  }

  async getSetting(key: string): Promise<string | null> {
    return (await getRecord<SettingRow>("settings", key))?.value ?? null;
  }
}
