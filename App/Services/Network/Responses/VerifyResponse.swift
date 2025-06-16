import Foundation

struct VerifyResponse: Decodable {
    let jwt: String
    let expiresIn: Int
    let refreshToken: String
}
