import CoreGraphics
import CoreText
import UIKit
import os

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
            case .medal(let frame, let background, let rect):
                Medal.draw(frame, background: background, in: flipped(rect), context: context, scale: scale)
            }
        }
        return context.makeImage()
    }
}

/// Icons are drawn with UIKit from the app's SVGs (asset catalog) and SF Symbols, on whichever
/// thread wants one. Drawing one of the SVGs on two threads at once corrupts memory: UIKit
/// over-releases the image's data from the asset catalog (the app crashed on launch when both
/// render threads drew the first notes' action icons). So icons are drawn one at a time, each
/// once, and the SVGs are drawn only here: UIKit views take them from `templateImage`.
final class IconStore: Sendable {
    static let shared = IconStore()

    private struct Key: Hashable {
        let icon: Icon
        let width: Int
        let height: Int
        let role: ColorRole
        let style: ThemeStyle
        let scale: Int
        let fills: Bool
    }

    private let cache = Locked<[Key: ImageBox]>([:])
    /// Held while drawing (`cache` is not, so cached icons stay quick to get meanwhile).
    private let drawing = OSAllocatedUnfairLock()

    /// The icon at most at its natural size, centered in `size`.
    func image(_ icon: Icon, size: CGSize, role: ColorRole, palette: Palette, scale: CGFloat) -> CGImage? {
        image(icon, size: size, role: role, palette: palette, scale: scale, fills: false)
    }

    /// For UIKit views, which tint it with their tint color. The icon fills `size`, as an image
    /// view scales a vector image to fit.
    func templateImage(_ icon: Icon, size: CGSize, scale: CGFloat) -> UIImage? {
        image(icon, size: size, role: .primaryText, palette: .light, scale: scale, fills: true)
            .map { UIImage(cgImage: $0, scale: scale, orientation: .up).withRenderingMode(.alwaysTemplate) }
    }

    private func image(_ icon: Icon, size: CGSize, role: ColorRole, palette: Palette, scale: CGFloat,
                       fills: Bool) -> CGImage? {
        let key = Key(icon: icon, width: Int(size.width * 100), height: Int(size.height * 100), role: role,
                      style: palette.style, scale: Int(scale * 100), fills: fills)
        if let hit = cache.withLock({ $0[key] }) { return hit.image }
        return drawing.withLock { () -> ImageBox? in
            if let hit = cache.withLock({ $0[key] }) { return hit }
            guard let image = Self.draw(icon, size: size, color: palette[role], scale: scale, fills: fills)
            else { return nil }
            let box = ImageBox(image)
            cache.withLock { $0[key] = box }
            return box
        }?.image
    }

    private static func draw(_ icon: Icon, size: CGSize, color: CGColor, scale: CGFloat, fills: Bool) -> CGImage? {
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
            let fit = min(fills ? .infinity : 1, size.width / natural.width, size.height / natural.height)
            let w = natural.width * fit
            let h = natural.height * fit
            symbol.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
        }
        return rendered.cgImage
    }
}

private extension Icon {
    /// Only `IconStore` draws these (see there).
    var assetName: String? {
        switch self {
        case .reply: "NoteReply"
        case .renote, .renoteBadge: "NoteRenote"
        case .reaction: "NoteReact"
        case .reacted: "NoteReacted"
        case .like: "NoteLike"
        case .liked: "NoteLiked"
        case .bookmark: "NoteBookmark"
        case .bookmarked: "NoteBookmarked"
        case .share: "NoteShare"
        case .visibilityHome: "VisibilityHome"
        case .visibilityFollowers: "VisibilityFollowers"
        case .visibilitySpecified: "VisibilitySpecified"
        default: nil
        }
    }
}
