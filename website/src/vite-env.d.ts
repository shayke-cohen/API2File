interface ImportMeta {
  glob<T = unknown>(
    pattern: string,
    options?: {
      eager?: boolean;
      import?: string;
      query?: string;
    }
  ): Record<string, T>;
}

interface Window {
  showDirectoryPicker?(options?: { mode?: "read" | "readwrite" }): Promise<FileSystemDirectoryHandle>;
}

interface FileSystemDirectoryHandle {
  entries(): AsyncIterableIterator<[string, FileSystemHandle]>;
}
