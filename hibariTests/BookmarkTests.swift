import Foundation
import Testing
@testable import hibari

@Suite("Bookmarks")
struct BookmarkTests {
    private func bookmarkButton(_ layout: NoteLayout) -> (icon: Icon, color: ColorRole)? {
        layout.blocks.flatMap(\.ops).lazy.compactMap { op -> (Icon, ColorRole)? in
            if case .icon(let icon, _, let color) = op, icon == .bookmark || icon == .bookmarked { return (icon, color) }
            return nil
        }.first
    }

    @Test func aBookmarkShowsOnTheButton() throws {
        let plain = try #require(Samples.firstNote { !$0.isPureRenote })
        let engine = Samples.engine()
        let before = engine.layout(for: TimelineItem(note: plain), context: Samples.context())
        #expect(bookmarkButton(before)?.icon == .bookmark && bookmarkButton(before)?.color == .secondaryText)

        let bookmarked = plain.applying(BookmarkChange(noteID: plain.id, isBookmarked: true))
        #expect(bookmarked.isBookmarked && bookmarked.id == plain.id && bookmarked.text == plain.text)
        #expect(TimelineItem(note: bookmarked).contentHash != TimelineItem(note: plain).contentHash)
        let after = engine.layout(for: TimelineItem(note: bookmarked), context: Samples.context())
        #expect(bookmarkButton(after)?.icon == .bookmarked && bookmarkButton(after)?.color == .accent)
        #expect(after.accessibility.label(at: Date()).contains("ブックマーク済み"))
        #expect(bookmarked.applying(BookmarkChange(noteID: plain.id, isBookmarked: true)) === bookmarked)
    }

    @Test func marksReachEveryCopyAndTakingOffWins() throws {
        let quote = try #require(Samples.firstNote { !$0.isPureRenote && $0.renote != nil })
        let quoted = try #require(quote.renote)
        var marks = BookmarkMarks()
        marks.bookmarked.insert(quoted.id)
        #expect(marks.apply(to: quote).renote?.isBookmarked == true)
        #expect(!marks.apply(to: quote).isBookmarked)
        let unrelated = try #require(Samples.firstNote { !$0.contains(noteID: quoted.id) })
        #expect(marks.apply(to: unrelated) === unrelated)

        var takenOff = BookmarkMarks()
        takenOff.notBookmarked.insert(quote.id)
        #expect(!takenOff.apply(to: quote.with(isBookmarked: true)).isBookmarked)
    }

    @Test func takingOffABookmarkKeepsQuotesOfTheNote() throws {
        let quote = try #require(Samples.firstNote { !$0.isPureRenote && $0.renote != nil })
        let quoted = try #require(quote.renote)
        let items = [TimelineItem(note: quoted), TimelineItem(note: quote)]
        var entries = TimelineEntries()
        entries.append(items, layouts: Samples.engine().layouts(for: items, context: Samples.context()))
        #expect(entries.remove(noteID: quoted.id) == [0])
        #expect(entries.items.map(\.id) == [quote.id])
        #expect(entries.index(of: quote.id) == 0 && entries.layouts[0].key.noteID == quote.id)
        #expect(entries.remove(noteID: quoted.id).isEmpty)
    }
}

@Suite("Bookmark API")
struct BookmarkAPITests {
    private func client(_ handler: @escaping StubURLProtocol.Handler) -> MisskeyClient {
        MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session(handler))
    }

    @Test func bookmarksPageByTheBookmarkAndComeMarked() async throws {
        let client = client { request, body in
            #expect(request.url?.path() == "/api/i/favorites")
            #expect(body["untilId"] as? String == "f9" && body["limit"] as? Int == 20)
            return .json([
                ["id": "f8", "createdAt": "2026-09-23T15:00:00.000Z", "noteId": "n5", "note": TestData.note(id: "n5")],
                ["id": "f7", "createdAt": "2026-09-23T15:00:00.000Z", "noteId": "n2", "note": ["id": "n2"]],
            ])
        }
        let source = BookmarkedNotesSource(client: client)
        let page = try await source.page(until: "f9", limit: 20)
        #expect(page.entries.map(\.id) == ["n5"] && page.cursor == "f7")
        guard case .note(let note) = page.entries.first else {
            Issue.record("no note")
            return
        }
        #expect(note.isBookmarked)
        #expect(source.refreshPolicy == .replace, "in the order they were bookmarked, not by note id")
    }

    @Test func theNotesTheAccountReactedToPageByTheReaction() async throws {
        let client = client { request, body in
            #expect(request.url?.path() == "/api/users/reactions")
            #expect(body["userId"] as? String == "me" && body["untilId"] as? String == "r9")
            return .json([
                ["id": "r2", "createdAt": "2026-09-23T15:00:00.000Z", "type": "👍", "note": TestData.note(id: "n3")],
            ])
        }
        let page = try await ReactedNotesSource(client: client, userID: "me").page(until: "r9", limit: 20)
        #expect(page.entries.map(\.id) == ["n3"] && page.cursor == "r2")
        let end = try await ReactedNotesSource(client: self.client { _, _ in .json([]) }, userID: "me")
            .page(until: "r2", limit: 20)
        #expect(end.entries.isEmpty && end.cursor == nil)
    }
}

