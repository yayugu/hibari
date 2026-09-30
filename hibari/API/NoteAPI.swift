import Foundation

extension MisskeyClient {
    func note(_ noteID: String) async throws -> Note {
        try await request("notes/show", ["noteId": noteID], as: Note.self)
    }

    /// `notes/conversation`: the notes a reply answers, from its parent upwards.
    func conversation(of noteID: String, limit: Int = 30) async throws -> [Note] {
        try MisskeyJSON.decodeNotes(from: await data("notes/conversation", ["noteId": noteID, "limit": limit]))
    }

    /// `notes/replies`: direct replies, oldest first, starting after `sinceID` (the note
    /// itself for the first page: replies are always newer). With only `sinceId`, Misskey
    /// pages in ascending order.
    func replies(to noteID: String, since sinceID: String, limit: Int) async throws -> [Note] {
        let data = try await data("notes/replies", ["noteId": noteID, "sinceId": sinceID, "limit": limit])
        return try MisskeyJSON.decodeNotes(from: data).sorted { $0.id < $1.id }
    }

    /// `notes/reactions/create`. `reaction` is a unicode emoji or `:name:` (a local custom
    /// emoji).
    func react(to noteID: String, with reaction: String) async throws {
        _ = try await data("notes/reactions/create", ["noteId": noteID, "reaction": reaction])
    }

    func unreact(_ noteID: String) async throws {
        _ = try await data("notes/reactions/delete", ["noteId": noteID])
    }

    func deleteNote(_ noteID: String) async throws {
        _ = try await data("notes/delete", ["noteId": noteID])
    }
}

extension MisskeyAPIError {
    var code: String? {
        if case .server(_, let body) = self { return body.code }
        return nil
    }
}
