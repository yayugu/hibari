import Foundation

final class Note: Codable, Sendable {
    let id: String
    let createdAt: Date
    let user: User
    let text: String?
    let cw: String?
    let visibility: String
    /// Who a direct note (`specified`) is for, besides its author.
    let visibleUserIds: [String]
    let localOnly: Bool
    let renoteCount: Int
    let repliesCount: Int
    let reactions: [String: Int]
    let reactionEmojis: [String: String]
    /// Custom emojis used in `text` / `cw` of a remote note (name -> raw URL).
    let emojis: [String: String]
    let files: [DriveFile]
    let replyId: String?
    let renoteId: String?
    let reply: Note?
    let renote: Note?
    let poll: Poll?
    let myReaction: String?
    /// Which reactions the author takes (Misskey's `reactionAcceptance`). The server turns
    /// the others into ❤. Its `…ForRemote` parts are about users of other servers, never
    /// the account; remote notes do not carry it (their own server applies it).
    let reactionAcceptance: String?
    /// The account has renoted this note (a pure renote). Misskey does not say, so this is
    /// what the app knows (`RenoteController`): renotes made in the app, and the account's
    /// renotes that came in timelines. Always false as decoded.
    let isRenotedByMe: Bool
    /// The account has bookmarked this note (Misskey's お気に入り). Notes do not say
    /// either (only `notes/state` does), so this is what the app knows
    /// (`BookmarkController`). Always false as decoded.
    let isBookmarked: Bool

    /// A renote without its own content: shown as "X がリノート" + the renoted note.
    /// Like Misskey, a renote that is also a reply counts as a quote.
    var isPureRenote: Bool {
        renote != nil && replyId == nil && !hasOwnContent
    }

    /// A pure renote whose target did not come with it (deleted, or not visible to us).
    /// There is nothing to show.
    var isUnavailableRenote: Bool {
        renoteId != nil && renote == nil && replyId == nil && !hasOwnContent
    }

    /// The note the timeline shows: the renoted one for a pure renote.
    var displayedNote: Note {
        isPureRenote ? renote! : self
    }

    private var hasOwnContent: Bool {
        text != nil || cw != nil || !files.isEmpty || poll != nil
    }

    var reactionTotal: Int { reactions.values.reduce(0, ServerCount.adding) }

    /// Takes likes only (Misskey's いいねのみ): every reaction becomes ❤.
    var isLikeOnly: Bool { reactionAcceptance == "likeOnly" }

