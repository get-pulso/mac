import Foundation

struct FriendResponse: Decodable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id = "user_id"
        case name
        case avatar = "avatar_url"
        case rank
        case activeMinutes = "active_minutes"
    }

    let id: String
    let name: String
    let avatar: URL?
    let rank: Int
    let activeMinutes: Int?
}
