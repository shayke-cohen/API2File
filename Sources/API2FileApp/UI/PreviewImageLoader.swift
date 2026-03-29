import AppKit
import Foundation
import ImageIO

enum PreviewImageLoader {
    static func load(from fileURL: URL) -> NSImage? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "svg" {
            return NSImage(contentsOf: fileURL)
        }

        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
           ) {
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }

        guard let image = NSImage(contentsOf: fileURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSImage(contentsOf: fileURL)
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }
}
