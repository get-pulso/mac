import Foundation

struct DashboardUserItem: Identifiable {
    let id: String
    let name: String
    let avatar: URL?
    let minutes: Int?
    let updatedAt: Date?

    var isOnline: Bool {
        guard let updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) <= 120 // 2 minutes threshold
    }
}
