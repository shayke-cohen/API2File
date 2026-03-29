import AppKit
import SwiftUI

struct PreviewImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.image = image

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = imageView
        updateImageView(imageView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        imageView.image = image
        updateImageView(imageView)
    }

    private func updateImageView(_ imageView: NSImageView) {
        let size = image.size
        imageView.frame = CGRect(origin: .zero, size: size)
        imageView.setFrameSize(size)
    }
}
