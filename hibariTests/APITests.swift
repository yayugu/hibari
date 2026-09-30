import Foundation
import Testing
@testable import hibari

@Suite("API")
struct APITests {
    @Test func requestsArePostsWithTheTokenInTheBody() async throws {
        let urlSession = StubURLProtocol.session { request, body in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == "https://misskey.example/api/notes/local-timeline")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(body["i"] as? String == "T")
            #expect(body["limit"] as? Int == 20)
            #expect(body["untilId"] as? String == "n9")
            return .json([TestData.note(id: "n10"), TestData.note(id: "n11")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let source = APITimelineSource(client: client, endpoint: TimelineKind.local.endpoint)
        let notes = try await source.notes(until: "n9", limit: 20)
        #expect(notes.map(\.id) == ["n10", "n11"])
    }

    @Test func pagesAfterANoteAreOldestFirst() async throws {
        let urlSession = StubURLProtocol.session { _, body in
            #expect(body["sinceId"] as? String == "n1" && body["untilId"] == nil)
            return .json([TestData.note(id: "n3"), TestData.note(id: "n2")])
        }
        let client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        let page = try await APITimelineSource(client: client, endpoint: "notes/timeline").page(after: "n1", limit: 20)
        #expect(page?.entries.map(\.id) == ["n2", "n3"] && page?.cursor == "n3")
        let featured = APITimelineSource(client: client, endpoint: TimelineKind.featured.endpoint)
        #expect(try await featured.page(after: "n1", limit: 20) == nil)
    }

    @Test func sourcesSendTheirOwnParameters() async throws {
        let urlSession = StubURLProtocol.session { request, body in
            #expect(request.url?.path == "/api/notes/mentions")
            #expect(body["visibility"] as? String == "specified")
            #expect(body["untilId"] != nil || body["sinceId"] != nil)
            return .json([])
        }
        let source = APITimelineSource(client: MisskeyClient(server: TestData.server, token: "T", session: urlSession),
                                       endpoint: "notes/mentions", parameters: ["visibility": "specified"])
        #expect(try await source.notes(until: "n9", limit: 10).isEmpty)
        #expect(try await source.notes(after: "n1", limit: 10)?.isEmpty == true)
    }

    @Test func theFirstPageHasNoCursor() async throws {
        let urlSession = StubURLProtocol.session { _, body in
            #expect(body["untilId"] == nil)
            return .json([])
        }
        let source = APITimelineSource(client: MisskeyClient(server: TestData.server, token: "T", session: urlSession),
                                       endpoint: "notes/timeline")
        #expect(try await source.notes(until: nil, limit: 10).isEmpty)
    }

    @Test func errorsCarryMisskeysCode() async {
        func error(status: Int, _ body: Any) async -> MisskeyAPIError? {
            let response = StubURLProtocol.Response.json(body, status: status)
            let urlSession = StubURLProtocol.session { _, _ in response }
            do {
                _ = try await MisskeyClient(server: TestData.server, token: "T", session: urlSession).data("i")
                return nil
            } catch {
                return error as? MisskeyAPIError
            }
        }
        let expired = await error(status: 401, ["error": ["code": "AUTHENTICATION_FAILED", "message": "Authentication failed."]])
        #expect(expired?.isAuthenticationFailure == true && expired?.isTransient == false)
        #expect(expired?.errorDescription == "サーバーがログイン情報を受け付けませんでした")

        let disabled = await error(status: 400, ["error": ["code": "LTL_DISABLED", "message": "Local timeline has been disabled."]])
        #expect(disabled?.isAuthenticationFailure == false && disabled?.isTransient == false)
        #expect(disabled?.errorDescription == "このタイムラインは使えません")

        let denied = await error(status: 403, ["error": ["code": "PERMISSION_DENIED",
                                                         "message": "Your app does not have the necessary permissions to use this endpoint."]])
        #expect(denied?.isAuthenticationFailure == false)
        #expect(denied?.errorDescription == "この操作の権限がありません。ログインし直してください")

        let limited = await error(status: 429, ["error": ["code": "RATE_LIMIT_EXCEEDED"]])
        #expect(limited?.isTransient == true)
        let down = await error(status: 502, "<html>bad gateway</html>")
        #expect(down?.isTransient == true && down?.errorDescription == "サーバーでエラーが起きました（502）")
    }

    @Test func onlyARefusalOfITellsTheTokenIsRefused() async {
        func refuses(_ response: StubURLProtocol.Response?) async -> Bool {
            let urlSession = StubURLProtocol.session { request, body in
                #expect(request.url?.path == "/api/i" && body["i"] as? String == "T")
                guard let response else { throw URLError(.notConnectedToInternet) }
                return response
            }
            return await MisskeyClient(server: TestData.server, token: "T", session: urlSession).refusesToken()
        }
        #expect(await refuses(.json(["error": ["code": "AUTHENTICATION_FAILED"]], status: 401)))
        #expect(await !refuses(.json(TestData.me)))
        #expect(await !refuses(.json(["error": ["code": "INTERNAL_ERROR"]], status: 500)))
        #expect(await !refuses(nil), "offline")
    }

    @Test func undecodableResponsesAreInvalid() async {
        let urlSession = StubURLProtocol.session { _, _ in .init(status: 200, body: Data("<html>".utf8)) }
        await #expect(throws: MisskeyAPIError.self) {
            try await MisskeyClient(server: TestData.server, session: urlSession).request("i", as: MeDetailed.self)
        }
    }

    @Test func serverResourcesComeFromMetaAndEmojis() async throws {
        let urlSession = StubURLProtocol.session { request, _ in
            switch request.url?.path {
            case "/api/meta":
                return .json(["version": "2025.4.1", "mediaProxy": "https://proxy.example", "features": ["miauth": true]])
            case "/api/emojis":
                return .json(["emojis": [
                    ["name": "blobcat", "url": "https://misskey.example/emoji/blobcat.png", "aliases": [String](), "category": NSNull()],
                    ["name": "broken"],
                ]])
            default:
                return .init(status: 404)
            }
        }
        let cache = ServerResourceCache(directory: TestData.temporaryDirectory())
        #expect(cache.load(for: TestData.server) == nil)
        let fetched = try await cache.refresh(for: TestData.server, session: urlSession)
        #expect(fetched.emojis == ["blobcat": "https://misskey.example/emoji/blobcat.png"], "undecodable emojis are skipped")
        #expect(fetched.info.mediaProxy == "https://proxy.example")

        let saved = try #require(cache.load(for: TestData.server))
        #expect(saved.emojis == fetched.emojis && saved.info == fetched.info)
        let resolver = saved.emojiResolver()
        #expect(resolver.url(forName: "blobcat", in: EmojiContext(host: nil, remoteEmojis: [:]))
            == "https://misskey.example/emoji/blobcat.png")
        #expect(resolver.url(forName: "x", in: EmojiContext(host: "remote.example", remoteEmojis: ["x": "https://r/x.png"]))
            == "https://proxy.example/image.webp?url=https%3A%2F%2Fr%2Fx.png&emoji=1")
    }
}
