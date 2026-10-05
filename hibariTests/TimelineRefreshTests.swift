import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Timeline refresh", .serialized)
@MainActor
struct TimelineRefreshTests {
    enum List: Sendable {
        case timeline(TimelineKind)
        case profile(ProfileTab)
        case bookmarks, likes, notifications, mentions, direct
        case search(NoteSearch)

        func source(client: MisskeyClient) -> any TimelineSource {
            switch self {
            case .timeline(let kind): APITimelineSource(client: client, endpoint: kind.endpoint)
            case .profile(let tab): UserNotesSource(client: client, userID: "u1", tab: tab)
            case .bookmarks: BookmarkedNotesSource(client: client)
            case .likes: ReactedNotesSource(client: client, userID: "u1")
            case .notifications: NotificationTimelineSource(client: client, didRead: {})
            case .mentions: APITimelineSource(client: client, endpoint: "notes/mentions")
            case .direct: APITimelineSource(client: client, endpoint: "notes/mentions",
                                             parameters: ["visibility": "specified"])
            case .search(let search): NoteSearchSource(client: client, search: search)
            }
        }
    }

    nonisolated static let historyLists: [List] = [.timeline(.home), .timeline(.local), .timeline(.social), .timeline(.global)]
    nonisolated static let replacementLists: [List] = [.timeline(.featured)] + ProfileTab.allCases.map(List.profile) + [
        .bookmarks, .likes, .notifications, .mentions, .direct,
        .search(.keywords("hello", userID: nil)), .search(.hashtag("hello")), .search(.user("u1")),
    ]

    private struct DefaultNoteSource: NoteTimelineSource {
        func notes(until untilID: String?, limit: Int) async throws -> [Note] { [] }
    }

    private final class Server: Sendable {
        struct State {
            var ids: [String]
            var text = "original"
            var fails = false
        }
        let state: Locked<State>
        let cursors = Locked<[String?]>([])
        let renoteID: String?

        init(_ ids: [String] = ["n006", "n005", "n004", "n003"], renoteID: String? = nil) {
            state = Locked(State(ids: ids))
            self.renoteID = renoteID
        }

        func update(_ ids: [String]) {
            state.withLock { $0 = State(ids: ids, text: "updated") }
        }

        func respond(_ request: URLRequest, _ body: [String: Any]) -> StubURLProtocol.Response {
            let path = request.url?.path() ?? ""
            if path == "/api/notes/delete" {
                state.withLock { $0.ids.removeAll { $0 == body["noteId"] as? String } }
                return StubURLProtocol.Response(status: 204)
            }
            let state = state.withLock { $0 }
            if state.fails {
                return .json(["error": ["code": "INTERNAL_ERROR", "message": "failed"]], status: 500)
            }
            let prefix = switch path {
            case "/api/i/favorites": "f-"
            case "/api/users/reactions": "r-"
            default: ""
            }
            let cursor = body["untilId"] as? String
            cursors.withLock { $0.append(cursor) }
            let start: Int
            if let cursor {
                guard let index = state.ids.firstIndex(where: { prefix + $0 == cursor }) else { return .json([]) }
                start = index + 1
            } else {
                start = 0
            }
            let ids = Array(state.ids.dropFirst(start).prefix(body["limit"] as? Int ?? 20))
            if path == "/api/i/notifications-grouped" {
                return .json(ids.map { id in
                    ["id": id, "createdAt": "2026-09-23T15:00:00.000Z", "type": "follow", "userId": "u-" + id,
                     "user": ["id": "u-" + id, "username": id, "name": state.text]] as [String: Any]
                })
            }
            let notes = ids.map { id -> [String: Any] in
                var note = TestData.note(id: id, text: state.text)
                if id == renoteID {
                    note["text"] = NSNull()
                    note["user"] = ["id": "u1", "username": "alice"]
                    note["renoteId"] = "target"
                    note["renote"] = TestData.note(id: "target")
                }
                return note
            }
            return prefix.isEmpty ? .json(notes) : .json(zip(ids, notes).map { id, note in
                ["id": prefix + id, "note": note] as [String: Any]
            })
        }
    }

