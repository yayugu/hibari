import Foundation

struct MisskeyNotification: Decodable, Sendable {
    struct Reaction: Decodable, Sendable {
        let user: User
        /// A key of `note.reactions`.
        let reaction: String
    }

    enum Kind: Sendable {
        /// A note by a user whose notes the account subscribed to.
        case note
        case mention
        case reply
        case quote

        /// To the account's note (`note`), newest first.
        case reactions([Reaction])
        /// Of the account's note, newest first. `note` is (the newest) renote; the account's
        /// note is its `renote`.
        case renotes([User])
        case follow(User)
        case followRequest(User)
        case followRequestAccepted(User)
        /// A poll the account made or voted in (`note`) ended.
        case pollEnded
        /// A note the account scheduled (`note`) was posted.
        case scheduledNotePosted
        case scheduledNotePostFailed
        /// The name of the role, if the server sent it.
        case roleAssigned(String?)
        /// Misskey's achievement id (`notes1`, ...).
        case achievementEarned(String)
        /// From an app (`notifications/create`).
        case app(header: String?, body: String?, icon: String?)
        case chatRoomInvitation(User)
        case exportCompleted
        case login
        case createToken
        case test
    }

    let id: String
    let createdAt: Date
    let kind: Kind
    let note: Note?

    /// Shown as a note (mentions, replies, quotes, subscribed users' notes) rather than as
    /// a row saying what happened.
    var isShownAsNote: Bool {
        switch kind {
        case .note, .mention, .reply, .quote: true
        default: false
        }
    }

    /// Misskey groups runs of these (reactions to one note, renotes of one note).
    var isGroupable: Bool {
        switch kind {
        case .reactions, .renotes: true
        default: false
        }
    }

    /// The account's note the notification is about (the renoted one, not the renote).
    var subjectNote: Note? {
        if case .renotes = kind { return note?.renote }
        return note
    }

    /// The users who did it, newest first (none for notifications shown as notes and the
    /// server's own).
    var users: [User] {
        switch kind {
        case .reactions(let reactions): reactions.map(\.user)
        case .renotes(let users): users
        case .follow(let user), .followRequest(let user), .followRequestAccepted(let user),
             .chatRoomInvitation(let user):
            [user]
        default: []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, type, note, user, users, reaction, reactions, role, achievement, header, body, icon
    }

    private struct Role: Decodable {
        let name: String?
    }

    private struct Unusable: Error {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        let type = try c.decode(String.self, forKey: .type)
        let note = try? c.decodeIfPresent(Note.self, forKey: .note)
        func user() throws -> User { try c.decode(User.self, forKey: .user) }
        func requireNote() throws {
            if note == nil { throw Unusable() }
        }
        func string(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == false ? $0 : nil }
        }
        switch type {
        case "note", "mention", "reply", "quote":
            try requireNote()
            kind = switch type {
            case "note": .note
            case "mention": .mention
            case "reply": .reply
            default: .quote
            }
        case "reaction":
            try requireNote()
            kind = .reactions([Reaction(user: try user(), reaction: try c.decode(String.self, forKey: .reaction))])
        case "reaction:grouped":
            try requireNote()
            let reactions = try c.decode(LossyArray<Reaction>.self, forKey: .reactions).elements
            guard !reactions.isEmpty else { throw Unusable() }
            kind = .reactions(reactions)
        case "renote", "renote:grouped":
            guard note?.renote != nil else { throw Unusable() }
            let users = type == "renote" ? [try user()] : try c.decode(LossyArray<User>.self, forKey: .users).elements
            guard !users.isEmpty else { throw Unusable() }
            kind = .renotes(users)
        case "follow": kind = .follow(try user())
        case "receiveFollowRequest": kind = .followRequest(try user())
        case "followRequestAccepted": kind = .followRequestAccepted(try user())
        case "chatRoomInvitationReceived": kind = .chatRoomInvitation(try user())
        case "pollEnded":
            try requireNote()
            kind = .pollEnded
        case "scheduledNotePosted":
            try requireNote()
            kind = .scheduledNotePosted
        case "scheduledNotePostFailed": kind = .scheduledNotePostFailed
        case "roleAssigned": kind = .roleAssigned((try? c.decodeIfPresent(Role.self, forKey: .role))?.name)
        case "achievementEarned": kind = .achievementEarned(string(.achievement) ?? "")
        case "app": kind = .app(header: string(.header), body: string(.body), icon: string(.icon))
        case "exportCompleted": kind = .exportCompleted
        case "login": kind = .login
        case "createToken": kind = .createToken
        case "test": kind = .test
        default: throw Unusable()
        }
        self.note = note
    }
}

extension MisskeyJSON {
    /// A page of notifications, and the id of the last one the server sent: where the next
    /// page starts, also when that one did not decode (nil for an empty page, the end).
    static func decodeNotifications(from data: Data) throws -> (notifications: [MisskeyNotification], lastID: String?) {
        let entries = try decoder().decode([Tolerant].self, from: data)
        return (entries.compactMap(\.notification), entries.last?.id)
    }

    private struct Tolerant: Decodable {
        let id: String?
        let notification: MisskeyNotification?

        private enum CodingKeys: String, CodingKey { case id }

        init(from decoder: any Decoder) throws {
            id = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
            notification = try? MisskeyNotification(from: decoder)
        }
    }
}
