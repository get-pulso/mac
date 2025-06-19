import Foundation

struct DashboardUserItem: Identifiable {
    let id: String
    let name: String
    let avatar: URL?
    let minutes: Int?
    let lastActiveAt: Date?

    var isOnline: Bool {
        guard let lastActiveAt else { return false }
        return Date().timeIntervalSince(lastActiveAt) <= 120 // 2 minutes threshold
    }
}
