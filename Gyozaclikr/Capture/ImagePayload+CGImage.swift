import AppKit
import CoreGraphics
import ImageIO

/// Packs a captured CGImage as PNG bytes at full resolution, with the size
/// in points the box lays out with and the scale that relates the two.
extension ImagePayload {
    nonisolated init?(cgImage: CGImage, pointSize: CGSize, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        self.init(png: png, pointSize: pointSize, scale: scale)
    }

    /// From a pasteboard image whose screen is unknown: one pixel per point.
    nonisolated init?(cgImage: CGImage) {
        self.init(cgImage: cgImage, pointSize: CGSize(width: cgImage.width, height: cgImage.height), scale: 1)
    }

    /// The image back, for OCR or a thumbnail.
    nonisolated var cgImage: CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
