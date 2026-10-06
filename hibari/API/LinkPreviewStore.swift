import Foundation

protocol LinkPreviewProvider: Sendable {
    /// What layout shows for `url`. Must not block on the network.
    func state(for url: String) -> LinkPreviewState

    /// Fetches the previews of `urls` and their thumbnails, waiting at most `timeout`. Ones
    /// still loading then go on, and `LinkPreviewStore.didLoad` tells layout when they are in.
    func prepare(_ urls: Set<String>, timeout: Duration) async
}

/// No previews: tests, and the fixtures of perf builds.
struct NoLinkPreviews: LinkPreviewProvider {
    func state(for url: String) -> LinkPreviewState { .none }
    func prepare(_ urls: Set<String>, timeout: Duration) async {}
}

/// The previews of an account's server (`/url`), each fetched once a session. The server
/// says how long its answers keep (a day on Misskey, a week on misskey.io), and the disk
/// cache of `.linkPreviews` keeps them that long across launches. The page's image downloads
/// into `media` before the card shows, for layout to know its size.
final class LinkPreviewStore: LinkPreviewProvider {
    /// A preview that a layout went without is in. Posted on the main thread.
    static let didLoad = Notification.Name("LinkPreviewStore.didLoad")

    private let server: URL
    private let session: URLSession
    private let media: any MediaSource

    private struct State {
        var known: [String: LinkPreviewState] = [:]
        /// Asked for by layout while unknown.
        var missed: Set<String> = []
        var loads: [String: Task<Void, Never>] = [:]
        /// The server makes no previews (`URL_PREVIEW_DISABLED`).
        var isDisabled = false
    }

    private let state = Locked(State())
    private let limit = 5000

    init(server: URL, media: any MediaSource, session: URLSession = .linkPreviews) {
        self.server = server
        self.media = media
        self.session = session
    }

    func state(for url: String) -> LinkPreviewState {
        state.withLock { state in
            if let known = state.known[url] { return known }
            if state.isDisabled { return .none }
            state.missed.insert(url)
            return .unknown
        }
    }

    func prepare(_ urls: Set<String>, timeout: Duration) async {
        let loads = state.withLock { state -> [Task<Void, Never>] in
            guard !state.isDisabled else { return [] }
            return urls.filter { state.known[$0] == nil }.map { url in
                if let running = state.loads[url] { return running }
                let load = Task { await self.load(url) }
                state.loads[url] = load
                return load
            }
        }
        guard !loads.isEmpty else { return }
        let all = Task {
            for load in loads { await load.value }
        }
        await waitForCompletion(of: all, timeout: timeout)
    }

    private func load(_ url: String) async {
        let result = await fetch(url)
        let wasMissed = state.withLock { state in
            state.loads[url] = nil
            // Left unknown when it may work later (offline, the server busy): the next
            // `prepare` asks again.
            guard let result else { return false }
            if state.known.count >= limit { state.known.removeAll(keepingCapacity: true) }
            state.known[url] = result
            return state.missed.remove(url) != nil
        }
        if wasMissed {
            Task { @MainActor in
                NotificationCenter.default.post(name: Self.didLoad, object: self)
            }
        }
    }

    private func fetch(_ url: String) async -> LinkPreviewState? {
        guard var components = URLComponents(url: server.appending(path: "url"), resolvingAgainstBaseURL: false)
        else { return LinkPreviewState.none }
        components.queryItems = [URLQueryItem(name: "url", value: url), URLQueryItem(name: "lang", value: "ja-JP")]
        guard let requestURL = components.url else { return LinkPreviewState.none }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: requestURL)
        } catch {
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return LinkPreviewState.none }
        switch http.statusCode {
        case 200..<300:
            break
        case 403 where MisskeyAPIError.Body(data).code == "URL_PREVIEW_DISABLED":
            state.withLock { $0.isDisabled = true }
            return LinkPreviewState.none
        case 408, 429, 500...:
            return nil
        default:
            return LinkPreviewState.none
        }
        guard let preview = LinkPreview(json: data) else { return LinkPreviewState.none }
        guard let url = preview.thumbnail else { return .ready(LinkCard(preview: preview, thumbnail: nil)) }
        _ = await media.prepare(url)
        switch media.mediaSize(for: url) {
        case .known(let size):
            return .ready(LinkCard(preview: preview, thumbnail: LinkCard.Thumbnail(url: url, pixelSize: size)))
        case .unavailable:
            return .ready(LinkCard(preview: preview, thumbnail: nil))
        case .unknown:
            // It did not download this time (offline?): asked again with the page.
            return nil
        }
    }
}

extension URLSession {
    /// Keeps `/url` answers on disk for as long as the server says.
    static let linkPreviews: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 16 * 1024 * 1024,
                                          directory: URL.cachesDirectory.appending(path: "LinkPreviews",
                                                                                   directoryHint: .isDirectory))
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": HibariUserAgent.value]
        return URLSession(configuration: configuration)
    }()
}
