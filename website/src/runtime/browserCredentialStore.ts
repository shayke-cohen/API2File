import type { BrowserCredentialStore } from "./interfaces.js";
import { deleteRecord, getRecord, listRecords, putRecord } from "./idb.js";

interface CredentialRow {
  key: string;
  value: string;
}

export class IndexedDbCredentialStore implements BrowserCredentialStore {
  async load(key: string): Promise<string | null> {
    return (await getRecord<CredentialRow>("credentials", key))?.value ?? null;
  }

  async save(key: string, value: string): Promise<void> {
    await putRecord<CredentialRow>("credentials", { key, value });
  }

  async delete(key: string): Promise<void> {
    await deleteRecord("credentials", key);
  }

  async clearAll(): Promise<void> {
    const rows = await listRecords<CredentialRow>("credentials");
    await Promise.all(rows.map((row) => deleteRecord("credentials", row.key)));
  }
}
