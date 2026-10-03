import CoreGraphics
import CoreText
import Foundation

final class Typography: @unchecked Sendable {
    let fontScale: CGFloat
    let lineHeightMultiple: CGFloat

    let body: CTFont
    let bodyBold: CTFont
    let secondary: CTFont
    let small: CTFont
    let smallBold: CTFont
    let caption: CTFont
    /// Achievements' flavor text, set apart from the rest like a card game's.
    let flavor: CTFont

    private static let cache = Locked<[CGFloat: Typography]>([:])

    static func shared(fontScale: CGFloat, lineHeightMultiple: CGFloat) -> Typography {
        let key = fontScale * 1000 + lineHeightMultiple
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let typography = Typography(fontScale: fontScale, lineHeightMultiple: lineHeightMultiple)
        cache.withLock { $0[key] = typography }
        return typography
    }

    private init(fontScale: CGFloat, lineHeightMultiple: CGFloat) {
        self.fontScale = fontScale
        self.lineHeightMultiple = lineHeightMultiple
        func size(_ base: CGFloat) -> CGFloat { (base * fontScale).rounded() }
        body = Self.system(size(16))
        bodyBold = Self.system(size(16), bold: true)
        secondary = Self.system(size(15))
        small = Self.system(size(14))
        smallBold = Self.system(size(14), bold: true)
        caption = Self.system(size(13))
        // Below the body size: Mincho looks larger than the system font at the same size.
        flavor = CTFontCreateWithName("HiraMinProN-W3" as CFString, size(14), nil)
    }

    static func system(_ size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "ja" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    func lineMetrics(for font: CTFont) -> LineMetrics {
        LineMetrics(font: font, multiple: lineHeightMultiple)
    }

    static func bold(_ font: CTFont) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitBold, .traitBold)
            ?? system(CTFontGetSize(font), bold: true)
    }

    static func italic(_ font: CTFont) -> CTFont {
        var skew = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), &skew, nil)
    }

    static func resized(_ font: CTFont, by factor: CGFloat) -> CTFont {
        CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * factor, nil, nil)
    }

    /// Equal-width digits, so labels like "12分" have a width that is known in advance.
    static func tabularDigits(_ font: CTFont) -> CTFont {
        let feature: [CFString: Any] = [kCTFontOpenTypeFeatureTag: "tnum", kCTFontOpenTypeFeatureValue: 1]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }
}

struct LineMetrics: Sendable {
    let lineHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(font: CTFont, multiple: CGFloat) {
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        lineHeight = max(ascent + descent, (CTFontGetSize(font) * multiple).rounded())
    }

    /// Baseline of a line of ordinary text, from the top of the line.
    var baseline: CGFloat { (lineHeight - ascent - descent) / 2 + ascent }
}
