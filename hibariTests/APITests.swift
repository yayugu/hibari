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
                                                         "message": "Your app does not have the necessary permissions to use this endpoint.",
                                                         "id": "1370e5b7-d4eb-4566-bb1d-7748ee6a1838"]])
        #expect(denied?.isAuthenticationFailure == false && denied?.isMissingPermission == true)
        #expect(denied?.errorDescription == "この操作の権限がありません。ログインし直してください")
        let refused = await error(status: 403, ["error": ["code": "PERMISSION_DENIED", "message": "Permission denied.",
                                                          "id": "fc20d118-5705-4462-b6c5-2b5b43092cf3"]])
        #expect(refused?.isMissingPermission == false, "an endpoint's own refusal, not the token's permissions")

        let limited = await error(status: 429, ["error": ["code": "RATE_LIMIT_EXCEEDED"]])
        #expect(limited?.isTransient == true)
        let down = await error(status: 502, "<html>bad gateway</html>")
        #expect(down?.isTransient == true && down?.errorDescription == "サーバーでエラーが起きました（502）")
    }

    @Test func atsRejectionExplainsHTTPConnectionLimitations() async throws {
        let session = StubURLProtocol.session { _, _ in
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        do {
            _ = try await MisskeyClient(server: URL(string: "http://misskey.example")!, session: session).data("meta")
            Issue.record("Expected ATS rejection")
        } catch let error as MisskeyAPIError {
            #expect(error.errorDescription == "ATSにより接続できませんでした。HTTPのサーバーには接続できない場合があります")
            #expect(!error.isTransient)
            #expect(!error.isAuthenticationFailure)
        }
        #expect(MisskeyAPIError.transport(URLError(.timedOut)).isTransient)
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

    @Test func aRefusalForAPermissionIsTold() async throws {
        let urlSession = StubURLProtocol.session { request, _ in
            request.url?.path == "/api/channels/follow"
                ? .json(["error": ["code": "PERMISSION_DENIED", "id": "1370e5b7-d4eb-4566-bb1d-7748ee6a1838"]], status: 403)
                : .json(["error": ["code": "NO_SUCH_NOTE"]], status: 400)
        }
        let told = Locked(0)
        var client = MisskeyClient(server: TestData.server, token: "T", session: urlSession)
        client.onMissingPermission = { told.withLock { $0 += 1 } }
        _ = try? await client.data("channels/follow")
        _ = try? await client.data("notes/show")
        #expect(told.withLock { $0 } == 1)
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
