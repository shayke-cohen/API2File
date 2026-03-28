import type { BrowserDirectoryAccess, BrowserFileRecord } from "../types.js";
import type { BrowserFileSystem, BrowserWorkspace } from "./interfaces.js";
import { fileHash } from "./hash.js";
import { getRecord, putRecord } from "./idb.js";

interface StoredFolder {
  id: string;
  label: string;
  mode: "readwrite";
  handle: FileSystemDirectoryHandle;
}

interface SnapshotFolder {
  id: string;
  label: string;
  mode: "snapshot";
  files: Map<string, File>;
}

type WorkspaceBacking = StoredFolder | SnapshotFolder;

export class FileSystemAccessBrowserFileSystem implements BrowserFileSystem {
  private readonly backings = new Map<string, WorkspaceBacking>();

  async pickDirectory(): Promise<BrowserWorkspace> {
    if (typeof window.showDirectoryPicker !== "function") {
      throw new Error("This browser does not support choosing writable directories.");
    }

    const handle = await window.showDirectoryPicker({ mode: "readwrite" });
    const access: BrowserDirectoryAccess = {
      id: `folder:${handle.name}:${Date.now()}`,
      label: handle.name,
      mode: "readwrite"
    };
    const backing: StoredFolder = { id: access.id, label: access.label, mode: "readwrite", handle };
    await putRecord<StoredFolder>("folders", backing);
    this.backings.set(access.id, backing);
    return { access };
  }

  async importSnapshot(files: FileList): Promise<BrowserWorkspace> {
    const entries = Array.from(files);
    if (!entries.length) {
      throw new Error("Choose a folder snapshot first.");
    }

    const root = entries[0].webkitRelativePath.split("/")[0] || "snapshot";
    const access: BrowserDirectoryAccess = {
      id: `snapshot:${root}:${Date.now()}`,
      label: root,
      mode: "snapshot"
    };
    const mapped = new Map<string, File>();
    for (const file of entries) {
      const relativePath = file.webkitRelativePath.split("/").slice(1).join("/");
      if (relativePath) {
        mapped.set(relativePath, file);
      }
    }
    this.backings.set(access.id, { id: access.id, label: access.label, mode: "snapshot", files: mapped });
    return { access };
  }

  async restoreDirectory(accessId: string): Promise<BrowserWorkspace | null> {
    const cached = this.backings.get(accessId);
    if (cached) {
      return { access: cached };
    }

    const stored = await getRecord<StoredFolder>("folders", accessId);
    if (!stored) {
      return null;
    }
    this.backings.set(accessId, stored);
    return { access: stored };
  }

  async listFiles(workspace: BrowserWorkspace): Promise<BrowserFileRecord[]> {
    const backing = this.requireBacking(workspace.access.id);
    if (backing.mode === "snapshot") {
      return Promise.all(
        Array.from(backing.files.entries()).map(async ([path, file]) => this.buildFileRecord(path, file, false))
      );
    }

    const files: BrowserFileRecord[] = [];
    await this.walkDirectory(backing.handle, "", files);
    return files.sort((left, right) => left.path.localeCompare(right.path));
  }

  async readFile(workspace: BrowserWorkspace, path: string): Promise<File> {
    const backing = this.requireBacking(workspace.access.id);
    if (backing.mode === "snapshot") {
      const file = backing.files.get(path);
      if (!file) {
        throw new Error(`Missing snapshot file: ${path}`);
      }
      return file;
    }

    const handle = await this.getFileHandle(backing.handle, path);
    return handle.getFile();
  }

  async readText(workspace: BrowserWorkspace, path: string): Promise<string> {
    return (await this.readFile(workspace, path)).text();
  }

  async writeText(workspace: BrowserWorkspace, path: string, value: string): Promise<void> {
    const backing = this.requireBacking(workspace.access.id);
    if (backing.mode !== "readwrite") {
      throw new Error("Snapshot folders are read-only.");
    }

    const handle = await this.getFileHandle(backing.handle, path, true);
    const writable = await handle.createWritable();
    await writable.write(value);
    await writable.close();
  }

  private requireBacking(accessId: string): WorkspaceBacking {
    const backing = this.backings.get(accessId);
    if (!backing) {
      throw new Error("Folder access expired. Reconnect the workspace.");
    }
    return backing;
  }

  private async walkDirectory(handle: FileSystemDirectoryHandle, prefix: string, files: BrowserFileRecord[]): Promise<void> {
    for await (const [name, entry] of handle.entries()) {
      const nextPath = prefix ? `${prefix}/${name}` : name;
      if (entry.kind === "directory") {
        await this.walkDirectory(entry as FileSystemDirectoryHandle, nextPath, files);
      } else {
        files.push(await this.buildFileRecord(nextPath, await (entry as FileSystemFileHandle).getFile(), true));
      }
    }
  }

  private async buildFileRecord(path: string, file: File, writable: boolean): Promise<BrowserFileRecord> {
    const extension = path.split(".").pop()?.toLowerCase() ?? "";
    return {
      path,
      name: file.name,
      size: file.size,
      modified: file.lastModified,
      hash: await fileHash(file),
      extension,
      writable,
      contentType: file.type || "application/octet-stream"
    };
  }

  private async getFileHandle(
    root: FileSystemDirectoryHandle,
    path: string,
    create = false
  ): Promise<FileSystemFileHandle> {
    const parts = path.split("/").filter(Boolean);
    const filename = parts.pop();
    if (!filename) {
      throw new Error(`Invalid path: ${path}`);
    }

    let directory = root;
    for (const part of parts) {
      directory = await directory.getDirectoryHandle(part, { create });
    }
    return directory.getFileHandle(filename, { create });
  }
}
