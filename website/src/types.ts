export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | { [key: string]: JsonValue };

export interface SetupField {
  key: string;
  label: string;
  placeholder?: string;
  templateKey: string;
  helpText?: string;
  isSecure?: boolean;
}

export interface AuthSetup {
  instructions: string;
  url?: string;
}

export type AuthType = "bearer" | "oauth2" | "apiKey" | "basic";

export interface AuthConfig {
  type: AuthType;
  keychainKey: string;
  setup?: AuthSetup;
  authorizeUrl?: string;
  tokenUrl?: string;
  refreshUrl?: string;
  scopes?: string[];
  callbackPort?: number;
}

export interface GlobalsConfig {
  baseUrl?: string;
  headers?: Record<string, string>;
  method?: string;
}

export type ApiType = "rest" | "graphql" | "media";
export type PaginationType = "cursor" | "offset" | "page" | "body";
export type MappingStrategy = "one-per-record" | "collection" | "mirror";
export type FileFormat =
  | "json"
  | "csv"
  | "html"
  | "md"
  | "yaml"
  | "txt"
  | "raw"
  | "ics"
  | "vcf"
  | "eml"
  | "svg"
  | "webloc"
  | "xlsx"
  | "docx"
  | "pptx";

export interface FormatOptions {
  sheetMapping?: string;
  columnTypes?: Record<string, string>;
  fieldMapping?: Record<string, string>;
}

export interface TransformOp {
  op: string;
  fields?: string[];
  from?: string;
  to?: string;
  path?: string;
  select?: string;
  key?: string;
  value?: string;
  wrap?: Record<string, string>;
  field?: string;
  template?: string;
}

export interface TransformConfig {
  pull?: TransformOp[];
  push?: TransformOp[];
}

export type PushMode = "auto-reverse" | "read-only" | "custom" | "passthrough";

export interface FileMappingConfig {
  strategy: MappingStrategy;
  directory: string;
  filename?: string;
  format: FileFormat;
  formatOptions?: FormatOptions;
  idField?: string;
  contentField?: string;
  readOnly?: boolean;
  preserveExtension?: boolean;
  transforms?: TransformConfig;
  pushMode?: PushMode;
  deleteFromAPI?: boolean;
}

export interface MediaConfig {
  urlField: string;
  filenameField: string;
  idField?: string;
  sizeField?: string;
  hashField?: string;
}

export interface PaginationParamNames {
  limit?: string;
  offset?: string;
  page?: string;
  cursor?: string;
}

export interface PaginationConfig {
  type: PaginationType;
  nextCursorPath?: string;
  pageSize?: number;
  maxRecords?: number;
  cursorField?: string;
  offsetField?: string;
  limitField?: string;
  queryTemplate?: string;
  paramNames?: PaginationParamNames;
}

export interface PullDetailConfig {
  method?: string;
  url: string;
  dataPath?: string;
}

export interface PullConfig {
  method?: string;
  url: string;
  type?: ApiType;
  query?: string;
  body?: JsonValue;
  dataPath?: string;
  detail?: PullDetailConfig;
  pagination?: PaginationConfig;
  mediaConfig?: MediaConfig;
  updatedSinceField?: string;
  updatedSinceBodyPath?: string;
  updatedSinceDateFormat?: string;
  supportsETag?: boolean;
}

export interface FollowupConfig {
  method?: string;
  url: string;
}

export interface EndpointConfig {
  method?: string;
  url: string;
  type?: ApiType;
  query?: string;
  mutation?: string;
  bodyWrapper?: string;
  bodyType?: string;
  contentTypeFromExtension?: boolean;
  bodyRootFields?: string[];
  followup?: FollowupConfig;
}

export interface PushConfig {
  create?: EndpointConfig;
  update?: EndpointConfig;
  delete?: EndpointConfig;
  type?: string;
  steps?: EndpointConfig[];
}

export interface SyncConfig {
  interval?: number;
  debounceMs?: number;
  fullSyncEvery?: number;
}

export interface ResourceConfig {
  name: string;
  description?: string;
  pull?: PullConfig;
  push?: PushConfig;
  fileMapping: FileMappingConfig;
  children?: ResourceConfig[];
  sync?: SyncConfig;
  siteUrl?: string;
  dashboardUrl?: string;
}

export interface AdapterConfig {
  service: string;
  displayName: string;
  version: string;
  auth: AuthConfig;
  globals?: GlobalsConfig;
  resources: ResourceConfig[];
  icon?: string;
  wizardDescription?: string;
  setupFields?: SetupField[];
  hidden?: boolean;
  enabled?: boolean;
  siteUrl?: string;
  dashboardUrl?: string;
}

export interface AdapterTemplate {
  config: AdapterConfig;
  rawJson: string;
  sourcePath: string;
}

export interface BrowserFileRecord {
  path: string;
  name: string;
  size: number;
  modified: number;
  hash: string;
  extension: string;
  writable: boolean;
  contentType: string;
}

export interface BrowserDirectoryAccess {
  id: string;
  label: string;
  mode: "readwrite" | "snapshot";
}

export interface BrowserServiceManifest {
  serviceId: string;
  displayName: string;
  adapter: AdapterConfig;
  folderAccessId: string;
  folderAccessLabel: string;
  credentialsKey: string;
  setupValues: Record<string, string>;
  lastConnectedAt: string;
  lastSyncAt?: string;
  autoSync: boolean;
  syncIntervalSeconds: number;
  fileHashes: Record<string, string>;
}

export interface SyncHistoryEntry {
  timestamp: string;
  level: "info" | "warn" | "error";
  message: string;
}

export interface AdapterCapabilityReport {
  adapterId: string;
  displayName: string;
  pullSupported: boolean;
  pushSupported: boolean;
  authSupported: boolean;
  corsBlocked: boolean;
  mediaSupported: boolean;
  notes: string[];
}

export interface SyncResult {
  serviceId: string;
  pulledFiles: string[];
  pushedResources: string[];
  history: SyncHistoryEntry[];
}

export type RecordValue = string | number | boolean | null | string[] | number[] | boolean[] | Record<string, unknown> | unknown[];
export type DataRecord = Record<string, RecordValue>;
