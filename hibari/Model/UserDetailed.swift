import Foundation

struct UserDetailed: Decodable, Sendable {
    struct Field: Decodable, Sendable, Equatable {
        let name: String
        let value: String
    }

    /// How the signed-in account relates to the user. Misskey leaves these out for the
    /// account itself (`isKnown` is false then).
    struct Relation: Sendable, Equatable {
        var isFollowing = false
        var isFollowed = false
        var hasPendingFollowRequestFromYou = false
        var isBlocking = false
        var isBlocked = false
        var isMuted = false
        var isRenoteMuted = false
        /// Replies to others show in the home timeline (a setting of the follow).
        var withReplies = false
        var isKnown = false
    }

    let user: User
    let bannerUrl: String?
    let bannerBlurhash: String?
    let description: String?
    let location: String?
    /// "YYYY-MM-DD".
    let birthday: String?
    let createdAt: Date?
    let fields: [Field]
    /// Field values the server found a link back to the profile at (`rel="me"`).
    let verifiedLinks: [String]
    /// nil when the user hides them from the account.
    let followingCount: Int?
    let followersCount: Int?
    let notesCount: Int?
    let isLocked: Bool
    let url: URL?
    var relation: Relation

    private enum CodingKeys: String, CodingKey {
        case bannerUrl, bannerBlurhash, description, location, birthday, createdAt, fields, verifiedLinks
        case followingCount, followersCount, notesCount, isLocked, url
        case isFollowing, isFollowed, hasPendingFollowRequestFromYou, isBlocking, isBlocked, isMuted, isRenoteMuted
        case withReplies
    }

    init(from decoder: any Decoder) throws {
        user = try User(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            (try? c.decodeIfPresent(String.self, forKey: key)).flatMap { $0?.isEmpty == false ? $0 : nil }
        }
        func bool(_ key: CodingKeys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: key) }
        func int(_ key: CodingKeys) -> Int? { try? c.decodeIfPresent(Int.self, forKey: key) }
        bannerUrl = string(.bannerUrl)
        bannerBlurhash = string(.bannerBlurhash)
        description = string(.description)
        location = string(.location)
        birthday = string(.birthday)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        fields = ((try? c.decodeIfPresent(LossyArray<Field>.self, forKey: .fields))?.elements ?? [])
            .filter { !$0.name.isEmpty || !$0.value.isEmpty }
        verifiedLinks = (try? c.decodeIfPresent([String].self, forKey: .verifiedLinks)) ?? []
        followingCount = int(.followingCount)
        followersCount = int(.followersCount)
        notesCount = int(.notesCount)
        isLocked = bool(.isLocked) ?? false
        url = string(.url).flatMap(URL.init(string:)).flatMap {
            ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil
        }
        let isFollowing = bool(.isFollowing)
        relation = Relation(
            isFollowing: isFollowing ?? false,
            isFollowed: bool(.isFollowed) ?? false,
            hasPendingFollowRequestFromYou: bool(.hasPendingFollowRequestFromYou) ?? false,
            isBlocking: bool(.isBlocking) ?? false,
            isBlocked: bool(.isBlocked) ?? false,
            isMuted: bool(.isMuted) ?? false,
            isRenoteMuted: bool(.isRenoteMuted) ?? false,
            withReplies: bool(.withReplies) ?? false,
            isKnown: isFollowing != nil)
    }

    /// "1998年1月2日" from `birthday`, nil if it is not a date.
    var formattedBirthday: String? {
        guard let birthday else { return nil }
        let parts = birthday.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return "\(parts[0])年\(parts[1])月\(parts[2])日"
    }
}

enum FollowState: Equatable, Sendable {
    case follow
    case followBack
    case following
    case requested
    case blocking

    init(_ relation: UserDetailed.Relation) {
        if relation.isBlocking {
            self = .blocking
        } else if relation.isFollowing {
            self = .following
        } else if relation.hasPendingFollowRequestFromYou {
            self = .requested
        } else if relation.isFollowed {
            self = .followBack
        } else {
            self = .follow
        }
    }

    var title: String {
        switch self {
        case .follow: "フォロー"
        case .followBack: "フォローバック"
        case .following: "フォロー中"
        case .requested: "承認待ち"
        case .blocking: "ブロック中"
        }
    }
}
