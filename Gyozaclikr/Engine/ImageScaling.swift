import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure image helpers for the engines: PNG bytes ↔ `CGImage`, and the
/// downscale both models get (≤ 1024 px on the long side: fewer image
/// tokens, the same answer).
nonisolated enum ImageScaling {
    /// The long side both engines send.
    static let defaultLongSide = 1_024

    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func cgImage(from payload: ImagePayload) -> CGImage? {
        cgImage(fromPNG: payload.png)
    }

    static func png(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// An `ImagePayload` for an image that came from a screen of `scale`.
    static func payload(from image: CGImage, scale: CGFloat = 2) -> ImagePayload? {
        guard let png = png(from: image) else { return nil }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return ImagePayload(png: png, pointSize: size, scale: scale)
    }

    /// The image scaled so its longer side is at most `longSide` pixels;
    /// unchanged when it already fits. Aspect is preserved.
    static func downscaled(_ image: CGImage, longSide: Int = defaultLongSide) -> CGImage {
        let width = image.width, height = image.height
        let longest = max(width, height)
        guard longest > longSide, longest > 0 else { return image }
        let factor = Double(longSide) / Double(longest)
        let newWidth = max(1, Int((Double(width) * factor).rounded()))
        let newHeight = max(1, Int((Double(height) * factor).rounded()))
        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    /// PNG bytes of the payload's image scaled for a model; the original bytes
    /// when they cannot be decoded.
    static func scaledPNG(from payload: ImagePayload, longSide: Int = defaultLongSide) -> Data {
        guard let image = cgImage(fromPNG: payload.png) else { return payload.png }
        let scaled = downscaled(image, longSide: longSide)
        if scaled === image { return payload.png }
        return png(from: scaled) ?? payload.png
    }

    /// A solid-colour image, for the launch probe and the tests.
    static func solidColour(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
