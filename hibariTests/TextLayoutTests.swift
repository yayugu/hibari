import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import hibari

@Suite("Text layout")
struct TextLayoutTests {
    private let typography = Typography.shared(fontScale: 1, lineHeightMultiple: 1.32)

    private func attributed(_ text: String, emojis: [String: String] = [:]) -> NSAttributedString {
        let builder = RichTextBuilder(
            palette: .dark,
            emojiResolver: EmojiResolver(localEmojis: emojis, mediaProxy: nil),
            emojiContext: EmojiContext(host: nil, remoteEmojis: [:]),
            sizer: EmojiSizer(FakeMediaSizes()))
        return builder.build(MFMParser.parse(text), style: TextStyle(font: typography.body, color: Palette.dark[.primaryText]))
    }

    private var metrics: LineMetrics { typography.lineMetrics(for: typography.body) }

    @Test func mixedScriptLinesHaveUniformSpacing() {
        let layout = TextLayout(attributed("Hello world\nこんにちは世界\n絵文字😀テスト\nabc"), width: 300, metrics: metrics)
        #expect(layout.lines.count == 4)
        let gaps = zip(layout.lines.dropFirst(), layout.lines).map { $0.origin.y - $1.origin.y }
        #expect(gaps.allSatisfy { abs($0 - metrics.lineHeight) < 0.5 }, "\(gaps)")
        #expect(abs(layout.size.height - metrics.lineHeight * 4) < 1)
    }

    @Test func urlsShowAsOnX() {
        #expect(RichTextBuilder.displayURL("https://news.livedoor.com/article/detail/30512345/")
            == "news.livedoor.com/article/detail…")
        #expect(RichTextBuilder.displayURL("https://www.example.com/") == "example.com")
        #expect(RichTextBuilder.displayURL("http://example.com/a?b=1") == "example.com/a?b=1")
        #expect(RichTextBuilder.displayURL("https://example.com/0123456789abcd") == "example.com/0123456789abcd")
        #expect(RichTextBuilder.displayURL("https://example.com/?q=0123456789abcdef") == "example.com/?q=0123456789a…")
        #expect(String(attributed("見て https://news.livedoor.com/article/detail/30512345/").string)
            == "見て news.livedoor.com/article/detail…")
    }

    @Test func maxLinesTruncatesWithEllipsis() {
        let text = (1...20).map { "行\($0)" }.joined(separator: "\n")
        let layout = TextLayout(attributed(text), width: 300, metrics: metrics, maxLines: 3)
        #expect(layout.lines.count == 3)
        #expect(layout.isTruncated)
        let last = layout.lines[2].line
        let range = CTLineGetStringRange(last)
        #expect(range.length > 0)
        let runs = CTLineGetGlyphRuns(last) as! [CTRun]
        #expect(!runs.isEmpty)
    }

    @Test func emojiAttachmentsArePlacedOnTheirLine() {
        let layout = TextLayout(attributed("猫:cat:と:cat:", emojis: ["cat": "https://e/cat.png"]), width: 300, metrics: metrics)
        #expect(layout.emojis.count == 2)
        for emoji in layout.emojis {
            #expect(emoji.rect.maxX <= layout.size.width + 0.5)
            #expect(emoji.rect.minY >= -0.5 && emoji.rect.maxY <= layout.size.height + 0.5)
            #expect(emoji.url == "https://e/cat.png")
        }
        #expect(layout.emojis[1].rect.minX > layout.emojis[0].rect.maxX)
    }

    @Test func unknownEmojiStaysAsText() {
        let string = attributed(":unknown:")
        #expect(string.string == ":unknown:")
    }

    @Test func nestedZoomDoesNotCompound() throws {
        func fontSize(_ text: String) throws -> CGFloat {
            let string = attributed(text)
            let index = (string.string as NSString).range(of: "a").location
            let font = try #require(string.attribute(TextAttribute.font, at: index, effectiveRange: nil))
            return CTFontGetSize(font as! CTFont)
        }
        let once = try fontSize("$[x4 a]")
        #expect(once == CTFontGetSize(typography.body) * 6)
        #expect(try fontSize("$[x4 $[x4 $[x4 a]]]") == once)
        #expect(try fontSize("$[x2 $[x4 a]]") == CTFontGetSize(typography.body) * 2)
    }

    @Test func ellipsisAfterAnEmojiIsVisible() throws {
        let name = attributed(String(repeating: "長い名前", count: 10) + ":cat:", emojis: ["cat": "https://e/cat.png"])
        let layout = TextLayout.singleLine(name, maxWidth: 120, metrics: metrics)
        #expect(layout.isTruncated && layout.size.width <= 120.5)
        let line = try #require(layout.lines.first).line
        let ellipsis = try #require((CTLineGetGlyphRuns(line) as! [CTRun]).last)
        let attributes = CTRunGetAttributes(ellipsis) as NSDictionary
        let color = attributes[TextAttribute.foregroundColor.rawValue].map { $0 as! CGColor }
        #expect((color?.alpha ?? 0) > 0)
    }
}
