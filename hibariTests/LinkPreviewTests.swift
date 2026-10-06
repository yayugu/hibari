import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import hibari

@Suite("Link previews")
struct LinkPreviewTests {
    private static func note(_ text: String, extra: [String: Any] = [:]) throws -> Note {
        var object: [String: Any] = [
            "id": "n-\(UUID().uuidString)", "createdAt": "2026-09-23T15:00:00.000Z",
            "user": ["id": "u", "username": "tester"], "text": text,
        ]
        object.merge(extra) { $1 }
        return try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func theCardIsForTheLastLinkOfANoteWithoutMediaQuoteOrPoll() throws {
        #expect(LinkPreview.target(of: try Self.note("見て https://a.example/1 と https://b.example/2 です")) == "https://b.example/2")
        #expect(LinkPreview.target(of: try Self.note("**[記事](https://a.example/x)** #tag @someone")) == "https://a.example/x")
        #expect(LinkPreview.target(of: try Self.note("https://a.example/1 ?[静か](https://b.example/2)")) == "https://a.example/1")
        #expect(LinkPreview.target(of: try Self.note("?[静か](https://b.example/2)")) == nil)
        #expect(LinkPreview.target(of: try Self.note("`https://code.example` だけ")) == nil)
        #expect(LinkPreview.target(of: try Self.note("リンクなし")) == nil)

        let file: [String: Any] = ["id": "f", "type": "image/png", "url": "https://media.example/f.png",
                                   "isSensitive": false, "name": "f.png", "properties": [String: Any]()]
        #expect(LinkPreview.target(of: try Self.note("https://a.example", extra: ["files": [file]])) == nil)
        let quoted: [String: Any] = ["id": "q", "createdAt": "2026-09-23T15:00:00.000Z",
                                     "user": ["id": "v", "username": "other"], "text": "引用元"]
        #expect(LinkPreview.target(of: try Self.note("https://a.example", extra: ["renoteId": "q", "renote": quoted])) == nil)
        let poll: [String: Any] = ["multiple": false, "choices": [["text": "a", "votes": 0], ["text": "b", "votes": 0]]]
        #expect(LinkPreview.target(of: try Self.note("https://a.example", extra: ["poll": poll])) == nil)
    }

    @Test func theCardTakesTheLinksPlaceWhereTheTextBeginsOrEndsWithIt() {
        let url = "https://news.example/a"
        #expect(LinkPreview.text("▽ニュースリリースはこちら\n\(url)\n", showingCardFor: url) == "▽ニュースリリースはこちら")
        #expect(LinkPreview.text("\(url)\n先頭のリンク", showingCardFor: url) == "先頭のリンク")
        #expect(LinkPreview.text(url, showingCardFor: url) == "")
        let middle = "途中の \(url) は残す"
        #expect(LinkPreview.text(middle, showingCardFor: url) == middle)
        // Not a bare URL at the end: a link with a label, a URL running on, punctuation after it.
        for text in ["[記事](\(url))", "\(url)/more", "\(url)。", "<\(url)>"] {
            #expect(LinkPreview.text("見て \(text)", showingCardFor: url) == "見て \(text)")
        }
    }

    @Test func readsMisskeysAnswerAndAsksItsProxyForTheFullSizeImage() throws {
        let body: [String: Any] = [
            "url": "https://www.news.example/articles/1", "title": " 記事のタイトル ", "description": "説明",
            "thumbnail": "https://misskey.example/proxy/preview.webp?url=https%3A%2F%2Fnews.example%2Fog.png%3Fa%3D1%26b%3D2&preview=1",
            "thumbnailStyle": "summary_large_image", "sitename": "News",
            "player": ["url": NSNull(), "width": NSNull(), "height": NSNull(), "allow": []], "sensitive": false,
        ]
        let preview = try #require(LinkPreview(json: try JSONSerialization.data(withJSONObject: body)))
        #expect(preview.title == "記事のタイトル")
        #expect(preview.style == .largeImage)
        #expect(preview.domain == "news.example")
        #expect(!preview.hasPlayer && !preview.isSensitive)
        #expect(preview.thumbnail == "https://misskey.example/proxy/preview.webp?url=https%3A%2F%2Fnews.example%2Fog.png%3Fa%3D1%26b%3D2",
                "the image's own query stays escaped")
    }

