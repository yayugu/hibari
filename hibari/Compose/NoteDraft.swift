import Foundation

/// What `notes/create` sends: a note, a reply (`replyID`), a quote (`renoteID` with text or
/// files) or a renote (`renoteID` alone).
struct NoteDraft: Sendable, Equatable {
    var text: String?
    var visibility: NoteVisibility
    /// Who a direct note is for (with `.specified` only).
    var visibleUserIDs: [String] = []
    var fileIDs: [String] = []
    var replyID: String?
    var renoteID: String?

    var parameters: [String: any Sendable] {
        var parameters: [String: any Sendable] = ["visibility": visibility.rawValue]
        if visibility == .specified { parameters["visibleUserIds"] = visibleUserIDs }
        if let text, !text.isEmpty { parameters["text"] = text }
        if !fileIDs.isEmpty { parameters["fileIds"] = fileIDs }
        if let replyID { parameters["replyId"] = replyID }
        if let renoteID { parameters["renoteId"] = renoteID }
        return parameters
    }
}

extension MisskeyClient {
    func createNote(_ draft: NoteDraft) async throws -> Note {
        struct Created: Decodable {
            let createdNote: Note
        }
        return try await request("notes/create", draft.parameters, as: Created.self).createdNote
    }
}

enum NoteVisibility: String, CaseIterable, Sendable {
    case `public`
    case home
    case followers
    /// Direct: the users it names (`NoteDraft.visibleUserIDs`). Not one to pick: the
    /// composer writes it for replies to direct notes and for a profile's "ダイレクトで送る".
    case specified

    static let pickable: [NoteVisibility] = [.public, .home, .followers]

    /// A note's; nil for one Misskey does not have.
    init?(of note: Note) {
        self.init(rawValue: note.visibility)
    }

    var title: String {
        switch self {
        case .public: "パブリック"
        case .home: "ホーム"
        case .followers: "フォロワー"
        case .specified: "ダイレクト"
        }
    }

    var subtitle: String {
        switch self {
        case .public: "全てのユーザーに公開"
        case .home: "ホームタイムラインのみに公開"
        case .followers: "自分のフォロワーのみに公開"
        case .specified: "指定したユーザーのみに公開"
        }
    }

    var symbol: String {
        switch self {
        case .public: "globe"
        case .home: "house"
        case .followers: "lock"
        case .specified: "envelope"
        }
    }

    /// Whether it reaches no further than `other`.
    func isNoWiderThan(_ other: NoteVisibility) -> Bool {
        Self.allCases.firstIndex(of: self)! >= Self.allCases.firstIndex(of: other)!
    }

    /// The narrower of the two. Misskey narrows a reply (or quote) to its target's, so the
    /// composer starts there.
    func narrowed(to other: NoteVisibility?) -> NoteVisibility {
        guard let other, !isNoWiderThan(other) else { return self }
        return other
    }

    /// The one the user picked last on the account (public until then).
    static func remembered(for account: Account) -> NoteVisibility {
        guard let picked = UserDefaults.standard.string(forKey: key(for: account)).flatMap(Self.init(rawValue:)),
              pickable.contains(picked)
        else { return .public }
        return picked
    }

    static func remember(_ visibility: NoteVisibility, for account: Account) {
        UserDefaults.standard.set(visibility.rawValue, forKey: key(for: account))
    }

    private static func key(for account: Account) -> String {
        (AppSettings.usesTestAccounts ? "HibariUITestNoteVisibility." : "HibariNoteVisibility.") + account.id
    }
}

enum NoteText {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Misskey's limit (`maxNoteTextLength`) counts unicode scalars (a JSON schema
    /// `maxLength`): 👍🏽 is 2, 😀 is 1.
    static func length(_ text: String) -> Int {
        trimmed(text).unicodeScalars.count
    }

    /// The note that `text` links to when it is nothing but the address of a note on
    /// `server` (`https://server/notes/<id>`), as pasted to quote it. Notes of other
    /// servers are left alone: they have other ids here.
    static func linkedNoteID(_ text: String, server: URL) -> String? {
        let text = trimmed(text)
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased(), host == server.host()?.lowercased(), url.port == server.port
        else { return nil }
        let path = url.path().split(separator: "/")
        guard path.count == 2, path[0] == "notes", !path[1].isEmpty,
              path[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return String(path[1])
    }
}

extension Note {
    /// Misskey lets anyone renote (or quote) public and home notes; followers-only ones
    /// only their author, direct ones no one.
    func canBeRenoted(by account: Account) -> Bool {
        switch visibility {
        case "public", "home": true
        case "followers": user.host == nil && user.id == account.userID
        default: false
        }
    }

    /// Who a reply to this direct note is for, as Misskey's web client has it: the author
    /// and the users the note was for, without the account.
    func directRecipientIDs(excluding accountUserID: String) -> [String] {
        var ids: [String] = []
        for id in [user.id] + visibleUserIds where id != accountUserID && !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }
}