    /// Sensitive custom emojis become ❤.
    var rejectsSensitiveReactions: Bool {
        reactionAcceptance == "nonSensitiveOnly" || reactionAcceptance == "nonSensitiveOnlyForLocalLikeOnlyForRemote"
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, user, text, cw, visibility, visibleUserIds, localOnly, renoteCount, repliesCount
        case reactions, reactionEmojis, emojis, files, replyId, renoteId, reply, renote, poll, myReaction
        case reactionAcceptance
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        user = try c.decode(User.self, forKey: .user)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        cw = try c.decodeIfPresent(String.self, forKey: .cw)
        visibility = (try? c.decodeIfPresent(String.self, forKey: .visibility)) ?? "public"
        visibleUserIds = (try? c.decodeIfPresent([String].self, forKey: .visibleUserIds)) ?? []
        localOnly = (try? c.decodeIfPresent(Bool.self, forKey: .localOnly)) ?? false
        renoteCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .renoteCount)) ?? 0)
        repliesCount = max(0, (try? c.decodeIfPresent(Int.self, forKey: .repliesCount)) ?? 0)
        reactions = ((try? c.decodeIfPresent([String: Int].self, forKey: .reactions)) ?? [:]).mapValues { max(0, $0) }
        reactionEmojis = (try? c.decodeIfPresent([String: String].self, forKey: .reactionEmojis)) ?? [:]
        emojis = (try? c.decodeIfPresent([String: String].self, forKey: .emojis)) ?? [:]
        files = (try? c.decodeIfPresent(LossyArray<DriveFile>.self, forKey: .files))?.elements ?? []
        replyId = try c.decodeIfPresent(String.self, forKey: .replyId)
        renoteId = try c.decodeIfPresent(String.self, forKey: .renoteId)
        reply = try? c.decodeIfPresent(Note.self, forKey: .reply)
        renote = try? c.decodeIfPresent(Note.self, forKey: .renote)
        poll = try? c.decodeIfPresent(Poll.self, forKey: .poll)
        myReaction = try? c.decodeIfPresent(String.self, forKey: .myReaction)
        reactionAcceptance = try? c.decodeIfPresent(String.self, forKey: .reactionAcceptance)
        isRenotedByMe = false
        isBookmarked = false
    }

    /// `isRenotedByMe` and `isBookmarked` are not the server's, so they are not written.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(user, forKey: .user)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(cw, forKey: .cw)
        try c.encode(visibility, forKey: .visibility)
        if !visibleUserIds.isEmpty { try c.encode(visibleUserIds, forKey: .visibleUserIds) }
        try c.encode(localOnly, forKey: .localOnly)
        try c.encode(renoteCount, forKey: .renoteCount)
        try c.encode(repliesCount, forKey: .repliesCount)
        try c.encode(reactions, forKey: .reactions)
        try c.encode(reactionEmojis, forKey: .reactionEmojis)
        try c.encode(emojis, forKey: .emojis)
        try c.encode(files, forKey: .files)
        try c.encodeIfPresent(replyId, forKey: .replyId)
        try c.encodeIfPresent(renoteId, forKey: .renoteId)
        try c.encodeIfPresent(reply, forKey: .reply)
        try c.encodeIfPresent(renote, forKey: .renote)
        try c.encodeIfPresent(poll, forKey: .poll)
        try c.encodeIfPresent(myReaction, forKey: .myReaction)
        try c.encodeIfPresent(reactionAcceptance, forKey: .reactionAcceptance)
    }

    private init(_ note: Note, reactions: [String: Int]? = nil, reactionEmojis: [String: String]? = nil,
                 myReaction: String?? = nil, renoteCount: Int? = nil, isRenotedByMe: Bool? = nil,
                 isBookmarked: Bool? = nil, reply: Note?? = nil, renote: Note?? = nil) {
        id = note.id
        createdAt = note.createdAt
        user = note.user
        text = note.text
        cw = note.cw
        visibility = note.visibility
        visibleUserIds = note.visibleUserIds
        localOnly = note.localOnly
        self.renoteCount = renoteCount ?? note.renoteCount
        repliesCount = note.repliesCount
        self.reactions = reactions ?? note.reactions
        self.reactionEmojis = reactionEmojis ?? note.reactionEmojis
        emojis = note.emojis
        files = note.files
        replyId = note.replyId
        renoteId = note.renoteId
        self.reply = reply ?? note.reply
        self.renote = renote ?? note.renote
        poll = note.poll
        self.myReaction = myReaction ?? note.myReaction
        reactionAcceptance = note.reactionAcceptance
        self.isRenotedByMe = isRenotedByMe ?? note.isRenotedByMe
        self.isBookmarked = isBookmarked ?? note.isBookmarked
    }

    func with(reactions: [String: Int], reactionEmojis: [String: String], myReaction: String?) -> Note {
        Note(self, reactions: reactions, reactionEmojis: reactionEmojis, myReaction: .some(myReaction))
    }

    /// With the account's renote state (and the count, unless nil).
    func with(isRenotedByMe: Bool, renoteCount: Int? = nil) -> Note {
        var count = renoteCount ?? self.renoteCount
        // The account's renote counts, whatever the copy says: Misskey sends the renoted
        // note along before counting the renote.
        if isRenotedByMe { count = max(count, 1) }
        guard isRenotedByMe != self.isRenotedByMe || count != self.renoteCount else { return self }
        return Note(self, renoteCount: count, isRenotedByMe: isRenotedByMe)
    }

    func with(isBookmarked: Bool) -> Note {
        isBookmarked == self.isBookmarked ? self : Note(self, isBookmarked: isBookmarked)
    }

    /// This note with `change` applied wherever the note it is about appears: itself, or the
    /// notes it renotes, quotes or replies to. Returns `self` when none of them is affected.
    func applying(_ change: some NoteChange) -> Note {
        let reply = self.reply?.applying(change)
        let renote = self.renote?.applying(change)
        let note = reply !== self.reply || renote !== self.renote
            ? Note(self, reply: .some(reply), renote: .some(renote)) : self
        return id == change.noteID ? change.applied(to: note) : note
    }

    /// Whether `noteID` is this note or one it embeds.
    func contains(noteID: String) -> Bool {
        id == noteID || reply?.contains(noteID: noteID) == true || renote?.contains(noteID: noteID) == true
    }

    /// The ids of this note and of the notes it embeds.
    var containedNoteIDs: [String] {
        [id] + (reply?.containedNoteIDs ?? []) + (renote?.containedNoteIDs ?? [])
    }

    var visualFiles: [DriveFile] { files.filter { $0.isImage || $0.isVideo } }

    var otherFiles: [DriveFile] { files.filter { !($0.isImage || $0.isVideo) } }
}

