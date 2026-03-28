import type { DataRecord, FileFormat, FileMappingConfig } from "../types.js";
import { renderTemplate } from "./template.js";

function escapeCsv(value: unknown): string {
  const text = value === null || value === undefined ? "" : String(value);
  if (/[,"\n]/.test(text)) {
    return `"${text.replaceAll('"', '""')}"`;
  }
  return text;
}

export function encodeCsv(records: DataRecord[]): string {
  const headers = Array.from(new Set(records.flatMap((record) => Object.keys(record))));
  const rows = [headers.join(",")];
  for (const record of records) {
    rows.push(headers.map((header) => escapeCsv(record[header])).join(","));
  }
  return rows.join("\n");
}

export function decodeCsv(text: string): DataRecord[] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;

  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    const next = text[index + 1];
    if (quoted) {
      if (char === '"' && next === '"') {
        cell += '"';
        index += 1;
      } else if (char === '"') {
        quoted = false;
      } else {
        cell += char;
      }
    } else if (char === '"') {
      quoted = true;
    } else if (char === ",") {
      row.push(cell);
      cell = "";
    } else if (char === "\n") {
      row.push(cell);
      rows.push(row);
      row = [];
      cell = "";
    } else if (char !== "\r") {
      cell += char;
    }
  }

  if (cell.length || row.length) {
    row.push(cell);
    rows.push(row);
  }

  const [headers = [], ...body] = rows;
  return body.map((values) => {
    const record: DataRecord = {};
    headers.forEach((header, index) => {
      record[header] = values[index] ?? "";
    });
    return record;
  });
}

function encodeYamlRecord(record: DataRecord): string {
  return Object.entries(record)
    .map(([key, value]) => `${key}: ${typeof value === "object" ? JSON.stringify(value) : value ?? ""}`)
    .join("\n");
}

function decodeYamlRecord(text: string): DataRecord {
  const record: DataRecord = {};
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(/^([^:#]+):\s*(.*)$/);
    if (match) {
      record[match[1].trim()] = match[2].trim();
    }
  }
  return record;
}

export function encodeRecordsForFile(
  format: FileFormat,
  records: DataRecord[],
  mapping: FileMappingConfig
): string {
  switch (format) {
    case "csv":
      return encodeCsv(records);
    case "json":
      return JSON.stringify(records, null, 2);
    case "yaml":
      return records.map(encodeYamlRecord).join("\n---\n");
    case "txt":
      return records.map((record) => String(record[mapping.contentField ?? "content"] ?? "")).join("\n\n");
    case "md":
    case "html":
      if (mapping.strategy === "collection") {
        return records.map((record) => String(record[mapping.contentField ?? "content"] ?? "")).join("\n\n");
      }
      return String(records[0]?.[mapping.contentField ?? "content"] ?? "");
    default:
      throw new Error(`Format ${format} is not yet supported in Lite runtime.`);
  }
}

export function decodeRecordsFromFile(
  format: FileFormat,
  text: string,
  mapping: FileMappingConfig,
  previousRecords: DataRecord[] = []
): DataRecord[] {
  switch (format) {
    case "csv":
      return decodeCsv(text);
    case "json":
      return JSON.parse(text) as DataRecord[];
    case "yaml":
      return text
        .split(/\n---\n/)
        .map((chunk) => decodeYamlRecord(chunk))
        .filter((record) => Object.keys(record).length > 0);
    case "txt":
    case "md":
    case "html":
      if (mapping.strategy === "collection") {
        return [{ [mapping.contentField ?? "content"]: text }];
      }
      return [{ ...(previousRecords[0] ?? {}), [mapping.contentField ?? "content"]: text }];
    default:
      throw new Error(`Format ${format} is not yet supported in Lite runtime.`);
  }
}

export function projectedPathForRecord(mapping: FileMappingConfig, record: DataRecord): string {
  const directory = mapping.directory === "." ? "" : mapping.directory.replace(/^\/+|\/+$/g, "");
  if (mapping.strategy === "collection") {
    return directory ? `${directory}/${mapping.filename ?? "collection.json"}` : (mapping.filename ?? "collection.json");
  }
  const rendered = renderTemplate(mapping.filename ?? "{id}.json", record);
  return directory ? `${directory}/${rendered}` : rendered;
}

export function canonicalPathForProjectedPath(mapping: FileMappingConfig, projectedPath: string): string {
  const lastSlash = projectedPath.lastIndexOf("/");
  const directory = lastSlash >= 0 ? projectedPath.slice(0, lastSlash) : "";
  const filename = lastSlash >= 0 ? projectedPath.slice(lastSlash + 1) : projectedPath;
  const stem = filename.replace(/\.[^.]+$/, "");

  if (mapping.strategy === "collection") {
    return directory ? `${directory}/.${stem}.objects.json` : `.${stem}.objects.json`;
  }

  return directory ? `${directory}/.objects/${stem}.json` : `.objects/${stem}.json`;
}
