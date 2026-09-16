import Foundation

struct NativeGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let created_by: String?
    let is_creator: Bool?
}

struct NativePerson: Decodable, Identifiable {
    // MARK: Internal

    let user_id: String
    let name: String?
    let avatar_url: String?
    let rank: Int?
    let active_minutes: Double?
    let last_active_at: String?
    let bio: String?
    let location: String?
    let website: String?
    let twitter: String?
    let telegram: String?
    let active_app: NativeAppPresence?

    var id: String { self.user_id }
    var displayName: String { self.name?.isEmpty == false ? self.name! : "Firstlight user" }
    var minutes: Int { DurationLabel.wholeMinutes(self.active_minutes ?? 0) }
    var timeLabel: String { DurationLabel.minutes(self.active_minutes ?? 0) }
    var isActiveNow: Bool {
        guard let raw = last_active_at, let date = Self.timestamp(raw) else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= -30 && age <= 120
    }

    // MARK: Private

    // Every row asks this on each render; the formatters are shared rather
    // than rebuilt per row. ISO8601DateFormatter is safe to share across threads.
    private static let fractionalTimestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeTimestamps = ISO8601DateFormatter()

    private static func timestamp(_ raw: String) -> Date? {
        self.fractionalTimestamps.date(from: raw) ?? self.wholeTimestamps.date(from: raw)
    }
}

/// One slice of a ranking, as `/api/friends/leaderboard` answers when asked
/// for a `limit`. `me` is the caller's own row whether or not it made the page.
struct NativeLeaderboardPage: Decodable {
    let items: [NativePerson]
    let total: Int
    let next_offset: Int?
    let me: NativePerson?
}

struct NativeContact: Decodable, Identifiable {
    let id: String
    let name: String?
    let email: String?
    let avatar_url: String?
    let is_creator: Bool?

    var displayName: String { self.name ?? "Firstlight user" }
}

struct NativeFriendRequest: Decodable, Identifiable {
    let id: String
    let requester: NativeContact?
    let target_user: NativeContact?
}

struct NativeRequests: Decodable {
    var incoming: [NativeFriendRequest] = []
    var outgoing: [NativeFriendRequest] = []
}

struct NativeMembers: Decodable {
    struct Group: Decodable { let id: String; let name: String; let is_user_creator: Bool }

    let members: [NativeContact]
    let group: Group
}

struct NativePersonalInvite: Decodable {
    let personalInviteCode: String
    let personalInviteLink: String
    let tokensAvailable: Int
}

struct NativeInviteLink: Decodable { let token: String; let inviteLink: String; let expiresAt: String }
struct NativeInviteInfo: Decodable {
    struct Invite: Decodable {
        let groupName: String
        let inviterName: String
        let memberCount: Int
        let isUniversal: Bool
    }

    let invite: Invite
}

struct NativeActivity: Decodable {
    struct Interval: Decodable { let start_time: String; let end_time: String }

    let active_minutes: Double
    let period: String
    let last_active: String?
    let intervals: [Interval]?
    let active_app: NativeAppActivity?
    let top_apps: [NativeAppActivity]?
}

struct NativeAppActivity: Decodable, Identifiable {
    let bundle_identifier: String
    let name: String
    let active_minutes: Double
    let last_active_at: String
    let icon_url: String?

    var id: String { self.bundle_identifier }
}

struct NativeAppPresence: Decodable {
    let bundle_identifier: String
    let name: String
    let last_active_at: String
    let icon_url: String?
}

struct NativeAck: Decodable {}

struct NativeDirectFriends: Decodable {
    let directFriendIds: [String]
}

enum InviteInput: Hashable {
    case token(String)
    case friendCode(String)

    // MARK: Internal

    static func parse(_ text: String) throws -> InviteInput {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let scheme = url.scheme {
            guard ["https", "http", "firstlight"].contains(scheme)
            else { throw NativeError.message("Use a Firstlight invitation link or friend code.") }
            if scheme != "firstlight" {
                guard url.host == "firstlight.sh" || url.host == "www.firstlight.sh" || url.host == AppEnvironment
                    .baseURL.host
                else {
                    throw NativeError.message("This is not a Firstlight invitation link.")
                }
            }
            let isInvite = scheme == "firstlight" ? url.host == "invite" : url.path == "/invite"
            let isJoin = scheme == "firstlight" ? url.host == "join" : url.path.hasPrefix("/join/")
            guard isInvite || isJoin
            else { throw NativeError.message("Use a Firstlight invitation link or friend code.") }
            if let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "token" })?.value, isInvite, !token.isEmpty, token.count <= 128
            {
                return .token(token)
            }
            if isJoin, !url.lastPathComponent.isEmpty, url.lastPathComponent != "join" {
                let code = url.lastPathComponent.uppercased()
                guard code.count <= 24, code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
                else { throw NativeError.message("The invitation code is invalid.") }
                return .friendCode(code)
            }
            throw NativeError.message("The invitation link is missing its code.")
        }
        guard !value.isEmpty, value.count <= 128, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw NativeError.message("Enter a valid invitation link or friend code.")
        }
        return value.count > 24 ? .token(value) : .friendCode(value.uppercased())
    }
}
