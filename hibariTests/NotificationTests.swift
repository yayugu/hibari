import CoreGraphics
import Foundation
import Testing
@testable import hibari

private enum NotificationJSON {
    static func user(_ id: String, name: String? = nil) -> [String: Any] {
        ["id": id, "username": id, "name": name ?? id.capitalized,
         "avatarUrl": "https://media.example/avatar/\(id).png?w=400&h=400"]
    }

    static var note: [String: Any] {
        var note = TestData.note(id: "mine", text: "今日のノート :blobcat:")
        note["user"] = user("me")
        note["reactions"] = ["👍": 1, ":blobcat@.:": 1, ":remote_ai@remote.example:": 1]
        note["reactionEmojis"] = ["remote_ai@remote.example": "https://remote.example/emoji/remote_ai.png?w=128&h=128"]
        return note
    }

    static func notification(_ id: String, _ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["id": id, "createdAt": "2026-09-23T14:00:00.000Z", "type": type]
        object.merge(fields) { $1 }
        return object
    }

    static var reactions: [String: Any] {
        notification("g1", "reaction:grouped", [
            "note": note,
            "reactions": [
                ["user": user("alice", name: "Alice :blobcat:"), "reaction": "👍"],
                ["user": user("bob"), "reaction": ":blobcat:"],
                ["user": user("carol"), "reaction": ":remote_ai@remote.example:"],
            ],
        ])
    }

    static var reply: [String: Any] {
        var reply = TestData.note(id: "r1", text: "返信です")
        reply["user"] = user("dave")
        reply["replyId"] = "mine"
        reply["reply"] = note
        return notification("n2", "reply", ["userId": "dave", "user": user("dave"), "note": reply])
    }

    static var renotes: [String: Any] {
        var renote = TestData.note(id: "rn1", text: "")
        renote["text"] = NSNull()
        renote["user"] = user("erin")
        renote["renoteId"] = "mine"
        renote["renote"] = note
        return notification("g3", "renote:grouped", ["note": renote, "users": [user("erin"), user("frank")]])
    }

    static var follow: [String: Any] {
        notification("n4", "follow", ["userId": "grace", "user": user("grace")])
    }
}

@Suite("Notifications")
struct NotificationTests {
    private func decode(_ objects: [[String: Any]]) throws -> (notifications: [MisskeyNotification], lastID: String?) {
        try MisskeyJSON.decodeNotifications(from: JSONSerialization.data(withJSONObject: objects))
    }

    @Test func groupsAndSinglesDecode() throws {
        let page = try decode([
            NotificationJSON.reactions, NotificationJSON.reply, NotificationJSON.renotes, NotificationJSON.follow,
            NotificationJSON.notification("n5", "reaction", ["userId": "heidi", "user": NotificationJSON.user("heidi"),
                                                             "note": NotificationJSON.note, "reaction": "🎉"]),
            NotificationJSON.notification("n6", "achievementEarned", ["achievement": "notes1"]),
            NotificationJSON.notification("n7", "app", ["header": "お知らせ", "body": "本文", "icon": NSNull()]),
        ])
        #expect(page.notifications.map(\.id) == ["g1", "n2", "g3", "n4", "n5", "n6", "n7"])
        let reactions = page.notifications[0]
        guard case .reactions(let list) = reactions.kind else { Issue.record("not reactions"); return }
        #expect(list.map(\.reaction) == ["👍", ":blobcat:", ":remote_ai@remote.example:"])
        #expect(reactions.users.map(\.id) == ["alice", "bob", "carol"])
        #expect(reactions.subjectNote?.id == "mine" && reactions.isGroupable && !reactions.isShownAsNote)

        let reply = page.notifications[1]
        #expect(reply.isShownAsNote && reply.note?.id == "r1" && reply.users.isEmpty)

        let renotes = page.notifications[2]
        #expect(renotes.users.map(\.id) == ["erin", "frank"])
        #expect(renotes.subjectNote?.id == "mine", "the renoted note, not the renote")

        #expect(page.notifications[3].users.map(\.id) == ["grace"] && page.notifications[3].subjectNote == nil)
        if case .reactions(let single) = page.notifications[4].kind {
            #expect(single.map(\.user.id) == ["heidi"])
        } else {
            Issue.record("a single reaction is a group of one")
        }
        if case .app(let header, let body, let icon) = page.notifications[6].kind {
            #expect(header == "お知らせ" && body == "本文" && icon == nil)
        } else {
            Issue.record("not an app notification")
        }
    }

