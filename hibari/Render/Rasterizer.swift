import CoreGraphics
import CoreText
import UIKit

enum Rasterizer {
    static let maxPixelDimension = 16384

    /// `emoji` returns the bitmap for a custom emoji, or nil if it is not available.
    static func render(
        _ block: RasterBlock,
        palette: Palette,
        scale: CGFloat,
        emoji image: (ImageRequest) -> CGImage?
    ) -> CGImage? {
        let allowed = 1...CGFloat(maxPixelDimension)
        let pixelWidth = (block.frame.width * scale).rounded()
        let pixelHeight = (block.frame.height * scale).rounded()
        guard allowed.contains(pixelWidth), allowed.contains(pixelHeight),
              let context = Bitmap.makeContext(width: Int(pixelWidth), height: Int(pixelHeight), opaque: false)
        else { return nil }

        let height = block.frame.height
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        func drawEmoji(_ url: String, _ rect: CGRect) {
            if let image = image(NoteLayout.emojiRequest(url, rect.size, scale)) {
                context.draw(image, in: flipped(rect))
            }
        }

        for op in block.ops {
            switch op {
            case .text(let layout, let origin):
                for line in layout.lines {
                    context.textPosition = CGPoint(x: origin.x + line.origin.x, y: height - (origin.y + line.origin.y))
                    CTLineDraw(line.line, context)
                }
                for strike in layout.strikes {
                    context.setFillColor(strike.color)
                    context.fill(flipped(strike.rect.offsetBy(dx: origin.x, dy: origin.y)))
                }
                for emoji in layout.emojis {
                    drawEmoji(emoji.url, emoji.rect.offsetBy(dx: origin.x, dy: origin.y))
                }
            case .emoji(let url, let rect):
                drawEmoji(url, rect)
            case .icon(let icon, let rect, let role):
                if let image = IconStore.shared.image(icon, size: rect.size, role: role, palette: palette, scale: scale) {
                    context.draw(image, in: flipped(rect))
                }
            case .roundedRect(let rect, let radius, let fill, let stroke):
                let r = min(radius, rect.width / 2, rect.height / 2)
                let path = CGPath(roundedRect: flipped(rect), cornerWidth: r, cornerHeight: r, transform: nil)
                if let fill {
                    context.addPath(path)
                    context.setFillColor(palette[fill])
                    context.fillPath()
                }
                if let stroke {
                    context.addPath(path)
                    context.setStrokeColor(palette[stroke])
                    context.setLineWidth(1)
                    context.strokePath()
                }
            }
        }
        return context.makeImage()
    }
}

final class IconStore: Sendable {
    static let shared = IconStore()

    private struct Key: Hashable {
        let icon: Icon
        let width: Int
        let height: Int
        let role: ColorRole
        let style: ThemeStyle
        let scale: Int
    }

    private let cache = Locked<[Key: ImageBox]>([:])

    func image(_ icon: Icon, size: CGSize, role: ColorRole, palette: Palette, scale: CGFloat) -> CGImage? {
        let key = Key(icon: icon, width: Int(size.width * 100), height: Int(size.height * 100), role: role,
                      style: palette.style, scale: Int(scale * 100))
        if let hit = cache.withLock({ $0[key] }) { return hit.image }
        guard let image = Self.draw(icon, size: size, color: palette[role], scale: scale) else { return nil }
        cache.withLock { $0[key] = ImageBox(image) }
        return image
    }

    private static func draw(_ icon: Icon, size: CGSize, color: CGColor, scale: CGFloat) -> CGImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: size.height * 0.8,
            weight: icon.weight == .bold ? .bold : .regular)
        let source = icon.assetName.flatMap { UIImage(named: $0) }
            ?? UIImage(systemName: icon.symbolName, withConfiguration: configuration)
        guard let symbol = source?
            .withTintColor(UIColor(cgColor: color), renderingMode: .alwaysOriginal)
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let natural = symbol.size
            let fit = min(1, size.width / natural.width, size.height / natural.height)
            let w = natural.width * fit
            let h = natural.height * fit
            symbol.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        return rendered.cgImage
    }
}