protocol NoteChange: Sendable {
    var noteID: String { get }
    /// `note`, which has the id `noteID`, with the change.
    func applied(to note: Note) -> Note
}

struct ReactionChange: NoteChange, Equatable {
    let noteID: String
    let reactions: [String: Int]
    let reactionEmojis: [String: String]
    let myReaction: String?

    init(noteID: String, reactions: [String: Int], reactionEmojis: [String: String], myReaction: String?) {
        self.noteID = noteID
        self.reactions = reactions
        self.reactionEmojis = reactionEmojis
        self.myReaction = myReaction
    }

    init(_ note: Note) {
        self.init(noteID: note.id, reactions: note.reactions, reactionEmojis: note.reactionEmojis,
                  myReaction: note.myReaction)
    }

    /// With the user's reaction set to `key` (a stored key, see `ReactionKey`), or removed
    /// for nil. Counts follow: the old reaction loses one, the new one gains one.
    func reacting(_ key: String?) -> ReactionChange {
        guard key != myReaction else { return self }
        var reactions = self.reactions
        if let old = myReaction, let count = reactions[old] {
            reactions[old] = count > 1 ? count - 1 : nil
        }
        if let key {
            reactions[key] = ServerCount.adding(reactions[key, default: 0], 1)
        }
        return ReactionChange(noteID: noteID, reactions: reactions, reactionEmojis: reactionEmojis, myReaction: key)
    }

    func applied(to note: Note) -> Note {
        note.with(reactions: reactions, reactionEmojis: reactionEmojis, myReaction: myReaction)
    }
}

struct RenoteChange: NoteChange, Equatable {
    let noteID: String
    let isRenoted: Bool
    /// nil: the count each copy has.
    let renoteCount: Int?

    func applied(to note: Note) -> Note {
        note.with(isRenotedByMe: isRenoted, renoteCount: renoteCount)
    }
}

struct BookmarkChange: NoteChange, Equatable {
    let noteID: String
    let isBookmarked: Bool

    func applied(to note: Note) -> Note {
        note.with(isBookmarked: isBookmarked)
    }
}

enum ReactionKey {
    static let like = "❤"

    /// The stored key of a reaction as sent to `notes/reactions/create`: a local custom
    /// emoji `:name:` is stored as `:name@.:`, and unicode emojis lose their variation
    /// selectors unless they are ZWJ sequences (Misskey's `toDbReaction`).
    static func stored(_ reaction: String) -> String {
        if reaction.count > 2, reaction.hasPrefix(":"), reaction.hasSuffix(":") {
            let name = reaction.dropFirst().dropLast()
            return name.contains("@") ? reaction : ":\(name)@.:"
        }
        guard !reaction.unicodeScalars.contains("\u{200D}") else { return reaction }
        return String(String.UnicodeScalarView(reaction.unicodeScalars.filter { $0 != "\u{FE0F}" }))
    }

