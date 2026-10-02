import Foundation

/// How a refresh updates a list; independent of whether its view stays in memory.
enum RefreshPolicy: Sendable {
    /// Replace with the newest page and restart pagination, even if entries overlap.
    case replace
    /// Keep fetched history and merge new entries. Entries must be newest first with
    /// ids growing with time; an unfetched interval stays as a gap to fill later.
    case preserveHistory
}

protocol TimelineSource: Sendable {
    /// Up to `limit` entries older than the one `cursor` names (the newest when nil).
    func page(until cursor: String?, limit: Int) async throws -> TimelinePage

    /// Replacing is the default. Only timelines meant to retain browsing history opt
    /// into `preserveHistory`; returning notes does not imply that policy.
    var refreshPolicy: RefreshPolicy { get }

    /// Up to `limit` entries newer than `sinceID`, the oldest first: the ones right above it
    /// (Misskey's `sinceId` without `untilId`), to fill a gap from below. The page's cursor
    /// is the newest entry sent. nil when the source cannot page that way.
    func page(after sinceID: String, limit: Int) async throws -> TimelinePage?
}

extension TimelineSource {
    var refreshPolicy: RefreshPolicy { .replace }

    func page(after sinceID: String, limit: Int) async throws -> TimelinePage? { nil }
}

enum TimelineEntry: Sendable {
    case note(Note)
    case notification(MisskeyNotification)

    var id: String {
        switch self {
        case .note(let note): note.id
        case .notification(let notification): notification.id
        }
    }
}

struct TimelinePage: Sendable {
    let entries: [TimelineEntry]
    /// Where the next page starts: the last entry the server sent, also when it is not in
    /// `entries` (it did not decode). nil for an empty page: the end of the list.
    let cursor: String?
}

protocol NoteTimelineSource: TimelineSource {
    /// Up to `limit` notes older than the note `untilID` (the newest when nil). An empty
    /// result means the end of the timeline.
    func notes(until untilID: String?, limit: Int) async throws -> [Note]

    /// Up to `limit` notes newer than `sinceID`, the oldest first (see
    /// `TimelineSource.page(after:limit:)`). nil when the endpoint cannot.
    func notes(after sinceID: String, limit: Int) async throws -> [Note]?
}

extension NoteTimelineSource {
    func page(until cursor: String?, limit: Int) async throws -> TimelinePage {
        let notes = try await notes(until: cursor, limit: limit)
        return TimelinePage(entries: notes.map(TimelineEntry.note), cursor: notes.last?.id)
    }

    func notes(after sinceID: String, limit: Int) async throws -> [Note]? { nil }

    func page(after sinceID: String, limit: Int) async throws -> TimelinePage? {
        guard let notes = try await notes(after: sinceID, limit: limit)?.sorted(by: { $0.id < $1.id }) else {
            return nil
        }
        return TimelinePage(entries: notes.map(TimelineEntry.note), cursor: notes.last?.id)
    }
}
