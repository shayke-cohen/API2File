import AppKit
import WebKit

/// NSViewController managing the browser toolbar and WKWebView.
final class BrowserViewController: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    private(set) var webView: WKWebView!
    private var addressBar: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!

    /// True while a navigation is in progress (used to delay screenshots).
    private(set) var isLoading = false

    /// Called when a navigation finishes — used by WebViewBridge to resolve continuations.
    var onNavigationFinished: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // --- Toolbar ---
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        backButton = makeToolbarButton(systemSymbol: "chevron.left", action: #selector(goBackTapped))
        forwardButton = makeToolbarButton(systemSymbol: "chevron.right", action: #selector(goForwardTapped))
        reloadButton = makeToolbarButton(systemSymbol: "arrow.clockwise", action: #selector(reloadTapped))

        addressBar = NSTextField()
        addressBar.placeholderString = "Enter URL..."
        addressBar.font = .systemFont(ofSize: 13)
        addressBar.lineBreakMode = .byTruncatingTail
        addressBar.delegate = self
        addressBar.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addArrangedSubview(backButton)
        toolbar.addArrangedSubview(forwardButton)
        toolbar.addArrangedSubview(reloadButton)
        toolbar.addArrangedSubview(addressBar)

        // Address bar should fill remaining space
        addressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // --- WebView ---
        let config = BrowserWebViewDefaults.makeConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        BrowserWebViewDefaults.configure(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbar)
        root.addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 36),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        self.view = root
    }

    // MARK: - Toolbar Actions

    @objc private func goBackTapped() {
        webView.goBack()
    }

    @objc private func goForwardTapped() {
        webView.goForward()
    }

    @objc private func reloadTapped() {
        webView.reload()
    }

    // MARK: - NSTextFieldDelegate (address bar)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            var urlString = addressBar.stringValue.trimmingCharacters(in: .whitespaces)
            if !urlString.contains("://") {
                urlString = "https://\(urlString)"
            }
            if let url = URL(string: urlString) {
                webView.load(URLRequest(url: url))
            }
            return true
        }
        return false
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        updateAddressBar()
        updateNavigationButtons()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        updateAddressBar()
        updateNavigationButtons()
        onNavigationFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateNavigationButtons()
        onNavigationFinished?()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        updateNavigationButtons()
        onNavigationFinished?()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    // MARK: - Helpers

    private func updateAddressBar() {
        addressBar.stringValue = webView.url?.absoluteString ?? ""
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
    }

    private func makeToolbarButton(systemSymbol: String, action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: nil) {
            button = NSButton(image: image, target: self, action: action)
        } else {
            button = NSButton(title: systemSymbol, target: self, action: action)
        }
        button.bezelStyle = .texturedRounded
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }
}
