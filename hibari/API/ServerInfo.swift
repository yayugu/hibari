import Foundation

struct ServerInfo: Codable, Sendable, Equatable {
    struct Features: Codable, Sendable, Equatable {
        var miauth: Bool?
        var localTimeline: Bool?
        var globalTimeline: Bool?
    }

    var name: String?
    var uri: String?
    var version: String?
    var iconUrl: String?
    /// Base URL of the media proxy (`https://proxy.example`); remote custom emojis go
    /// through it.
    var mediaProxy: String?
    /// The most characters a note's text may have (Misskey counts unicode scalars).
    var maxNoteTextLength: Int?
    var features: Features?

    static func fetch(from server: URL, session: URLSession = .misskeyAPI) async throws -> ServerInfo {
        let info = try await MisskeyClient(server: server, session: session).request("meta", as: ServerInfo.self)
        guard info.version != nil else { throw MisskeyAPIError.invalidResponse }
        return info
    }
}

struct MeDetailed: Decodable, Sendable {
    struct Policies: Decodable, Sendable {
        var ltlAvailable: Bool?
        var gtlAvailable: Bool?
    }

    let id: String
    let username: String
    let name: String?
    let avatarUrl: String?
    let policies: Policies?
    let followingCount: Int?
    let followersCount: Int?
}

/// Parses what the user types as a server: `misskey.io`, `https://misskey.io/`,
/// `http://localhost:3000`. Assumes https without a scheme, drops paths and lowercases
/// the host (`URLComponents` turns non-ASCII hosts into punycode).
enum ServerAddress {
    static func url(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let at = text.lastIndex(of: "@"), !text.contains("://") {
            text = String(text[text.index(after: at)...])
        }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, !host.contains(" ")
        else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url, url.host() != nil else { return nil }
        return url
    }
}
