import Foundation

extension MisskeyClient {
    func user(id userID: String) async throws -> UserDetailed {
        try await request("users/show", ["userId": userID], as: UserDetailed.self)
    }

    /// `users/show` by name, as in a mention. `host` nil is a user of the account's server;
    /// Misskey fetches remote users it does not know yet.
    func user(username: String, host: String?) async throws -> UserDetailed {
        var parameters: [String: any Sendable] = ["username": username]
        if let host { parameters["host"] = host }
        return try await request("users/show", parameters, as: UserDetailed.self)
    }

    /// `users/show` by ids: the ones Misskey knows, in no particular order.
    func users(ids userIDs: [String]) async throws -> [User] {
        try await request("users/show", ["userIds": userIDs], as: LossyArray<User>.self).elements
    }

    /// `following/create`. A locked account gets a follow request instead.
    func follow(_ userID: String) async throws {
        _ = try await data("following/create", ["userId": userID])
    }

    func unfollow(_ userID: String) async throws {
        _ = try await data("following/delete", ["userId": userID])
    }

    func cancelFollowRequest(to userID: String) async throws {
        _ = try await data("following/requests/cancel", ["userId": userID])
    }

    /// Whether the user's replies to others show in the home timeline (`following/update`).
    func setShowsReplies(_ shows: Bool, of userID: String) async throws {
        _ = try await data("following/update", ["userId": userID, "withReplies": shows])
    }

    /// `mute/create` with no expiry.
    func mute(_ userID: String) async throws {
        _ = try await data("mute/create", ["userId": userID])
    }

    func unmute(_ userID: String) async throws {
        _ = try await data("mute/delete", ["userId": userID])
    }

    func muteRenotes(of userID: String) async throws {
        _ = try await data("renote-mute/create", ["userId": userID])
    }

    func unmuteRenotes(of userID: String) async throws {
        _ = try await data("renote-mute/delete", ["userId": userID])
    }

    func block(_ userID: String) async throws {
        _ = try await data("blocking/create", ["userId": userID])
    }

    func unblock(_ userID: String) async throws {
        _ = try await data("blocking/delete", ["userId": userID])
    }

    /// `users/report-abuse`: to the server's moderators, who can pass it on to a remote
    /// user's server. The comment is 1 to `maxReportLength` characters.
    func report(_ userID: String, comment: String) async throws {
        _ = try await data("users/report-abuse", ["userId": userID, "comment": comment])
    }

    static let maxReportLength = 2048
}

enum ProfileTab: Int, CaseIterable, Sendable {
    case highlights
    /// Without replies and renotes.
    case notes
    /// With replies and renotes.
    case all
    /// Notes with files ("ファイル付き" on the web).
    case media

    var title: String {
        switch self {
        case .highlights: "ハイライト"
        case .notes: "ノート"
        case .all: "すべて"
        case .media: "メディア"
        }
    }

    var id: String {
        switch self {
        case .highlights: "highlights"
        case .notes: "notes"
        case .all: "all"
        case .media: "media"
        }
    }
}

struct UserNotesSource: NoteTimelineSource {
    let client: MisskeyClient
    let userID: String
    let tab: ProfileTab

    func notes(until untilID: String?, limit: Int) async throws -> [Note] {
        var parameters: [String: any Sendable] = ["userId": userID, "limit": limit]
        if let untilID { parameters["untilId"] = untilID }
        let endpoint: String
        switch tab {
        case .highlights:
            endpoint = "users/featured-notes"
        case .notes, .all, .media:
            endpoint = "users/notes"
            parameters["withReplies"] = tab == .all
            parameters["withRenotes"] = tab == .all
            parameters["withFiles"] = tab == .media
            parameters["withChannelNotes"] = true
        }
        return try MisskeyJSON.decodeNotes(from: await client.data(endpoint, parameters))
    }
}
