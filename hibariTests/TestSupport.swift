import CoreGraphics
import Foundation
import ImageIO
@testable import hibari

enum Samples {
    static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    static let emojis: [String: String] = [
        "blobcat": "https://media.example/emoji/blobcat.png?w=128&h=128",
        "hibari_wide": "https://media.example/emoji/hibari_wide.png?w=384&h=96",
        "tall_bird": "https://media.example/emoji/tall_bird.png?w=96&h=160",
        "ok": "https://media.example/emoji/ok.png?w=128&h=128",
    ]
    static let mediaProxy = "https://proxy.example"

    static let allNotes: [Note] = {
        let data = try! JSONSerialization.data(withJSONObject: SampleJSON.notes(now: now))
        return try! MisskeyJSON.decodeNotes(from: data)
    }()

    static var items: [TimelineItem] { allNotes.map { TimelineItem(note: $0) } }
    /// Without the renotes: each shows another note, which a list shows only once.
    static var distinctItems: [TimelineItem] { items.filter { $0.note?.isPureRenote != true } }

    static func engine() -> NoteLayoutEngine {
        NoteLayoutEngine(emojiResolver: EmojiResolver(localEmojis: emojis, mediaProxy: mediaProxy),
                         sizes: SampleMediaSource())
    }

    /// iPhone 17 / 17 Pro width at 3x.
    static func context(
        width: CGFloat = 402,
        fontScale: CGFloat = 1,
        style: ThemeStyle = .dark,
        revealsSensitiveMedia: Bool = false
    ) -> LayoutContext {
        LayoutContext(canvasWidth: width, displayScale: 3, fontScale: fontScale, style: style,
                      revealsSensitiveMedia: revealsSensitiveMedia)
    }

    static func firstNote(where predicate: (Note) -> Bool) -> Note? {
        allNotes.first(where: predicate)
    }

    static func makeNote(text: String, cw: String? = nil) throws -> Note {
        let object: [String: Any?] = [
            "id": "synthetic-\(UUID().uuidString)",
            "createdAt": "2026-09-23T15:00:00.000Z",
            "user": ["id": "u", "username": "tester", "name": "テスター"],
            "text": text,
            "cw": cw,
        ]
        let data = try JSONSerialization.data(withJSONObject: object.compactMapValues { $0 })
        return try MisskeyJSON.decoder().decode(Note.self, from: data)
    }
}

private enum SampleJSON {
    static let texts = [
        "おはようございます☀️",
        "今日はいい天気ですね。散歩に行ってきます",
        "**太字** と <i>斜体</i> と ~~取り消し~~ と <small>小さい文字</small>",
        "ハッシュタグ #hibari とメンション @alice とリンク https://misskey-hub.net/ja/docs/ と [名前付きリンク](https://example.com)",
        "$[x2 大きい文字] と $[spin くるくる] と $[fg.color=f80 色]",
        "カスタム絵文字 :blobcat: :hibari_wide: :tall_bird: を使ってみる",
        (1...15).map { "\($0)行目のテキスト" }.joined(separator: "\n"),
        "Hello from the tests! This is a longer English sentence to check how the text wraps over several lines.",
        "<center>中央寄せのテキスト</center>",
        "> 引用された文章\nそれに対する返事",
        "`inline code` と\n```\nlet code = \"block\"\n```",
        "🐦🐦🐦",
        "吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。",
        "ｗ",
        "知らない絵文字 :not_an_emoji: はそのまま",
    ]

    static var users: [[String: Any]] {
        let names = ["ひばり", "すずめ :blobcat:", "Tsubame", "メジロ", "とても長い名前のユーザーです :hibari_wide: ほんとうに長い",
                     "Crow", "うぐいす", "Robin"]
        return names.enumerated().map { index, name in
            let remote = index == 5 || index == 7
            return [
                "id": "u\(index)",
                "username": "user\(index)",
                "name": name,
                "host": remote ? "remote.example" : NSNull(),
                "avatarUrl": "https://media.example/avatar/u\(index).png?w=400&h=400",
                "isBot": index == 3,
                "isCat": index == 1,
                "emojis": remote ? ["remote_ai": "https://remote.example/emoji/remote_ai.png?w=128&h=128"] : [:],
            ]
        }
    }

