import Foundation

struct UpdateResponse: Decodable {
    let success: Bool?
    let error: String?
    let needs_app_icon: Bool?
}