    @Test func readsMisskeyIosAnswer() throws {
        // No thumbnailStyle, and the image in the proxy's path.
        let body: [String: Any] = [
            "url": "https://github.com/misskey-dev/misskey", "title": "GitHub - misskey-dev/misskey",
            "thumbnail": "https://proxy.misskeyusercontent.jp/preview/repository-images.githubusercontent.com%2F77326607%2Fimage?preview=1",
            "player": ["url": "https://player.example/embed"],
        ]
        let preview = try #require(LinkPreview(json: try JSONSerialization.data(withJSONObject: body)))
        #expect(preview.style == nil)
        #expect(preview.hasPlayer)
        #expect(preview.thumbnail == "https://proxy.misskeyusercontent.jp/preview/repository-images.githubusercontent.com%2F77326607%2Fimage")

        let failed: [String: Any] = ["url": "https://youtube.example", "title": "Preview not available: HTTP 429 Too Many Requests"]
        #expect(LinkPreview(json: try JSONSerialization.data(withJSONObject: failed)) == nil)
        #expect(LinkPreview(json: try JSONSerialization.data(withJSONObject: ["url": "https://a.example"])) == nil)
    }

    @Test func theCardIsTheSizeThePageAsksForIfItsImageCanTakeIt() {
        func size(_ style: LinkPreview.Style?, _ pixels: CGSize?) -> LinkCard.Size {
            LinkCard(preview: Self.card(style: style).preview,
                     thumbnail: pixels.map { .init(url: "https://img.example/a.png", pixelSize: $0) }).size
        }
        #expect(size(.largeImage, CGSize(width: 1200, height: 630)) == .large)
        #expect(size(.largeImage, CGSize(width: 512, height: 512)) == .large, "cropped to the card")
        #expect(size(.summary, CGSize(width: 1200, height: 630)) == .small)
        // Pages that do not say (misskey.io never tells): by the image.
        #expect(size(nil, CGSize(width: 1200, height: 630)) == .large)
        #expect(size(nil, CGSize(width: 512, height: 512)) == .small)
        // Images too small to stand across the note.
        #expect(size(.largeImage, CGSize(width: 180, height: 180)) == .small, "an icon")
        #expect(size(.largeImage, CGSize(width: 1200, height: 120)) == .small, "a thin banner, cropped")
        #expect(size(.largeImage, nil) == .small, "no image")
    }

    @Test func fetchesEachPreviewOnceWithItsImagesSize() async throws {
        let requests = Counter()
        let session = StubURLProtocol.session { request, _ in
            requests.increment()
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            #expect(request.url?.path() == "/url")
            switch page {
            case "https://news.example/1":
                return .json(["url": "https://news.example/1", "title": "記事",
                              "thumbnail": Self.proxied("https://news.example/og.png")])
            case "https://icon.example/":
                return .json(["url": "https://icon.example/", "title": "アイコンだけ",
                              "thumbnail": Self.proxied("https://icon.example/apple-touch-icon.png")])
            case "https://text.example/":
                return .json(["url": "https://text.example/", "title": "画像なし"])
            default:
                return .json(["error": ["code": "URL_PREVIEW_FAILED"]], status: 422)
            }
        }
        let media = PickyMediaSource(available: [
            LinkPreview.fullSize(Self.proxied("https://news.example/og.png")): CGSize(width: 1200, height: 630),
            LinkPreview.fullSize(Self.proxied("https://icon.example/apple-touch-icon.png")): CGSize(width: 180, height: 180),
        ])
        let store = LinkPreviewStore(server: TestData.server, media: media, session: session)
        #expect(store.state(for: "https://news.example/1") == .unknown)

        let pages: Set = ["https://news.example/1", "https://icon.example/", "https://text.example/", "https://gone.example/"]
        await store.prepare(pages, timeout: .seconds(10))
        func card(_ page: String) -> LinkCard? {
            if case .ready(let card) = store.state(for: page) { return card }
            return nil
        }
        #expect(card("https://news.example/1")?.thumbnail?.pixelSize == CGSize(width: 1200, height: 630))
        #expect(card("https://icon.example/")?.thumbnail?.pixelSize == CGSize(width: 180, height: 180))
        #expect(card("https://text.example/")?.preview.title == "画像なし")
        #expect(card("https://text.example/")?.thumbnail == nil)
        #expect(store.state(for: "https://gone.example/") == LinkPreviewState.none)

        await store.prepare(pages, timeout: .seconds(10))
        #expect(requests.count == 4)
    }

