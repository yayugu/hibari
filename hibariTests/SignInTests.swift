import Foundation
import Testing
@testable import hibari

@Suite("Sign-in")
struct SignInTests {

    @Test(arguments: [
        ("misskey.io", "https://misskey.io"),
        ("  Misskey.IO/  ", "https://misskey.io"),
        ("https://misskey.io/notes/abc?x=1", "https://misskey.io"),
        ("http://localhost:8765", "http://localhost:8765"),
        ("@alice@misskey.io", "https://misskey.io"),
        ("alice@misskey.io", "https://misskey.io"),
        ("例え.jp", "https://xn--r8jz45g.jp"),
    ])
    func serverAddresses(input: String, expected: String) {
        #expect(ServerAddress.url(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://misskey.io", "https://", "foo bar"])
    func invalidServerAddresses(input: String) {
        #expect(ServerAddress.url(from: input) == nil)
    }

    @Test func authorizationURLCarriesTheSessionAppAndCallback() throws {
        let url = MiAuth.authorizationURL(server: TestData.server, session: "S-1")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "misskey.example" && components.path == "/miauth/S-1")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["name"] == "Hibari")
        #expect(query["callback"] == "hibari://miauth")
        let permissions = try #require(query["permission"]).split(separator: ",").map(String.init)
        #expect(permissions.contains("read:account") && permissions.contains("write:notes"))
        #expect(permissions.contains("write:report-abuse"), "reporting (App Review asks for it)")
    }

    @Test func callbacksAreParsed() throws {
        #expect(MiAuth.session(fromCallback: try #require(URL(string: "hibari://miauth?session=S-1"))) == "S-1")
        #expect(MiAuth.session(fromCallback: try #require(URL(string: "hibari://miauth/?session=S-1"))) == "S-1")
        #expect(MiAuth.session(fromCallback: try #require(URL(string: "other://miauth?session=S-1"))) == nil)
        #expect(MiAuth.session(fromCallback: try #require(URL(string: "hibari://elsewhere?session=S-1"))) == nil)
        #expect(MiAuth.session(fromCallback: try #require(URL(string: "hibari://miauth"))) == nil)
    }

    private func meta(miauth: Bool?, body: [String: Any] = [:]) -> StubURLProtocol.Response {
        var meta: [String: Any] = ["version": "2025.4.1", "name": "Example"]
        if body["detail"] as? Bool != false {
            meta["features"] = miauth.map { ["miauth": $0] } ?? [:]
        }
        return .json(meta)
    }

    @Test func startingChecksThatTheServerSupportsMiAuth() async throws {
        let supported = StubURLProtocol.session { request, body in
            #expect(request.url?.path == "/api/meta" && request.httpMethod == "POST")
            return self.meta(miauth: true, body: body)
        }
        let session = try await MiAuthSession.start("misskey.example", urlSession: supported)
        #expect(session.server == TestData.server && !session.id.isEmpty)

        let unsupported = StubURLProtocol.session { _, _ in self.meta(miauth: false) }
        await #expect(throws: SignInError.miauthUnsupported) {
            try await MiAuthSession.start("misskey.example", urlSession: unsupported)
        }
        let old = StubURLProtocol.session { _, _ in self.meta(miauth: nil) }
        await #expect(throws: SignInError.miauthUnsupported) {
            try await MiAuthSession.start("misskey.example", urlSession: old)
        }
        let website = StubURLProtocol.session { _, _ in .init(status: 404, body: Data("<html>".utf8)) }
        await #expect(throws: SignInError.notMisskey) {
            try await MiAuthSession.start("example.com", urlSession: website)
        }
        let notMisskeyJSON = StubURLProtocol.session { _, _ in .json(["hello": "world"]) }
        await #expect(throws: SignInError.notMisskey) {
            try await MiAuthSession.start("example.com", urlSession: notMisskeyJSON)
        }
        await #expect(throws: SignInError.invalidAddress) {
            try await MiAuthSession.start("not a server", urlSession: supported)
        }
    }

    @Test func connectionProblemsAreNotReportedAsNotMisskey() async {
        let offline = StubURLProtocol.session { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await MiAuthSession.start("misskey.example", urlSession: offline)
            Issue.record("should fail")
        } catch let error as MisskeyAPIError {
            #expect(error.isTransient)
            #expect(error.errorDescription == "インターネットに接続されていません")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// ATS refuses plain HTTP to public hosts (`URLError.appTransportSecurityRequiresSecureConnection`).
    private static func refusesPlainHTTP(_ request: URLRequest) throws {
        if request.url?.scheme == "http" { throw URLError(.appTransportSecurityRequiresSecureConnection) }
    }

    @Test func aServerTypedWithHTTPIsReachedOverHTTPSWhenATSRefusesIt() async throws {
        let refusesHTTP = StubURLProtocol.session { request, body in
            try Self.refusesPlainHTTP(request)
            return self.meta(miauth: true, body: body)
        }
        let session = try await MiAuthSession.start("http://misskey.example", urlSession: refusesHTTP)
        #expect(session.server == TestData.server)

        let neither = StubURLProtocol.session { request, _ in
            try Self.refusesPlainHTTP(request)
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: SignInError.plainHTTPBlocked) {
            try await MiAuthSession.start("http://misskey.example", urlSession: neither)
        }
    }

    @Test func aServerATSLetsThroughStaysOnHTTP() async throws {
        let local = StubURLProtocol.session { request, body in
            #expect(request.url?.scheme == "http")
            return self.meta(miauth: true, body: body)
        }
        let session = try await MiAuthSession.start("http://localhost:3000", urlSession: local)
        #expect(session.server.absoluteString == "http://localhost:3000")
    }

    @Test func completingExchangesTheSessionForATokenOnceApproved() async throws {
        let approved = Locked(false)
        let urlSession = StubURLProtocol.session { request, body in
            switch request.url?.path {
            case "/api/miauth/S-1/check":
                #expect(body["i"] == nil, "check is not authenticated")
                return approved.withLock { $0 } ? .json(["ok": true, "token": "T", "user": TestData.me]) : .json(["ok": false])
            case "/api/i":
                #expect(body["i"] as? String == "T")
                return .json(TestData.me)
            default:
                Issue.record("unexpected \(request.url!)")
                return .init(status: 404)
            }
        }
        let session = MiAuthSession(server: TestData.server, id: "S-1", startedAt: Date())
        #expect(try await session.complete(urlSession: urlSession) == nil, "not approved yet")

        approved.withLock { $0 = true }
        let (account, token) = try #require(try await session.complete(urlSession: urlSession))
        #expect(token == "T")
        #expect(account.id == "u1@misskey.example" && account.acct == "@alice@misskey.example")
        #expect(account.name == "Alice" && account.ltlAvailable == true && account.gtlAvailable == false)
    }

    @Test func completingKeepsTheTokenWhenTheProfileFails() async throws {
        var user = TestData.me
        user["policies"] = nil
        let checkUser = Locked<Any?>(user)
        let urlSession = StubURLProtocol.session { request, _ in
            switch request.url?.path {
            case "/api/miauth/S-1/check":
                var check: [String: Any] = ["ok": true, "token": "T"]
                check["user"] = checkUser.withLock { $0 }
                return .json(check)
            default:
                return .init(status: 502)
            }
        }
        let session = MiAuthSession(server: TestData.server, id: "S-1", startedAt: Date())
        let (account, token) = try #require(try await session.complete(urlSession: urlSession))
        #expect(token == "T")
        #expect(account.id == "u1@misskey.example" && account.name == "Alice")
        #expect(account.ltlAvailable == nil && account.gtlAvailable == nil)

        checkUser.withLock { $0 = ["id": "u1"] }
        await #expect(throws: MisskeyAPIError.self, "without a usable user, the error") {
            try await session.complete(urlSession: urlSession)
        }
    }

    @Test func pendingSessionsSurviveUntilTheyExpire() throws {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let store = PendingMiAuthStore(defaults: defaults, lifetime: 60)
        #expect(store.session == nil)
        let session = MiAuthSession(server: TestData.server, id: "S-1", startedAt: Date())
        store.session = session
        #expect(PendingMiAuthStore(defaults: defaults).session == session)
        store.session = MiAuthSession(server: TestData.server, id: "S-2", startedAt: Date(timeIntervalSinceNow: -61))
        #expect(store.session == nil, "expired")
        store.session = nil
        #expect(PendingMiAuthStore(defaults: defaults, lifetime: .infinity).session == nil)
    }

    private func account(_ id: String = "u1") throws -> Account {
        var me = TestData.me
        me["id"] = id
        let data = try JSONSerialization.data(withJSONObject: me)
        return Account(server: TestData.server, me: try JSONDecoder().decode(MeDetailed.self, from: data))
    }

    @MainActor
    @Test func accountsAndTokensPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let tokens = InMemoryTokenStore()
        let store = AccountStore(defaults: defaults, tokens: tokens)
        #expect(store.current == nil)

        let alice = try account("u1")
        let bob = try account("u2")
        try store.signIn(alice, token: "A")
        try store.signIn(bob, token: "B")
        #expect(store.current?.id == bob.id, "the last sign-in is current")

        let reloaded = AccountStore(defaults: defaults, tokens: tokens)
        #expect(reloaded.accounts.map(\.id) == [alice.id, bob.id])
        #expect(reloaded.current.map(reloaded.token(for:)) == "B")

        var renamed = alice
        renamed.name = "Alice 2"
        reloaded.update(renamed)
        #expect(AccountStore(defaults: defaults, tokens: tokens).accounts.first?.name == "Alice 2")

        reloaded.signOut(bob)
        #expect(tokens.token(for: bob.id) == nil)
        #expect(reloaded.current?.id == alice.id)
    }

    @MainActor
    @Test func accountsWithoutATokenAreDropped() throws {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let tokens = InMemoryTokenStore()
        let store = AccountStore(defaults: defaults, tokens: tokens)
        let alice = try account()
        try store.signIn(alice, token: "A")
        tokens.removeToken(for: alice.id)
        #expect(AccountStore(defaults: defaults, tokens: tokens).current == nil)
    }

    @MainActor
    @Test func switchingAndSigningOutPicksTheNextAccount() throws {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let store = AccountStore(defaults: defaults, tokens: InMemoryTokenStore())
        let (alice, bob, carol) = (try account("u1"), try account("u2"), try account("u3"))
        for (account, token) in [(alice, "A"), (bob, "B"), (carol, "C")] {
            try store.signIn(account, token: token)
        }
        #expect(store.others.map(\.id) == [alice.id, bob.id], "in the order they were added")

        let notified = Locked(0)
        let observer = NotificationCenter.default.addObserver(forName: AccountStore.didChange, object: store,
                                                              queue: nil) { _ in notified.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.select(alice)
        #expect(store.current?.id == alice.id && notified.withLock { $0 } == 1)
        store.select(alice)
        #expect(notified.withLock { $0 } == 1, "selecting the current one changes nothing")
        store.signOut(alice)
        #expect(store.current?.id == bob.id)
        store.select(carol)
        store.signOut(carol)
        #expect(store.current?.id == bob.id)
        store.signOut(bob)
        #expect(store.current == nil && store.accounts.isEmpty)
    }

    @MainActor
    @Test func tokensAreReadOnceAndForgottenOnSignOut() throws {
        let defaults = try #require(UserDefaults(suiteName: "hibari-tests-\(UUID().uuidString)"))
        let tokens = InMemoryTokenStore()
        let alice = try account("u1")
        let bob = try account("u2")
        try AccountStore(defaults: defaults, tokens: tokens).signIn(alice, token: "A")
        try AccountStore(defaults: defaults, tokens: tokens).signIn(bob, token: "B")

        let store = AccountStore(defaults: defaults, tokens: tokens)
        try tokens.setToken("changed elsewhere", for: alice.id)
        #expect(store.token(for: alice) == "A", "read once, when the store loads")

        store.signOut(alice)
        #expect(store.token(for: alice) == nil && tokens.token(for: alice.id) == nil)
        store.signOutAll()
        #expect(store.token(for: bob) == nil && tokens.token(for: bob.id) == nil)

        try store.signIn(alice, token: "A2")
        #expect(store.token(for: alice) == "A2")
    }

    @Test func keychainStoresTokens() throws {
        let store = KeychainTokenStore(service: "hibari-tests-\(UUID().uuidString)")
        #expect(store.token(for: "a") == nil)
        try store.setToken("one", for: "a")
        try store.setToken("two", for: "a")
        #expect(store.token(for: "a") == "two")
        store.removeToken(for: "a")
        #expect(store.token(for: "a") == nil)
    }

    @Test func timelineTabsFollowPolicies() throws {
        let alice = try account()
        let server = ServerInfo(features: .init(miauth: true, localTimeline: true, globalTimeline: true))
        #expect(TimelineKind.available(for: alice, server: server) == [.home, .featured, .local, .social])
        var unknown = alice
        unknown.ltlAvailable = nil
        unknown.gtlAvailable = nil
        #expect(TimelineKind.available(for: unknown, server: server) == TimelineKind.allCases)
        let noLocal = ServerInfo(features: .init(miauth: true, localTimeline: false, globalTimeline: true))
        #expect(TimelineKind.available(for: unknown, server: noLocal) == [.home, .featured, .global])
    }
}
