import Foundation

@MainActor
final class BookmarkController {
    static let didChange = Notification.Name("BookmarkController.didChange")

    static let recentLimit = 100

    private let client: MisskeyClient?
    private var states: [String: Bool] = [:]
    private var queues: [String: Task<Void, Never>] = [:]
    private var pending: [String: Int] = [:]

    init(client: MisskeyClient?) {
        self.client = client
    }

    func isBookmarked(_ note: Note) -> Bool {
        states[note.id] ?? note.isBookmarked
    }

    /// Bookmarks the note, or takes the bookmark off. Returns whether it is bookmarked now.
    @discardableResult
    func toggle(_ note: Note) -> Bool {
        let bookmarked = !isBookmarked(note)
        set(bookmarked, for: note.id)
        guard let client else { return bookmarked }
        let noteID = note.id
        pending[noteID, default: 0] += 1
        let previous = queues[noteID]
        queues[noteID] = Task {
            await previous?.value
            do {
                if bookmarked {
                    try await client.bookmark(noteID)
                } else {
                    try await client.unbookmark(noteID)
                }
            } catch {
                let code = (error as? MisskeyAPIError)?.code
                if code != "ALREADY_FAVORITED" && code != "NOT_FAVORITED" {
                    await recover(noteID, bookmarked: bookmarked, from: error, client: client)
                }
            }
            finish(noteID)
        }
        return bookmarked
    }

    private func recover(_ noteID: String, bookmarked: Bool, from error: any Error, client: MisskeyClient) async {
        let fallback = bookmarked ? "ブックマークできませんでした" : "ブックマークから削除できませんでした"
        Toast.show((error as? MisskeyAPIError)?.errorDescription ?? fallback)
        let actual = (try? await client.isBookmarked(noteID)) ?? !bookmarked
        guard pending[noteID] == 1 else { return }
        set(actual, for: noteID)
    }

    private func finish(_ noteID: String) {
        let count = (pending[noteID] ?? 1) - 1
        pending[noteID] = count > 0 ? count : nil
        if count <= 0 { queues[noteID] = nil }
    }

    /// Asks the server whether the note is bookmarked (the post screen), unless the
    /// account is changing that.
    func refresh(_ noteID: String) {
        guard let client else { return }
        Task {
            guard let bookmarked = try? await client.isBookmarked(noteID), pending[noteID] == nil else { return }
            set(bookmarked, for: noteID)
        }
    }

    func loadRecent() {
        guard let client else { return }
        Task {
            guard let page = try? await client.bookmarks(until: nil, limit: Self.recentLimit) else { return }
            learn(bookmarked: page.notes.map(\.id))
        }
    }

    /// Remembers the notes among `notes` that came marked as bookmarked (the bookmarks
    /// screen's), unless the app knows better.
    func learn(from notes: some Sequence<Note>) {
        learn(bookmarked: notes.lazy.filter(\.isBookmarked).map(\.id))
    }

    private func learn(bookmarked noteIDs: some Sequence<String>) {
        for noteID in noteIDs where states[noteID] == nil {
            set(true, for: noteID)
        }
    }

    var marks: BookmarkMarks {
        var marks = BookmarkMarks()
        for (noteID, bookmarked) in states {
            if bookmarked {
                marks.bookmarked.insert(noteID)
            } else {
                marks.notBookmarked.insert(noteID)
            }
        }
        return marks
    }

    private func set(_ bookmarked: Bool, for noteID: String) {
        states[noteID] = bookmarked
        let change = BookmarkChange(noteID: noteID, isBookmarked: bookmarked)
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["change": change])
    }
}

struct BookmarkMarks: Sendable {
    var bookmarked: Set<String> = []
    var notBookmarked: Set<String> = []

    /// `note` with what is known marked, in it and the notes it embeds.
    func apply(to note: Note) -> Note {
        guard !bookmarked.isEmpty || !notBookmarked.isEmpty else { return note }
        var marked = note
        for noteID in note.containedNoteIDs {
            if bookmarked.contains(noteID) {
                marked = marked.applying(BookmarkChange(noteID: noteID, isBookmarked: true))
            } else if notBookmarked.contains(noteID) {
                marked = marked.applying(BookmarkChange(noteID: noteID, isBookmarked: false))
            }
        }
        return marked
    }
}
