import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Bookmark list", .serialized)
@MainActor
struct BookmarkListTests {
    private final class Server: Sendable {
        let ids: Locked<[String]>
        let rejectsDeletion: Bool

        init(_ ids: [String] = ["n1", "n2"], rejectsDeletion: Bool = false) {
            self.ids = Locked(ids)
            self.rejectsDeletion = rejectsDeletion
        }

        func respond(_ request: URLRequest, _ body: [String: Any]) -> StubURLProtocol.Response {
            switch request.url?.path() {
            case "/api/i/favorites":
                let page = ids.withLock { ids in
                    let start = (body["untilId"] as? String).flatMap { cursor in
                        ids.firstIndex { "f-\($0)" == cursor }.map { $0 + 1 }
                    } ?? 0
                    return Array(ids.dropFirst(start).prefix(body["limit"] as? Int ?? 20))
                }
                return .json(page.map { ["id": "f-\($0)", "note": TestData.note(id: $0)] })
            case "/api/notes/favorites/delete":
                if rejectsDeletion {
                    return .json(["error": ["code": "INTERNAL_ERROR", "message": "failed"]], status: 500)
                }
                ids.withLock { $0.removeAll { $0 == body["noteId"] as? String } }
                return StubURLProtocol.Response(status: 204)
            case "/api/notes/state":
                return .json(["isFavorited": ids.withLock { $0.contains(body["noteId"] as? String ?? "") }])
            default:
                Issue.record("unexpected request: \(request.url?.path() ?? "")")
                return .json([])
            }
        }
    }

    private func screen(_ server: Server) async throws
        -> (navigation: UINavigationController, services: NoteServices, timeline: TimelineViewController) {
        let client = MisskeyClient(server: TestData.server, token: "T",
                                   session: StubURLProtocol.session { server.respond($0, $1) })
        let account = Account(server: TestData.server, me: try MisskeyJSON.decoder().decode(
            MeDetailed.self, from: JSONSerialization.data(withJSONObject: TestData.me)))
        let session = TimelineSession(timelines: [], engine: Samples.engine(), clock: .live,
                                      account: account, client: client, emojis: EmojiCatalog(entries: []))
        let pipeline = ImagePipeline(source: SampleMediaSource(), diskDirectory: TestData.temporaryDirectory())
        let services = NoteServices(session: session, renderer: NoteRenderer(imagePipeline: pipeline),
                                    imagePipeline: pipeline)
        let bookmarks = BookmarksViewController(services: services)
        let navigation = UINavigationController(rootViewController: bookmarks)
        bookmarks.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        bookmarks.view.layoutIfNeeded()
        let timeline = try #require(bookmarks.children.first as? TimelineViewController)
        await loadAll(timeline)
        return (navigation, services, timeline)
    }

    private func loadAll(_ timeline: TimelineViewController) async {
        while timeline.hasMorePages {
            // There is no window/run loop laying out this test's collection view.
            // Consume pending reloads before another page changes its item count.
            timeline.collectionView.layoutIfNeeded()
            _ = timeline.collectionView.numberOfItems(inSection: 0)
            await withCheckedContinuation { continuation in
                timeline.loadNextPage {
                    timeline.collectionView.layoutIfNeeded()
                    _ = timeline.collectionView.numberOfItems(inSection: 0)
                    continuation.resume()
                }
            }
        }
    }

    private func refresh(_ timeline: TimelineViewController) async {
        await withCheckedContinuation { continuation in
            timeline.refresh { continuation.resume() }
        }
    }

    private func wait(until ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready())
    }

    @Test(arguments: ["n1", "n2"])
    func takingOffABookmarkRemovesItsRowAndRefreshDoesNotBringItBack(_ noteID: String) async throws {
        let server = Server()
        let screen = try await screen(server)
        let note = try #require(screen.timeline.item(forNote: noteID)?.note)
        screen.services.bookmarks.toggle(note)
        #expect(!screen.timeline.contains(noteID: noteID))
        #expect(screen.timeline.noteCount == 1)
        try await wait { !server.ids.withLock { $0.contains(noteID) } }
        await refresh(screen.timeline)
        #expect(!screen.timeline.contains(noteID: noteID) && screen.timeline.noteCount == 1)
        #expect(screen.timeline.collectionView.numberOfItems(inSection: 0) == 1)
    }

    @Test(arguments: ["n1", "n2"])
    func refreshRemovesABookmarkDeletedElsewhereEvenWithOverlap(_ noteID: String) async throws {
        let server = Server()
        let screen = try await screen(server)
        server.ids.withLock { $0.removeAll { $0 == noteID } }
        await refresh(screen.timeline)
        #expect(!screen.timeline.contains(noteID: noteID) && screen.timeline.noteCount == 1)
        #expect(screen.timeline.collectionView.numberOfItems(inSection: 0) == 1)
    }

    @Test func removingTheLastBookmarkLeavesAnEmptyList() async throws {
        let server = Server(["n1"])
        let screen = try await screen(server)
        screen.services.bookmarks.toggle(try #require(screen.timeline.item(forNote: "n1")?.note))
        #expect(screen.timeline.noteCount == 0)
        try await wait { server.ids.withLock { $0.isEmpty } }
        await refresh(screen.timeline)
        #expect(screen.timeline.noteCount == 0 && !screen.timeline.hasMorePages)
        #expect(screen.timeline.collectionView.numberOfItems(inSection: 0) == 0)
    }

    @Test func aFailedDeletionRestoresTheBookmarkRow() async throws {
        let screen = try await screen(Server(rejectsDeletion: true))
        let note = try #require(screen.timeline.item(forNote: "n1")?.note)
        screen.services.bookmarks.toggle(note)
        #expect(!screen.timeline.contains(noteID: "n1"))
        try await wait { screen.timeline.contains(noteID: "n1") }
        #expect(screen.timeline.noteCount == 2 && screen.services.bookmarks.isBookmarked(note))
    }

    @Test func refreshRestartsPaginationInBookmarkOrder() async throws {
        let ids = (1...(AppSettings.timelinePageSize + 3)).map { "n\($0)" }
        let server = Server(ids)
        let screen = try await screen(server)
        server.ids.withLock {
            $0.removeAll { $0 == "n2" }
            $0.insert("new", at: 0)
        }
        await refresh(screen.timeline)
        await loadAll(screen.timeline)
        #expect(!screen.timeline.contains(noteID: "n2"))
        #expect(screen.timeline.noteCount == ids.count)
        let ordered = server.ids.withLock { $0 }
        for (index, id) in ordered.enumerated() {
            #expect(screen.timeline.indexPath(forNote: id)?.item == index)
        }
    }
}
