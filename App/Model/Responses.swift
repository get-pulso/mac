import Foundation

struct VerifyResponse: Decodable {
    let jwt: String
    let expiresIn: Int
    let refreshToken: String
}

struct RefreshTokenResponse: Decodable {
    let jwt: String
}

struct UserResponse: Decodable {
    struct User: Decodable {
        let id: String
        let name: String
    }

    let user: User
}
