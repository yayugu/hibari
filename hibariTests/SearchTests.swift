import CoreGraphics
import Foundation
import Testing
@testable import hibari

@Suite("Search")
struct SearchTests {
    private static func query(_ text: String) -> SearchQuery {
        SearchQuery(text, server: TestData.server)
    }

    @Test func fromNamesTheUserLikeXAndTheRestAreTheKeywords() {
        let query = Self.query("  ねこ from:alice   かわいい ")
        #expect(query.text == "ねこ from:alice   かわいい")
        #expect(query.keywords == "ねこ かわいい")
        #expect(query.from == SearchQuery.UserName(username: "alice", host: nil))
        #expect(Self.query("From:@bob@Remote.Example").from == .init(username: "bob", host: "remote.example"))
        #expect(Self.query("from:@carol@misskey.example x").from == .init(username: "carol", host: nil),
                "the account's own server needs no host")
        #expect(Self.query("from:alice from:bob").from?.username == "bob", "Misskey searches one user: the last")
        #expect(Self.query("ねこ　from:alice").keywords == "ねこ", "full-width spaces separate words too")
    }

    @Test func anEmptyFromIsAKeyword() {
        let query = Self.query("from: ねこ")
        #expect(query.from == nil && query.keywords == "from: ねこ")
        #expect(Self.query("   ").isEmpty)
        #expect(!Self.query("from:alice").isEmpty)
    }

    @Test func aLoneHashtagSearchesTheTag() {
        #expect(Self.query("#hibari_dev").hashtag == "hibari_dev")
        #expect(Self.query("＃ねこ").hashtag == "ねこ")
        #expect(Self.query("#ねこ かわいい").hashtag == nil)
        #expect(Self.query("#ねこ from:alice").hashtag == nil)
        #expect(Self.query("#").hashtag == nil)
    }

    @Test func whatTheNotesTabAsksFor() {
        #expect(Self.query("#ねこ").noteSearch(userID: nil) == .hashtag("ねこ"))
        #expect(Self.query("ねこ").noteSearch(userID: nil) == .keywords("ねこ", userID: nil))
        #expect(Self.query("ねこ from:alice").noteSearch(userID: "u1") == .keywords("ねこ", userID: "u1"))
        #expect(Self.query("from:alice").noteSearch(userID: "u1") == .user("u1"))
        #expect(Self.query("#ねこ from:alice").noteSearch(userID: "u1") == .keywords("#ねこ", userID: "u1"))
    }

    @Test func noteSearchesAskTheEndpointsForTheirPages() async throws {
        let requests = Locked<[String: [String: Any]]>([:])
        let urlSession = StubURLProtocol.session { request, body in
            requests.withLock { $0[request.url!.path()] = body }
            return .json([TestData.note(id: "n1")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        for search in [NoteSearch.keywords("ねこ", userID: "u1"), .hashtag("ねこ"), .user("u2")] {
            let notes = try await NoteSearchSource(client: client, search: search).notes(until: "n9", limit: 20)
            #expect(notes.map(\.id) == ["n1"])
        }
        let sent = requests.withLock { $0 }
        #expect(sent["/api/notes/search"]?["query"] as? String == "ねこ")
        #expect(sent["/api/notes/search"]?["userId"] as? String == "u1")
        #expect(sent["/api/notes/search-by-tag"]?["tag"] as? String == "ねこ")
        #expect(sent["/api/users/notes"]?["userId"] as? String == "u2")
        #expect(sent["/api/users/notes"]?["withReplies"] as? Bool == true)
        #expect(sent["/api/users/notes"]?["withRenotes"] as? Bool == false)
        for body in sent.values {
            #expect(body["untilId"] as? String == "n9" && body["limit"] as? Int == 20)
        }
    }

    @Test func serversThatDoNotAllowSearchingSaySo() async throws {
        let urlSession = StubURLProtocol.session { request, _ in
            if request.url!.path().hasSuffix("users/search") {
                return .json(["error": ["code": "ROLE_PERMISSION_DENIED", "message": "You are not assigned to a required role."]],
                             status: 400)
            }
            return .json(["error": ["code": "UNAVAILABLE", "message": "Search of notes unavailable."]], status: 400)
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        await #expect(throws: SearchError.notesNotAllowed) {
            try await NoteSearchSource(client: client, search: .keywords("ねこ", userID: nil)).notes(until: nil, limit: 20)
        }
        await #expect(throws: SearchError.usersNotAllowed) {
            try await UserSearchSource(client: client, query: "ねこ").users(offset: 0, limit: 20)
        }
        #expect(SearchError.notesNotAllowed.errorDescription == "このサーバーではノートの検索が許可されていません")
    }

    @Test func userSearchesPageByOffset() async throws {
        let requests = Locked<[[String: Any]]>([])
        let urlSession = StubURLProtocol.session { _, body in
            requests.withLock { $0.append(body) }
            return .json([["id": "u1", "username": "alice", "description": "ねこ"]])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let users = try await UserSearchSource(client: client, query: "ali").users(offset: 30, limit: 30)
        #expect(users.map(\.user.acct) == ["@alice"] && users.first?.description == "ねこ")
        let body = try #require(requests.withLock { $0.first })
        #expect(body["query"] as? String == "ali" && body["offset"] as? Int == 30 && body["limit"] as? Int == 30)
        #expect(body["origin"] as? String == "combined", "remote users too")
    }

    @Test func aFixedListEndsAfterItsUsers() async throws {
        let user = try MisskeyJSON.decoder().decode(
            UserDetailed.self, from: JSONSerialization.data(withJSONObject: ["id": "u1", "username": "alice"]))
        let source = FixedUserListSource(list: [user])
        #expect(try await source.users(offset: 0, limit: 30).map(\.user.id) == ["u1"])
        #expect(try await source.users(offset: 1, limit: 30).isEmpty)
    }

    @Test func trendsAreDrawnOldestFirst() async throws {
        let urlSession = StubURLProtocol.session { request, _ in
            #expect(request.url!.path() == "/api/hashtags/trend")
            return .json([["tag": "ねこ", "chart": [5, 3, 1, 0], "usersCount": 5]])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let trends = try await client.trends()
        #expect(trends == [Trend(tag: "ねこ", chart: [5, 3, 1, 0], usersCount: 5)])
        #expect(trends[0].history == [0, 1, 3, 5], "Misskey sends the latest 10 minutes first")

        let path = try #require(SparklineView.path([0, 1, 3, 5], in: CGRect(x: 0, y: 0, width: 30, height: 10)))
        #expect(path.boundingBox == CGRect(x: 0, y: 0, width: 30, height: 10), "scaled to the peak")
        #expect(SparklineView.path([4], in: CGRect(x: 0, y: 0, width: 30, height: 10)) == nil)
    }
}