    /// The name of a custom emoji reaction (`:name@host:` or `:name@.:`), nil for unicode.
    static func customName(_ key: String) -> String? {
        guard key.count > 2, key.hasPrefix(":"), key.hasSuffix(":") else { return nil }
        let body = key.dropFirst().dropLast()
        return String(body[..<(body.lastIndex(of: "@") ?? body.endIndex)])
    }

    static func isRemote(_ key: String) -> Bool {
        guard customName(key) != nil, let at = key.lastIndex(of: "@") else { return false }
        return key[key.index(after: at)...] != ".:"
    }
}

struct User: Codable, Sendable {
    let id: String
    let name: String?
    let username: String
    /// nil for local users.
    let host: String?
    let avatarUrl: String?
    let avatarBlurhash: String?
    let isBot: Bool
    let isCat: Bool
    /// Custom emojis used in the display name of a remote user (name -> raw URL).
    let emojis: [String: String]

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return username
    }

    var acct: String {
        if let host { return "@\(username)@\(host)" }
        return "@\(username)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, username, host, avatarUrl, avatarBlurhash, isBot, isCat, emojis
    }

    init(id: String, name: String?, username: String, host: String?, avatarUrl: String?, avatarBlurhash: String? = nil,
         isBot: Bool = false, isCat: Bool = false, emojis: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.username = username
        self.host = host
        self.avatarUrl = avatarUrl
        self.avatarBlurhash = avatarBlurhash
        self.isBot = isBot
        self.isCat = isCat
        self.emojis = emojis
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        username = try c.decode(String.self, forKey: .username)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        avatarBlurhash = try c.decodeIfPresent(String.self, forKey: .avatarBlurhash)
        isBot = try c.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        isCat = try c.decodeIfPresent(Bool.self, forKey: .isCat) ?? false
        emojis = (try? c.decodeIfPresent([String: String].self, forKey: .emojis)) ?? [:]
    }
}

struct DriveFile: Codable, Sendable {
    struct Properties: Codable, Sendable {
        let width: Double?
        let height: Double?
    }

    let id: String
    let type: String
    let name: String
    let size: Int?
    let isSensitive: Bool
    let blurhash: String?
    let properties: Properties
    let url: String?
    let thumbnailUrl: String?
    let comment: String?

    var isImage: Bool { type.hasPrefix("image/") }
    var isVideo: Bool { type.hasPrefix("video/") }
    var isGIF: Bool { type == "image/gif" }

    /// Width / height of the original, if the server knows it.
    var aspectRatio: Double? {
        guard let w = properties.width, let h = properties.height, w > 0, h > 0 else { return nil }
        return w / h
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, size, isSensitive, blurhash, properties, url, thumbnailUrl, comment
    }

    init(imageURL: String, blurhash: String? = nil) {
        id = imageURL
        type = "image/webp"
        name = ""
        size = nil
        isSensitive = false
        self.blurhash = blurhash
        properties = Properties(width: nil, height: nil)
        url = imageURL
        thumbnailUrl = nil
        comment = nil
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "application/octet-stream"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        isSensitive = try c.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
        blurhash = try c.decodeIfPresent(String.self, forKey: .blurhash)
        properties = (try? c.decodeIfPresent(Properties.self, forKey: .properties)) ?? Properties(width: nil, height: nil)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        thumbnailUrl = try c.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
    }
}

struct Poll: Codable, Sendable {
    struct Choice: Codable, Sendable {
        let text: String
        let votes: Int
        let isVoted: Bool?
    }

    let multiple: Bool
    let expiresAt: Date?
    let choices: [Choice]
}

struct CustomEmoji: Decodable, Sendable {
    let name: String
    let url: String
    let aliases: [String]?
    let category: String?
    /// Only there when true.
    let isSensitive: Bool?
}

/// Decodes an array, skipping elements that fail to decode instead of failing the array.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        self.elements = elements
    }

    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

enum MisskeyJSON {
    /// A page of notes (a timeline response). Notes that fail to decode are dropped.
    static func decodeNotes(from data: Data) throws -> [Note] {
        try decoder().decode(LossyArray<Note>.self, from: data).elements
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? fractional.parse(string) { return date }
            if let date = try? plain.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractional))
        }
        return encoder
    }
}
