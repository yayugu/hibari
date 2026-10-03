import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Profile")
struct ProfileTests {
    private static func decode(_ object: [String: Any]) throws -> UserDetailed {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try MisskeyJSON.decoder().decode(UserDetailed.self, from: data)
    }

    @Test func profilesDecodeWithTheRelationToTheAccount() throws {
        let profile = try Self.decode([
            "id": "u2", "username": "bob", "name": "Bob :blobcat:", "host": "remote.example",
            "emojis": ["blobcat": "https://remote.example/blobcat.png"],
            "bannerUrl": "https://remote.example/banner.png", "description": "hello @alice",
            "location": "Tokyo", "birthday": "1998-01-02", "createdAt": "2020-04-15T02:17:27.000Z",
            "fields": [["name": "Web", "value": "https://bob.example"], ["name": "", "value": ""], ["broken": true]],
            "verifiedLinks": ["https://bob.example"],
            "followersCount": 3, "followingCount": 5, "notesCount": 32, "isLocked": true,
            "url": "https://remote.example/@bob",
            "isFollowing": false, "isFollowed": true, "hasPendingFollowRequestFromYou": true,
            "isBlocking": false, "isMuted": true, "isRenoteMuted": false, "withReplies": true,
        ])
        #expect(profile.user.acct == "@bob@remote.example")
        #expect(profile.user.emojis["blobcat"] != nil)
        #expect(profile.description == "hello @alice")
        #expect(profile.fields == [UserDetailed.Field(name: "Web", value: "https://bob.example")],
                "empty and broken fields are dropped")
        #expect(profile.formattedBirthday == "1998年1月2日")
        #expect(profile.notesCount == 32 && profile.followersCount == 3 && profile.isLocked)
        #expect(profile.relation.isKnown && profile.relation.isFollowed && profile.relation.isMuted)
        #expect(profile.relation.withReplies)
        #expect(FollowState(profile.relation) == .requested)
        #expect(profile.url == URL(string: "https://remote.example/@bob"))
    }

    @Test func theUsersPageIsAWebPageOnly() throws {
        for url in ["javascript:alert(1)", "tel:0120", "file:///etc/hosts", "app-settings:", "not a url"] {
            #expect(try Self.decode(["id": "u2", "username": "bob", "url": url]).url == nil, "\(url)")
        }
        #expect(try Self.decode(["id": "u2", "username": "bob", "url": "HTTP://remote.example/@bob"]).url != nil)
    }

    @Test func followButtonStates() {
        typealias Relation = UserDetailed.Relation
        #expect(FollowState(Relation(isKnown: true)) == .follow)
        #expect(FollowState(Relation(isFollowed: true, isKnown: true)) == .followBack)
        #expect(FollowState(Relation(isFollowing: true, isFollowed: true, isKnown: true)) == .following)
        #expect(FollowState(Relation(hasPendingFollowRequestFromYou: true, isKnown: true)) == .requested)
        #expect(FollowState(Relation(isFollowing: true, isBlocking: true, isKnown: true)) == .blocking)
    }

    @Test func followListsPageByTheFollowAndListTheOtherUser() async throws {
        let requests = Locked<[(String, [String: Any])]>([])
        let urlSession = StubURLProtocol.session { request, body in
            let endpoint = request.url!.lastPathComponent
            requests.withLock { $0.append((endpoint, body)) }
            let key = endpoint == "followers" ? "follower" : "followee"
            return .json([
                ["id": "f9", key: ["id": "u1", "username": "alice", "isFollowing": false, "isFollowed": true]],
                ["id": "f8", key: ["broken": true]],
            ])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let followers = try await FollowListSource(client: client, userID: "u0", list: .followers)
            .users(from: nil, limit: 30)
        #expect(followers.users.map(\.user.acct) == ["@alice"], "users that do not decode are dropped")
        #expect(followers.next == "f8", "the next page starts after the last follow, decoded or not")
        #expect(FollowState(followers.users[0].relation) == .followBack)
        let following = try await FollowListSource(client: client, userID: "u0", list: .following)
            .users(from: "f8", limit: 30)
        #expect(following.users.map(\.user.acct) == ["@alice"])
        let sent = requests.withLock { $0 }
        #expect(sent.map(\.0) == ["followers", "following"])
        #expect(sent[0].1["userId"] as? String == "u0" && sent[0].1["untilId"] == nil)
        #expect(sent[1].1["untilId"] as? String == "f8" && sent[1].1["limit"] as? Int == 30)
    }

    @Test func hiddenFollowListsSaySo() async throws {
        let urlSession = StubURLProtocol.session { _, _ in
            .json(["error": ["code": "FORBIDDEN", "message": "Forbidden."]], status: 400)
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        await #expect(throws: FollowListError.hidden(.following)) {
            try await FollowListSource(client: client, userID: "u0", list: .following).users(from: nil, limit: 30)
        }
    }

    @Test func tabsAskForTheNotesMisskeysWebClientShows() async throws {
        let requests = Locked<[String: [String: Any]]>([:])
        let urlSession = StubURLProtocol.session { request, body in
            let key = "\(request.url!.lastPathComponent):\(body["withReplies"] as? Bool ?? false)"
                + ":\(body["withFiles"] as? Bool ?? false)"
            requests.withLock { $0[key] = body }
            return .json([TestData.note(id: "n1")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        for tab in ProfileTab.allCases {
            let notes = try await UserNotesSource(client: client, userID: "u9", tab: tab).notes(until: "n5", limit: 20)
            #expect(notes.map(\.id) == ["n1"])
        }
        let sent = requests.withLock { $0 }
        #expect(Set(sent.keys) == ["featured-notes:false:false", "notes:false:false", "notes:true:false",
                                   "notes:false:true"])
        #expect(sent["notes:true:false"]?["withRenotes"] as? Bool == true, "すべて has renotes")
        #expect(sent["notes:false:true"]?["withRenotes"] as? Bool == false)
        for body in sent.values {
            #expect(body["userId"] as? String == "u9" && body["untilId"] as? String == "n5" && body["limit"] as? Int == 20)
        }
        #expect(ProfileTab.allCases.first == .highlights, "the profile opens on the leftmost tab")
    }

    @Test func mentionsNameUsersOfTheAccountsServerWithoutAHost() {
        let server = URL(string: "https://misskey.example")!
        func user(_ acct: String, _ server: URL? = server) -> String? {
            NoteServices.mentionedUser(acct, server: server).map { "\($0.username)|\($0.host ?? "-")" }
        }
        #expect(user("@alice") == "alice|-")
        #expect(user("@alice@misskey.example") == "alice|-")
        #expect(user("@Bob@Remote.Example") == "Bob|remote.example")
        #expect(user("@alice@localhost:3000", URL(string: "http://localhost:3000")!) == "alice|-")
        #expect(user("@") == nil)
    }

    @Test func mentionsWithoutAHostInRemoteNotesPointAtTheAuthorsServer() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "n1", "createdAt": "2026-09-23T15:00:00.000Z", "text": "@carol hi @dave@else.example",
            "user": ["id": "u", "username": "bob", "host": "remote.example"],
        ])
        let note = try MisskeyJSON.decoder().decode(Note.self, from: data)
        let palette = Palette.dark
        let builder = RichTextBuilder(palette: palette, emojiResolver: EmojiResolver(localEmojis: [:], mediaProxy: nil),
                                      emojiContext: .text(of: note), sizer: EmojiSizer(SampleMediaSource()))
        let text = builder.build(MFMParser.parse(note.text!), style: TextStyle(font: Typography.system(16),
                                                                               color: palette[.primaryText]))
        var links: [String] = []
        text.enumerateAttribute(TextAttribute.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let value = value as? String { links.append(value) }
        }
        #expect(links == ["mention:@carol@remote.example", "mention:@dave@else.example"])
        #expect(text.string == "@carol hi @dave@else.example", "shown as written")
    }

    @Test func avatarsNamesRepliedAndQuotedUsersOpenProfiles() throws {
        let engine = Samples.engine()
        let context = Samples.context()
        let notes = try [
            #require(Samples.firstNote { !$0.isPureRenote && $0.renote == nil && $0.reply == nil }),
            #require(Samples.firstNote { $0.isPureRenote }),
            #require(Samples.firstNote { !$0.isPureRenote && $0.reply != nil }),
            #require(Samples.firstNote { !$0.isPureRenote && $0.renote != nil && $0.cw == nil }),
        ]
        for outer in notes {
            let layout = engine.layout(for: TimelineItem(note: outer), context: context, now: Samples.now)
            let note = outer.displayedNote
            let avatar = try #require(layout.images.first { $0.media == nil })
            #expect(layout.action(at: CGPoint(x: avatar.frame.midX, y: avatar.frame.midY)) == .user(note.user.id))
            if outer.isPureRenote {
                #expect(layout.targets.contains { $0.action == .user(outer.user.id) }, "the renoter")
            }
            if let replied = note.reply?.user {
                #expect(layout.targets.contains { $0.action == .user(replied.id) }, "返信先")
            }
            if let quoted = note.renote, note.cw == nil {
                #expect(layout.targets.contains { $0.action == .user(quoted.user.id) }, "the quoted user")
            }
        }
    }

    @Test func avatarsOpenInTheViewerAtFullSize() {
        let proxied = "https://misskey.io/proxy/avatar.webp?url=https%3A%2F%2Fmedia.misskey.io%2Fa.png&avatar=1"
        #expect(ProfileViewController.originalImageURL(proxied) == "https://media.misskey.io/a.png")
        #expect(ProfileViewController.originalImageURL("https://media.example/a.png") == "https://media.example/a.png")
    }
}
