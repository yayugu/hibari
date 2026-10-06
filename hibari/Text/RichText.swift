import CoreGraphics
import CoreText
import Foundation

enum TextAttribute {
    static let font = NSAttributedString.Key(kCTFontAttributeName as String)
    static let foregroundColor = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    static let runDelegate = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
    static let language = NSAttributedString.Key(kCTLanguageAttributeName as String)
    /// `EmojiAttachment`
    static let emoji = NSAttributedString.Key("HibariEmoji")
    static let link = NSAttributedString.Key("HibariLink")
    static let strikethrough = NSAttributedString.Key("HibariStrike")
    /// Paragraph flush factor (0 = leading, 0.5 = center). Applied by `TextLayout`.
    static let flush = NSAttributedString.Key("HibariFlush")
    /// Leading indent of the paragraph in points. Applied by `TextLayout`.
    static let indent = NSAttributedString.Key("HibariIndent")
}

final class EmojiAttachment: NSObject, @unchecked Sendable {
    let url: String
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    /// Color of the surrounding text. The placeholder character itself is transparent.
    let textColor: CGColor
    /// The text it stands for (`:name:`), for copying.
    let alt: String

    init(url: String, width: CGFloat, ascent: CGFloat, descent: CGFloat, textColor: CGColor, alt: String = "") {
        self.url = url
        self.alt = alt
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.textColor = textColor
    }

    var height: CGFloat { ascent + descent }

    func makeRunDelegate() -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { ref in Unmanaged<EmojiAttachment>.fromOpaque(ref).release() },
            getAscent: { ref in Unmanaged<EmojiAttachment>.fromOpaque(ref).takeUnretainedValue().ascent },
            getDescent: { ref in Unmanaged<EmojiAttachment>.fromOpaque(ref).takeUnretainedValue().descent },
            getWidth: { ref in Unmanaged<EmojiAttachment>.fromOpaque(ref).takeUnretainedValue().width }
        )
        return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(self).toOpaque())
    }
}

struct TextStyle {
    var font: CTFont
    var color: CGColor
    var link: String?
    var flush: CGFloat = 0
    var indent: CGFloat = 0
    var strikethrough = false
    var isZoomed = false
}

/// One per layout; not thread-safe.
final class EmojiSizer {
    private let sizes: any MediaSizeProvider
    /// Laid out with a guessed (square) size.
    private(set) var provisional: Set<String> = []

    init(_ sizes: any MediaSizeProvider) {
        self.sizes = sizes
    }

    /// Width / height: 1 (square) while unknown, nil if the emoji cannot be loaded (it is
    /// shown as ":name:" text then, like Misskey's alt text).
    func aspectRatio(of url: String) -> CGFloat? {
        switch sizes.mediaSize(for: url) {
        case .known(let size):
            return size.width / size.height
        case .unavailable:
            return nil
        case .unknown:
            provisional.insert(url)
            return 1
        }
    }
}

struct RichTextBuilder {
    let palette: Palette
    let emojiResolver: EmojiResolver
    let emojiContext: EmojiContext
    let sizer: EmojiSizer
    var emojiScale: CGFloat = 1.25
    var maxEmojiWidth: CGFloat = 320

    private final class Output {
        let string = NSMutableAttributedString()
        var pendingBreak = false
    }

