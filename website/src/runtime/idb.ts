const DB_NAME = "api2file-lite";
const DB_VERSION = 1;

type UpgradeDb = IDBDatabase;
type StoreMemory = Map<IDBValidKey, unknown>;

const memoryStores = new Map<string, StoreMemory>();

function memoryStore(storeName: string): StoreMemory {
  let store = memoryStores.get(storeName);
  if (!store) {
    store = new Map<IDBValidKey, unknown>();
    memoryStores.set(storeName, store);
  }
  return store;
}

function requestToPromise<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("IndexedDB request failed"));
  });
}

export async function openLiteDb(): Promise<UpgradeDb> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("folders")) {
        db.createObjectStore("folders", { keyPath: "id" });
      }
      if (!db.objectStoreNames.contains("credentials")) {
        db.createObjectStore("credentials", { keyPath: "key" });
      }
      if (!db.objectStoreNames.contains("services")) {
        db.createObjectStore("services", { keyPath: "serviceId" });
      }
      if (!db.objectStoreNames.contains("history")) {
        db.createObjectStore("history", { keyPath: "serviceId" });
      }
      if (!db.objectStoreNames.contains("audit")) {
        db.createObjectStore("audit", { keyPath: "key" });
      }
      if (!db.objectStoreNames.contains("settings")) {
        db.createObjectStore("settings", { keyPath: "key" });
      }
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Failed to open IndexedDB"));
  });
}

async function withDbFallback<T>(
  storeName: string,
  indexedDbOperation: (db: UpgradeDb) => Promise<T>,
  memoryOperation: (store: StoreMemory) => T | Promise<T>
): Promise<T> {
  try {
    const db = await openLiteDb();
    return await indexedDbOperation(db);
  } catch (error) {
    console.warn(`IndexedDB unavailable for ${storeName}; falling back to in-memory storage.`, error);
    return memoryOperation(memoryStore(storeName));
  }
}

export async function getRecord<T>(storeName: string, key: IDBValidKey): Promise<T | null> {
  return withDbFallback(
    storeName,
    async (db) => {
      const tx = db.transaction(storeName, "readonly");
      const record = await requestToPromise<T | undefined>(tx.objectStore(storeName).get(key));
      return record ?? null;
    },
    (store) => (store.get(key) as T | undefined) ?? null
  );
}

export async function putRecord<T>(storeName: string, value: T): Promise<void> {
  await withDbFallback(
    storeName,
    async (db) => {
      const tx = db.transaction(storeName, "readwrite");
      tx.objectStore(storeName).put(value);
      await new Promise<void>((resolve, reject) => {
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error ?? new Error(`Failed to write ${storeName}`));
      });
    },
    (store) => {
      const key = extractKey(value);
      store.set(key, value);
    }
  );
}

export async function deleteRecord(storeName: string, key: IDBValidKey): Promise<void> {
  await withDbFallback(
    storeName,
    async (db) => {
      const tx = db.transaction(storeName, "readwrite");
      tx.objectStore(storeName).delete(key);
      await new Promise<void>((resolve, reject) => {
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error ?? new Error(`Failed to delete ${storeName}`));
      });
    },
    (store) => {
      store.delete(key);
    }
  );
}

export async function listRecords<T>(storeName: string): Promise<T[]> {
  return withDbFallback(
    storeName,
    async (db) => {
      const tx = db.transaction(storeName, "readonly");
      return requestToPromise<T[]>(tx.objectStore(storeName).getAll());
    },
    (store) => Array.from(store.values()) as T[]
  );
}

function extractKey(value: unknown): IDBValidKey {
  if (!value || typeof value !== "object") {
    throw new Error("Cannot persist value without an object key.");
  }

  for (const keyField of ["id", "key", "serviceId"]) {
    const candidate = (value as Record<string, unknown>)[keyField];
    if (typeof candidate === "string" || typeof candidate === "number" || candidate instanceof Date) {
      return candidate;
    }
  }

  throw new Error("Cannot infer key for in-memory fallback storage.");
}
