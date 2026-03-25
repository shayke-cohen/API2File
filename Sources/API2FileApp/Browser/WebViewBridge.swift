import AppKit
import WebKit
import API2FileCore

/// Controls the browser window and implements `BrowserControlDelegate` for the LocalServer.
@MainActor
final class WebViewBridge: ObservableObject, BrowserControlDelegate {
    private var browserWindow: NSWindow?
    private var viewController: BrowserViewController?

    private var webView: WKWebView? { viewController?.webView }

    // MARK: - Window Management

    func openBrowser() async throws {
        openWindow()
    }

    func isBrowserOpen() async -> Bool {
        browserWindow?.isVisible ?? false
    }

    func openWindow() {
        if let window = browserWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vc = BrowserViewController()
        let window = NSWindow(contentViewController: vc)
        window.title = "API2File Browser"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1024, height: 768))
        window.minSize = NSSize(width: 400, height: 300)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.viewController = vc
        self.browserWindow = window
    }

    // MARK: - Navigation

    func navigate(to url: String) async throws -> String {
        guard let webView else { throw BrowserError.windowNotOpen }
        guard let parsedURL = URL(string: url) else {
            throw BrowserError.navigationFailed("Invalid URL: \(url)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            viewController?.onNavigationFinished = {
                continuation.resume(returning: webView.url?.absoluteString ?? url)
            }
            webView.load(URLRequest(url: parsedURL))

            // Timeout after 30 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                // If the continuation hasn't been resumed yet, the closure is still set
                if self.viewController?.onNavigationFinished != nil {
                    self.viewController?.onNavigationFinished = nil
                    continuation.resume(returning: webView.url?.absoluteString ?? url)
                }
            }
        }
    }

    func goBack() async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        webView.goBack()
    }

    func goForward() async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        webView.goForward()
    }

    func reload() async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        webView.reload()
    }

    // MARK: - Screenshot

    func captureScreenshot(width: Int?, height: Int?) async throws -> Data {
        guard let webView else { throw BrowserError.windowNotOpen }

        // Wait for page to finish loading if currently navigating
        if viewController?.isLoading == true {
            try await waitForNavigationFinish()
        }

        let config = WKSnapshotConfiguration()
        if let width, let height {
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        }

        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError.evaluationFailed("Failed to encode screenshot as PNG")
        }
        return pngData
    }

    // MARK: - DOM

    func getDOM(selector: String?) async throws -> String {
        guard let webView else { throw BrowserError.windowNotOpen }
        let js: String
        if let selector {
            js = "(() => { const el = document.querySelector(\(jsStringLiteral(selector))); return el ? el.outerHTML : null; })()"
        } else {
            js = "document.documentElement.outerHTML"
        }
        let result = try await webView.evaluateJavaScript(js)
        guard let html = result as? String else {
            if selector != nil {
                throw BrowserError.elementNotFound(selector: selector!)
            }
            throw BrowserError.evaluationFailed("Failed to get DOM")
        }
        return html
    }

    // MARK: - Interaction

    func click(selector: String) async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        let js = """
        (() => {
            const el = document.querySelector(\(jsStringLiteral(selector)));
            if (!el) return 'NOT_FOUND';
            el.click();
            return 'OK';
        })()
        """
        let result = try await webView.evaluateJavaScript(js)
        if let str = result as? String, str == "NOT_FOUND" {
            throw BrowserError.elementNotFound(selector: selector)
        }
    }

    func type(selector: String, text: String) async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        let js = """
        (() => {
            const el = document.querySelector(\(jsStringLiteral(selector)));
            if (!el) return 'NOT_FOUND';
            el.focus();
            el.value = \(jsStringLiteral(text));
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'OK';
        })()
        """
        let result = try await webView.evaluateJavaScript(js)
        if let str = result as? String, str == "NOT_FOUND" {
            throw BrowserError.elementNotFound(selector: selector)
        }
    }

    func evaluateJS(_ code: String) async throws -> String {
        guard let webView else { throw BrowserError.windowNotOpen }
        do {
            let result = try await webView.evaluateJavaScript(code)
            if let str = result as? String { return str }
            if let num = result as? NSNumber { return num.stringValue }
            if result == nil { return "undefined" }
            if let data = try? JSONSerialization.data(withJSONObject: result!, options: [.fragmentsAllowed]),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: result!)
        } catch {
            throw BrowserError.evaluationFailed(error.localizedDescription)
        }
    }

    func getCurrentURL() async -> String? {
        webView?.url?.absoluteString
    }

    // MARK: - Wait

    func waitFor(selector: String, timeout: TimeInterval) async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        let startTime = Date()
        let pollInterval: TimeInterval = 0.25

        while true {
            let js = "document.querySelector(\(jsStringLiteral(selector))) !== null"
            let result = try? await webView.evaluateJavaScript(js)
            if let found = result as? Bool, found {
                return
            }
            if Date().timeIntervalSince(startTime) >= timeout {
                throw BrowserError.timeout(selector: selector, seconds: timeout)
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: - Scroll

    func scroll(direction: ScrollDirection, amount: Int?) async throws {
        guard let webView else { throw BrowserError.windowNotOpen }
        let pixels = amount ?? 300
        let js: String
        switch direction {
        case .up:    js = "window.scrollBy(0, -\(pixels))"
        case .down:  js = "window.scrollBy(0, \(pixels))"
        case .left:  js = "window.scrollBy(-\(pixels), 0)"
        case .right: js = "window.scrollBy(\(pixels), 0)"
        }
        _ = try? await webView.evaluateJavaScript(js)
    }

    // MARK: - Helpers

    private func waitForNavigationFinish() async throws {
        guard let vc = viewController, vc.isLoading else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vc.onNavigationFinished = {
                continuation.resume()
            }
            // Timeout after 30s
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if vc.onNavigationFinished != nil {
                    vc.onNavigationFinished = nil
                    continuation.resume()
                }
            }
        }
    }

    /// Escape a Swift string into a JavaScript string literal (with quotes).
    private func jsStringLiteral(_ str: String) -> String {
        let escaped = str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "'\(escaped)'"
    }
}
