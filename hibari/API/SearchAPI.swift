import Foundation

/// What was typed in the search field, read like X's: `from:alice` (also `from:@alice`,
/// `from:alice@host`) narrows the notes to one user's, and the rest are the keywords. A
/// lone `#tag` looks the tag up instead of the text.
struct SearchQuery: Equatable, Sendable {
    /// A user named by `from:`. `host` nil is a user of the account's server.
    struct UserName: Equatable, Sendable {
        let username: String
        let host: String?
    }

    /// As typed, trimmed.
    let text: String
    /// The words besides `from:`, one space between them.
    let keywords: String
    let from: UserName?

    /// `server`: the account's, whose users need no host.
    init(_ text: String, server: URL?) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [Substring] = []
        var from: UserName?
        for word in self.text.split(whereSeparator: \.isWhitespace) {
            if word.lowercased().hasPrefix("from:"),
               let name = NoteServices.mentionedUser(String(word.dropFirst("from:".count)), server: server) {
                from = UserName(username: name.username, host: name.host)
            } else {
                words.append(word)
            }
        }
        keywords = words.joined(separator: " ")
        self.from = from
    }

    var isEmpty: Bool { keywords.isEmpty && from == nil }

    /// The tag of a query that is only `#tag` (or `＃tag`).
    var hashtag: String? {
        guard from == nil, !keywords.contains(" "), let first = keywords.first, first == "#" || first == "＃",
              keywords.count > 1
        else { return nil }
        return String(keywords.dropFirst())
    }

    /// The notes to look for, once the `from:` user is known by id.
    func noteSearch(userID: String?) -> NoteSearch {
        if let hashtag { return .hashtag(hashtag) }
        if let userID, keywords.isEmpty { return .user(userID) }
        return .keywords(keywords, userID: userID)
    }
}

enum NoteSearch: Equatable, Sendable {
    /// `notes/search`: the text, optionally of one user's notes.
    case keywords(String, userID: String?)
    /// `notes/search-by-tag`, which servers allow even where searching text is not.
    case hashtag(String)
    /// `from:` alone: the user's notes and replies (`users/notes`).
    case user(String)
}

struct NoteSearchSource: NoteTimelineSource {
    let client: MisskeyClient
    let search: NoteSearch

    func notes(until untilID: String?, limit: Int) async throws -> [Note] {
        var parameters: [String: any Sendable] = ["limit": limit]
        if let untilID { parameters["untilId"] = untilID }
        let endpoint: String
        switch search {
        case .keywords(let query, let userID):
            endpoint = "notes/search"
            parameters["query"] = query
            if let userID { parameters["userId"] = userID }
        case .hashtag(let tag):
            endpoint = "notes/search-by-tag"
            parameters["tag"] = tag
        case .user(let userID):
            endpoint = "users/notes"
            parameters["userId"] = userID
            parameters["withReplies"] = true
            parameters["withRenotes"] = false
            parameters["withChannelNotes"] = true
        }
        do {
            return try MisskeyJSON.decodeNotes(from: await client.data(endpoint, parameters))
        } catch let error as MisskeyAPIError where SearchError.isNotAllowed(error) {
            throw SearchError.notesNotAllowed
        }
    }
}

protocol UserListSource: Sendable {
    /// Up to `limit` users after the first `offset`. Empty at the end of the list.
    func users(offset: Int, limit: Int) async throws -> [UserDetailed]
}

/// `users/search`: users whose name or username (or, when those find few, bio) has the
/// query, of this server and the ones it knows.
struct UserSearchSource: UserListSource {
    let client: MisskeyClient
    let query: String

    func users(offset: Int, limit: Int) async throws -> [UserDetailed] {
        do {
            return try await client.request(
                "users/search", ["query": query, "offset": offset, "limit": limit, "origin": "combined"],
                as: [UserDetailed].self)
        } catch let error as MisskeyAPIError where SearchError.isNotAllowed(error) {
            throw SearchError.usersNotAllowed
        }
    }
}

struct FixedUserListSource: UserListSource {
    let list: [UserDetailed]

    func users(offset: Int, limit: Int) async throws -> [UserDetailed] {
        offset < list.count ? Array(list[offset...].prefix(limit)) : []
    }
}

enum SearchError: LocalizedError, Equatable {
    case notesNotAllowed
    case usersNotAllowed
    case noSuchUser(String)

    /// What `notes/search` answers without `canSearchNotes`, and any endpoint without the
    /// policy it requires (`users/search`: `canSearchUsers`).
    static func isNotAllowed(_ error: MisskeyAPIError) -> Bool {
        error.code == "UNAVAILABLE" || error.code == "ROLE_PERMISSION_DENIED"
    }

    var errorDescription: String? {
        switch self {
        case .notesNotAllowed: "このサーバーではノートの検索が許可されていません"
        case .usersNotAllowed: "このサーバーではユーザーの検索が許可されていません"
        case .noSuchUser(let acct): "\(acct) は見つかりませんでした"
        }
    }
}

struct Trend: Decodable, Equatable, Sendable {
    let tag: String
    /// How many users used it every 10 minutes, the latest first.
    let chart: [Int]
    /// The most in any 10 minutes.
    let usersCount: Int

    /// `chart` oldest first, for drawing.
    var history: [Int] { chart.reversed() }
}

extension MisskeyClient {
    func trends() async throws -> [Trend] {
        try await request("hashtags/trend", as: [Trend].self)
    }
}
