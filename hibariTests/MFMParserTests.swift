import Foundation
import Testing
@testable import hibari

struct MFMParserTests {
    @Test func mentions() {
        #expect(MFMParser.parse("@alice さん") == [.mention(username: "alice", host: nil), .text(" さん")])
        #expect(MFMParser.parse("@bob@example.com.") == [.mention(username: "bob", host: "example.com"), .text(".")])
        #expect(MFMParser.parse("a@b") == [.text("a@b")])
    }

    @Test func hashtags() {
        #expect(MFMParser.parse("#tkx #beekeeb") == [.hashtag("tkx"), .text(" "), .hashtag("beekeeb")])
        #expect(MFMParser.parse("#ラッキーカラー診断\n次") == [.hashtag("ラッキーカラー診断"), .text("\n次")])
        #expect(MFMParser.parse("#123") == [.text("#123")])
        #expect(MFMParser.parse("「#タグ」") == [.text("「"), .hashtag("タグ"), .text("」")])
    }

    @Test func urls() {
        #expect(MFMParser.parse("見て https://misskey.io/notes/abc.") == [
            .text("見て "), .url("https://misskey.io/notes/abc"), .text("."),
        ])
        #expect(MFMParser.parse("(https://example.com/a_(b))") == [
            .text("("), .url("https://example.com/a_(b)"), .text(")"),
        ])
        #expect(MFMParser.parse("<https://example.com/日本>") == [.url("https://example.com/日本")])
        #expect(MFMParser.parse("https://example.com/パス") == [.url("https://example.com/"), .text("パス")])
    }

    @Test func links() {
        #expect(MFMParser.parse("[ここ](https://example.com)") == [
            .link(label: [.text("ここ")], url: "https://example.com", silent: false),
        ])
        #expect(MFMParser.parse("?[silent](https://example.com)") == [
            .link(label: [.text("silent")], url: "https://example.com", silent: true),
        ])
        #expect(MFMParser.parse("[not a link]") == [.text("[not a link]")])
    }

    @Test func customEmoji() {
        #expect(MFMParser.parse("草:blobcat:草") == [.text("草"), .emoji("blobcat"), .text("草")])
        #expect(MFMParser.parse(":a::b:") == [.emoji("a"), .emoji("b")])
        #expect(MFMParser.parse("12:30:45") == [.text("12:30:45")])
        #expect(MFMParser.parse("abc:ok:") == [.text("abc"), .emoji("ok")])
        #expect(MFMParser.parse(":ok:abc") == [.text(":ok:abc")])
    }

    @Test func highlightsAreWhereTheSourceHasThem() {
        let text = "😀 #tag @alice@example.com :ok: https://a.example [link](https://b.example)"
        let highlights = MFMParser.highlights(in: text)
        #expect(highlights.map { source(of: $0, in: text) } == [
            "#tag", "@alice@example.com", ":ok:", "https://a.example", "[link](https://b.example)",
        ])
        #expect(highlights.map(\.kind) == [.hashtag, .mention, .emoji("ok"), .url, .link])
        #expect(MFMParser.highlights(in: "**#a b").map(\.kind) == [.hashtag])
        #expect(MFMParser.highlights(in: "`#a` #b").map { source(of: $0, in: "`#a` #b") } == ["#b"])
        #expect(MFMParser.highlights(in: "a\r\n#b").map(\.range) == [3..<5])
    }

    private func source(of highlight: MFMHighlight, in text: String) -> String {
        (text as NSString).substring(with: NSRange(highlight.range))
    }

    @Test func inlineStyles() {
        #expect(MFMParser.parse("**太字**") == [.bold([.text("太字")])])
        #expect(MFMParser.parse("<b>太字</b>") == [.bold([.text("太字")])])
        #expect(MFMParser.parse("*italic*") == [.italic([.text("italic")])])
        #expect(MFMParser.parse("~~消す~~") == [.strike([.text("消す")])])
        #expect(MFMParser.parse("<small>小さい</small>") == [.small([.text("小さい")])])
        #expect(MFMParser.parse("`#FA8743`") == [.inlineCode("#FA8743")])
        #expect(MFMParser.parse("<plain>**raw**</plain>") == [.text("**raw**")])
    }

    @Test func unclosedMarkersStayText() {
        #expect(MFMParser.parse("**not closed") == [.text("**not closed")])
        #expect(MFMParser.parse("$[x2 open") == [.text("$[x2 open")])
        #expect(MFMParser.parse("`code") == [.text("`code")])
    }

    @Test func functions() {
        #expect(MFMParser.parse("$[x2 大きい]") == [.fn(name: "x2", args: [:], children: [.text("大きい")])])
        #expect(MFMParser.parse("$[fg.color=f00 赤]") == [.fn(name: "fg", args: ["color": "f00"], children: [.text("赤")])])
        #expect(MFMParser.parse("$[tada.speed=0s $[x2 :a:]]") == [
            .fn(name: "tada", args: ["speed": "0s"], children: [.fn(name: "x2", args: [:], children: [.emoji("a")])]),
        ])
        #expect(MFMParser.parse("$[fg.=f00,color=0f0 a]") == [.fn(name: "fg", args: ["color": "0f0"], children: [.text("a")])])
    }

    @Test func blocks() {
        #expect(MFMParser.parse("> 引用\n> 続き\n本文") == [.quote([.text("引用\n続き")]), .text("本文")])
        #expect(MFMParser.parse("```swift\nlet a = 1\n```\n後") == [.codeBlock("let a = 1"), .text("後")])
        #expect(MFMParser.parse("<center>中央</center>") == [.center([.text("中央")])])
        #expect(MFMParser.parse("a > b") == [.text("a > b")])
    }

    @Test func simpleParserOnlyHandlesEmoji() {
        #expect(MFMParser.parseSimple("**name** :cat: @x #y") == [.text("**name** "), .emoji("cat"), .text(" @x #y")])
    }

    // One input per parser path: nested markup, links and functions.
    @Test(arguments: ["<i>", "[", "$[a "])
    func unclosedOpenersParseInPolynomialTime(opener: String) {
        let text = String(repeating: opener, count: 300) + "x"
        let start = ContinuousClock.now
        let nodes = MFMParser.parse(text)
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(!nodes.isEmpty)
    }

    @Test func quotesWithUnclosedOpenersParseQuickly() {
        let text = (1...40).map { String(repeating: "> ", count: $0) + String(repeating: "<i>", count: 20) }
            .joined(separator: "\n")
        let start = ContinuousClock.now
        let nodes = MFMParser.parse(text)
        #expect(ContinuousClock.now - start < .seconds(1))
        guard case .quote(let children)? = nodes.first else {
            Issue.record("not a quote: \(nodes)")
            return
        }
        #expect(children.contains { if case .quote = $0 { true } else { false } })
    }

    @Test(arguments: ["[", "$[a."])
    func textMadeToBeSlowIsPlainText(opener: String) {
        let text = String(repeating: opener, count: 4000) + " @alice"
        let start = ContinuousClock.now
        #expect(MFMParser.parse(text) == [.text(text)])
        #expect(MFMParser.highlights(in: text).isEmpty)
        #expect(ContinuousClock.now - start < .seconds(1))
        let short = String(repeating: opener, count: 5) + " @alice"
        #expect(MFMParser.parse(short).last == .mention(username: "alice", host: nil))
    }

    @Test func closedConstructsAfterFailedOnesStillParse() {
        #expect(MFMParser.parse("<i><b>a</b>") == [.text("<i>"), .bold([.text("a")])])
        #expect(MFMParser.parse("[[a](https://e.com)") == [.text("["), .link(label: [.text("a")], url: "https://e.com", silent: false)])
    }

    @Test func deepNestingDoesNotRecurseForever() {
        let text = String(repeating: "$[x2 ", count: 200) + "a" + String(repeating: "]", count: 200)
        let nodes = MFMParser.parse(text)
        #expect(!nodes.isEmpty)
    }
}