    func build(_ nodes: [MFMNode], style: TextStyle) -> NSAttributedString {
        let output = Output()
        append(nodes, style: style, to: output)
        let result = output.string
        while result.length > 0, result.mutableString.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        if result.length > 0 {
            result.addAttribute(TextAttribute.language, value: "ja", range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    private func attributes(_ style: TextStyle) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            TextAttribute.font: style.font,
            TextAttribute.foregroundColor: style.color,
        ]
        if let link = style.link { attrs[TextAttribute.link] = link }
        if style.flush != 0 { attrs[TextAttribute.flush] = style.flush }
        if style.indent != 0 { attrs[TextAttribute.indent] = style.indent }
        if style.strikethrough { attrs[TextAttribute.strikethrough] = true }
        return attrs
    }

    private func appendText(_ text: String, style: TextStyle, to output: Output) {
        guard !text.isEmpty else { return }
        var text = text
        if output.pendingBreak {
            output.pendingBreak = false
            if output.string.length > 0 && !text.hasPrefix("\n") {
                text = "\n" + text
            }
        }
        output.string.append(NSAttributedString(string: text, attributes: attributes(style)))
    }

    private func beginBlock(_ output: Output) {
        output.pendingBreak = false
        if output.string.length > 0 && !output.string.mutableString.hasSuffix("\n") {
            output.string.append(NSAttributedString(string: "\n"))
        }
    }

    private func endBlock(_ output: Output) {
        output.pendingBreak = true
    }

    private func append(_ nodes: [MFMNode], style: TextStyle, to output: Output) {
        for node in nodes {
            append(node, style: style, to: output)
        }
    }

    private func append(_ node: MFMNode, style: TextStyle, to output: Output) {
        var style = style
        switch node {
        case .text(let text):
            appendText(text, style: style, to: output)
        case .bold(let children):
            style.font = Typography.bold(style.font)
            append(children, style: style, to: output)
        case .italic(let children):
            style.font = Typography.italic(style.font)
            append(children, style: style, to: output)
        case .strike(let children):
            style.strikethrough = true
            append(children, style: style, to: output)
        case .small(let children):
            style.font = Typography.resized(style.font, by: 0.8)
            style.color = palette[.secondaryText]
            append(children, style: style, to: output)
        case .center(let children):
            beginBlock(output)
            style.flush = 0.5
            append(children, style: style, to: output)
            endBlock(output)
        case .quote(let children):
            beginBlock(output)
            style.color = palette[.secondaryText]
            style.indent += 12
            append(children, style: style, to: output)
            endBlock(output)
        case .inlineCode(let code):
            appendText(code, style: monospaced(style), to: output)
        case .codeBlock(let code):
            beginBlock(output)
            appendText(code, style: monospaced(style), to: output)
            endBlock(output)
        case .mention(let username, let host):
            style.color = palette[.accent]
            let acct = host.map { "@\(username)@\($0)" } ?? "@\(username)"
            style.link = "mention:" + ((host ?? emojiContext.host).map { "@\(username)@\($0)" } ?? acct)
            appendText(acct, style: style, to: output)
        case .hashtag(let tag):
            style.color = palette[.accent]
            style.link = "hashtag:\(tag)"
            appendText("#\(tag)", style: style, to: output)
        case .url(let url):
            style.color = palette[.accent]
            style.link = url
            appendText(Self.displayURL(url), style: style, to: output)
        case .link(let label, let url, _):
            style.color = palette[.accent]
            style.link = url
            append(label, style: style, to: output)
        case .emoji(let name):
            appendEmoji(name: name, style: style, to: output)
        case .fn(let name, let args, let children):
            applyFunction(name: name, args: args, to: &style)
            append(children, style: style, to: output)
        }
    }

    private func monospaced(_ style: TextStyle) -> TextStyle {
        var style = style
        style.font = CTFontCreateWithName("Menlo-Regular" as CFString, CTFontGetSize(style.font) * 0.9, nil)
        return style
    }

    private func applyFunction(name: String, args: [String: String], to style: inout TextStyle) {
        switch name {
        case "x2", "x3", "x4":
            guard !style.isZoomed else { break }
            style.font = Typography.resized(style.font, by: name == "x2" ? 2 : name == "x3" ? 4 : 6)
            style.isZoomed = true
        case "fg":
            if let color = args["color"].flatMap(Self.color(hex:)) { style.color = color }
        case "font":
            if args["monospace"] != nil { style = monospaced(style) }
        case "small":
            style.font = Typography.resized(style.font, by: 0.8)
        default:
            break
        }
    }

    private func appendEmoji(name: String, style: TextStyle, to output: Output) {
        guard let url = emojiResolver.url(forName: name, in: emojiContext), let aspect = sizer.aspectRatio(of: url) else {
            appendText(":\(name):", style: style, to: output)
            return
        }
        let fontSize = CTFontGetSize(style.font)
        let height = (fontSize * emojiScale).rounded()
        let width = min(maxEmojiWidth, max(height * 0.5, (height * min(aspect, 8)).rounded()))
        let descent = (fontSize * (emojiScale - 1)).rounded()
        let attachment = EmojiAttachment(url: url, width: width, ascent: height - descent, descent: descent,
                                         textColor: style.color, alt: ":\(name):")
        guard let delegate = attachment.makeRunDelegate() else {
            appendText(":\(name):", style: style, to: output)
            return
        }
        if output.pendingBreak {
            appendText("\n", style: style, to: output)
        }
        var attrs = attributes(style)
        attrs[TextAttribute.runDelegate] = delegate
        attrs[TextAttribute.emoji] = attachment
        // Keep CoreText from drawing the placeholder glyph; the rasterizer draws the image.
        attrs[TextAttribute.foregroundColor] = Self.clear
        output.string.append(NSAttributedString(string: "\u{FFFC}", attributes: attrs))
    }

    private static let clear = CGColor(gray: 0, alpha: 0)

    static func displayURL(_ url: String) -> String {
        var s = Substring(url)
        if s.hasPrefix("https://") {
            s = s.dropFirst(8)
        } else if s.hasPrefix("http://") {
            s = s.dropFirst(7)
        }
        if s.hasSuffix("/") { s = s.dropLast() }
        return s.count > 40 ? String(s.prefix(39)) + "…" : String(s)
    }

    static func color(hex: String) -> CGColor? {
        var digits = Array(hex.unicodeScalars.compactMap { Int(String($0), radix: 16) })
        guard digits.count == hex.unicodeScalars.count else { return nil }
        if digits.count == 3 || digits.count == 4 {
            digits = digits.flatMap { [$0, $0] }
        }
        guard digits.count == 6 || digits.count == 8 else { return nil }
        func byte(_ i: Int) -> CGFloat { CGFloat(digits[i] * 16 + digits[i + 1]) / 255 }
        return CGColor(srgbRed: byte(0), green: byte(2), blue: byte(4), alpha: digits.count == 8 ? byte(6) : 1)
    }
}
