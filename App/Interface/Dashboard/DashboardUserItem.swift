import Foundation

struct DashboardUserItem: Identifiable {
    let id: String
    let name: String
    let avatar: URL?
    let minutes: Int?
}