@Suite("Bookmark controller")
@MainActor
struct BookmarkControllerTests {
    private final class Log: Sendable {
        let entries = Locked<[String]>([])
        var all: [String] { entries.withLock { $0 } }

        func wait(for count: Int) async throws {
            for _ in 0..<200 where all.count < count {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    private func controller(log: Log, errors: [String: String?] = [:], bookmarked: Bool = false)
        -> BookmarkController {
        let session = StubURLProtocol.session { request, body in
            let endpoint = request.url!.path().replacingOccurrences(of: "/api/", with: "")
            log.entries.withLock { $0.append("\(endpoint) \(body["noteId"] as? String ?? "")") }
            if let error = errors[endpoint] {
                return error.map { StubURLProtocol.Response.json(["error": ["code": $0, "message": "no"]], status: 400) }
                    ?? .json(["error": ["code": "INTERNAL_ERROR", "message": "boom"]], status: 500)
            }
            if endpoint == "notes/state" { return .json(["isFavorited": bookmarked]) }
            return StubURLProtocol.Response(status: 204)
        }
        return BookmarkController(client: MisskeyClient(server: TestData.server, token: "T", session: session))
    }

    private func note(_ id: String = "n1") throws -> Note {
        try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: TestData.note(id: id)))
    }

    private func changes(of controller: BookmarkController, count: Int,
                         during body: () throws -> Void) async throws -> [BookmarkChange] {
        let received = Locked<[BookmarkChange]>([])
        let observer = NotificationCenter.default.addObserver(forName: BookmarkController.didChange, object: controller,
                                                              queue: nil) { notification in
            if let change = notification.userInfo?["change"] as? BookmarkChange {
                received.withLock { $0.append(change) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try body()
        for _ in 0..<200 where received.withLock({ $0.count }) < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return received.withLock { $0 }
    }

    @Test func quickTapsReachTheServerInOrder() async throws {
        let log = Log()
        let controller = controller(log: log)
        let note = try note()
        let posted = try await changes(of: controller, count: 2) {
            #expect(controller.toggle(note))
            #expect(controller.isBookmarked(note) && controller.marks.bookmarked == ["n1"])
            #expect(!controller.toggle(note))
        }
        #expect(posted.map(\.isBookmarked) == [true, false])
        try await log.wait(for: 2)
        #expect(log.all == ["notes/favorites/create n1", "notes/favorites/delete n1"])
        #expect(controller.marks.notBookmarked == ["n1"])
    }

    @Test func bookmarkedElsewhereAlreadyIsAsGoodAsDone() async throws {
        let log = Log()
        let controller = controller(log: log, errors: ["notes/favorites/create": "ALREADY_FAVORITED"])
        let note = try note()
        _ = try await changes(of: controller, count: 1) { controller.toggle(note) }
        try await log.wait(for: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.all == ["notes/favorites/create n1"], "no need to ask")
        #expect(controller.isBookmarked(note))
    }

    @Test func aFailedRequestShowsWhetherTheNoteIsBookmarked() async throws {
        let log = Log()
        let controller = controller(log: log, errors: ["notes/favorites/create": nil], bookmarked: false)
        let note = try note()
        let posted = try await changes(of: controller, count: 2) { controller.toggle(note) }
        #expect(posted.map(\.isBookmarked) == [true, false])
        #expect(log.all == ["notes/favorites/create n1", "notes/state n1"])
        #expect(!controller.isBookmarked(note))
    }

    @Test func thePostScreenAsksTheServer() async throws {
        let log = Log()
        let controller = controller(log: log, bookmarked: true)
        let posted = try await changes(of: controller, count: 1) { controller.refresh("n1") }
        #expect(posted == [BookmarkChange(noteID: "n1", isBookmarked: true)])
    }

    @Test func learnsFromTheBookmarksButWhatTheAppDidWins() throws {
        let controller = BookmarkController(client: nil)
        let listed = try note("n1").with(isBookmarked: true)
        let other = try note("n2")
        controller.learn(from: [listed, other])
        #expect(controller.isBookmarked(try note("n1")), "known by id: other copies follow")
        #expect(!controller.isBookmarked(other) && controller.marks.notBookmarked.isEmpty, "not known either way")

        controller.toggle(listed)
        controller.learn(from: [listed])
        #expect(!controller.isBookmarked(listed), "taken off since it was listed")
    }
}
