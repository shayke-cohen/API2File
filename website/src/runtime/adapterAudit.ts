import type { AdapterCapabilityReport, AdapterTemplate, FileFormat, ResourceConfig } from "../types.js";

const supportedFormats = new Set<FileFormat>(["csv", "json", "md", "html", "yaml", "txt"]);
const supportedPullTypes = new Set(["rest", "graphql"]);
const supportedPushTypes = new Set(["rest", "graphql"]);
const supportedPagination = new Set(["page", "offset"]);

function isLocalUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.hostname === "localhost" || parsed.hostname === "127.0.0.1";
  } catch {
    return false;
  }
}

function resourceUrls(resource: ResourceConfig): string[] {
  const urls = [resource.pull?.url, resource.push?.create?.url, resource.push?.update?.url, resource.push?.delete?.url];
  return urls.filter((value): value is string => Boolean(value));
}

function auditResource(resource: ResourceConfig): string[] {
  const notes: string[] = [];
  if (!supportedFormats.has(resource.fileMapping.format)) {
    notes.push(`${resource.name}: format ${resource.fileMapping.format} is not in Lite v1.`);
  }
  if (resource.pull?.type && !supportedPullTypes.has(resource.pull.type)) {
    notes.push(`${resource.name}: pull type ${resource.pull.type} is unsupported.`);
  }
  if (resource.push?.create?.type && !supportedPushTypes.has(resource.push.create.type)) {
    notes.push(`${resource.name}: create type ${resource.push.create.type} is unsupported.`);
  }
  if (resource.pull?.pagination?.type && !supportedPagination.has(resource.pull.pagination.type)) {
    notes.push(`${resource.name}: pagination ${resource.pull.pagination.type} needs a follow-up implementation.`);
  }
  if (resource.pull?.mediaConfig) {
    notes.push(`${resource.name}: media downloads are audit-only in Lite v1.`);
  }
  return notes;
}

export function buildAdapterCapabilityReport(template: AdapterTemplate): AdapterCapabilityReport {
  const notes = template.config.resources.flatMap(auditResource);
  const authSupported = template.config.auth.type !== "oauth2";
  if (!authSupported) {
    notes.push("OAuth2 adapters need a dedicated browser auth flow and are not yet enabled.");
  }

  const corsBlocked =
    template.config.resources.some((resource) =>
      resourceUrls(resource).some((url) => /^https?:\/\//.test(url) && !isLocalUrl(url))
    ) && template.config.auth.type !== "oauth2";

  if (corsBlocked) {
    notes.push("Cross-origin requests need live CORS verification before promising browser-native support.");
  }

  const pullSupported =
    authSupported &&
    template.config.resources.every((resource) => supportedFormats.has(resource.fileMapping.format) && (!resource.pull?.pagination?.type || supportedPagination.has(resource.pull.pagination.type)));

  const pushSupported =
    authSupported &&
    template.config.resources.every((resource) => {
      if (!resource.push) {
        return true;
      }
      return supportedFormats.has(resource.fileMapping.format) && resource.fileMapping.strategy !== "mirror";
    });

  const mediaSupported = template.config.resources.every((resource) => !resource.pull?.mediaConfig && resource.fileMapping.format !== "raw");

  return {
    adapterId: template.config.service,
    displayName: template.config.displayName,
    pullSupported,
    pushSupported,
    authSupported,
    corsBlocked,
    mediaSupported,
    notes
  };
}

export function auditAdapterTemplates(templates: AdapterTemplate[]): AdapterCapabilityReport[] {
  return templates.map(buildAdapterCapabilityReport).sort((left, right) => left.adapterId.localeCompare(right.adapterId));
}
