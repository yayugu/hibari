import CoreGraphics

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

enum Bitmap {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 32-bit BGRA, premultiplied (or opaque) — the layout Core Animation consumes without
    /// a conversion copy on commit.
    static func makeContext(width: Int, height: Int, opaque: Bool) -> CGContext? {
        let alpha = opaque ? CGImageAlphaInfo.noneSkipFirst : CGImageAlphaInfo.premultipliedFirst
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue
        )
        context?.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// Redraws an ImageIO-decoded image into the canonical format.
    static func normalized(_ image: CGImage) -> CGImage? {
        guard let context = makeContext(width: image.width, height: image.height, opaque: !image.hasAlpha) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
