import type { DataRecord } from "../types.js";

function slugify(value: string): string {
  return value
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function normalizeValue(value: unknown): string {
  if (value === null || value === undefined) {
    return "";
  }
  if (Array.isArray(value)) {
    return value.join("-");
  }
  if (typeof value === "object") {
    return JSON.stringify(value);
  }
  return String(value);
}

export function renderTemplate(template: string, record: DataRecord): string {
  return template.replace(/\{([^}|]+)(\|[^}]+)?\}/g, (_, field: string, filterBlock?: string) => {
    let value = normalizeValue(record[field]);
    const filters = filterBlock ? filterBlock.slice(1).split("|") : [];
    for (const filter of filters) {
      if (filter === "slugify") {
        value = slugify(value);
      } else if (filter === "lower") {
        value = value.toLowerCase();
      } else if (filter.startsWith("default:") && !value) {
        value = filter.slice("default:".length);
      }
    }
    return value;
  });
}
