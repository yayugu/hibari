import Foundation

struct APITimelineSource: NoteTimelineSource {
    let client: MisskeyClient
    let endpoint: String
    /// Sent with every page (the direct notes: `notes/mentions` with `visibility`).
    var parameters: [String: any Sendable] = [:]

    func notes(until untilID: String?, limit: Int) async throws -> [Note] {
        var parameters = parameters
        parameters["limit"] = limit
        if let untilID { parameters["untilId"] = untilID }
        let data = try await client.data(endpoint, parameters)
        return try MisskeyJSON.decodeNotes(from: data)
    }

    /// Misskey pages ascending with only `sinceId`. `notes/featured` takes no `sinceId`.
    func notes(after sinceID: String, limit: Int) async throws -> [Note]? {
        guard endpoint != TimelineKind.featured.endpoint else { return nil }
        var parameters = parameters
        parameters["limit"] = limit
        parameters["sinceId"] = sinceID
        let data = try await client.data(endpoint, parameters)
        return try MisskeyJSON.decodeNotes(from: data)
    }
}

enum TimelineKind: String, CaseIterable, Sendable {
    case home
    case featured
    case local
    case social
    case global

    var title: String {
        switch self {
        case .home: "ホーム"
        case .featured: "ハイライト"
        case .local: "ローカル"
        case .social: "ソーシャル"
        case .global: "グローバル"
        }
    }

    var endpoint: String {
        switch self {
        case .home: "notes/timeline"
        case .featured: "notes/featured"
        case .local: "notes/local-timeline"
        case .social: "notes/hybrid-timeline"
        case .global: "notes/global-timeline"
        }
    }

    /// Hides the tabs the server or the user's role turned off. Unknown means available.
    static func available(for account: Account, server: ServerInfo) -> [TimelineKind] {
        let local = (account.ltlAvailable ?? true) && (server.features?.localTimeline ?? true)
        let global = (account.gtlAvailable ?? true) && (server.features?.globalTimeline ?? true)
        return allCases.filter { kind in
            switch kind {
            case .home, .featured: true
            case .local, .social: local
            case .global: global
            }
        }
    }
}
