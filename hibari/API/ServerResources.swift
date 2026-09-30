import Foundation

struct ServerResources: Codable, Sendable {
    let info: ServerInfo
    /// Local custom emoji name -> URL.
    let emojis: [String: String]
    /// The emojis in the server's order with their aliases and categories, for the
    /// reaction picker. nil in copies saved before it existed.
    var emojiList: [EmojiCatalog.Entry]?
    let fetchedAt: Date

    func emojiResolver() -> EmojiResolver {
        EmojiResolver(localEmojis: emojis, mediaProxy: info.mediaProxy)
    }

    func emojiCatalog() -> EmojiCatalog {
        EmojiCatalog(entries: emojiList ?? emojis.sorted { $0.key < $1.key }.map {
            EmojiCatalog.Entry(name: $0.key, url: $0.value, aliases: [], category: nil)
        })
    }

    static func fetch(from server: URL, session: URLSession = .misskeyAPI) async throws -> ServerResources {
        async let info = ServerInfo.fetch(from: server, session: session)
        async let list = fetchEmojis(from: server, session: session)
        let entries = try await list
        let emojis = Dictionary(entries.map { ($0.name, $0.url) }, uniquingKeysWith: { first, _ in first })
        return try await ServerResources(info: info, emojis: emojis, emojiList: entries, fetchedAt: Date())
    }

    private static func fetchEmojis(from server: URL, session: URLSession) async throws -> [EmojiCatalog.Entry] {
        struct List: Decodable {
            let emojis: LossyArray<CustomEmoji>
        }
        let list = try await MisskeyClient(server: server, session: session).request("emojis", as: List.self)
        return list.emojis.elements.map {
            EmojiCatalog.Entry(name: $0.name, url: $0.url, aliases: $0.aliases ?? [], category: $0.category,
                               isSensitive: $0.isSensitive)
        }
    }
}

struct ServerResourceCache: Sendable {
    static let shared = ServerResourceCache(
        directory: URL.cachesDirectory.appending(path: "Servers", directoryHint: .isDirectory))

    let directory: URL

    private func fileURL(for server: URL) -> URL {
        let name = (server.host() ?? "server") + (server.port.map { "_\($0)" } ?? "")
        return directory.appending(path: "\(name).json")
    }

    /// Reads the saved copy. Call off the main thread (it can be a few MB).
    func load(for server: URL) -> ServerResources? {
        guard let data = try? Data(contentsOf: fileURL(for: server)) else { return nil }
        return try? JSONDecoder().decode(ServerResources.self, from: data)
    }

    @discardableResult
    func refresh(for server: URL, session: URLSession = .misskeyAPI) async throws -> ServerResources {
        let resources = try await ServerResources.fetch(from: server, session: session)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(resources) {
            try? data.write(to: fileURL(for: server), options: .atomic)
        }
        return resources
    }
}
