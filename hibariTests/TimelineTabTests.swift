import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Timeline tabs")
@MainActor
struct TimelineTabTests {
    private func client(_ handler: @escaping StubURLProtocol.Handler = { _, _ in .json([]) }) -> MisskeyClient {
        MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session(handler))
    }

    @Test func savedTabsKeepTheirFormat() throws {
        let saved = #"[{"source":{"timeline":{"kind":"local"}},"mediaOnly":true},{"source":{"timeline":{"kind":"home"}},"mediaOnly":false}]"#
        let tabs = try JSONDecoder().decode([TimelineTab].self, from: Data(saved.utf8))
        #expect(tabs == [TimelineTab(.local, mediaOnly: true), TimelineTab(.home)])
        #expect(try JSONDecoder().decode([TimelineTab].self, from: JSONEncoder().encode(tabs)) == tabs)
        // The timelines of all the notes keep the ids (and saved positions) they had before tabs.
        #expect(TimelineTab.defaults.map(\.id) == TimelineKind.allCases.map(\.rawValue))
        #expect(tabs.map(\.id) == ["local.media", "home"])
        #expect(tabs.map(\.title) == ["ローカルのメディア", "ホーム"])
    }

    @Test func shownTabsAreTheOnesOfTheAccountsTimelines() {
        let kinds: [TimelineKind] = [.home, .featured, .global]
        let tabs = [TimelineTab(.local), TimelineTab(.global, mediaOnly: true), TimelineTab(.home),
                    TimelineTab(.global, mediaOnly: true)]
        #expect(TimelineTab.shown(tabs, of: kinds) == [TimelineTab(.global, mediaOnly: true), TimelineTab(.home)])
        #expect(TimelineTab.shown([TimelineTab(.local, mediaOnly: true)], of: kinds) == [TimelineTab(.home)])
        #expect(TimelineTab.choices(of: kinds).map(\.id) == ["home", "featured", "global",
                                                              "home.media", "featured.media", "global.media"])
    }

    @Test func mediaTabsAskTheServerForNotesWithFiles() async throws {
        let asked = Locked<[String]>([])
        let client = client { request, body in
            let withFiles = body["withFiles"] as? Bool == true ? " withFiles" : ""
            asked.withLock { $0.append((request.url?.path ?? "") + withFiles) }
            return .json([])
        }
        let all = TimelineTab(.local).timeline(client: client).source
        let media = TimelineTab(.local, mediaOnly: true).timeline(client: client).source
        _ = try await all.page(until: nil, limit: 20)
        _ = try await media.page(until: nil, limit: 20)
        _ = try await media.page(after: "n1", limit: 20)
        #expect(asked.withLock { $0 } == ["/api/notes/local-timeline", "/api/notes/local-timeline withFiles",
                                          "/api/notes/local-timeline withFiles"])
        #expect(media.refreshPolicy == .preserveHistory)
    }

    @Test func featuredMediaIsPickedOutHere() async throws {
        let client = client { request, body in
            #expect(request.url?.path == "/api/notes/featured" && body["withFiles"] == nil)
            var withFile = TestData.note(id: "n3")
            withFile["files"] = [["id": "f", "type": "image/png", "name": "f.png", "isSensitive": false,
                                  "properties": ["width": 4, "height": 3], "url": "https://media.example/f.png"]]
            return .json([withFile, TestData.note(id: "n2"), TestData.note(id: "n1")])
        }
        let source = TimelineTab(.featured, mediaOnly: true).timeline(client: client).source
        let page = try await source.page(until: nil, limit: 3)
        #expect(page.entries.map(\.id) == ["n3"])
        // The next page starts below what the server sent, not below what is shown.
        #expect(page.cursor == "n1")
        #expect(source.refreshPolicy == .replace)
    }

    @Test func listAndAntennaTabsKeepTheirIDsAsTheyAreRenamed() throws {
        let list = TimelineTab(UserList(id: "l1", name: "友だち"))
        let antenna = TimelineTab(Antenna(id: "a1", name: "画像"), mediaOnly: true)
        let saved = try JSONEncoder().encode([list, antenna])
        #expect(try JSONDecoder().decode([TimelineTab].self, from: saved) == [list, antenna])
        #expect([list, antenna].map(\.id) == ["list.l1", "antenna.a1.media"])
        #expect([list, antenna].map(\.title) == ["友だち", "画像のメディア"])
        #expect(TimelineTab(UserList(id: "l1", name: "家族")).id == list.id)
        #expect(TimelineTab.choices(of: [UserList(id: "l1", name: "友だち"), UserList(id: "l2", name: "仕事")]).map(\.id)
                == ["list.l1", "list.l2", "list.l1.media", "list.l2.media"])
    }

    @Test func listsAndAntennasStayUntilTheyAreKnownToBeGone() {
        let list = TimelineTab(UserList(id: "l1", name: "友だち"))
        let gone = TimelineTab(UserList(id: "l2", name: "旧"))
        let antenna = TimelineTab(Antenna(id: "a1", name: "画像"))
        let tabs = [list, TimelineTab(.home), gone, antenna, TimelineTab(UserList(id: "l1", name: "友だち2"))]
        // Which there are is not known at launch: none is left out, only repeats.
        #expect(TimelineTab.shown(tabs, of: [.home]) == [list, TimelineTab(.home), gone, antenna])
        #expect(TimelineTab.shown([list], of: [.home]) == [list])

        let lists = [UserList(id: "l1", name: "家族")]
        #expect(TimelineTab.reconciled([list, TimelineTab(.home), gone, antenna], lists: lists, antennas: nil)
                == [TimelineTab(UserList(id: "l1", name: "家族")), TimelineTab(.home), antenna])
        #expect(TimelineTab.reconciled([list, antenna], lists: nil, antennas: []) == [list])
    }

    @Test func listAndAntennaTabsAskForTheirNotes() async throws {
        let asked = Locked<[String]>([])
        let client = client { request, body in
            let parameters = body.filter { $0.key != "i" && $0.key != "limit" }
                .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            asked.withLock { $0.append((request.url?.path ?? "") + " " + parameters) }
            return .json([])
        }
        let list = UserList(id: "l1", name: "友だち")
        let antenna = Antenna(id: "a1", name: "画像")
        let sources = [TimelineTab(list), TimelineTab(list, mediaOnly: true), TimelineTab(antenna),
                       TimelineTab(antenna, mediaOnly: true)].map { $0.timeline(client: client).source }
        for source in sources {
            _ = try await source.page(until: nil, limit: 20)
            #expect(source.refreshPolicy == .preserveHistory)
        }
        // `antennas/notes` takes no `withFiles`: its notes with files are picked out here.
        #expect(asked.withLock { $0 } == ["/api/notes/user-list-timeline listId=l1",
                                          "/api/notes/user-list-timeline listId=l1 withFiles=1",
                                          "/api/antennas/notes antennaId=a1", "/api/antennas/notes antennaId=a1"])
    }

    @Test func changingTheTabsKeepsTheTimelinesThatStay() throws {
        let client = client()
        let services = try TimelineTestSupport.services(client: client)
        let session = TimelineSession(timelines: [], timelineKinds: TimelineKind.allCases, engine: services.engine,
                                      clock: services.clock, account: services.account, client: client,
                                      emojis: services.emojis)
        func pages(_ tabs: TimelineTab...) throws -> [TimelineSession.Timeline] {
            try #require(session.timelines(for: tabs))
        }
        func labels(in view: UIView) -> [UILabel] {
            view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels(in: $0) }
        }
        /// The titles, "▲" for the media mark, "*" for the selected one.
        func tabs(of pager: TimelinePagerViewController) -> [String] {
            labels(in: pager.view).filter { $0.accessibilityIdentifier?.hasPrefix("tab.") == true }
                .sorted { $0.frame.minX < $1.frame.minX }
                .map { label in
                    (label.attributedText?.string ?? "").replacingOccurrences(of: "\u{FFFC}", with: "▲")
                        + (label.accessibilityTraits.contains(.selected) ? "*" : "")
                }
        }

        let pager = TimelinePagerViewController(session: session, services: services,
                                                pages: try pages(TimelineTab(.home), TimelineTab(.local), TimelineTab(.social)))
        pager.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        pager.view.layoutIfNeeded()
        pager.select(1, animated: false)
        let before = pager.timelines

        pager.setPages(try pages(TimelineTab(.social), TimelineTab(.local), TimelineTab(.home, mediaOnly: true)))
        #expect(pager.timelines.map(\.timelineID) == ["social", "local", "home.media"])
        #expect(pager.timelines[0] === before[2] && pager.timelines[1] === before[1])
        #expect(before[0].parent == nil && before[0].view.superview == nil)
        #expect(pager.currentTimeline === before[1])
        #expect(tabs(of: pager) == ["ソーシャル", "ローカル*", "▲ ホーム"])
        #expect(labels(in: pager.view).first { $0.accessibilityIdentifier == "tab.2" }?.accessibilityLabel
                == "ホームのメディア")

        // The one shown goes: the one in its place shows.
        pager.setPages(try pages(TimelineTab(.social), TimelineTab(.home, mediaOnly: true)))
        #expect(pager.currentTimeline?.timelineID == "home.media")
        #expect(tabs(of: pager) == ["ソーシャル", "▲ ホーム*"])
    }
}
