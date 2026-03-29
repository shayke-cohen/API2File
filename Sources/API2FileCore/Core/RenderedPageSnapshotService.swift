import CoreGraphics
import Foundation
import ImageIO

public struct RenderedPageSnapshot: Sendable, Equatable {
    public let sourceURL: String
    public let finalURL: String
    public let html: String
    public let screenshotData: Data
    public let title: String
    public let capturedAt: Date

    public init(
        sourceURL: String,
        finalURL: String,
        html: String,
        screenshotData: Data,
        title: String,
        capturedAt: Date = Date()
    ) {
        self.sourceURL = sourceURL
        self.finalURL = finalURL
        self.html = html
        self.screenshotData = screenshotData
        self.title = title
        self.capturedAt = capturedAt
    }
}

public protocol RenderedPageSnapshotService: Sendable {
    func capture(url: String) async throws -> RenderedPageSnapshot
}

public actor BrowserRenderedPageSnapshotService: RenderedPageSnapshotService {
    private let browserDelegate: any BrowserControlDelegate
    private let maxSnapshotHeight = 12_000
    private let maxSnapshotWidth = 2_048

    public init(browserDelegate: any BrowserControlDelegate) {
        self.browserDelegate = browserDelegate
    }

    public func capture(url: String) async throws -> RenderedPageSnapshot {
        if !(await browserDelegate.isBrowserOpen()) {
            try await browserDelegate.openBrowser()
        }

        let finalURL = try await browserDelegate.navigate(to: url)
        let metrics = try await waitForPageMetrics()
        let html = try await browserDelegate.getDOM(selector: nil)
        let rawTitle = (try? await browserDelegate.evaluateJS("document.title")) ?? ""
        let screenshotData = try await captureStableScreenshot(metrics: metrics)

        return RenderedPageSnapshot(
            sourceURL: url,
            finalURL: finalURL,
            html: html,
            screenshotData: screenshotData,
            title: Self.normalizeTitle(rawTitle)
        )
    }

    private func waitForPageMetrics() async throws -> PageMetrics {
        var lastMetrics: PageMetrics?

        for _ in 0..<12 {
            let metrics = try await fetchPageMetrics()
            if metrics.isRenderable, let lastMetrics, lastMetrics.isClose(to: metrics) {
                _ = try? await browserDelegate.evaluateJS("window.scrollTo(0, 0)")
                try await Task.sleep(nanoseconds: 350_000_000)
                return metrics.clamped(maxWidth: maxSnapshotWidth, maxHeight: maxSnapshotHeight)
            }

            lastMetrics = metrics
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        return (try await fetchPageMetrics()).clamped(maxWidth: maxSnapshotWidth, maxHeight: maxSnapshotHeight)
    }

    private func fetchPageMetrics() async throws -> PageMetrics {
        let script = """
        JSON.stringify((() => {
            const doc = document.documentElement;
            const body = document.body;
            const width = Math.max(
                window.innerWidth || 0,
                doc ? doc.clientWidth : 0,
                doc ? doc.scrollWidth : 0,
                body ? body.scrollWidth : 0
            );
            const height = Math.max(
                window.innerHeight || 0,
                doc ? doc.clientHeight : 0,
                doc ? doc.scrollHeight : 0,
                body ? body.scrollHeight : 0
            );
            const fontsReady = !document.fonts || document.fonts.status === 'loaded';
            return {
                readyState: document.readyState || '',
                fontsReady,
                width,
                height
            };
        })())
        """

        let raw = try await browserDelegate.evaluateJS(script)
        guard let data = raw.data(using: .utf8) else {
            throw BrowserError.evaluationFailed("Failed to decode page metrics")
        }
        return try JSONDecoder().decode(PageMetrics.self, from: data)
    }

    private func captureStableScreenshot(metrics: PageMetrics) async throws -> Data {
        var lastData: Data?

        for _ in 0..<4 {
            let data = try await browserDelegate.captureScreenshot(width: metrics.width, height: metrics.height)
            if !Self.isLikelyBlankScreenshot(data) {
                return data
            }
            lastData = data
            try await Task.sleep(nanoseconds: 400_000_000)
        }

        if let lastData {
            return lastData
        }
        throw BrowserError.evaluationFailed("Failed to capture screenshot")
    }

    private static func normalizeTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\"" else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func isLikelyBlankScreenshot(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }

        let sampleWidth = 32
        let sampleHeight = 32
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var minChannel = UInt8.max
        var maxChannel = UInt8.min
        var nonWhitePixels = 0

        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let r = pixels[index]
            let g = pixels[index + 1]
            let b = pixels[index + 2]
            let a = pixels[index + 3]
            minChannel = min(minChannel, r, g, b)
            maxChannel = max(maxChannel, r, g, b)
            if a > 0 && (r < 250 || g < 250 || b < 250) {
                nonWhitePixels += 1
            }
        }

        let channelSpread = Int(maxChannel) - Int(minChannel)
        return nonWhitePixels < 8 && channelSpread < 3
    }
}

private struct PageMetrics: Decodable {
    let readyState: String
    let fontsReady: Bool
    let width: Int
    let height: Int

    var isRenderable: Bool {
        (readyState == "complete" || readyState == "interactive") && fontsReady && width > 0 && height > 0
    }

    func clamped(maxWidth: Int, maxHeight: Int) -> PageMetrics {
        PageMetrics(
            readyState: readyState,
            fontsReady: fontsReady,
            width: max(1, min(width, maxWidth)),
            height: max(1, min(height, maxHeight))
        )
    }

    func isClose(to other: PageMetrics) -> Bool {
        abs(width - other.width) <= 4 && abs(height - other.height) <= 24 && other.isRenderable
    }
}
