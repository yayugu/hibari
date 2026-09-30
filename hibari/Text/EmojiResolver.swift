import Foundation

struct EmojiContext: Sendable {
    /// Host of the author; nil for local users.
    let host: String?
    /// For remote authors: name -> raw URL (`note.emojis` or `user.emojis`).
    let remoteEmojis: [String: String]

    static func text(of note: Note) -> EmojiContext {
        EmojiContext(host: note.user.host, remoteEmojis: note.emojis)
    }

    static func name(of user: User) -> EmojiContext {
        EmojiContext(host: user.host, remoteEmojis: user.emojis)
    }
}

final class EmojiResolver: Sendable {
    enum Reaction: Equatable, Sendable {
        case unicode(String)
        /// `url` is nil if the emoji is unknown (deleted, or not federated).
        case custom(name: String, url: String?)
    }

    private let localEmojis: [String: String]
    private let mediaProxy: String?

    init(localEmojis: [String: String], mediaProxy: String?) {
        self.localEmojis = localEmojis
        self.mediaProxy = mediaProxy
    }

    func url(forName name: String, in context: EmojiContext) -> String? {
        guard context.host != nil else { return localEmojis[name] }
        return context.remoteEmojis[name].map { MediaRequestPolicy.remoteEmojiURL($0, mediaProxy: mediaProxy) }
    }

    /// Reaction keys are `❤` (unicode), `:name@.:` (local) or `:name@host:` (remote).
    func reaction(_ key: String, reactionEmojis: [String: String]) -> Reaction {
        guard key.count > 2, key.hasPrefix(":"), key.hasSuffix(":") else { return .unicode(key) }
        let body = key.dropFirst().dropLast()
        guard let at = body.lastIndex(of: "@") else {
            let name = String(body)
            return .custom(name: name, url: localEmojis[name])
        }
        let name = String(body[..<at])
        let host = String(body[body.index(after: at)...])
        if host == "." {
            return .custom(name: name, url: localEmojis[name])
        }
        let raw = reactionEmojis["\(name)@\(host)"]
        return .custom(name: name, url: raw.map { MediaRequestPolicy.remoteEmojiURL($0, mediaProxy: mediaProxy) })
    }
}
