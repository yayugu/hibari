import Foundation

struct UserList: Decodable, Hashable, Sendable {
    let id: String
    let name: String
    var userIds: [String]

    private enum CodingKeys: String, CodingKey { case id, name, userIds }

    init(id: String, name: String, userIds: [String] = []) {
        self.id = id
        self.name = name
        self.userIds = userIds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        userIds = (try? c.decodeIfPresent([String].self, forKey: .userIds)) ?? []
    }
}

struct Antenna: Decodable, Hashable, Sendable {
    let id: String
    let name: String
}

extension MisskeyClient {
    func userLists() async throws -> [UserList] {
        try await request("users/lists/list", as: LossyArray<UserList>.self).elements
    }

    func antennas() async throws -> [Antenna] {
        try await request("antennas/list", as: LossyArray<Antenna>.self).elements
    }
}