    @Test func stopsAskingAServerThatMakesNoPreviews() async {
        let requests = Counter()
        let session = StubURLProtocol.session { _, _ in
            requests.increment()
            return .json(["error": ["code": "URL_PREVIEW_DISABLED", "message": "URL preview is disabled"]], status: 403)
        }
        let store = LinkPreviewStore(server: TestData.server, media: PickyMediaSource(available: [:]), session: session)
        await store.prepare(["https://a.example/"], timeout: .seconds(10))
        await store.prepare(["https://b.example/"], timeout: .seconds(10))
        #expect(store.state(for: "https://a.example/") == LinkPreviewState.none)
        #expect(store.state(for: "https://b.example/") == LinkPreviewState.none)
        #expect(requests.count == 1)
    }

    @Test func asksAgainAfterTheServerWasBusy() async {
        let requests = Counter()
        let session = StubURLProtocol.session { _, _ in
            requests.increment() == 1
                ? .json(["error": ["code": "RATE_LIMIT_EXCEEDED"]], status: 429)
                : .json(["url": "https://a.example/", "title": "A", "thumbnail": Self.proxied("https://a.example/og.png")])
        }
        let media = PickyMediaSource(available: [
            LinkPreview.fullSize(Self.proxied("https://a.example/og.png")): CGSize(width: 1200, height: 630),
        ])
        let store = LinkPreviewStore(server: TestData.server, media: media, session: session)
        await store.prepare(["https://a.example/"], timeout: .seconds(10))
        #expect(store.state(for: "https://a.example/") == .unknown)
        await store.prepare(["https://a.example/"], timeout: .seconds(10))
        guard case .ready = store.state(for: "https://a.example/") else {
            Issue.record("no preview")
            return
        }
    }

    // MARK: Layout

    @Test func theCardSpansTheNoteAtXsAspectInPlaceOfTheLinkAndOpensIt() throws {
        let link = "https://news.example/1"
        let previews = FakeLinkPreviews()
        previews.set(.ready(Self.card()), for: link)
        let engine = Self.engine(previews)
        let context = Samples.context()
        let plain = engine.layout(for: TimelineItem(note: try Self.note("記事")), context: context)
        let layout = engine.layout(for: TimelineItem(note: try Self.note("記事\n\(link)")), context: context)

        let image = try #require(layout.images.first { $0.request?.url == Self.card().thumbnail?.url })
        let text = try #require(layout.blocks.dropFirst().first)
        #expect(text.frame.height == plain.blocks.dropFirst().first?.frame.height, "the link is gone from the text")
        #expect(abs(image.frame.minX - text.frame.minX) < 0.5)
        #expect(abs(image.frame.maxX - text.frame.maxX) < 0.5)
        #expect(abs(image.frame.width / image.frame.height - LinkCardGeometry.aspect) < 0.02)
        #expect(layout.height > plain.height + image.frame.height)
        #expect(layout.action(at: CGPoint(x: image.frame.midX, y: image.frame.midY)) == .link(link))
        let title = try #require(layout.blocks.first { image.frame.contains($0.frame) }, "the title over the image")
        #expect(title.frame.maxY < image.frame.maxY && title.frame.minX > image.frame.minX)
        let domain = try #require(layout.blocks.first { $0.frame.minY >= image.frame.maxY && $0.frame.minY < image.frame.maxY + 10 })
        #expect(domain.frame.minX > image.frame.minX)
        #expect(layout.accessibility.afterTime.contains("記事のタイトル"))
    }

