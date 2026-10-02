import Foundation

struct MisskeyClient: Sendable {
    let server: URL
    let token: String?
    let session: URLSession

    init(server: URL, token: String? = nil, session: URLSession = .misskeyAPI) {
        self.server = server
        self.token = token
        self.session = session
    }

    func url(for endpoint: String) -> URL {
        server.appending(path: "api").appending(path: endpoint)
    }

    /// The raw response body. `parameters` are JSON values (strings, numbers, booleans,
    /// arrays, dictionaries).
    func data(_ endpoint: String, _ parameters: [String: any Sendable] = [:]) async throws -> Data {
        var body: [String: Any] = parameters
        if let token { body["i"] = token }
        var request = URLRequest(url: url(for: endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    func send(_ request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch let error as URLError {
            throw MisskeyAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MisskeyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw MisskeyAPIError.server(status: http.statusCode, MisskeyAPIError.Body(data))
        }
        return data
    }

    /// Whether the server refuses the token, asked with `i`. False when it accepts it, and
    /// when it cannot say (offline, a server error).
    func refusesToken() async -> Bool {
        do {
            _ = try await data("i")
            return false
        } catch {
            return (error as? MisskeyAPIError)?.isAuthenticationFailure == true
        }
    }

    func request<Response: Decodable>(
        _ endpoint: String, _ parameters: [String: any Sendable] = [:], as type: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await data(endpoint, parameters)
        do {
            return try MisskeyJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw MisskeyAPIError.invalidResponse
        }
    }
}

enum MisskeyAPIError: Error, LocalizedError {
    struct Body: Sendable, Equatable {
        let code: String?
        let message: String?

        init(code: String?, message: String?) {
            self.code = code
            self.message = message
        }

        init(_ data: Data) {
            struct Envelope: Decodable {
                struct Error: Decodable {
                    let code: String?
                    let message: String?
                }

                let error: Error
            }
            let error = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
            self.init(code: error?.code, message: error?.message)
        }
    }

    case transport(URLError)
    case server(status: Int, Body)
    case invalidResponse

    var isAuthenticationFailure: Bool {
        if case .server(let status, let body) = self {
            return status == 401 || body.code == "AUTHENTICATION_FAILED" || body.code == "CREDENTIAL_REQUIRED"
        }
        return false
    }

    var isTransient: Bool {
        switch self {
        case .transport(let error): error.code != .appTransportSecurityRequiresSecureConnection
        case .server(let status, _): status == 429 || status >= 500
        case .invalidResponse: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .transport(let error):
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                "インターネットに接続されていません"
            case .appTransportSecurityRequiresSecureConnection:
                "ATSにより接続できませんでした。HTTPのサーバーには接続できない場合があります"
            case .timedOut:
                "サーバーが応答しませんでした"
            case .cannotFindHost, .dnsLookupFailed:
                "サーバーが見つかりませんでした"
            default:
                "サーバーに接続できませんでした"
            }
        case .server(let status, let body):
            if isAuthenticationFailure {
                "サーバーがログイン情報を受け付けませんでした"
            } else if status == 429 {
                "リクエストが多すぎます。しばらく待ってから試してください"
            } else if status >= 500 {
                "サーバーでエラーが起きました（\(status)）"
            } else if let code = body.code, code.hasSuffix("TL_DISABLED") {
                "このタイムラインは使えません"
            } else if body.code == "PERMISSION_DENIED" {
                "この操作の権限がありません。ログインし直してください"
            } else if let message = body.message {
                message
            } else {
                "サーバーエラー（\(status)）"
            }
        case .invalidResponse:
            "サーバーから予期しない応答がありました"
        }
    }
}

extension URLSession {
    static let misskeyAPI: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = ["User-Agent": HibariUserAgent.value]
        return URLSession(configuration: configuration)
    }()
}

enum HibariUserAgent {
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Hibari/\(version) (iOS)"
    }()
}
