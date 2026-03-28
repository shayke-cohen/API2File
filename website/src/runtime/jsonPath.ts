import type { JsonValue } from "../types.js";

function pathSegments(path: string): string[] {
  return path
    .replace(/^\$\./, "")
    .replace(/^\$/, "")
    .split(".")
    .flatMap((segment) => segment.split(/\[(\*|\d+)\]/).filter(Boolean));
}

export function extractJsonPath(input: JsonValue, dataPath?: string): JsonValue {
  if (!dataPath || dataPath === "$") {
    return input;
  }

  let current: JsonValue = input;
  for (const segment of pathSegments(dataPath)) {
    if (segment === "*") {
      return Array.isArray(current) ? current : [];
    }
    if (Array.isArray(current)) {
      current = current[Number(segment)] as JsonValue;
    } else if (current && typeof current === "object") {
      current = (current as Record<string, JsonValue>)[segment];
    } else {
      return [];
    }
  }
  return current;
}
