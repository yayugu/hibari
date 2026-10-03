import CoreGraphics

/// Draws an achievement's badge like Misskey's web client: a ring in the frame's metal
/// around a disc in the badge's background, both lit from above and casting a shadow. The
/// emoji goes on top (`Medal.emojiRect`). The gold and platinum shine is left out: it moves.
enum Medal {
    /// Where the emoji goes in a medal drawn in `rect`.
    static func emojiRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 12 / 58, dy: rect.height * 12 / 58)
    }

    /// How far the shadow reaches below `rect`; leave room for it.
    static func shadowOverhang(for size: CGFloat) -> CGFloat {
        (size * 4 / 58).rounded(.up)
    }

    /// `rect` is in the context's flipped (bottom-left origin) coordinates; `scale` is the
    /// context's, for the shadow, which ignores the transform.
    static func draw(_ frame: Achievement.Frame, background: (bottom: UInt32, top: UInt32)?, in rect: CGRect,
                     context: CGContext, scale: CGFloat) {
        let unit = rect.width / 58
        let inner = rect.insetBy(dx: 6 * unit, dy: 6 * unit)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2 * unit * scale), blur: 2 * unit * scale,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0x44 / 255))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        disc(rect, stops: frame.ring, highlight: unit, context: context)
        let fill = background.map { [($0.bottom, 0), ($0.top, 1)] } ?? frame.disc
        disc(inner, stops: fill, highlight: unit, context: context)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A circle filled bottom to top with `stops` (0xRRGGBB, location), with a lighter
    /// crescent `highlight` thick along its top.
    private static func disc(_ rect: CGRect, stops: [(UInt32, CGFloat)], highlight: CGFloat, context: CGContext) {
        let colors = stops.map { color($0.0) } as CFArray
        let locations = stops.map(\.1)
        guard let gradient = CGGradient(colorsSpace: Bitmap.colorSpace, colors: colors, locations: locations)
        else { return }
        context.saveGState()
        context.addEllipse(in: rect)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        context.addRect(rect)
        context.addEllipse(in: rect.offsetBy(dx: 0, dy: -highlight))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0x88 / 255))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private static func color(_ rgb: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

private extension Achievement.Frame {
    /// The ring, bottom to top.
    var ring: [(UInt32, CGFloat)] {
        switch self {
        case .bronze: [(0x703827, 0), (0xd37566, 1)]
        case .silver: [(0x7c7c7c, 0), (0xe1e1e1, 1)]
        case .gold: [(0xffb655, 0), (0xe98500, 0.49), (0xfff35d, 0.51), (0xffbb19, 1)]
        case .platinum: [(0x9a9a9a, 0), (0xe2e2e2, 0.49), (0xffffff, 0.51), (0xc3c3c3, 1)]
        }
    }

    /// The disc of a badge without its own background, bottom to top.
    var disc: [(UInt32, CGFloat)] {
        switch self {
        case .bronze: [(0xd37566, 0), (0x703827, 1)]
        case .silver, .platinum: [(0xe1e1e1, 0), (0x7c7c7c, 1)]
        case .gold: [(0xffee20, 0), (0xeb7018, 1)]
        }
    }
}
