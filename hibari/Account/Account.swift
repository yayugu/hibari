import Foundation

struct Account: Codable, Hashable, Sendable, Identifiable {
    let server: URL
    let userID: String
    var username: String
    var name: String?
    var avatarUrl: String?
    /// From the user's role policies; nil until known (then assumed available).
    var ltlAvailable: Bool?
    var gtlAvailable: Bool?
    /// nil in accounts saved before they were kept.
    var followingCount: Int?
    var followersCount: Int?
    var nameEmojis: [String: String]?

    var id: String { "\(userID)@\(host)" }
    var host: String { server.host() ?? server.absoluteString }
    var acct: String { "@\(username)@\(host)" }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return username
    }

    init(server: URL, me: MeDetailed) {
        self.server = server
        userID = me.id
        username = me.username
        update(with: me)
    }

    mutating func update(with me: MeDetailed) {
        username = me.username
        name = me.name
        avatarUrl = me.avatarUrl
        ltlAvailable = me.policies?.ltlAvailable
        gtlAvailable = me.policies?.gtlAvailable
        followingCount = me.followingCount ?? followingCount
        followersCount = me.followersCount ?? followersCount
    }

    mutating func resolveNameEmojis(_ resolver: EmojiResolver) {
        let names = MFMParser.parseSimple(displayName).compactMap { node -> String? in
            if case .emoji(let name) = node { name } else { nil }
        }
        let local = EmojiContext(host: nil, remoteEmojis: [:])
        nameEmojis = Dictionary(names.compactMap { name in resolver.url(forName: name, in: local).map { (name, $0) } },
                                uniquingKeysWith: { first, _ in first })
    }
}
