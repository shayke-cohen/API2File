import AppKit
import WebKit
import API2FileCore

/// Controls the browser window and implements `BrowserControlDelegate` for the LocalServer.
@MainActor
final class WebViewBridge: ObservableObject, BrowserControlDelegate {
    enum PresentationMode {
        case interactive
        case hiddenSnapshot
    }

    private var browserWindow: NSWindow?
    private var viewController: BrowserViewController?
    private let presentationMode: PresentationMode

    private var webView: WKWebView? { viewController?.webView }

    init(presentationMode: PresentationMode = .interactive) {
        self.presentationMode = presentationMode
    }

    // MARK: - Window Management

    func openBrowser() async throws {
        openWindow()
    }

    func isBrowserOpen() async -> Bool {
        browserWindow?.isVisible ?? false
    }

    func openWindow() {
        if let window = browserWindow, window.isVisible {
            if presentationMode == .interactive {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window.orderFrontRegardless()
            }
            return
        }

        let vc = BrowserViewController()
        let window = makeWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false

        if presentationMode == .interactive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFrontRegardless()
        }

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
            var didResume = false
            let finish: () -> Void = { [weak self] in
                guard !didResume else { return }
                didResume = true
                self?.viewController?.onNavigationFinished = nil
                continuation.resume(returning: webView.url?.absoluteString ?? url)
            }
            viewController?.onNavigationFinished = finish
            webView.load(URLRequest(url: parsedURL))

            // Timeout after 30 seconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                finish()
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

        webView.layoutSubtreeIfNeeded()
        webView.window?.displayIfNeeded()
        if webView.url?.isFileURL == true {
            return try await WebViewCaptureSupport.capturePNG(from: webView, width: width, height: height)
        }
        return try await captureRenderedViewportPNG(from: webView, width: width, height: height)
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

    private func makeWindow(contentViewController: BrowserViewController) -> NSWindow {
        switch presentationMode {
        case .interactive:
            let window = NSWindow(contentViewController: contentViewController)
            window.title = "API2File Browser"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 1024, height: 768))
            window.minSize = NSSize(width: 400, height: 300)
            window.center()
            return window

        case .hiddenSnapshot:
            let panel = NSPanel(contentViewController: contentViewController)
            panel.title = "API2File Snapshot Browser"
            panel.styleMask = [.borderless, .nonactivatingPanel]
            panel.setContentSize(NSSize(width: 1280, height: 900))
            panel.level = .normal
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.alphaValue = 0.01
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
            if let screenFrame = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screenFrame.minX + 24, y: screenFrame.minY + 24))
            }
            return panel
        }
    }

    private func waitForNavigationFinish() async throws {
        guard let vc = viewController, vc.isLoading else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            let finish: () -> Void = {
                guard !didResume else { return }
                didResume = true
                vc.onNavigationFinished = nil
                continuation.resume()
            }
            vc.onNavigationFinished = finish
            // Timeout after 30s
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                finish()
            }
        }
    }

    private func captureRenderedViewportPNG(from webView: WKWebView, width: Int?, height: Int?) async throws -> Data {
        let viewportSize = webView.bounds.size
        let viewportWidth = max(Int(viewportSize.width.rounded(.up)), 1)
        let viewportHeight = max(Int(viewportSize.height.rounded(.up)), 1)
        let targetWidth = max(width ?? viewportWidth, 1)
        let targetHeight = max(height ?? viewportHeight, 1)

        let originalOffset = try? await evaluateJS("window.pageYOffset.toString()")
        let firstSegment = try captureCurrentWebViewBitmap(webView)
        let scaleX = CGFloat(firstSegment.pixelsWide) / max(viewportSize.width, 1)
        let scaleY = CGFloat(firstSegment.pixelsHigh) / max(viewportSize.height, 1)
        let targetWidthPixels = max(Int((CGFloat(targetWidth) * scaleX).rounded(.up)), 1)
        let targetHeightPixels = max(Int((CGFloat(targetHeight) * scaleY).rounded(.up)), 1)
        let offsets = buildCaptureOffsets(targetHeight: targetHeight, viewportHeight: viewportHeight)

        guard let finalBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidthPixels,
            pixelsHigh: targetHeightPixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw BrowserError.evaluationFailed("Failed to allocate screenshot bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: finalBitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            throw BrowserError.evaluationFailed("Failed to create screenshot context")
        }
        NSGraphicsContext.current = context

        var coveredHeight = 0
        for (index, offset) in offsets.enumerated() {
            _ = try? await evaluateJS("window.scrollTo(0, \(offset)); 'OK'")
            try await Task.sleep(nanoseconds: 350_000_000)

            let segmentBitmap = index == 0 ? firstSegment : try captureCurrentWebViewBitmap(webView)
            guard let cgImage = segmentBitmap.cgImage else {
                continue
            }

            let segmentStart = max(offset, coveredHeight)
            let segmentEnd = min(offset + viewportHeight, targetHeight)
            guard segmentEnd > segmentStart else { continue }

            let overlapFromTop = segmentStart - offset
            let usefulHeight = segmentEnd - segmentStart
            let sourceY = max(
                Int(CGFloat(segmentBitmap.pixelsHigh) - (CGFloat(overlapFromTop + usefulHeight) * scaleY).rounded(.toNearestOrAwayFromZero)),
                0
            )
            let sourceHeight = min(
                max(Int((CGFloat(usefulHeight) * scaleY).rounded(.toNearestOrAwayFromZero)), 1),
                segmentBitmap.pixelsHigh - sourceY
            )
            let cropRect = CGRect(
                x: 0,
                y: sourceY,
                width: min(segmentBitmap.pixelsWide, targetWidthPixels),
                height: sourceHeight
            )
            guard let cropped = cgImage.cropping(to: cropRect) else { continue }

            let destinationY = max(
                Int(CGFloat(targetHeightPixels) - (CGFloat(segmentEnd) * scaleY).rounded(.toNearestOrAwayFromZero)),
                0
            )
            context.cgContext.draw(
                cropped,
                in: CGRect(x: 0, y: CGFloat(destinationY), width: cropRect.width, height: cropRect.height)
            )
            coveredHeight = segmentEnd
        }

        NSGraphicsContext.restoreGraphicsState()

        if let originalOffset, let value = Double(originalOffset) {
            _ = try? await evaluateJS("window.scrollTo(0, \(Int(value)))")
        } else {
            _ = try? await evaluateJS("window.scrollTo(0, 0)")
        }

        guard let pngData = finalBitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError.evaluationFailed("Failed to encode stitched screenshot")
        }
        return pngData
    }

    private func buildCaptureOffsets(targetHeight: Int, viewportHeight: Int) -> [Int] {
        guard targetHeight > viewportHeight else { return [0] }

        var offsets = Array(stride(from: 0, to: targetHeight, by: viewportHeight))
        offsets.append(max(targetHeight - viewportHeight, 0))
        return Array(Set(offsets)).sorted()
    }

    private func captureCurrentWebViewBitmap(_ webView: WKWebView) throws -> NSBitmapImageRep {
        let bounds = webView.bounds
        guard let bitmap = webView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw BrowserError.evaluationFailed("Failed to create bitmap rep for web view capture")
        }
        bitmap.size = bounds.size
        webView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
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
