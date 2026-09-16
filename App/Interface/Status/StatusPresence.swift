import Foundation

struct StatusPresenceCandidate: Equatable {
    // MARK: Lifecycle

    init?(id: String, avatarURL: String?, lastActiveAt: String?) {
        guard let avatarURL,
              let avatarURL = URL(string: avatarURL),
              let lastActiveAt,
              let lastActiveDate = Self.parse(lastActiveAt)
        else { return nil }

        self.id = id
        self.avatarURL = avatarURL
        self.lastActiveAt = lastActiveDate
    }

    // MARK: Internal

    let id: String
    let avatarURL: URL
    let lastActiveAt: Date

    // MARK: Private

    private static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum StatusPresenceSelection {
    static let onlineWindow: TimeInterval = 120
    static let futureTolerance: TimeInterval = 30

    static func avatarURLs(
        from candidates: [StatusPresenceCandidate],
        excluding currentUserID: String?,
        now: Date = .now,
        limit: Int = 3
    ) -> [URL] {
        candidates
            .filter { $0.id != currentUserID }
            .filter {
                let age = now.timeIntervalSince($0.lastActiveAt)
                return age >= -Self.futureTolerance && age <= Self.onlineWindow
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(max(0, limit))
            .map(\.avatarURL)
    }
}
