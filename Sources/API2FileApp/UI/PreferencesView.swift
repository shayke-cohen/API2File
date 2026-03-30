import SwiftUI
import API2FileCore

// MARK: - Sidebar Item

private enum SidebarItem: Hashable {
    case general
    case data
    case service(String)
    case browser
    case activity
}

// MARK: - Main Preferences View

struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selection: SidebarItem? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // General
                Label("General", systemImage: "gear")
                    .tag(SidebarItem.general)
                    .testId("sidebar-general")

                Label("Data Explorer", systemImage: "cylinder.split.1x2")
                    .tag(SidebarItem.data)
                    .testId("sidebar-data-explorer")

                // Services section
                Section("Services") {
                    ForEach(appState.services, id: \.serviceId) { service in
                        ServiceListRow(service: service)
                            .tag(SidebarItem.service(service.serviceId))
                            .testId("sidebar-service-\(service.serviceId)")
                            .contextMenu {
                                Button("Sync Now") {
                                    appState.syncService(serviceId: service.serviceId)
                                }
                                Button("Open Folder") {
                                    let url = appState.config.resolvedSyncFolder
                                        .appendingPathComponent(service.serviceId)
                                    FinderSupport.openInFinder(url)
                                }
                                Divider()
                                Button("Disconnect...", role: .destructive) {
                                    appState.removeService(serviceId: service.serviceId)
                                }
                            }
                    }
                }

                // Browser
                Label("Browser", systemImage: "globe")
                    .tag(SidebarItem.browser)
                    .testId("sidebar-browser")

                // Activity
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.activity)
                    .testId("sidebar-activity")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 6) {
                        Button {
                            appState.openAddServiceWindow()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .testId("sidebar-add-service")
                        .help("Add Service...")

                        Button {
                            if case .service(let id) = selection {
                                appState.removeService(serviceId: id)
                            }
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(!isServiceSelected)
                        .testId("sidebar-remove-service")
                        .help("Disconnect Service")

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        } detail: {
            detailView
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 500, idealHeight: 540)
        .testId("preferences-window")
    }

    private var isServiceSelected: Bool {
        if case .service = selection { return true }
        return false
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralPane(config: $appState.config, appState: appState)
        case .data:
            SQLExplorerPane(appState: appState, initialServiceId: nil)
        case .service(let id):
            if let service = appState.services.first(where: { $0.serviceId == id }) {
                ServiceDetailView(service: service, appState: appState)
            } else {
                emptyDetail
            }
        case .browser:
            BrowserPane(appState: appState)
        case .activity:
            ActivityPane(appState: appState)
        case nil:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        Text("Select an item")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General Pane

struct GeneralPane: View {
    @Binding var config: GlobalConfig

    @State private var isUpdatingAdapters = false
    @State private var adapterUpdateResult: String? = nil

    var appState: AppState? = nil

    var body: some View {
        Form {
            // Sync section
            Section {
                LabeledContent("Sync Folder") {
                    HStack(spacing: 6) {
                        TextField("", text: $config.syncFolder)
                            .testId("general-sync-folder")
                        Button("Browse…") { chooseSyncFolder() }
                            .controlSize(.small)
                    }
                }
                LabeledContent("Interval") {
                    HStack(spacing: 8) {
                        Stepper(value: $config.defaultSyncInterval, in: 10...600, step: 10) {
                            Text("\(config.defaultSyncInterval) s")
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                        .testId("general-sync-interval")
                        Text("10–600 s")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                LabeledContent("Adapters") {
                    HStack(spacing: 6) {
                        Text("~/.api2file/adapters")
                            .foregroundStyle(.secondary)

                        if let result = adapterUpdateResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .testId("general-adapters-update-result")
                        }
                        Button("Reveal") {
                            NSWorkspace.shared.open(AdapterStore.userAdaptersURL)
                        }
                        .controlSize(.small)
                        .testId("general-adapters-reveal")
                        if let appState {
                            Button(isUpdatingAdapters ? "Updating…" : "Update") {
                                Task {
                                    isUpdatingAdapters = true
                                    adapterUpdateResult = nil
                                    let count = await appState.updateInstalledAdapters()
                                    isUpdatingAdapters = false
                                    adapterUpdateResult = count > 0 ? "Updated \(count)" : "Up to date"
                                }
                            }
                            .controlSize(.small)
                            .disabled(isUpdatingAdapters)
                            .testId("general-adapters-update")
                        }
                    }
                }
            } header: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }

            // Git section
            Section {
                Toggle("Auto-commit", isOn: $config.gitAutoCommit)
                    .testId("general-git-auto-commit")
                LabeledContent("Commit format") {
                    TextField("", text: $config.commitMessageFormat)
                        .font(.system(.callout, design: .monospaced))
                        .testId("general-commit-format")
                }
            } header: {
                Label("Git", systemImage: "arrow.triangle.branch")
            }

            // App section
            Section {
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                    .testId("general-launch-at-login")
                Toggle("Notifications", isOn: $config.showNotifications)
                    .testId("general-show-notifications")
                Toggle("Finder badges", isOn: $config.finderBadges)
                    .testId("general-finder-badges")
                Toggle("Generate snapshots", isOn: $config.enableSnapshots)
                    .testId("general-enable-snapshots")
                Toggle("Generate companion Markdown files", isOn: $config.generateCompanionFiles)
                    .testId("general-generate-companion-files")
                LabeledContent("Server port") {
                    Stepper(value: $config.serverPort, in: 1024...65535) {
                        Text(String(config.serverPort))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .testId("general-server-port")
                }
            } header: {
                Label("App", systemImage: "app.badge.checkmark")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            config.syncFolder = url.path
        }
    }
}

// MARK: - Activity Pane

struct ActivityPane: View {
    @ObservedObject var appState: AppState
    @State private var serviceFilter: String? = nil
    @State private var directionFilter: SyncDirection? = nil
    @State private var allActivity: [SyncHistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 10) {
                Picker("Service", selection: $serviceFilter) {
                    Text("All Services").tag(nil as String?)
                    ForEach(appState.services, id: \.serviceId) { service in
                        Text(service.displayName).tag(service.serviceId as String?)
                    }
                }
                .frame(maxWidth: 180)
                .testId("activity-service-filter")

                Picker("Direction", selection: $directionFilter) {
                    Text("All").tag(nil as SyncDirection?)
                    Text("↓ Pull").tag(SyncDirection.pull as SyncDirection?)
                    Text("↑ Push").tag(SyncDirection.push as SyncDirection?)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
                .testId("activity-direction-filter")

                Spacer()

                Text("\(filteredActivity.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            if filteredActivity.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredActivity) { entry in
                            SyncHistoryRow(entry: entry, showServiceName: serviceFilter == nil)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 2)
                                .testId("activity-row-\(entry.id)")
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
                .testId("activity-scroll-view")
            }
        }
        .task {
            await loadActivity()
        }
        .onChange(of: serviceFilter) { _ in
            Task { await loadActivity() }
        }
        .onReceive(appState.$recentActivity) { _ in
            Task { await loadActivity() }
        }
    }

    private var filteredActivity: [SyncHistoryEntry] {
        var result = allActivity
        if let directionFilter {
            result = result.filter { $0.direction == directionFilter }
        }
        return result
    }

    private func loadActivity() async {
        if let serviceFilter {
            allActivity = await appState.getServiceHistory(serviceId: serviceFilter, limit: 100)
        } else {
            await appState.refreshHistory()
            allActivity = appState.recentActivity
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No sync activity yet")
                .font(.title3)
                .fontWeight(.medium)
            Text("Activity will appear here after\nyour first sync operation.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .testId("activity-empty-state")
    }
}

// MARK: - Service List Row

struct ServiceListRow: View {
    let service: ServiceInfo

    private var statusColor: Color {
        switch service.status {
        case .connected: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var isDisabled: Bool {
        service.config.enabled == false
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .testId("service-row-status-\(service.serviceId)")
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .testId("service-row-name-\(service.serviceId)")
                HStack(spacing: 4) {
                    if isDisabled {
                        Text("Disabled")
                    } else {
                        Text("\(service.fileCount) files")
                            .testId("service-row-count-\(service.serviceId)")
                        if let time = service.lastSyncTime {
                            Text("·")
                            Text(time, style: .relative)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer()
        }
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

// MARK: - Browser Pane

import WebKit

struct BrowserPane: View {
    @ObservedObject var appState: AppState
    @State private var urlText: String = "http://localhost:8089"

    private var webViewStore: WebViewStore { appState.sharedWebViewStore }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Button(action: { webViewStore.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!webViewStore.canGoBack)

                Button(action: { webViewStore.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!webViewStore.canGoForward)

                Button(action: { webViewStore.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }

                TextField("URL", text: $urlText, onCommit: {
                    webViewStore.navigate(to: urlText)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }
            .padding(8)

            Divider()

            // WebView
            WebViewRepresentable(store: webViewStore, onURLChange: { url in
                urlText = url
            })
        }
        .onAppear {
            // Navigate on first appear if no URL loaded yet
            if webViewStore.webView.url == nil {
                webViewStore.navigate(to: urlText)
            }
        }
        .testId("browser-pane")
    }
}

/// Observable store managing a WKWebView instance for SwiftUI embedding.
/// Also conforms to BrowserControlDelegate so MCP tools control the same WebView.
@MainActor
final class WebViewStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, BrowserControlDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    var onURLChange: ((String) -> Void)?
    private var isLoading = false
    private var navigationContinuation: CheckedContinuation<Void, Never>?

    /// Offscreen window that hosts the WebView when the Browser tab isn't visible.
    /// Required for `takeSnapshot` to work — WKWebView must be in a window hierarchy.
    /// Keep it on-screen but effectively invisible so WebKit still paints real pixels.
    private var offscreenWindow: NSWindow?

    override init() {
        let config = BrowserWebViewDefaults.makeConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        BrowserWebViewDefaults.configure(webView)

        // Attach to an offscreen window so takeSnapshot works even when Browser tab isn't open
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 80, y: 80, width: 1280, height: 900)
        let origin = NSPoint(x: screenFrame.midX - 512, y: screenFrame.midY - 384)
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 1024, height: 768)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = webView
        window.orderFrontRegardless()
        offscreenWindow = window
    }

    func navigate(to urlString: String) {
        var url = urlString
        if !url.contains("://") { url = "https://\(url)" }
        guard let parsed = URL(string: url) else { return }
        webView.load(URLRequest(url: parsed))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url?.absoluteString {
            onURLChange?(url)
        }
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        if let url = webView.url?.absoluteString {
            onURLChange?(url)
        }
    }

    // MARK: - WKUIDelegate (popup/OAuth support)

    /// Handle popup requests (OAuth login flows open new windows)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Load the popup URL in the same WebView instead of opening a new window
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// Handle JavaScript alerts
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    /// Handle JavaScript confirm dialogs
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        navigationContinuation?.resume()
        navigationContinuation = nil
    }

    // MARK: - BrowserControlDelegate

    func openBrowser() async throws { /* already open as a pane */ }
    func isBrowserOpen() async -> Bool { true }

    func navigate(to url: String) async throws -> String {
        guard let parsed = URL(string: url) else {
            throw BrowserError.navigationFailed("Invalid URL: \(url)")
        }
        webView.load(URLRequest(url: parsed))
        // Wait for navigation to finish
        await withCheckedContinuation { continuation in
            navigationContinuation = continuation
        }
        onURLChange?(webView.url?.absoluteString ?? url)
        return webView.url?.absoluteString ?? url
    }

    func goBack() async throws { webView.goBack() }
    func goForward() async throws { webView.goForward() }
    func reload() async throws { webView.reload() }

    func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
        if isLoading {
            await withCheckedContinuation { continuation in
                navigationContinuation = continuation
            }
        }

        if let offscreenWindow {
            offscreenWindow.orderFrontRegardless()
            offscreenWindow.displayIfNeeded()
        }
        webView.layoutSubtreeIfNeeded()
        webView.window?.displayIfNeeded()
        return try await WebViewCaptureSupport.capturePNG(from: webView, width: width, height: height)
    }

    func getDOM(selector: String?) async throws -> String {
        let js: String
        if let selector {
            js = "(() => { const el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))'); return el ? el.outerHTML : null; })()"
        } else {
            js = "document.documentElement.outerHTML"
        }
        let result = try await webView.evaluateJavaScript(js)
        guard let html = result as? String else {
            if selector != nil { throw BrowserError.elementNotFound(selector: selector!) }
            throw BrowserError.evaluationFailed("Failed to get DOM")
        }
        return html
    }

    func click(selector: String) async throws {
        let js = "(() => { const el = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))'); if (!el) return 'NOT_FOUND'; el.click(); return 'OK'; })()"
        let result = try await webView.evaluateJavaScript(js)
        if let str = result as? String, str == "NOT_FOUND" {
            throw BrowserError.elementNotFound(selector: selector)
        }
    }

    func type(selector: String, text: String) async throws {
        let escapedSel = selector.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
        let js = "(() => { const el = document.querySelector('\(escapedSel)'); if (!el) return 'NOT_FOUND'; el.focus(); el.value = '\(escapedText)'; el.dispatchEvent(new Event('input', {bubbles:true})); return 'OK'; })()"
        let result = try await webView.evaluateJavaScript(js)
        if let str = result as? String, str == "NOT_FOUND" {
            throw BrowserError.elementNotFound(selector: selector)
        }
    }

    func evaluateJS(_ code: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(code)
        if let str = result as? String { return str }
        if result == nil { return "undefined" }
        if let num = result as? NSNumber { return num.stringValue }
        return String(describing: result!)
    }

    func getCurrentURL() async -> String? {
        webView.url?.absoluteString
    }

    func waitFor(selector: String, timeout: TimeInterval) async throws {
        let start = Date()
        while true {
            let js = "document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))') !== null"
            let result = try? await webView.evaluateJavaScript(js)
            if let found = result as? Bool, found { return }
            if Date().timeIntervalSince(start) >= timeout {
                throw BrowserError.timeout(selector: selector, seconds: timeout)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func scroll(direction: ScrollDirection, amount: Int?) async throws {
        let px = amount ?? 300
        let js: String
        switch direction {
        case .up:    js = "window.scrollBy(0,-\(px))"
        case .down:  js = "window.scrollBy(0,\(px))"
        case .left:  js = "window.scrollBy(-\(px),0)"
        case .right: js = "window.scrollBy(\(px),0)"
        }
        _ = try? await webView.evaluateJavaScript(js)
    }
}

/// NSViewRepresentable wrapper for WKWebView in SwiftUI.
struct WebViewRepresentable: NSViewRepresentable {
    let store: WebViewStore
    var onURLChange: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        store.onURLChange = onURLChange
        return store.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
