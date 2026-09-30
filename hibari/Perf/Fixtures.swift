#if PERF
import Foundation
import ImageIO
import UIKit

final class FixtureStore: Sendable {
    struct Manifest: Decodable, Sendable {
        struct Timeline: Decodable, Sendable {
            let id: String
            let title: String
            let endpoint: String
            let pages: [String]
        }

        let host: String
        let mediaProxy: String?
        let fetchedAt: Date
        let timelines: [Timeline]
        let emojis: String
        let mediaIndex: String
    }

    static let shared: FixtureStore? = {
        guard let url = Bundle.main.url(forResource: "Fixtures", withExtension: "bundle") else { return nil }
        return try? FixtureStore(root: url)
    }()

    let root: URL
    let manifest: Manifest
    /// Local custom emoji name -> URL (subset of `/api/emojis`).
    let localEmojis: [String: String]
    private let mediaIndex: [String: String]

    init(root: URL) throws {
        self.root = root
        let decoder = MisskeyJSON.decoder()
        manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        mediaIndex = try JSONDecoder().decode(
            [String: String].self,
            from: Data(contentsOf: root.appending(path: manifest.mediaIndex))
        )
        struct EmojiList: Decodable { let emojis: [CustomEmoji] }
        let emojis = try decoder.decode(EmojiList.self, from: Data(contentsOf: root.appending(path: manifest.emojis)))
        localEmojis = Dictionary(emojis.emojis.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
    }

    var timelines: [Manifest.Timeline] { manifest.timelines }

    /// Reads and decodes one page. Call off the main thread.
    func loadPage(_ path: String) throws -> [Note] {
        let data = try Data(contentsOf: root.appending(path: path), options: .mappedIfSafe)
        return try MisskeyJSON.decodeNotes(from: data)
    }

    func fileURL(forMedia requestURL: String) -> URL? {
        mediaIndex[requestURL].map { root.appending(path: $0) }
    }
}

/// A fixture timeline served the way the API pages it: `untilId` cursor (or `sinceId`,
/// oldest first), `limit` notes per request, after a simulated network delay. It can hold
/// back its newest notes (`hidden`) until `revealAll()`, as if they were posted meanwhile.
actor FixtureTimelineSource: NoteTimelineSource {
    private let store: FixtureStore
    private let pages: [String]
    private let latency: Duration
    private var hidden: Int
    private var all: [Note]?
    private var positions: [String: Int] = [:]

    init(store: FixtureStore, timeline: FixtureStore.Manifest.Timeline, latency: Duration, hidden: Int = 0) {
        self.store = store
        pages = timeline.pages
        self.latency = latency
        self.hidden = hidden
    }

    func notes(until untilID: String?, limit: Int) async throws -> [Note] {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        let all = try loadAll()
        var start = min(hidden, all.count)
        if let untilID {
            guard let position = positions[untilID] else { return [] }
            start = max(start, position + 1)
        }
        return Array(all[start..<min(start + limit, all.count)])
    }

    func notes(after sinceID: String, limit: Int) async throws -> [Note]? {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        let all = try loadAll()
        guard let end = positions[sinceID] else { return [] }
        let start = max(hidden, end - limit)
        return start < end ? Array(all[start..<end].reversed()) : []
    }

    func revealAll() {
        hidden = 0
    }

    /// Every note, newest first.
    func allNotes() throws -> [Note] {
        try loadAll()
    }

    private func loadAll() throws -> [Note] {
        if let all { return all }
        let notes = try pages.flatMap { try store.loadPage($0) }
        positions = Dictionary(notes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        all = notes
        return notes
    }
}

/// Fixture media is all local: a URL either has its file (and a size) or never will.
final class FixtureMediaSource: MediaSource {
    private let store: FixtureStore
    private let sizes = Locked<[String: MediaSize]>([:])

    init(store: FixtureStore) {
        self.store = store
    }

    func imageSource(for url: String) -> CGImageSource? {
        guard let file = store.fileURL(forMedia: url) else { return nil }
        return CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    func mediaSize(for url: String) -> MediaSize {
        if let cached = sizes.withLock({ $0[url] }) { return cached }
        let size = imageSource(for: url).flatMap(ImageMetadata.pixelSize(of:)).map(MediaSize.known) ?? .unavailable
        sizes.withLock { $0[url] = size }
        return size
    }

    func prepare(_ url: String) async -> Bool {
        store.fileURL(forMedia: url) != nil
    }

    func localFile(for url: String) -> URL? {
        store.fileURL(forMedia: url)
    }
}

struct EmptyMediaSource: MediaSource {
    func imageSource(for url: String) -> CGImageSource? { nil }
    func mediaSize(for url: String) -> MediaSize { .unavailable }
    func prepare(_ url: String) async -> Bool { false }
}

extension TimelineSession {
    static func fixtures(_ store: FixtureStore) -> TimelineSession {
        let fetchedAt = store.manifest.fetchedAt
        return TimelineSession(
            timelines: store.timelines.map { timeline in
                Timeline(id: timeline.id, title: timeline.title,
                         source: FixtureTimelineSource(store: store, timeline: timeline, latency: AppSettings.fixtureLatency,
                                                       hidden: AppSettings.fixtureHiddenNewest))
            },
            engine: NoteLayoutEngine(
                emojiResolver: EmojiResolver(localEmojis: store.localEmojis, mediaProxy: store.manifest.mediaProxy),
                sizes: ImagePipeline.shared),
            clock: AppSettings.benchmarkMode != nil ? .frozen(at: fetchedAt) : .starting(at: fetchedAt),
            account: Account(server: URL(string: "https://\(store.manifest.host)")!,
                             me: MeDetailed(id: "perf", username: "perf", name: nil, avatarUrl: nil, policies: nil,
                                            followingCount: 0, followersCount: 0)),
            client: nil,
            emojis: EmojiCatalog(entries: store.localEmojis.sorted { $0.key < $1.key }.map {
                EmojiCatalog.Entry(name: $0.key, url: $0.value, aliases: [], category: nil)
            }))
    }
}

final class MissingFixturesViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Fixtures.bundle がありません。\n\nscripts/fetch_fixtures.py を実行してから\nビルドし直してください。"
        label.frame = view.bounds.insetBy(dx: 24, dy: 0)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}
#endif
