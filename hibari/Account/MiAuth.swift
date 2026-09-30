import Foundation

enum MiAuth {
    static let callbackScheme = "hibari"
    static let callback = "\(callbackScheme)://miauth"
    static let appName = "Hibari"

    static let permissions = [
        "read:account", "write:account",
        "read:following", "write:following",
        "read:notifications", "write:notifications",
        "write:notes",
        "read:reactions", "write:reactions",
        "write:votes",
        "read:drive", "write:drive",
        "read:favorites", "write:favorites",
        "read:mutes", "write:mutes",
        "read:blocks", "write:blocks",
        "write:report-abuse",
        "read:channels",
        "read:chat", "write:chat",
    ]

    static func authorizationURL(server: URL, session: String) -> URL {
        let url = server.appending(path: "miauth").appending(path: session)
        return url.appending(queryItems: [
            URLQueryItem(name: "name", value: appName),
            URLQueryItem(name: "permission", value: permissions.joined(separator: ",")),
            URLQueryItem(name: "callback", value: callback),
        ])
    }

    static func session(fromCallback url: URL) -> String? {
        guard url.scheme == callbackScheme, url.host() == "miauth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first { $0.name == "session" }?.value
    }
}

struct MiAuthSession: Codable, Equatable, Sendable {
    let server: URL
    let id: String
    let startedAt: Date

    var authorizationURL: URL { MiAuth.authorizationURL(server: server, session: id) }

    static func start(_ input: String, urlSession: URLSession = .misskeyAPI) async throws -> MiAuthSession {
        guard let server = ServerAddress.url(from: input) else { throw SignInError.invalidAddress }
        let info: ServerInfo
        do {
            info = try await ServerInfo.fetch(from: server, session: urlSession)
        } catch let error as MisskeyAPIError where !error.isTransient {
            throw SignInError.notMisskey
        }
        guard info.features?.miauth ?? false else { throw SignInError.miauthUnsupported }
        return MiAuthSession(server: server, id: UUID().uuidString, startedAt: Date())
    }

    /// The account, once the user has approved; nil before that. A session gives out its
    /// token once: after a successful call it answers nil too.
    func complete(urlSession: URLSession = .misskeyAPI) async throws -> (account: Account, token: String)? {
        struct Check: Decodable {
            let ok: Bool
            let token: String?
            let user: MeDetailed?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                ok = try container.decode(Bool.self, forKey: .ok)
                token = try container.decodeIfPresent(String.self, forKey: .token)
                // Only a fallback: one that does not decode must not lose the token.
                user = try? container.decodeIfPresent(MeDetailed.self, forKey: .user)
            }

            private enum CodingKeys: String, CodingKey {
                case ok, token, user
            }
        }
        let check = try await MisskeyClient(server: server, session: urlSession)
            .request("miauth/\(id)/check", as: Check.self)
        guard check.ok, let token = check.token else { return nil }
        do {
            let me = try await MisskeyClient(server: server, token: token, session: urlSession).request("i", as: MeDetailed.self)
            return (Account(server: server, me: me), token)
        } catch {
            // Asking again cannot bring the token back: signs in with the check's user,
            // completed once the timelines show (`AppRouter.refreshProfile`).
            guard let user = check.user else { throw error }
            return (Account(server: server, me: user), token)
        }
    }
}

struct PendingMiAuthStore {
    var defaults: UserDefaults = .standard
    var lifetime: TimeInterval = 30 * 60
    var key = AppSettings.usesTestAccounts ? "HibariUITestPendingMiAuth" : "HibariPendingMiAuth"

    var session: MiAuthSession? {
        get {
            guard let data = defaults.data(forKey: key),
                  let session = try? JSONDecoder().decode(MiAuthSession.self, from: data),
                  Date().timeIntervalSince(session.startedAt) < lifetime
            else { return nil }
            return session
        }
        nonmutating set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        }
    }
}

enum SignInError: Error, LocalizedError, Equatable {
    case invalidAddress
    case notMisskey
    case miauthUnsupported
    case notApproved
    case keychain

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "サーバーのアドレスを確認してください"
        case .notMisskey: "Misskey のサーバーではないようです"
        case .miauthUnsupported: "このサーバーはアプリからのログイン（MiAuth）に対応していません"
        case .notApproved: "ログインが完了しませんでした。もう一度お試しください"
        case .keychain: "ログイン情報を保存できませんでした"
        }
    }
}