    @Test func unknownAndBrokenNotificationsAreDroppedButStillMoveTheCursor() throws {
        let page = try decode([
            NotificationJSON.follow,
            NotificationJSON.notification("n8", "reaction", ["userId": "a", "user": NotificationJSON.user("a"),
                                                             "reaction": "👍"]),
            NotificationJSON.notification("n9", "someFutureType"),
        ])
        #expect(page.notifications.map(\.id) == ["n4"])
        #expect(page.lastID == "n9", "the next page starts after what the server sent")
        #expect(try decode([]).lastID == nil)
    }

    @Test func pagesMarkReadAndHoldBackAGroupThePageCutOff() async throws {
        let requests = Locked<[[String: Any]]>([])
        let urlSession = StubURLProtocol.session { request, body in
            #expect(request.url?.path() == "/api/i/notifications-grouped")
            requests.withLock { $0.append(body) }
            return .json([NotificationJSON.reply, NotificationJSON.follow, NotificationJSON.reactions])
        }
        let reads = Counter()
        let source = NotificationTimelineSource(
            client: MisskeyClient(server: TestData.server, token: "T", session: urlSession),
            didRead: { reads.increment() })
        let page = try await source.page(until: "n0", limit: 20)
        #expect(page.entries.map(\.id) == ["n2", "n4"], "the reactions at the end may go on in the next page")
        #expect(page.cursor == "n4", "which starts after the entry before them")
        #expect(reads.count == 1)
        let body = try #require(requests.withLock { $0.first })
        #expect(body["untilId"] as? String == "n0" && body["markAsRead"] as? Bool == true && body["limit"] as? Int == 20)
    }

    @Test func aPageOfOneGroupIsKept() async throws {
        let urlSession = StubURLProtocol.session { _, _ in .json([NotificationJSON.reactions]) }
        let source = NotificationTimelineSource(
            client: MisskeyClient(server: TestData.server, token: "T", session: urlSession), didRead: {})
        let page = try await source.page(until: nil, limit: 20)
        #expect(page.entries.map(\.id) == ["g1"] && page.cursor == "g1")
    }

    private func notification(_ object: [String: Any]) throws -> MisskeyNotification {
        try #require(try decode([object]).notifications.first)
    }

    @Test func rowsChangeTheirHashWhenAGroupGrows() throws {
        let small = TimelineItem(notification: try notification(NotificationJSON.reactions))
        var more = NotificationJSON.reactions
        more["reactions"] = (more["reactions"] as! [[String: Any]])
            + [["user": NotificationJSON.user("zed"), "reaction": "🎉"]]
        let large = TimelineItem(notification: try notification(more))
        #expect(small.id == large.id && small.contentHash != large.contentHash)
        #expect(small.note == nil && small.notification != nil)
    }

    @Test func reactionRowsShowWhoAndLinkTheirProfiles() throws {
        let engine = Samples.engine()
        let item = TimelineItem(notification: try notification(NotificationJSON.reactions))
        let layout = engine.layout(for: item, context: Samples.context())
        #expect(layout.images.count == 3, "an avatar for each")
        for (slot, id) in zip(layout.images, ["alice", "bob", "carol"]) {
            #expect(layout.action(at: CGPoint(x: slot.frame.midX, y: slot.frame.midY)) == .user(id))
        }
        let below = try #require(layout.images.first).frame.maxY + 30
        #expect(layout.action(at: CGPoint(x: 200, y: below)) == nil, "the rest of the row opens the note")
        #expect(layout.accessibility.beforeTime == "Alice :blobcat:さんと他2人がリアクションしました")
        #expect(layout.accessibility.afterTime == "今日のノート :blobcat:")
        #expect(layout.timeSlots.count == 1)
        let emojis = layout.emojiRequests.map(\.url)
        #expect(emojis.contains(Samples.emojis["blobcat"]!))
        #expect(emojis.contains { $0.contains("remote_ai") })
    }