    @Test func theSmallCardHasTheImageBesideTheTitleAndDomain() throws {
        let link = "https://blog.example/1"
        let previews = FakeLinkPreviews()
        previews.set(.ready(Self.card(style: .summary)), for: link)
        let engine = Self.engine(previews)
        let layout = engine.layout(for: TimelineItem(note: try Self.note("ブログ \(link)")), context: Samples.context())

        let image = try #require(layout.images.first { $0.request?.url == Self.card().thumbnail?.url })
        #expect(image.frame.width == LinkCardGeometry.side && image.frame.height >= LinkCardGeometry.side)
        let card = try #require(layout.decorations.last)
        #expect(card.frame.minX == image.frame.minX && card.frame.height == image.frame.height)
        let text = try #require(layout.blocks.first { card.frame.contains($0.frame) }, "the title and domain")
        #expect(text.frame.minX > image.frame.maxX)
        #expect(layout.action(at: CGPoint(x: text.frame.midX, y: text.frame.midY)) == .link(link))
        #expect(layout.targets.allSatisfy { $0.frame.maxY <= card.frame.minY || $0.action != .link(link) || $0.frame == card.frame },
                "the link is gone from the text")
    }

    @Test func aSensitivePagesImageShowsOnlyIfTheAccountShowsSensitiveMedia() throws {
        let link = "https://adult.example/1"
        let previews = FakeLinkPreviews()
        previews.set(.ready(Self.card(sensitive: true)), for: link)
        let engine = Self.engine(previews)
        let item = TimelineItem(note: try Self.note("センシティブ \(link)"))
        let hidden = engine.layout(for: item, context: Samples.context())
        let placeholder = try #require(hidden.images.last)
        #expect(placeholder.request == nil && placeholder.frame.width == LinkCardGeometry.side, "a small card without it")
        let shown = engine.layout(for: item, context: Samples.context(revealsSensitiveMedia: true))
        #expect(shown.images.last?.request?.url == Self.card().thumbnail?.url)
        #expect((shown.images.last?.frame.width ?? 0) > LinkCardGeometry.side)
    }

    @Test func aNoteLaidOutBeforeItsPreviewIsInIsRedoneOnceItIs() throws {
        let link = "https://news.example/1"
        let previews = FakeLinkPreviews()
        let engine = Self.engine(previews)
        let item = TimelineItem(note: try Self.note("記事 \(link)"))
        #expect(engine.linkPreviewURLs(in: [item]) == [link])

        let without = engine.layout(for: item, context: Samples.context())
        #expect(without.pendingLinkPreview == link)
        #expect(engine.isCurrent(without))

        previews.set(.ready(Self.card()), for: link)
        #expect(!engine.isCurrent(without))
        let with = engine.layout(for: item, context: Samples.context())
        #expect(with.serial != without.serial && with.pendingLinkPreview == nil)
        #expect(with.height > without.height)
    }

    private static func card(style: LinkPreview.Style? = .largeImage, sensitive: Bool = false) -> LinkCard {
        var body: [String: Any] = ["url": "https://www.news.example/1", "title": "記事のタイトル", "sensitive": sensitive]
        body["thumbnailStyle"] = style == .largeImage ? "summary_large_image" : style == .summary ? "summary" : nil
        return LinkCard(preview: LinkPreview(json: try! JSONSerialization.data(withJSONObject: body))!,
                        thumbnail: .init(url: "https://img.example/og.png", pixelSize: CGSize(width: 1200, height: 630)))
    }

    private static func proxied(_ url: String) -> String {
        "https://misskey.example/proxy/preview.webp?url=\(url.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&preview=1"
    }

    private static func engine(_ previews: FakeLinkPreviews) -> NoteLayoutEngine {
        NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: [:], mediaProxy: nil), sizes: FakeMediaSizes(),
                         linkPreviews: previews)
    }
}

/// Previews a test sets; `.unknown` until set.
private final class FakeLinkPreviews: LinkPreviewProvider {
    private let states = Locked<[String: LinkPreviewState]>([:])

    func set(_ state: LinkPreviewState, for url: String) {
        states.withLock { $0[url] = state }
    }

    func state(for url: String) -> LinkPreviewState {
        states.withLock { $0[url] } ?? .unknown
    }

    func prepare(_ urls: Set<String>, timeout: Duration) async {}
}

/// Media where only `available` loads.
private final class PickyMediaSource: MediaSource {
    private let available: [String: CGSize]

    init(available: [String: CGSize]) {
        self.available = available
    }

    func imageSource(for url: String) -> CGImageSource? { nil }

    func mediaSize(for url: String) -> MediaSize {
        available[url].map(MediaSize.known) ?? .unavailable
    }

    func prepare(_ url: String) async -> Bool {
        available[url] != nil
    }
}
