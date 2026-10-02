import Foundation

extension MisskeyClient {
    func bookmark(_ noteID: String) async throws {
        _ = try await data("notes/favorites/create", ["noteId": noteID])
    }

    func unbookmark(_ noteID: String) async throws {
        _ = try await data("notes/favorites/delete", ["noteId": noteID])
    }

    /// Whether the account has bookmarked the note (`notes/state`): notes do not say.
    func isBookmarked(_ noteID: String) async throws -> Bool {
        struct State: Decodable {
            let isFavorited: Bool?
        }
        return try await request("notes/state", ["noteId": noteID], as: State.self).isFavorited ?? false
    }

    /// Up to `limit` of the account's bookmarks older than the bookmark `untilID` (by the
    /// bookmark's id, not the note's), the latest first: their notes, and the id of the
    /// last bookmark sent.
    func bookmarks(until untilID: String?, limit: Int) async throws -> (notes: [Note], lastID: String?) {
        var parameters: [String: any Sendable] = ["limit": limit]
        if let untilID { parameters["untilId"] = untilID }
        return try MisskeyJSON.decodeNoteRecords(from: await data("i/favorites", parameters))
    }
}

/// The account's bookmarks, the latest bookmarked first. The notes come marked as
/// bookmarked. Refreshes start over: bookmarks can be removed or reordered without
/// new notes, and the pagination cursor belongs to a bookmark, not its note.
struct BookmarkedNotesSource: TimelineSource {
    let client: MisskeyClient

    func page(until cursor: String?, limit: Int) async throws -> TimelinePage {
        let page = try await client.bookmarks(until: cursor, limit: limit)
        return TimelinePage(entries: page.notes.map { .note($0.with(isBookmarked: true)) }, cursor: page.lastID)
    }
}

/// The notes a user reacted to, the latest reaction first (`users/reactions`, paged by the
/// reaction's id). Misskey lists the account's own always, other users' only when they
/// made their reactions public.
struct ReactedNotesSource: TimelineSource {
    let client: MisskeyClient
    let userID: String

    func page(until cursor: String?, limit: Int) async throws -> TimelinePage {
        var parameters: [String: any Sendable] = ["userId": userID, "limit": limit]
        if let cursor { parameters["untilId"] = cursor }
        let page = try MisskeyJSON.decodeNoteRecords(from: await client.data("users/reactions", parameters))
        return TimelinePage(entries: page.notes.map(TimelineEntry.note), cursor: page.lastID)
    }
}

extension MisskeyJSON {
    /// A page of records that each carry a note (`{"id", "note", ...}`: bookmarks,
    /// reactions): the notes that decode, and the id of the last record, where the next
    /// page starts, also when its note did not decode (nil for an empty page, the end).
    static func decodeNoteRecords(from data: Data) throws -> (notes: [Note], lastID: String?) {
        let records = try decoder().decode([NoteRecord].self, from: data)
        return (records.compactMap(\.note), records.lazy.compactMap(\.id).last)
    }

    private struct NoteRecord: Decodable {
        let id: String?
        let note: Note?

        private enum CodingKeys: String, CodingKey { case id, note }

        init(from decoder: any Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            id = try? c?.decode(String.self, forKey: .id)
            note = try? c?.decode(Note.self, forKey: .note)
        }
    }
}