    private func client(_ server: Server) -> MisskeyClient {
        MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { server.respond($0, $1) })
    }

    private func screen(_ list: List, server: Server) async throws
        -> (timeline: TimelineViewController, services: NoteServices) {
        let client = client(server)
        let services = try TimelineTestSupport.services(client: client)
        let timeline = TimelineViewController(timelineID: "test", source: list.source(client: client), services: services)
        timeline.view.frame = CGRect(x: 0, y: 0, width: 402, height: 240)
        timeline.view.layoutIfNeeded()
        await TimelineTestSupport.loadAll(timeline)
        return (timeline, services)
    }

    private func expectIDs(_ ids: [String], in timeline: TimelineViewController) {
        #expect(timeline.noteCount == ids.count)
        #expect(timeline.collectionView.numberOfItems(inSection: 0) == ids.count)
        for (index, id) in ids.enumerated() {
            #expect(timeline.indexPath(forNote: id)?.item == index)
        }
    }

    private func ids(_ count: Int) -> [String] {
        (1...count).reversed().map { String(format: "n%03d", $0) }
    }

    @Test func sourcesChooseTheIntendedRefreshPolicy() {
        #expect(DefaultNoteSource().refreshPolicy == .replace)
        let client = client(Server())
        for list in Self.historyLists {
            #expect(list.source(client: client).refreshPolicy == .preserveHistory, "\(list)")
        }
        for list in Self.replacementLists {
            #expect(list.source(client: client).refreshPolicy == .replace, "\(list)")
        }
    }

    // The controller is shared. Exercise notes with a separate cursor and notifications;
    // source-specific endpoints and policies are checked without constructing every screen.
    @Test(arguments: [List.bookmarks, .notifications])
    func refreshReplacesDeletedAndChangedEntriesEvenWithOverlap(_ list: List) async throws {
        let server = Server()
        let screen = try await screen(list, server: server)
        let oldHash = try #require(screen.timeline.item(forNote: "n005")).contentHash
        server.update(["n004", "n005"])
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs(["n004", "n005"], in: screen.timeline)
        #expect(!screen.timeline.contains(noteID: "n006") && !screen.timeline.contains(noteID: "n003"))
        #expect(screen.timeline.item(forNote: "n005")?.contentHash != oldHash)
    }

    @Test func refreshCanReplaceTheListWithNothing() async throws {
        let server = Server()
        let screen = try await screen(.bookmarks, server: server)
        server.update([])
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs([], in: screen.timeline)
        #expect(!screen.timeline.hasMorePages && screen.timeline.gapCount == 0)
    }

    @Test(arguments: [List.bookmarks, .notifications])
    func refreshRestartsPaginationAndUsesTheServersOrder(_ list: List) async throws {
        let original = ids(AppSettings.timelinePageSize + 5)
        let server = Server(original)
        let screen = try await screen(list, server: server)
        let updated = ["new"] + original.filter { $0 != original[1] }
        server.update(updated)
        server.cursors.withLock { $0.removeAll() }
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs(Array(updated.prefix(AppSettings.timelinePageSize)), in: screen.timeline)
        #expect(screen.timeline.hasMorePages)
        await TimelineTestSupport.loadAll(screen.timeline)
        expectIDs(updated, in: screen.timeline)
        let cursors = server.cursors.withLock { $0 }
        #expect(cursors.count == 3 && cursors[0] == nil)
        let prefix = switch list {
        case .bookmarks: "f-"
        case .likes: "r-"
        default: ""
        }
        #expect(cursors.dropFirst().first == prefix + updated[AppSettings.timelinePageSize - 1])
    }

    @Test func aReplacedListShowsFromTheTopButLeavesAPullAsTheFingerHoldsIt() async throws {
        let server = Server(ids(10))
        let screen = try await screen(.bookmarks, server: server)
        let collectionView = screen.timeline.collectionView
        let top = -collectionView.adjustedContentInset.top
        collectionView.contentOffset.y = top + 200
        await TimelineTestSupport.refresh(screen.timeline)
        #expect(collectionView.contentOffset.y == top)
        collectionView.contentOffset.y = top - 60
        await TimelineTestSupport.refresh(screen.timeline)
        #expect(collectionView.contentOffset.y == top - 60)
    }

    private final class DraggedScrollView: UIScrollView {
        var isHeld = false
        override var isDragging: Bool { isHeld }
    }

    @Test func aDragStartsOneRefreshEvenWhenTheContentMovesUnderTheFinger() {
        let scrollView = DraggedScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        let pull = PullToRefresh(scrollView: scrollView)
        var refreshes = 0
        pull.onRefresh = { refreshes += 1 }
        func drag(to distance: CGFloat) {
            scrollView.contentOffset.y = -distance
            pull.scrollViewDidScroll(scrollView)
        }
        scrollView.isHeld = true
        pull.scrollViewWillBeginDragging(scrollView)
        drag(to: 60)
        pull.endRefreshing()
        drag(to: 0)
        drag(to: 60)
        #expect(refreshes == 1)
        scrollView.isHeld = false
        drag(to: 0)
        scrollView.isHeld = true
        pull.scrollViewWillBeginDragging(scrollView)
        drag(to: 60)
        #expect(refreshes == 2)
    }

    @Test(arguments: [List.bookmarks, .timeline(.home)])
    func aFailedRefreshKeepsTheExistingList(_ list: List) async throws {
        let server = Server()
        let screen = try await screen(list, server: server)
        server.state.withLock { $0.fails = true }
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs(["n006", "n005", "n004", "n003"], in: screen.timeline)
        #expect(!screen.timeline.hasMorePages)
        server.update(["n005", "n004"])
        await TimelineTestSupport.refresh(screen.timeline)
        #expect(screen.timeline.item(forNote: "n005")?.note?.text == "updated")
    }

    @Test func historyRefreshMergesNewNotesAndKeepsTheReadingPosition() async throws {
        let server = Server()
        let screen = try await screen(.timeline(.home), server: server)
        let timeline = screen.timeline
        let indexPath = try #require(timeline.indexPath(forNote: "n005"))
        let frame = try #require(timeline.collectionView.layoutAttributesForItem(at: indexPath)).frame
        timeline.collectionView.contentOffset.y = frame.minY + 10
        let before = frame.minY - timeline.collectionView.contentOffset.y
        server.update(["n008", "n007", "n006", "n005"])
        await TimelineTestSupport.refresh(timeline, keepingPosition: true)
        expectIDs(["n008", "n007", "n006", "n005", "n004", "n003"], in: timeline)
        #expect(timeline.item(forNote: "n006")?.note?.text == "updated")
        #expect(timeline.item(forNote: "n004")?.note?.text == "original")
        let afterPath = try #require(timeline.indexPath(forNote: "n005"))
        let after = try #require(timeline.collectionView.layoutAttributesForItem(at: afterPath)).frame.minY
            - timeline.collectionView.contentOffset.y
        #expect(abs(after - before) < 0.5)
        #expect(timeline.gapCount == 0)
    }

    @Test func aRefreshBeyondTheFetchedHistoryLeavesAGap() async throws {
        let original = ids(AppSettings.timelinePageSize * 4)
        let server = Server(original)
        let screen = try await screen(.timeline(.home), server: server)
        let timeline = screen.timeline
        let path = IndexPath(item: AppSettings.timelinePageSize * 3, section: 0)
        let frame = try #require(timeline.collectionView.layoutAttributesForItem(at: path)).frame
        timeline.collectionView.contentOffset.y = frame.minY + 10
        server.update(ids(original.count + AppSettings.timelinePageSize + 5))
        await TimelineTestSupport.refresh(timeline, keepingPosition: true)
        #expect(timeline.noteCount == original.count + AppSettings.timelinePageSize)
        #expect(timeline.gapCount == 1)
        #expect(original.allSatisfy { timeline.contains(noteID: $0) })
    }

    @Test func startingOverCanStillResetAHistoryTimeline() async throws {
        let server = Server()
        let screen = try await screen(.timeline(.home), server: server)
        server.update(["n005", "n004"])
        await TimelineTestSupport.refresh(screen.timeline, startingOver: true)
        expectIDs(["n005", "n004"], in: screen.timeline)
        #expect(screen.timeline.gapCount == 0)
    }

    @Test func changesWhileHeldShowTogetherWhenTheHoldEnds() async throws {
        let server = Server()
        let screen = try await screen(.timeline(.home), server: server)
        let timeline = screen.timeline
        let hold = timeline.listHold.begin()
        timeline.remove(noteID: "n005")
        server.update(["n008", "n007", "n006", "n004", "n003"])
        await TimelineTestSupport.refresh(timeline)
        #expect(timeline.noteCount == 5 && !timeline.contains(noteID: "n005") && timeline.contains(noteID: "n008"))
        #expect(timeline.collectionView.numberOfItems(inSection: 0) == 4)
        #expect(timeline.indexPath(forNote: "n005") != nil && timeline.indexPath(forNote: "n008") == nil)
        hold.end()
        expectIDs(["n008", "n007", "n006", "n004", "n003"], in: timeline)
    }

    @Test func aRefreshAskedForWhileOneIsUnderWayFollowsIt() async throws {
        let server = Server()
        let screen = try await screen(.bookmarks, server: server)
        server.cursors.withLock { $0.removeAll() }
        await withCheckedContinuation { continuation in
            screen.timeline.refresh()
            server.update(["n007", "n006"])
            screen.timeline.refresh { continuation.resume() }
        }
        expectIDs(["n007", "n006"], in: screen.timeline)
        #expect(server.cursors.withLock { $0 }.filter { $0 == nil }.count == 2, "the newest page, twice")
    }

    // Nothing lays these lists out, as for one off screen: the reload that showed the first
    // page still waits for layout when the next change comes, and UIKit only then reads
    // the rows that change starts from.
    @Test func aListNotLaidOutTakesTheNextPages() async throws {
        let original = ids(AppSettings.timelinePageSize * 2 + 5)
        let screen = try await screen(.timeline(.home), server: Server(original))
        expectIDs(original, in: screen.timeline)
    }

    @Test func aListNotLaidOutTakesARemoval() async throws {
        let screen = try await screen(.timeline(.home), server: Server())
        screen.timeline.remove(noteID: "n005")
        expectIDs(["n006", "n004", "n003"], in: screen.timeline)
    }

    @Test func aListNotLaidOutTakesNewNotesAtTheTop() async throws {
        let server = Server()
        let screen = try await screen(.timeline(.home), server: server)
        server.update(["n008", "n007", "n006", "n005", "n004", "n003"])
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs(["n008", "n007", "n006", "n005", "n004", "n003"], in: screen.timeline)
    }

    @Test func undoingARenoteRemovesItsRowInTheCommonController() async throws {
        let server = Server(renoteID: "n005")
        let screen = try await screen(.profile(.all), server: server)
        let target = try #require(screen.timeline.item(forNote: "n005")?.note?.renote)
        #expect(screen.services.renotes.isRenoted(target))
        screen.services.undoRenote(target)
        for _ in 0..<200 {
            if !screen.timeline.contains(noteID: "n005") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        expectIDs(["n006", "n004", "n003"], in: screen.timeline)
        #expect(!screen.services.renotes.isRenoted(target))
        await TimelineTestSupport.refresh(screen.timeline)
        expectIDs(["n006", "n004", "n003"], in: screen.timeline)
    }

    @Test func onlyHistoryTimelinesGetPersistentSnapshots() throws {
        let client = client(Server())
        let services = try TimelineTestSupport.services(client: client)
        let pages = TimelineKind.allCases.map { kind in
            TimelineSession.Timeline(id: kind.rawValue, title: kind.title,
                                     source: APITimelineSource(client: client, endpoint: kind.endpoint))
        }
        let session = TimelineSession(timelines: pages, engine: services.engine, clock: services.clock,
                                      account: services.account, client: client, emojis: services.emojis)
        let pager = TimelinePagerViewController(session: session, services: services, pages: pages, savesTimelines: true)
        pager.loadViewIfNeeded()
        for (kind, timeline) in zip(TimelineKind.allCases, pager.timelines) {
            #expect((timeline.snapshotStore != nil) == (kind != .featured))
        }
    }
}
