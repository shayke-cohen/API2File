import AppKit
import API2FileCore
import PDFKit
import WebKit
import ImageIO

enum WebViewCaptureSupport {
    @MainActor
    static func capturePNG(from webView: WKWebView, width: Int?, height: Int?) async throws -> Data {
        let captureWidth = max(width ?? Int(webView.bounds.width.rounded(.up)), 1)
        let captureHeight = max(height ?? Int(webView.bounds.height.rounded(.up)), 1)

        if let pdfPNG = try? await capturePDFRasterizedPNG(from: webView, width: captureWidth, height: captureHeight),
           !isLikelyBlankPNG(pdfPNG) {
            return pdfPNG
        }

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        config.rect = CGRect(x: 0, y: 0, width: captureWidth, height: captureHeight)
        config.snapshotWidth = NSNumber(value: captureWidth)

        let image = try await webView.takeSnapshot(configuration: config)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError.evaluationFailed("Failed to encode screenshot as PNG")
        }

        if !isLikelyBlankPNG(pngData) {
            return pngData
        }

        if let pdfPNG = try? await capturePDFRasterizedPNG(from: webView, width: captureWidth, height: captureHeight) {
            return pdfPNG
        }

        return pngData
    }

    @MainActor
    private static func capturePDFRasterizedPNG(from webView: WKWebView, width: Int, height: Int) async throws -> Data {
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let pdfData = try await webView.pdf(configuration: config)

        guard let document = PDFDocument(data: pdfData),
              let page = document.page(at: 0) else {
            throw BrowserError.evaluationFailed("Failed to build PDF snapshot")
        }

        let mediaRect = page.bounds(for: .mediaBox)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(mediaRect.width.rounded(.up)), 1),
            pixelsHigh: max(Int(mediaRect.height.rounded(.up)), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else {
            throw BrowserError.evaluationFailed("Failed to allocate PDF raster buffer")
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            NSGraphicsContext.restoreGraphicsState()
            throw BrowserError.evaluationFailed("Failed to create PDF raster graphics context")
        }
        NSGraphicsContext.current = context
        context.cgContext.setFillColor(NSColor.clear.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: mediaRect.size))
        page.draw(with: .mediaBox, to: context.cgContext)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserError.evaluationFailed("Failed to encode PDF snapshot as PNG")
        }
        return pngData
    }

    private static func isLikelyBlankPNG(_ data: Data) -> Bool {
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
