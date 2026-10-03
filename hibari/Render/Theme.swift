import CoreGraphics
import UIKit

enum ThemeStyle: UInt8, Hashable, Sendable {
    case light
    case dark

    init(_ style: UIUserInterfaceStyle) {
        self = style == .dark ? .dark : .light
    }
}

enum ColorRole: UInt8, Hashable, Sendable, CaseIterable {
    case background
    case primaryText
    case secondaryText
    case separator
    case accent
    case border
    case chipBackground
    case chipReactedBackground
    case mediaPlaceholder
    case overlayText
    case overlayBackground
    case renote
    case reaction
    /// Labels like "フォローされています".
    case badgeBackground
    /// The filled (follow) button.
    case filledButton
}

struct Palette: @unchecked Sendable {
    let style: ThemeStyle
    private let colors: [CGColor]

    static let dark = Palette(style: .dark)
    static let light = Palette(style: .light)

    static func palette(for style: ThemeStyle) -> Palette {
        style == .dark ? .dark : .light
    }

    private init(style: ThemeStyle) {
        self.style = style
        colors = ColorRole.allCases.map { Self.rgba(for: $0, style: style).cgColor }
    }

    subscript(role: ColorRole) -> CGColor { colors[Int(role.rawValue)] }

    struct RGBA {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat

        init(_ hex: UInt32, alpha: CGFloat = 1) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
            a = alpha
        }

        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }
    }

    static func rgba(for role: ColorRole, style: ThemeStyle) -> RGBA {
        let dark = style == .dark
        switch role {
        case .background: return RGBA(dark ? 0x000000 : 0xFFFFFF)
        case .primaryText: return RGBA(dark ? 0xE7E9EA : 0x0F1419)
        case .secondaryText: return RGBA(dark ? 0x71767B : 0x536471)
        case .separator: return RGBA(dark ? 0x2F3336 : 0xEFF3F4)
        case .accent: return RGBA(0x1D9BF0)
        case .border: return RGBA(dark ? 0x2F3336 : 0xCFD9DE)
        case .chipBackground: return RGBA(dark ? 0x16181C : 0xF2F4F5)
        case .chipReactedBackground: return RGBA(0x1D9BF0, alpha: dark ? 0.22 : 0.14)
        case .mediaPlaceholder: return RGBA(dark ? 0x202327 : 0xE8ECEE)
        case .overlayText: return RGBA(0xFFFFFF)
        case .overlayBackground: return RGBA(0x000000, alpha: 0.55)
        case .renote: return RGBA(0x00BA7C)
        case .reaction: return RGBA(0xF91880)
        case .badgeBackground: return RGBA(dark ? 0x202327 : 0xEFF3F4)
        case .filledButton: return RGBA(dark ? 0xEFF3F4 : 0x0F1419)
        }
    }
}

extension UIColor {
    /// Dynamic UIKit color for chrome drawn by UIKit views (bars, labels).
    static func hibari(_ role: ColorRole) -> UIColor {
        UIColor { traits in
            Palette.rgba(for: role, style: ThemeStyle(traits.userInterfaceStyle)).uiColor
        }
    }
}
