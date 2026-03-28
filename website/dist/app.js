const textExtensions = new Set(["txt", "md", "markdown", "json", "yaml", "yml", "html", "htm", "svg", "csv", "ics", "vcf", "eml", "xml", "js", "css", "log"]);
const imageExtensions = new Set(["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]);
function escapeHtml(value) {
    return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
}
function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0)
        return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
        size /= 1024;
        unit += 1;
    }
    return `${size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[unit]}`;
}
function relativeTime(value) {
    if (!value)
        return "never";
    const date = new Date(value);
    if (Number.isNaN(date.getTime()))
        return "unknown";
    const diffMinutes = Math.round((Date.now() - date.getTime()) / 1000 / 60);
    if (Math.abs(diffMinutes) < 1)
        return "just now";
    return new Intl.RelativeTimeFormat(undefined, { numeric: "auto" }).format(-diffMinutes, "minute");
}
function absoluteTime(value) {
    if (!value)
        return "Unknown";
    const date = new Date(value);
    if (Number.isNaN(date.getTime()))
        return "Unknown";
    return new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short"
    }).format(date);
}
function statusLabel(status) {
    switch (status) {
        case "active":
            return "Active";
        case "syncing":
            return "Syncing";
        case "paused":
            return "Paused";
        case "error":
            return "Needs attention";
        default:
            return status;
    }
}
function statusClass(status) {
    switch (status) {
        case "active":
            return "is-active";
        case "syncing":
            return "is-syncing";
        case "paused":
            return "is-paused";
        case "error":
            return "is-error";
        default:
            return "";
    }
}
function fileKey(file) {
    return `${file.serviceId}:${file.path}`;
}
function selectedServiceFromHash() {
    const params = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    return params.get("service") ?? "";
}
function syncHash(serviceId) {
    const nextHash = serviceId ? `service=${encodeURIComponent(serviceId)}` : "";
    if (window.location.hash.replace(/^#/, "") !== nextHash) {
        window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}${nextHash ? `#${nextHash}` : ""}`);
    }
}
function serviceQuery(serviceId, showHidden) {
    const params = new URLSearchParams();
    if (serviceId)
        params.set("service", serviceId);
    if (showHidden)
        params.set("includeHidden", "true");
    return `/lite/api/files?${params.toString()}`;
}
function fileURL(serviceId, path) {
    const params = new URLSearchParams({ service: serviceId, path });
    return `/lite/api/file?${params.toString()}`;
}
async function fetchJSON(url, init) {
    const response = await fetch(url, init);
    if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Request failed with status ${response.status}`);
    }
    return response.json();
}
function previewKind(file, contentType) {
    const ext = file.extension.toLowerCase();
    if (ext === "vcf")
        return "contact";
    if (ext === "ics")
        return "calendar";
    if (ext === "eml")
        return "email";
    if (ext === "webloc" || ext === "url")
        return "link";
    if (contentType.startsWith("image/") || imageExtensions.has(ext))
        return "image";
    if (ext === "pdf" || contentType === "application/pdf")
        return "pdf";
    if (ext === "html" || ext === "htm")
        return "html";
    if (ext === "md" || ext === "markdown")
        return "markdown";
    if (ext === "csv")
        return "csv";
    if (ext === "json")
        return "json";
    if (textExtensions.has(ext) || contentType.startsWith("text/"))
        return "text";
    return "binary";
}
function filteredFiles(state) {
    const query = state.search.trim().toLowerCase();
    return state.files.filter((file) => {
        if (!query)
            return true;
        return [file.displayName, file.serviceId, file.path, file.name, file.extension]
            .some((value) => value.toLowerCase().includes(query));
    });
}
function activeFile(state) {
    return state.files.find((file) => fileKey(file) === state.activeKey);
}
function currentDirectory(file) {
    if (!file?.path.includes("/"))
        return "";
    return file.path.slice(0, file.path.lastIndexOf("/") + 1);
}
function currentWriteService(state) {
    if (state.selectedService) {
        return state.services.find((service) => service.serviceId === state.selectedService);
    }
    const active = activeFile(state);
    if (active) {
        return state.services.find((service) => service.serviceId === active.serviceId);
    }
    if (state.services.length === 1) {
        return state.services[0];
    }
    return undefined;
}
function canEditFile(file, preview) {
    return Boolean(file?.editable && preview?.text !== undefined);
}
function effectiveWorkspaceMode(state) {
    const file = activeFile(state);
    if (!file || !state.preview) {
        return "browse";
    }
    if (state.workspaceMode === "edit" && !canEditFile(file, state.preview)) {
        return "preview";
    }
    return state.workspaceMode;
}
function revokePreview(preview) {
    if (preview?.objectURL) {
        URL.revokeObjectURL(preview.objectURL);
    }
}
function editorLabel(kind) {
    switch (kind) {
        case "json":
            return "JSON Source";
        case "markdown":
            return "Markdown Source";
        case "html":
            return "HTML Source";
        case "csv":
            return "CSV Source";
        case "contact":
            return "Contact Card Source";
        case "calendar":
            return "Calendar Source";
        case "email":
            return "Email Source";
        case "link":
            return "Link Source";
        default:
            return "Source";
    }
}
function lineCount(text) {
    return text ? text.split(/\r?\n/).length : 0;
}
function wordCount(text) {
    const trimmed = text.trim();
    return trimmed ? trimmed.split(/\s+/).length : 0;
}
function topLevelEntries(value) {
    if (Array.isArray(value)) {
        return value.slice(0, 12).map((entry, index) => [String(index), entry]);
    }
    if (value && typeof value === "object") {
        return Object.entries(value).slice(0, 12);
    }
    return [];
}
function valuePreview(value) {
    if (value === null)
        return "null";
    if (value === undefined)
        return "undefined";
    if (typeof value === "string")
        return value.length > 120 ? `${value.slice(0, 117)}...` : value;
    if (typeof value === "number" || typeof value === "boolean")
        return String(value);
    if (Array.isArray(value))
        return `Array (${value.length})`;
    if (typeof value === "object")
        return `Object (${Object.keys(value).length})`;
    return String(value);
}
function renderSummaryPairs(pairs) {
    const visiblePairs = pairs.filter(([, value]) => value.trim().length > 0);
    if (!visiblePairs.length) {
        return `<div class="empty-note">No structured details were extracted.</div>`;
    }
    return `
    <dl class="summary-grid">
      ${visiblePairs.map(([label, value]) => `
        <div class="summary-item">
          <dt>${escapeHtml(label)}</dt>
          <dd>${escapeHtml(value)}</dd>
        </div>
      `).join("")}
    </dl>
  `;
}
function markdownToHtml(markdown) {
    let html = escapeHtml(markdown);
    html = html.replace(/^### (.+)$/gm, "<h3>$1</h3>");
    html = html.replace(/^## (.+)$/gm, "<h2>$1</h2>");
    html = html.replace(/^# (.+)$/gm, "<h1>$1</h1>");
    html = html.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
    html = html.replace(/\*(.+?)\*/g, "<em>$1</em>");
    html = html.replace(/`(.+?)`/g, "<code>$1</code>");
    html = html.replace(/^- (.+)$/gm, "<li>$1</li>");
    html = html.replace(/(<li>.*<\/li>)/gs, "<ul>$1</ul>");
    return html
        .split(/\n{2,}/)
        .map((chunk) => (/^<h\d|^<ul>/.test(chunk) ? chunk : `<p>${chunk.replace(/\n/g, "<br>")}</p>`))
        .join("");
}
function parseCsv(text) {
    return text
        .trim()
        .split(/\r?\n/)
        .filter(Boolean)
        .map((line) => line.split(",").map((cell) => cell.trim()));
}
function renderCsvPreview(text) {
    const rows = parseCsv(text);
    if (!rows.length) {
        return `<div class="empty-note">No rows to preview.</div>`;
    }
    const headers = rows[0];
    const body = rows.slice(1, 13);
    return `
    <div class="section-stack">
      <div class="preview-stats">
        <div class="mini-metric"><span>Rows</span><strong>${rows.length}</strong></div>
        <div class="mini-metric"><span>Columns</span><strong>${headers.length}</strong></div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>${headers.map((header) => `<th>${escapeHtml(header)}</th>`).join("")}</tr>
          </thead>
          <tbody>
            ${body.map((row) => `<tr>${headers.map((_, index) => `<td>${escapeHtml(row[index] ?? "")}</td>`).join("")}</tr>`).join("")}
          </tbody>
        </table>
      </div>
    </div>
  `;
}
function unfoldStructuredLines(text) {
    const input = text.replace(/\r/g, "").split("\n");
    const lines = [];
    for (const line of input) {
        if ((line.startsWith(" ") || line.startsWith("\t")) && lines.length) {
            lines[lines.length - 1] += line.trim();
        }
        else {
            lines.push(line);
        }
    }
    return lines;
}
function parseStructuredMap(text) {
    const result = {};
    for (const line of unfoldStructuredLines(text)) {
        const separator = line.indexOf(":");
        if (separator === -1)
            continue;
        const rawKey = line.slice(0, separator).split(";")[0].trim().toUpperCase();
        const value = line.slice(separator + 1).trim();
        if (!rawKey || !value)
            continue;
        result[rawKey] ??= [];
        result[rawKey].push(value);
    }
    return result;
}
function parseEmail(text) {
    const separator = text.search(/\r?\n\r?\n/);
    const headerText = separator === -1 ? text : text.slice(0, separator);
    const body = separator === -1 ? "" : text.slice(separator).trim();
    const headers = {};
    let activeHeader = "";
    for (const rawLine of headerText.replace(/\r/g, "").split("\n")) {
        if (rawLine.startsWith(" ") || rawLine.startsWith("\t")) {
            if (activeHeader) {
                headers[activeHeader] = `${headers[activeHeader]} ${rawLine.trim()}`.trim();
            }
            continue;
        }
        const separatorIndex = rawLine.indexOf(":");
        if (separatorIndex === -1)
            continue;
        activeHeader = rawLine.slice(0, separatorIndex).trim();
        headers[activeHeader] = rawLine.slice(separatorIndex + 1).trim();
    }
    return { headers, body };
}
function parseLinkURL(text) {
    const direct = text.match(/https?:\/\/[^\s<"]+/i)?.[0];
    if (direct)
        return direct;
    const plist = text.match(/<key>URL<\/key>\s*<string>(.*?)<\/string>/is)?.[1];
    return plist?.trim() ?? "";
}
function renderJsonPanel(text) {
    try {
        const value = JSON.parse(text);
        const entries = topLevelEntries(value);
        const type = Array.isArray(value) ? "Array" : value && typeof value === "object" ? "Object" : typeof value;
        return `
      <div class="section-stack">
        <div class="preview-stats">
          <div class="mini-metric"><span>Type</span><strong>${escapeHtml(type)}</strong></div>
          <div class="mini-metric"><span>Entries</span><strong>${entries.length}</strong></div>
          <div class="mini-metric"><span>Chars</span><strong>${text.length}</strong></div>
        </div>
        ${entries.length ? `
          <div class="struct-table">
            ${entries.map(([key, value]) => `
              <div class="struct-row">
                <div class="struct-key">${escapeHtml(key)}</div>
                <div class="struct-value">${escapeHtml(valuePreview(value))}</div>
              </div>
            `).join("")}
          </div>
        ` : `<div class="empty-note">This file contains a scalar JSON value.</div>`}
      </div>
    `;
    }
    catch (error) {
        return `<div class="empty-note">JSON parse error: ${escapeHtml(error instanceof Error ? error.message : String(error))}</div>`;
    }
}
function renderContactPanel(text) {
    const map = parseStructuredMap(text);
    return `
    <div class="section-stack">
      ${renderSummaryPairs([
        ["Name", map.FN?.[0] ?? map.N?.[0] ?? ""],
        ["Email", map.EMAIL?.[0] ?? ""],
        ["Phone", map.TEL?.[0] ?? ""],
        ["Organization", map.ORG?.[0] ?? ""],
        ["Title", map.TITLE?.[0] ?? ""],
        ["Address", map.ADR?.[0]?.replaceAll(";", ", ") ?? ""]
    ])}
    </div>
  `;
}
function renderCalendarPanel(text) {
    const map = parseStructuredMap(text);
    return `
    <div class="section-stack">
      ${renderSummaryPairs([
        ["Summary", map.SUMMARY?.[0] ?? ""],
        ["Start", map.DTSTART?.[0] ?? ""],
        ["End", map.DTEND?.[0] ?? ""],
        ["Location", map.LOCATION?.[0] ?? ""],
        ["Description", map.DESCRIPTION?.[0] ?? ""]
    ])}
    </div>
  `;
}
function renderEmailPanel(text) {
    const email = parseEmail(text);
    return `
    <div class="section-stack">
      ${renderSummaryPairs([
        ["Subject", email.headers.Subject ?? ""],
        ["From", email.headers.From ?? ""],
        ["To", email.headers.To ?? ""],
        ["Cc", email.headers.Cc ?? ""],
        ["Date", email.headers.Date ?? ""]
    ])}
      <div class="read-card">
        <div class="panel-label">Body</div>
        <pre class="code-preview compact">${escapeHtml(email.body || "No message body.")}</pre>
      </div>
    </div>
  `;
}
function renderLinkPanel(text) {
    const url = parseLinkURL(text);
    return `
    <div class="section-stack">
      ${renderSummaryPairs([["Target", url]])}
      ${url ? `<a class="button-primary wide" href="${escapeHtml(url)}" target="_blank" rel="noreferrer">Open target</a>` : ""}
    </div>
  `;
}
function renderSourcePane(file, preview) {
    const text = preview.text ?? "";
    const stats = [
        [`${lineCount(text)} lines`, `${wordCount(text)} words`],
        [`${text.length} chars`, file.editable ? "Writable" : "Read only"]
    ];
    return `
    <section class="document-panel">
      <div class="panel-head">
        <div>
          <div class="panel-label">${escapeHtml(editorLabel(preview.kind))}</div>
          <h3>${file.editable ? "Edit in place" : "Source view"}</h3>
        </div>
        <div class="panel-inline-meta">
          ${stats.flat().map((item) => `<span>${escapeHtml(item)}</span>`).join("")}
        </div>
      </div>
      ${file.editable
        ? `<textarea class="editor" id="source-editor" data-editor spellcheck="false">${escapeHtml(text)}</textarea>`
        : `<pre class="code-preview">${escapeHtml(text)}</pre>`}
    </section>
  `;
}
function renderSourceOnlyPane(file, preview) {
    return `
    <div class="single-pane">
      ${renderSourcePane(file, preview)}
    </div>
  `;
}
function renderReviewPane(file, preview) {
    const text = preview.text ?? "";
    switch (preview.kind) {
        case "markdown":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Rendered Preview</div>
            <h3>Markdown output</h3>
          </div>
        </div>
        <div class="rendered-copy">${markdownToHtml(text)}</div>
      </section>
    `;
        case "html":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Live Preview</div>
            <h3>Browser output</h3>
          </div>
        </div>
        <iframe class="doc-preview" sandbox="allow-same-origin" srcdoc="${escapeHtml(text)}"></iframe>
      </section>
    `;
        case "csv":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Table Preview</div>
            <h3>Structured rows</h3>
          </div>
        </div>
        ${renderCsvPreview(text)}
      </section>
    `;
        case "json":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Structure</div>
            <h3>JSON inspector</h3>
          </div>
        </div>
        ${renderJsonPanel(text)}
      </section>
    `;
        case "contact":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Contact View</div>
            <h3>vCard fields</h3>
          </div>
        </div>
        ${renderContactPanel(text)}
      </section>
    `;
        case "calendar":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Event View</div>
            <h3>Calendar details</h3>
          </div>
        </div>
        ${renderCalendarPanel(text)}
      </section>
    `;
        case "email":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Message View</div>
            <h3>Email headers</h3>
          </div>
        </div>
        ${renderEmailPanel(text)}
      </section>
    `;
        case "link":
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Link View</div>
            <h3>Resolved destination</h3>
          </div>
        </div>
        ${renderLinkPanel(text)}
      </section>
    `;
        default:
            return `
      <section class="document-panel">
        <div class="panel-head">
          <div>
            <div class="panel-label">Readable Preview</div>
            <h3>Document content</h3>
          </div>
        </div>
        <pre class="code-preview">${escapeHtml(text)}</pre>
      </section>
    `;
    }
}
function renderVisualPane(file, preview) {
    switch (preview.kind) {
        case "image":
            return `
      <section class="document-panel single-visual">
        <div class="panel-head">
          <div>
            <div class="panel-label">Media Preview</div>
            <h3>Image asset</h3>
          </div>
        </div>
        <img class="media-preview" src="${escapeHtml(preview.objectURL ?? "")}" alt="${escapeHtml(file.name)}" />
      </section>
    `;
        case "pdf":
            return `
      <section class="document-panel single-visual">
        <div class="panel-head">
          <div>
            <div class="panel-label">Document Preview</div>
            <h3>PDF viewer</h3>
          </div>
        </div>
        <iframe class="doc-preview" src="${escapeHtml(preview.objectURL ?? "")}"></iframe>
      </section>
    `;
        case "binary":
            return `
      <section class="document-panel single-visual">
        <div class="panel-head">
          <div>
            <div class="panel-label">Binary Asset</div>
            <h3>Direct actions only</h3>
          </div>
        </div>
        <div class="empty-note">This file type doesn’t have an internal preview yet. Open or download it directly.</div>
      </section>
    `;
        default:
            return `
      <div class="editor-grid">
        ${renderSourcePane(file, preview)}
        ${renderReviewPane(file, preview)}
      </div>
    `;
    }
}
function renderPreviewOnlyPane(file, preview) {
    switch (preview.kind) {
        case "image":
        case "pdf":
        case "binary":
            return renderVisualPane(file, preview);
        default:
            return `
      <div class="single-pane">
        ${renderReviewPane(file, preview)}
      </div>
    `;
    }
}
async function ensurePreview(state) {
    const file = activeFile(state);
    if (!file) {
        revokePreview(state.preview);
        state.preview = null;
        return;
    }
    const key = fileKey(file);
    if (state.preview?.key === key) {
        return;
    }
    revokePreview(state.preview);
    const response = await fetch(fileURL(file.serviceId, file.path));
    if (!response.ok) {
        throw new Error(`Failed to load ${file.path}`);
    }
    const contentType = response.headers.get("Content-Type") ?? "application/octet-stream";
    const kind = previewKind(file, contentType);
    if (kind === "image" || kind === "pdf" || kind === "binary") {
        const blob = await response.blob();
        state.preview = {
            key,
            kind,
            contentType,
            objectURL: URL.createObjectURL(blob)
        };
        return;
    }
    state.preview = {
        key,
        kind,
        contentType,
        text: await response.text()
    };
}
function setNotice(state, tone, message) {
    state.noticeTone = tone;
    state.notice = message;
}
async function withBusy(state, message, work) {
    state.busyMessage = message;
    render(state);
    try {
        await work();
    }
    finally {
        state.busyMessage = "";
        render(state);
    }
}
async function refresh(state, keepSelection = true) {
    const services = await fetchJSON("/lite/api/services");
    state.services = services;
    const requestedService = selectedServiceFromHash();
    if (requestedService && services.some((service) => service.serviceId === requestedService)) {
        state.selectedService = requestedService;
    }
    else if (state.selectedService && !services.some((service) => service.serviceId === state.selectedService)) {
        state.selectedService = "";
    }
    syncHash(state.selectedService);
    const nextFiles = await fetchJSON(serviceQuery(state.selectedService, state.showHidden));
    const previousKey = keepSelection ? state.activeKey : "";
    state.files = nextFiles;
    if (!nextFiles.some((file) => fileKey(file) === previousKey)) {
        state.activeKey = nextFiles[0] ? fileKey(nextFiles[0]) : "";
    }
    try {
        await ensurePreview(state);
    }
    catch (error) {
        state.preview = null;
        setNotice(state, "error", error instanceof Error ? error.message : String(error));
    }
    render(state);
}
function renderNotice(state) {
    if (!state.notice && !state.busyMessage)
        return "";
    const tone = state.busyMessage ? "info" : state.noticeTone;
    const message = state.busyMessage || state.notice;
    return `<div class="notice ${tone}">${escapeHtml(message)}</div>`;
}
function renderServiceRail(state) {
    const serviceItems = [
        `
      <button class="service-row ${!state.selectedService ? "active" : ""}" data-action="select-service" data-service-id="">
        <div class="service-row-main">
          <div class="service-name">All services</div>
          <div class="service-meta">${state.services.length} connected sources</div>
        </div>
        <div class="service-badge">${filteredFiles(state).length}</div>
      </button>
    `
    ];
    for (const service of state.services) {
        serviceItems.push(`
      <button class="service-row ${state.selectedService === service.serviceId ? "active" : ""}" data-action="select-service" data-service-id="${escapeHtml(service.serviceId)}">
        <div class="service-row-main">
          <div class="service-name">${escapeHtml(service.displayName)}</div>
          <div class="service-meta">${escapeHtml(service.fileCount.toString())} files · ${escapeHtml(relativeTime(service.lastSyncTime))}</div>
        </div>
        <span class="status-dot ${statusClass(service.status)}">${escapeHtml(statusLabel(service.status))}</span>
      </button>
    `);
    }
    return `
    <section class="rail-panel">
      <div class="panel-label">Services</div>
      <h2>Workspace</h2>
      <p class="muted-copy">Navigate between synced sources, keep actions scoped, and jump into files without leaving the browser.</p>
      <div class="service-list">${serviceItems.join("")}</div>
    </section>
  `;
}
function renderFileBrowser(state) {
    const files = filteredFiles(state);
    const active = activeFile(state);
    const mode = effectiveWorkspaceMode(state);
    if (!files.length) {
        return `
      <section class="browser-shell">
        <div class="browser-head">
          <div>
            <div class="panel-label">Files</div>
            <h2>Nothing visible</h2>
          </div>
        </div>
        <div class="empty-note spacious">Try another service, clear the search, or reveal hidden internals.</div>
      </section>
    `;
    }
    return `
    <section class="browser-shell">
      <div class="browser-head">
        <div>
          <div class="panel-label">Files</div>
          <h2>${escapeHtml(state.selectedService ? (state.services.find((item) => item.serviceId === state.selectedService)?.displayName ?? state.selectedService) : "All services")}</h2>
        </div>
        <div class="browser-summary">
          <span>${files.length} visible</span>
          <span>${active ? escapeHtml(active.name) : "No selection"}</span>
          <span>${escapeHtml(mode)}</span>
        </div>
      </div>

      <div class="file-grid-header">
        <span>Name</span>
        <span>Location</span>
        <span>Type</span>
        <span>Size</span>
        <span>Updated</span>
      </div>

      <div class="file-grid">
        ${files.map((file) => `
          <button class="file-row ${state.activeKey === fileKey(file) ? "active" : ""}" data-action="select-file" data-service-id="${escapeHtml(file.serviceId)}" data-path="${escapeHtml(file.path)}">
            <span class="file-primary">
              <strong>${escapeHtml(file.name)}</strong>
              <small>${escapeHtml(file.displayName)}</small>
            </span>
            <span class="file-location">${escapeHtml(currentDirectory(file) || "Root")}</span>
            <span class="file-type">${escapeHtml((file.extension || "file").toUpperCase())}</span>
            <span class="file-size">${escapeHtml(formatBytes(file.size))}</span>
            <span class="file-updated">${escapeHtml(relativeTime(file.modifiedAt))}</span>
          </button>
        `).join("")}
      </div>
    </section>
  `;
}
function renderOverview(state) {
    return `
    <section class="empty-workspace">
      <div class="panel-label">Inspector</div>
      <h2>Select a file</h2>
      <p class="muted-copy">The right-hand pane becomes a live inspector with a type-aware preview and editor once you choose a file.</p>
      <div class="hint-grid">
        <div class="hint-card"><strong>Markdown / HTML</strong><span>Split source and live preview.</span></div>
        <div class="hint-card"><strong>JSON / CSV</strong><span>Structured viewer beside the source editor.</span></div>
        <div class="hint-card"><strong>VCF / ICS / EML</strong><span>Readable summaries for contacts, events, and mail files.</span></div>
      </div>
    </section>
  `;
}
function renderDetail(state) {
    const file = activeFile(state);
    if (!file)
        return renderOverview(state);
    const preview = state.preview;
    const mode = effectiveWorkspaceMode(state);
    const showSave = preview && preview.text !== undefined && file.editable;
    const showFormat = preview?.kind === "json";
    const showEdit = canEditFile(file, preview) && mode !== "edit";
    const showPreview = mode === "edit";
    return `
    <section class="inspector-shell">
      <div class="inspector-head">
        <div>
          <div class="panel-label">Inspector</div>
          <h2>${escapeHtml(file.name)}</h2>
          <p class="inspector-subtitle">${escapeHtml(file.path)}</p>
        </div>
        <div class="detail-actions">
          <button class="button-secondary" data-action="refresh">Refresh</button>
          ${showPreview ? `<button class="button-secondary" data-action="set-mode" data-mode="preview">Preview</button>` : ""}
          ${showEdit ? `<button class="button-secondary" data-action="set-mode" data-mode="edit">Edit</button>` : ""}
          ${showFormat ? `<button class="button-secondary" data-action="format-file">Format JSON</button>` : ""}
          ${showSave ? `<button class="button-primary" data-action="save-file">Save</button>` : ""}
          <button class="button-secondary" data-action="rename-file">Rename</button>
          <button class="button-danger" data-action="delete-file">Delete</button>
          <a class="button-secondary" href="${escapeHtml(fileURL(file.serviceId, file.path))}" target="_blank" rel="noreferrer">Open Raw</a>
          <a class="button-secondary" href="${escapeHtml(fileURL(file.serviceId, file.path))}" download="${escapeHtml(file.name)}">Download</a>
        </div>
      </div>

      <div class="inspector-metrics">
        <div class="mini-metric"><span>Service</span><strong>${escapeHtml(file.displayName)}</strong></div>
        <div class="mini-metric"><span>Format</span><strong>${escapeHtml((file.extension || "file").toUpperCase())}</strong></div>
        <div class="mini-metric"><span>Size</span><strong>${escapeHtml(formatBytes(file.size))}</strong></div>
        <div class="mini-metric"><span>Modified</span><strong>${escapeHtml(absoluteTime(file.modifiedAt))}</strong></div>
      </div>

      ${preview
        ? mode === "edit"
            ? renderSourceOnlyPane(file, preview)
            : renderPreviewOnlyPane(file, preview)
        : `<div class="empty-note spacious">Loading preview…</div>`}
    </section>
  `;
}
function render(state) {
    const files = filteredFiles(state);
    const service = currentWriteService(state);
    const syncingCount = state.services.filter((item) => item.status === "syncing").length;
    const mode = effectiveWorkspaceMode(state);
    const hasActiveFile = Boolean(activeFile(state));
    const editAvailable = canEditFile(activeFile(state), state.preview);
    state.root.innerHTML = `
    <div class="page">
      <div class="app-shell">
        <header class="topbar">
          <div class="brand-block">
            <div class="brand-mark">A</div>
            <div>
              <div class="brand-label">API2File Lite</div>
              <div class="brand-subtitle">Local file workspace with browser previews and editors</div>
            </div>
          </div>
          <div class="topbar-stats">
            <div class="top-stat"><span>Services</span><strong>${state.services.length}</strong></div>
            <div class="top-stat"><span>Visible files</span><strong>${files.length}</strong></div>
            <div class="top-stat"><span>Syncing now</span><strong>${syncingCount}</strong></div>
            <div class="top-stat wide"><span>Write target</span><strong>${escapeHtml(service?.displayName ?? "Choose a service")}</strong></div>
          </div>
        </header>

        <section class="command-strip">
          <div class="command-left">
            <input class="search-input" id="search-input" type="search" value="${escapeHtml(state.search)}" placeholder="Search files, paths, services, or extensions" />
            <label class="toggle">
              <input id="hidden-toggle" type="checkbox" ${state.showHidden ? "checked" : ""} />
              <span>Show hidden internals</span>
            </label>
            <div class="mode-switch" aria-label="Workspace mode">
              <button class="mode-button ${mode === "browse" ? "active" : ""}" data-action="set-mode" data-mode="browse">Browse</button>
              <button class="mode-button ${mode === "preview" ? "active" : ""} ${hasActiveFile ? "" : "is-disabled"}" data-action="set-mode" data-mode="preview">Preview</button>
              <button class="mode-button ${mode === "edit" ? "active" : ""} ${editAvailable ? "" : "is-disabled"}" data-action="set-mode" data-mode="edit">Edit</button>
            </div>
          </div>
          <div class="command-right">
            <button class="button-secondary" data-action="refresh">Refresh</button>
            <button class="button-secondary" data-action="create-folder">New Folder</button>
            <button class="button-secondary" data-action="create-file">New Text File</button>
            <button class="button-primary" data-action="upload-file">Upload File</button>
          </div>
        </section>

        ${renderNotice(state)}

        <section class="workspace-grid mode-${mode}">
          ${mode === "browse" ? `
            <aside class="workspace-rail">
              ${renderServiceRail(state)}
            </aside>
            <section class="workspace-browser">
              ${renderFileBrowser(state)}
            </section>
          ` : ""}
          ${mode === "preview" ? `
            <section class="workspace-browser">
              ${renderFileBrowser(state)}
            </section>
            <main class="workspace-inspector">
              ${renderDetail(state)}
            </main>
          ` : ""}
          ${mode === "edit" ? `
            <main class="workspace-inspector">
              ${renderDetail(state)}
            </main>
          ` : ""}
        </section>
      </div>
    </div>
    <input id="upload-input" type="file" hidden />
  `;
}
async function createEmptyFile(state) {
    const service = currentWriteService(state);
    if (!service) {
        throw new Error("Choose a service before creating a file.");
    }
    const defaultPath = `${currentDirectory(activeFile(state))}untitled.txt`;
    const path = window.prompt("Create a text file at this path:", defaultPath)?.trim();
    if (!path)
        return;
    await fetchJSON(fileURL(service.serviceId, path), {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: ""
    });
    state.selectedService = service.serviceId;
    state.activeKey = `${service.serviceId}:${path}`;
    state.workspaceMode = "edit";
    setNotice(state, "success", `Created ${path}`);
    await refresh(state);
}
async function createFolder(state) {
    const service = currentWriteService(state);
    if (!service) {
        throw new Error("Choose a service before creating a folder.");
    }
    const defaultPath = `${currentDirectory(activeFile(state))}new-folder`;
    const path = window.prompt("Create a folder at this path:", defaultPath)?.trim();
    if (!path)
        return;
    await fetchJSON(`/lite/api/folder?${new URLSearchParams({ service: service.serviceId, path }).toString()}`, {
        method: "POST"
    });
    setNotice(state, "success", `Created ${path}`);
    await refresh(state);
}
async function uploadFile(state, file) {
    const service = currentWriteService(state);
    if (!service) {
        throw new Error("Choose a service before uploading.");
    }
    const defaultPath = `${currentDirectory(activeFile(state))}${file.name}`;
    const path = window.prompt("Upload file to this path:", defaultPath)?.trim();
    if (!path)
        return;
    const response = await fetch(fileURL(service.serviceId, path), {
        method: "POST",
        headers: { "Content-Type": file.type || "application/octet-stream" },
        body: await file.arrayBuffer()
    });
    if (!response.ok) {
        throw new Error((await response.text()) || "Upload failed");
    }
    state.selectedService = service.serviceId;
    state.activeKey = `${service.serviceId}:${path}`;
    state.workspaceMode = "preview";
    setNotice(state, "success", `Uploaded ${file.name}`);
    await refresh(state);
}
function formattedEditorText(state) {
    const editor = state.root.querySelector("[data-editor]");
    if (!editor) {
        throw new Error("There is no active editor for this file.");
    }
    return editor.value;
}
async function saveActiveFile(state) {
    const file = activeFile(state);
    if (!file || !file.editable)
        return;
    const body = formattedEditorText(state);
    const response = await fetch(fileURL(file.serviceId, file.path), {
        method: "PUT",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body
    });
    if (!response.ok) {
        throw new Error((await response.text()) || `Failed to save ${file.path}`);
    }
    state.preview = {
        key: fileKey(file),
        kind: previewKind(file, state.preview?.contentType ?? "text/plain"),
        contentType: state.preview?.contentType ?? "text/plain; charset=utf-8",
        text: body
    };
    setNotice(state, "success", `Saved ${file.path}`);
    render(state);
}
function formatActiveFile(state) {
    const file = activeFile(state);
    if (!file || state.preview?.kind !== "json")
        return;
    const editor = state.root.querySelector("[data-editor]");
    if (!editor) {
        throw new Error("There is no active editor for this file.");
    }
    const formatted = JSON.stringify(JSON.parse(editor.value), null, 2);
    state.preview = {
        key: fileKey(file),
        kind: state.preview.kind,
        contentType: state.preview.contentType,
        text: formatted
    };
    setNotice(state, "success", "Formatted JSON in the editor.");
    render(state);
}
async function renameActiveFile(state, file) {
    const nextPath = window.prompt("Rename file to:", file.path)?.trim();
    if (!nextPath || nextPath === file.path)
        return;
    const params = new URLSearchParams({
        service: file.serviceId,
        path: file.path,
        nextPath
    });
    const response = await fetch(`/lite/api/rename?${params.toString()}`, { method: "POST" });
    if (!response.ok) {
        throw new Error((await response.text()) || "Rename failed");
    }
    state.activeKey = `${file.serviceId}:${nextPath}`;
    setNotice(state, "success", `Renamed to ${nextPath}`);
    await refresh(state);
}
async function deleteActiveFile(state, file) {
    if (!window.confirm(`Delete ${file.path}?`))
        return;
    const response = await fetch(fileURL(file.serviceId, file.path), { method: "DELETE" });
    if (!response.ok) {
        throw new Error((await response.text()) || "Delete failed");
    }
    state.activeKey = "";
    state.workspaceMode = "browse";
    setNotice(state, "success", `Deleted ${file.path}`);
    await refresh(state, false);
}
function bindEvents(state) {
    state.root.addEventListener("click", (event) => {
        const target = event.target;
        if (!(target instanceof HTMLElement))
            return;
        const source = target.closest("[data-action]");
        const action = source?.dataset.action;
        const serviceId = source?.dataset.serviceId ?? "";
        const path = source?.dataset.path ?? "";
        const requestedMode = source?.dataset.mode;
        if (!action)
            return;
        const run = (message, work) => {
            withBusy(state, message, work).catch((error) => {
                setNotice(state, "error", error instanceof Error ? error.message : String(error));
                render(state);
            });
        };
        if (action === "select-service") {
            state.selectedService = serviceId;
            state.activeKey = "";
            state.workspaceMode = "browse";
            state.notice = "";
            run("Loading files…", async () => {
                await refresh(state, false);
            });
            return;
        }
        if (action === "select-file") {
            state.activeKey = `${serviceId}:${path}`;
            state.workspaceMode = "preview";
            state.notice = "";
            run("Loading preview…", async () => {
                await ensurePreview(state);
                render(state);
            });
            return;
        }
        if (action === "set-mode" && requestedMode) {
            if (requestedMode === "preview" && !activeFile(state)) {
                return;
            }
            if (requestedMode === "edit" && !canEditFile(activeFile(state), state.preview)) {
                return;
            }
            state.workspaceMode = requestedMode;
            render(state);
            return;
        }
        if (action === "refresh") {
            run("Refreshing workspace…", async () => {
                await refresh(state);
            });
        }
        else if (action === "create-file") {
            run("Creating file…", async () => {
                await createEmptyFile(state);
            });
        }
        else if (action === "create-folder") {
            run("Creating folder…", async () => {
                await createFolder(state);
            });
        }
        else if (action === "upload-file") {
            state.root.querySelector("#upload-input")?.click();
        }
        else if (action === "save-file") {
            run("Saving changes…", async () => {
                await saveActiveFile(state);
            });
        }
        else if (action === "format-file") {
            try {
                formatActiveFile(state);
            }
            catch (error) {
                setNotice(state, "error", error instanceof Error ? error.message : String(error));
                render(state);
            }
        }
        else if (action === "rename-file") {
            const file = activeFile(state);
            if (file) {
                run("Renaming file…", async () => {
                    await renameActiveFile(state, file);
                });
            }
        }
        else if (action === "delete-file") {
            const file = activeFile(state);
            if (file) {
                run("Deleting file…", async () => {
                    await deleteActiveFile(state, file);
                });
            }
        }
    });
    state.root.addEventListener("input", (event) => {
        const target = event.target;
        if (!(target instanceof HTMLInputElement))
            return;
        if (target.id === "search-input") {
            state.search = target.value;
            render(state);
        }
    });
    state.root.addEventListener("change", (event) => {
        const target = event.target;
        if (!(target instanceof HTMLInputElement))
            return;
        if (target.id === "hidden-toggle") {
            state.showHidden = target.checked;
            withBusy(state, "Reloading files…", async () => {
                await refresh(state, false);
            }).catch((error) => {
                setNotice(state, "error", error instanceof Error ? error.message : String(error));
                render(state);
            });
            return;
        }
        if (target.id === "upload-input" && target.files?.[0]) {
            const chosen = target.files[0];
            withBusy(state, "Uploading file…", async () => {
                await uploadFile(state, chosen);
            }).catch((error) => {
                setNotice(state, "error", error instanceof Error ? error.message : String(error));
                render(state);
            }).finally(() => {
                target.value = "";
            });
        }
    });
    window.addEventListener("hashchange", () => {
        const requested = selectedServiceFromHash();
        if (requested !== state.selectedService) {
            state.selectedService = requested;
            state.activeKey = "";
            withBusy(state, "Loading files…", async () => {
                await refresh(state, false);
            }).catch((error) => {
                setNotice(state, "error", error instanceof Error ? error.message : String(error));
                render(state);
            });
        }
    });
}
export async function createApp(root) {
    const state = {
        root,
        services: [],
        files: [],
        selectedService: selectedServiceFromHash(),
        activeKey: "",
        workspaceMode: "browse",
        showHidden: false,
        search: "",
        preview: null,
        busyMessage: "",
        notice: "",
        noticeTone: "info"
    };
    bindEvents(state);
    render(state);
    try {
        await withBusy(state, "Loading Lite Manager…", async () => {
            await refresh(state, false);
        });
    }
    catch (error) {
        setNotice(state, "error", error instanceof Error ? error.message : String(error));
        render(state);
    }
}
