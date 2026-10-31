import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import hibari

@Suite("Channels")
@MainActor
struct ChannelTests {
    private func note(id: String = "n1", channel: [String: Any]?, renote: [String: Any]? = nil) throws -> Note {
        var object = TestData.note(id: id)
        object["channelId"] = channel?["id"]
        object["channel"] = channel
        if let renote {
            object["text"] = nil
            object["renoteId"] = renote["id"]
            object["renote"] = renote
        }
        return try MisskeyJSON.decoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private let dev: [String: Any] = ["id": "c1", "name": "ひばり開発", "color": "#1d9bf0", "isSensitive": false,
                                      "allowRenoteToExternal": true, "userId": "u2"]

    @Test func notesCarryTheirChannel() throws {
        let channel = try #require(try note(channel: dev).channel)
        #expect(channel == Channel(id: "c1", name: "ひばり開発", color: "#1d9bf0"))
        #expect(channel.rgb == 0x1d9bf0)
        #expect(try note(channel: nil).channel == nil)
        // A draft keeps the quote's.
        let quote = try note(channel: dev)
        let saved = try MisskeyJSON.decoder().decode(Note.self, from: MisskeyJSON.encoder().encode(quote))
        #expect(saved.channel == channel)

        let odd = try #require(try note(channel: ["id": "c2", "name": "古い", "color": "red"]).channel)
        #expect(odd.rgb == nil && odd.allowRenoteToExternal && !odd.isSensitive)
    }

    @Test func notesGoInTheChannelTheyAreSentTo() {
        let parameters = NoteDraft(text: "hi", visibility: .public, replyID: "r", channelID: "c1").parameters
        #expect(parameters["channelId"] as? String == "c1" && parameters["replyId"] as? String == "r")
        #expect(NoteDraft(text: "hi", visibility: .public).parameters["channelId"] == nil)
    }

    @Test func aChannelsNotesLeaveItOnlyWhereItAllows() throws {
        let account = Account(server: TestData.server, me: try JSONDecoder().decode(
            MeDetailed.self, from: JSONSerialization.data(withJSONObject: ["id": "me", "username": "me"])))
        let open = try note(channel: dev)
        #expect(open.canBeRenoted(by: account))
        #expect(open.canBeRenoted(by: account, into: "c1") && open.canBeRenoted(by: account, into: "c9"))
        var closedChannel = dev
        closedChannel["id"] = "c2"
        closedChannel["allowRenoteToExternal"] = false
        let closed = try note(channel: closedChannel)
        #expect(closed.canBeRenoted(by: account, into: "c2"))
        #expect(!closed.canBeRenoted(by: account) && !closed.canBeRenoted(by: account, into: "c1"))
    }

    @Test func aSensitiveChannelsNotesGoNoWiderThanHomeOutsideIt() throws {
        var sensitive = dev
        sensitive["isSensitive"] = true
        #expect(NoteVisibility(renoting: try note(channel: sensitive)) == .home)
        #expect(NoteVisibility(renoting: try note(channel: dev)) == .public)
        #expect(NoteVisibility(renoting: try note(channel: nil)) == .public)
    }

    @Test func renotingInTheChannelSendsIt() async throws {
        let sent = Locked<[String]>([])
        let client = MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { request, body in
            let fields = ["renoteId", "channelId", "visibility"].map { "\($0)=\(body[$0] as? String ?? "-")" }
            sent.withLock { $0.append((request.url?.path ?? "") + " " + fields.joined(separator: " ")) }
            return .json(["createdNote": TestData.note(id: "new")])
        })
        let services = try TimelineTestSupport.services(client: client)
        let note = try note(channel: dev)
        #expect(services.renote(note, in: note.channel))
        for _ in 0..<200 where sent.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent.withLock { $0 } == ["/api/notes/create renoteId=n1 channelId=c1 visibility=public"])
    }

    @Test func followedChannelsComeInFull() async throws {
        let asked = Locked<[String]>([])
        let client = MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { _, body in
            let until = body["untilId"] as? String
            asked.withLock { $0.append(until ?? "-") }
            let ids = until == nil ? (0..<100).map { "c\(999 - $0)" } : ["c1"]
            return .json(ids.map { ["id": $0, "name": $0] })
        })
        let channels = try await client.followedChannels()
        #expect(channels.count == 101 && channels.last?.id == "c1")
        #expect(asked.withLock { $0 } == ["-", "c900"])
    }

    @Test func aChannelsTabAsksForItsNotes() async throws {
        let asked = Locked<[String]>([])
        let client = MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { request, body in
            asked.withLock { $0.append("\(request.url?.path ?? "") \(body["channelId"] as? String ?? "-")") }
            #expect(body["withFiles"] == nil)
            var withFile = TestData.note(id: "n2")
            withFile["files"] = [["id": "f", "type": "image/png", "name": "f.png", "isSensitive": false,
                                  "properties": ["width": 4, "height": 3], "url": "https://media.example/f.png"]]
            return .json([withFile, TestData.note(id: "n1")])
        })
        let channel = Channel(id: "c1", name: "ひばり開発")
        let all = TimelineTab(channel).timeline(client: client)
        let media = TimelineTab(channel, mediaOnly: true).timeline(client: client)
        #expect(all.id == "channel.c1" && media.id == "channel.c1.media" && all.title == "ひばり開発")
        #expect(all.source.refreshPolicy == .preserveHistory && media.source.refreshPolicy == .preserveHistory)
        #expect(try await all.source.page(until: nil, limit: 2).entries.map(\.id) == ["n2", "n1"])
        #expect(try await media.source.page(until: nil, limit: 2).entries.map(\.id) == ["n2"])
        #expect(asked.withLock { $0 } == ["/api/channels/timeline c1", "/api/channels/timeline c1"])
    }

    @Test func tabsAreOfTheFavoriteAndFollowedChannels() async throws {
        let client = MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { request, _ in
            switch request.url?.path {
            case "/api/channels/my-favorites":
                return .json([["id": "c2", "name": "写真部", "color": "#f59e0b"], ["id": "c1", "name": "ひばり開発"]])
            default:
                return .json([["id": "c4", "name": "雑談"], ["id": "c1", "name": "ひばり開発"]])
            }
        })
        let channels = try await client.tabChannels()
        #expect(channels.map(\.id) == ["c2", "c1", "c4"])
        #expect(TimelineTab.choices(of: channels).map(\.id)
                == ["channel.c2", "channel.c1", "channel.c4", "channel.c2.media", "channel.c1.media", "channel.c4.media"])
        #expect(TimelineTab(channels[0], mediaOnly: true).timeline(client: client).channel
                == Channel(id: "c2", name: "写真部", color: "#f59e0b"))
        #expect(TimelineTab(.home).timeline(client: client).channel == nil)
    }

    @Test func channelTabsGoWhenTheSettingsWouldNoLongerOfferThem() {
        let dev = TimelineTab(Channel(id: "c1", name: "ひばり開発"))
        let unfollowed = TimelineTab(Channel(id: "c2", name: "写真部"), mediaOnly: true)
        let list = TimelineTab(UserList(id: "l1", name: "友だち"))
        let tabs = [dev, TimelineTab(.home), unfollowed, list]
        // Which there are is not known at launch.
        #expect(TimelineTab.shown(tabs, of: [.home]) == tabs)
        #expect(TimelineTab.reconciled(tabs, lists: nil, antennas: nil, channels: nil) == tabs)
        let renamed = Channel(id: "c1", name: "開発", color: "#22c55e")
        #expect(TimelineTab.reconciled(tabs, lists: nil, antennas: nil, channels: [renamed])
                == [TimelineTab(renamed), TimelineTab(.home), list])
        #expect(TimelineTab.reconciled(tabs, lists: [], antennas: nil) == [dev, TimelineTab(.home), unfollowed])
    }

    @Test func aChannelsTabOrScreenPostsInIt() throws {
        let client = MisskeyClient(server: TestData.server, token: "T", session: StubURLProtocol.session { _, _ in .json([]) })
        let services = try TimelineTestSupport.services(client: client)
        let channel = Channel(id: "c1", name: "雑談", color: "#e11d48")
        let pages = [TimelineTab(.home), TimelineTab(channel)].map { $0.timeline(client: client) }
        let session = TimelineSession(timelines: pages, timelineKinds: TimelineKind.allCases, engine: services.engine,
                                      clock: services.clock, account: services.account, client: client,
                                      emojis: services.emojis)
        let root = RootViewController(session: session)
        root.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        root.view.layoutIfNeeded()
        #expect(root.composeTarget == .some(nil))
        root.select(1, animated: false)
        #expect(root.composeTarget == .some(channel))

        let channelScreen = ListTimelineViewController(tab: TimelineTab(channel), services: services)
        root.home.navigationController?.pushViewController(channelScreen, animated: false)
        #expect(root.composeTarget == .some(channel))

        let listScreen = ListTimelineViewController(tab: TimelineTab(UserList(id: "l1", name: "友だち")), services: services)
        root.home.navigationController?.pushViewController(listScreen, animated: false)
        #expect(root.composeTarget == nil)
    }
}