    @Test func rowsWaitForTheEmojisOfTheirNameNoteAndReactions() throws {
        let item = TimelineItem(notification: try notification(NotificationJSON.reactions))
        let usage = Samples.engine().customEmojis(in: [item])
        #expect(usage.text.contains(Samples.emojis["blobcat"]!), "in the name and the note")
        #expect(usage.reactions.contains { $0.contains("remote_ai") })
    }

    @Test func longSummariesWrapAndKeepTheTime() throws {
        var follow = NotificationJSON.follow
        follow["user"] = NotificationJSON.user("grace", name: String(repeating: "とても長い名前", count: 3))
        let layout = Samples.engine().layout(for: TimelineItem(notification: try notification(follow)),
                                             context: Samples.context(width: 320))
        let slot = try #require(layout.timeSlots.first)
        let summary = try #require(layout.blocks.first { $0.frame.minY > layout.images[0].frame.maxY })
        #expect(summary.frame.height > slot.height * 1.5, "more than one line")
        #expect(slot.origin.x + slot.reservedWidth <= 320, "the time stays on screen")
    }
}

@Suite("Unread notifications")
@MainActor
struct UnreadNotificationTests {
    private func account(_ id: String) throws -> Account {
        var me = TestData.me
        me["id"] = id
        let data = try JSONSerialization.data(withJSONObject: me)
        return Account(server: TestData.server, me: try JSONDecoder().decode(MeDetailed.self, from: data))
    }

    private func setUp(counts: Locked<[String: Int]>) throws -> (AccountStore, UnreadNotifications, Account, Account) {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let store = AccountStore(defaults: defaults, tokens: InMemoryTokenStore())
        let alice = try account("u1")
        let bob = try account("u2")
        try store.signIn(alice, token: "A")
        try store.signIn(bob, token: "B")
        let urlSession = StubURLProtocol.session { request, body in
            #expect(request.url?.path() == "/api/i")
            let count = counts.withLock { $0[body["i"] as? String ?? ""] } ?? 0
            return .json(["id": "x", "username": "x", "hasUnreadNotification": count > 0,
                          "unreadNotificationsCount": count])
        }
        return (store, UnreadNotifications(accounts: store, urlSession: urlSession), alice, bob)
    }

    @Test func countsComeFromEachAccountsServer() async throws {
        let counts = Locked(["A": 4, "B": 0])
        let (_, unread, alice, bob) = try setUp(counts: counts)
        await unread.checkAll()
        #expect(unread.count(for: alice) == 4 && unread.count(for: bob) == 0)
        #expect(unread.othersHaveUnread, "alice is not the current account")

        counts.withLock { $0 = ["A": 0, "B": 2] }
        await unread.checkAll()
        #expect(unread.count(for: bob) == 2 && !unread.othersHaveUnread)
    }

    @Test func readingClearsTheCountAndOutdatesAnswersAskedBefore() async throws {
        let counts = Locked(["A": 0, "B": 3])
        let (_, unread, _, bob) = try setUp(counts: counts)
        await unread.checkAll()
        let askedBefore = ContinuousClock.now
        unread.didRead(bob.id)
        #expect(unread.count(for: bob) == 0)
        unread.update(3, for: bob.id, askedAt: askedBefore)
        #expect(unread.count(for: bob) == 0, "asked before the notifications were read")
        unread.update(1, for: bob.id, askedAt: .now)
        #expect(unread.count(for: bob) == 1)
    }

    @Test func signedOutAccountsLoseTheirCount() async throws {
        let counts = Locked(["A": 5, "B": 0])
        let (store, unread, alice, _) = try setUp(counts: counts)
        await unread.checkAll()
        #expect(unread.othersHaveUnread)
        store.signOut(alice)
        #expect(!unread.othersHaveUnread && unread.count(for: alice) == 0)
        unread.update(5, for: alice.id, askedAt: .now)
        #expect(unread.count(for: alice) == 0, "not an account any more")
    }

    @Test func serversWithoutACountOnlySayWhetherThereAreAny() throws {
        let decode = { (object: [String: Any]) in
            try MisskeyJSON.decoder().decode(UnreadNotificationCount.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(try decode(["hasUnreadNotification": true]).count == 1)
        #expect(try decode(["hasUnreadNotification": false]).count == 0)
        #expect(try decode(["hasUnreadNotification": true, "unreadNotificationsCount": 12]).count == 12)
        #expect(try decode([:]).count == 0)
    }
}
