import Foundation

/// Sends the user's reactions and keeps every copy of a note on screen in step with them.
///
/// Changes are optimistic: `didChange` is posted right away (`userInfo["change"]` is the
/// `ReactionChange`), and the request follows. Requests for one note run one after
/// another, so quick taps reach the server in order. If one fails, the note is fetched
/// again and its real state posted.
@MainActor
final class ReactionController {
    static let didChange = Notification.Name("ReactionController.didChange")

    enum Refusal: Error {
        /// A custom emoji of another server that this one does not have.
        case remoteEmoji
        /// A sensitive custom emoji, on a note that does not take them.
        case sensitiveEmoji

        var message: String {
            switch self {
            case .remoteEmoji: "他のサーバーの絵文字ではリアクションできません"
            case .sensitiveEmoji: "このノートにはセンシティブな絵文字でリアクションできません"
            }
        }
    }

    private let client: MisskeyClient?
    private let emojis: EmojiCatalog
    private let recentReactions: RecentReactions
    private var pending: [String: (state: ReactionChange, count: Int)] = [:]
    private var queues: [String: Task<Void, Never>] = [:]

    init(client: MisskeyClient?, emojis: EmojiCatalog, recentReactions: RecentReactions) {
        self.client = client
        self.emojis = emojis
        self.recentReactions = recentReactions
    }

    /// What `note` shows once pending changes land.
    func state(of note: Note) -> ReactionChange {
        pending[note.id]?.state ?? ReactionChange(note)
    }

    /// A reaction chip: takes the user's reaction back if it is this one, otherwise reacts
    /// with it (replacing the user's other reaction). Returns whether the user now has this
    /// reaction.
    @discardableResult
    func toggle(_ key: String, on note: Note) throws(Refusal) -> Bool {
        if state(of: note).myReaction == key {
            unreact(note)
            return false
        }
        try react(with: Self.reaction(forKey: key, emojis: emojis), to: note)
        return true
    }

    /// Reacts with `reaction` (a unicode emoji or `:name:`), replacing the user's current
    /// reaction. A note that takes likes only gets a like, as the server would store it.
    func react(with reaction: String, to note: Note) throws(Refusal) {
        let reaction = note.isLikeOnly ? ReactionKey.like : reaction
        let key = ReactionKey.stored(reaction)
        if ReactionKey.isRemote(key) { throw .remoteEmoji }
        if note.rejectsSensitiveReactions, let name = ReactionKey.customName(key),
           emojis.entry(named: name)?.isSensitive == true {
            throw .sensitiveEmoji
        }
        let before = state(of: note)
        guard before.myReaction != key else { return }
        let replaces = before.myReaction != nil
        if !note.isLikeOnly { recentReactions.add(reaction) }
        enqueue(before.reacting(key)) { client, noteID in
            if replaces {
                try? await client.unreact(noteID)
            }
            try await client.react(to: noteID, with: reaction)
        }
    }

    func unreact(_ note: Note) {
        let before = state(of: note)
        guard before.myReaction != nil else { return }
        enqueue(before.reacting(nil)) { client, noteID in
            try await client.unreact(noteID)
        }
    }

    /// Runs `action` once the server has every reaction change made to the note so far
    /// (right away if none is on its way).
    func whenSaved(_ noteID: String, _ action: @escaping @MainActor () -> Void) {
        guard let queue = queues[noteID] else { return action() }
        Task {
            await queue.value
            action()
        }
    }

    /// What to send to react like a chip: local custom emojis as `:name:`, remote ones as
    /// the local emoji of the same name if there is one.
    nonisolated static func reaction(forKey key: String, emojis: EmojiCatalog) throws(Refusal) -> String {
        guard let name = ReactionKey.customName(key) else { return key }
        if ReactionKey.isRemote(key) && emojis.entry(named: name) == nil { throw .remoteEmoji }
        return ":\(name):"
    }

    private func enqueue(
        _ change: ReactionChange,
        request: @escaping @Sendable (MisskeyClient, String) async throws -> Void
    ) {
        let noteID = change.noteID
        pending[noteID] = (change, (pending[noteID]?.count ?? 0) + 1)
        post(change)
        guard let client else {
            finish(noteID)
            return
        }
        let previous = queues[noteID]
        queues[noteID] = Task {
            await previous?.value
            do {
                try await request(client, noteID)
            } catch {
                await recover(noteID, from: error, client: client)
            }
            finish(noteID)
        }
    }

    private func recover(_ noteID: String, from error: any Error, client: MisskeyClient) async {
        let apiError = error as? MisskeyAPIError
        if apiError?.code != "ALREADY_REACTED" && apiError?.code != "NOT_REACTED" {
            Toast.show(apiError?.errorDescription ?? "リアクションできませんでした")
        }
        guard let fresh = try? await client.note(noteID) else { return }
        if var entry = pending[noteID] {
            entry.state = ReactionChange(fresh)
            pending[noteID] = entry
        }
        post(ReactionChange(fresh))
    }

    private func finish(_ noteID: String) {
        guard let entry = pending[noteID] else { return }
        if entry.count > 1 {
            pending[noteID] = (entry.state, entry.count - 1)
        } else {
            pending[noteID] = nil
            queues[noteID] = nil
        }
    }

    private func post(_ change: ReactionChange) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["change": change])
    }
}

struct RecentReactions {
    private let key: String
    private let defaults: UserDefaults
    private static let limit = 16

    init(account: Account, defaults: UserDefaults = .standard) {
        key = (AppSettings.usesTestAccounts ? "HibariUITestRecentReactions." : "HibariRecentReactions.") + account.id
        self.defaults = defaults
    }

    var all: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func add(_ reaction: String) {
        var list = all.filter { $0 != reaction }
        list.insert(reaction, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: key)
    }
}
