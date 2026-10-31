import Foundation

extension MisskeyClient {
    /// All of them, the newest channel first: Misskey sends 100 at most a time, paged by
    /// the channel's id.
    func followedChannels() async throws -> [Channel] {
        var channels: [Channel] = []
        while true {
            var parameters: [String: any Sendable] = ["limit": 100]
            if let last = channels.last { parameters["untilId"] = last.id }
            let page = try await request("channels/followed", parameters, as: LossyArray<Channel>.self).elements
            channels += page
            if page.count < 100 { return channels }
        }
    }

    /// All of them at once.
    func favoriteChannels() async throws -> [Channel] {
        try await request("channels/my-favorites", as: LossyArray<Channel>.self).elements
    }

    /// The channels the account can have tabs of: the favorite and followed ones, the
    /// favorites first, each once.
    func tabChannels() async throws -> [Channel] {
        async let favorites = favoriteChannels()
        async let followed = followedChannels()
        var seen: Set<String> = []
        return try await (favorites + followed).filter { seen.insert($0.id).inserted }
    }
}
