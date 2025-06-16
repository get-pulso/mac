import Foundation

struct UserResponse: Decodable {
    struct User: Decodable {
        let id: String
        let name: String
    }

    struct Group: Decodable {
        let id: String
        let name: String
    }

    let user: User
    let groups: [Group]
}