    static let reactions = ["👍", ":ok@.:", "❤", ":blobcat@.:", ":hibari_wide@.:", ":remote_ai@remote.example:", ":gone@.:"]
    static let aspects = [(1600, 1200), (600, 800), (960, 540), (500, 500), (400, 1000)]

    static func notes(now: Date, count: Int = 120) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let users = users
        var notes: [[String: Any]] = []
        for i in 0..<count {
            let user = users[i % users.count]
            let isRemote = !(user["host"] is NSNull)
            var note: [String: Any] = [
                "id": String(format: "n%05d", i),
                "createdAt": formatter.string(from: now.addingTimeInterval(-90 * Double(count - i))),
                "user": user,
                "text": texts[i % texts.count],
                "renoteCount": i % 4,
                "repliesCount": i % 3,
                "emojis": isRemote ? user["emojis"]! : [String: String](),
                "reactions": [String: Int](),
                "reactionEmojis": [String: String](),
                "files": [[String: Any]](),
            ]
            if isRemote, let text = note["text"] as? String {
                note["text"] = text.replacingOccurrences(of: ":blobcat:", with: ":remote_ai:")
            }
            let target = notes.last { $0["text"] != nil && $0["renote"] == nil }
            if let target, i % 7 == 3 {
                note["text"] = nil
                note["renoteId"] = target["id"]
                note["renote"] = target
                notes.append(note)
                continue
            }
            if let target, i % 11 == 5 {
                note["renoteId"] = target["id"]
                note["renote"] = target
            }
            if let target, i % 13 == 8 {
                note["replyId"] = target["id"]
                note["reply"] = target
            }
            if i % 9 == 4 { note["cw"] = "ネタバレ注意" }
            if i % 5 == 1 {
                let count = (i / 5) % 5 + 1
                let sensitive = (i / 5) % 3 == 0
                note["files"] = (0..<count).map { k in image(id: "n\(i)-\(k)", aspect: aspects[(i + k) % aspects.count],
                                                             sensitive: sensitive && k == 0) }
            }
            if i % 17 == 2 {
                note["files"] = [[
                    "id": "n\(i)-video", "type": "video/mp4", "name": "video.mp4", "isSensitive": false,
                    "properties": ["width": 1280, "height": 720], "url": "https://media.example/file/n\(i).mp4",
                    "thumbnailUrl": "https://media.example/thumb/n\(i).png?w=498&h=280",
                ]]
            }
            if i % 19 == 6 {
                note["poll"] = ["multiple": false, "expiresAt": NSNull(),
                                "choices": [["text": "たけのこ", "votes": 12], ["text": "きのこ", "votes": 7]]]
            }
            var counts: [String: Int] = [:]
            for (bit, key) in reactions.enumerated() where i & (1 << bit) != 0 {
                counts[key] = bit + 1
            }
            note["reactions"] = counts
            if counts.keys.contains(":remote_ai@remote.example:") {
                note["reactionEmojis"] = ["remote_ai@remote.example": "https://remote.example/emoji/remote_ai.png?w=128&h=128"]
            }
            notes.append(note)
        }
        return notes.reversed()
    }

    static func image(id: String, aspect: (Int, Int), sensitive: Bool) -> [String: Any] {
        let (w, h) = aspect
        return [
            "id": id, "type": "image/png", "name": "\(id).png", "isSensitive": sensitive,
            "properties": ["width": w, "height": h],
            "url": "https://media.example/file/\(id).png?w=\(w)&h=\(h)",
            "thumbnailUrl": "https://media.example/thumb/\(id).png?w=498&h=\(498 * h / w)",
        ]
    }
}

/// Media made up from its URL: `…?w=300&h=200` is a 300×200 PNG, generated on first use.
/// Proxied URLs (`…/image.webp?url=…`) are the image they proxy. Anything else is
/// unavailable. Everything is local: `prepare` never waits.
final class SampleMediaSource: MediaSource {
    private let images = Locked<[String: Data]>([:])

    static func pixelSize(of url: String) -> CGSize? {
        guard let items = URLComponents(string: url)?.queryItems else { return nil }
        if let inner = items.first(where: { $0.name == "url" })?.value { return pixelSize(of: inner) }
        guard let w = items.first(where: { $0.name == "w" })?.value.flatMap(Int.init),
              let h = items.first(where: { $0.name == "h" })?.value.flatMap(Int.init), w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    func imageSource(for url: String) -> CGImageSource? {
        guard let size = Self.pixelSize(of: url) else { return nil }
        let data = images.withLock { $0[url] } ?? {
            let data = TestData.png(width: Int(size.width), height: Int(size.height))
            images.withLock { $0[url] = data }
            return data
        }()
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    func mediaSize(for url: String) -> MediaSize {
        Self.pixelSize(of: url).map(MediaSize.known) ?? .unavailable
    }

    func prepare(_ url: String) async -> Bool {
        Self.pixelSize(of: url) != nil
    }
}

/// Layouts at `Samples.now` unless a test is about time.
extension NoteLayoutEngine {
    func key(for item: TimelineItem, context: LayoutContext) -> LayoutKey {
        key(for: item, context: context, now: Samples.now)
    }

    func cachedLayout(for item: TimelineItem, context: LayoutContext) -> NoteLayout? {
        cachedLayout(for: item, context: context, now: Samples.now)
    }

    func layout(for item: TimelineItem, context: LayoutContext) -> NoteLayout {
        layout(for: item, context: context, now: Samples.now)
    }

    func layouts(for items: [TimelineItem], context: LayoutContext) -> [NoteLayout] {
        layouts(for: items, context: context, now: Samples.now)
    }
}

/// Media sizes a test controls; `.unknown` until set.
final class FakeMediaSizes: MediaSizeProvider {
    private let sizes = Locked<[String: MediaSize]>([:])

    func set(_ size: MediaSize, for url: String) {
        sizes.withLock { $0[url] = size }
    }

    func mediaSize(for url: String) -> MediaSize {
        sizes.withLock { $0[url] } ?? .unknown
    }
}

/// Media that is unavailable on the first request for each URL, like a download that has
/// not finished yet.
final class FlakyMediaSource: MediaSource {
    private let base: any MediaSource
    private let requested = Locked<Set<String>>([])

    init(base: any MediaSource) {
        self.base = base
    }

    func imageSource(for url: String) -> CGImageSource? {
        let isFirst = requested.withLock { $0.insert(url).inserted }
        return isFirst ? nil : base.imageSource(for: url)
    }

    func mediaSize(for url: String) -> MediaSize {
        base.mediaSize(for: url)
    }

    func prepare(_ url: String) async -> Bool {
        await base.prepare(url)
    }
}

/// Media as a network source would see it: nothing is local until `prepare` has
/// "downloaded" it, which takes `delay`.
final class DownloadingMediaSource: MediaSource {
    private let base: any MediaSource
    private let delay: Duration
    private let downloaded = Locked<Set<String>>([])

    init(base: any MediaSource, delay: Duration) {
        self.base = base
        self.delay = delay
    }

    func imageSource(for url: String) -> CGImageSource? {
        downloaded.withLock { $0.contains(url) } ? base.imageSource(for: url) : nil
    }

    func mediaSize(for url: String) -> MediaSize {
        downloaded.withLock { $0.contains(url) } ? base.mediaSize(for: url) : .unknown
    }

    func prepare(_ url: String) async -> Bool {
        try? await Task.sleep(for: delay)
        guard await base.prepare(url) else { return false }
        downloaded.withLock { _ = $0.insert(url) }
        return true
    }
}
