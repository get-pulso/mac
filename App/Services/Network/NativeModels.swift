import Foundation

struct NativeGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let created_by: String?
    let is_creator: Bool?
}

struct NativePerson: Decodable, Identifiable {
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
    var displayName: String { self.name?.isEmpty == false ? self.name! : "Pulso user" }
    var minutes: Int { DurationLabel.wholeMinutes(self.active_minutes ?? 0) }
    var timeLabel: String { DurationLabel.minutes(self.active_minutes ?? 0) }
    var isActiveNow: Bool {
        guard let raw = last_active_at else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= -30 && age <= 120
    }
}

struct NativeContact: Decodable, Identifiable {
    let id: String
    let name: String?
    let email: String?
    let avatar_url: String?
    let is_creator: Bool?

    var displayName: String { self.name ?? "Pulso user" }
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

struct NativeInviteHistory: Decodable {
    struct Invite: Decodable, Identifiable {
        struct Group: Decodable { let name: String }

        let id: String
        let token: String
        let used: Bool?
        let usage_count: Int?
        let usage_limit: Int?
        let groups: Group?
    }

    let recentInvites: [Invite]
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

struct NativeTokens: Decodable {
    struct Balance: Decodable {
        let current: Int
        let totalEarned: Int
        let maxBalance: Int
        let canGetRescueToken: Bool
        let nextRescueTokenIn: String?
    }

    struct Transaction: Decodable, Identifiable {
        let id: String
        let amount: Int
        let reason: String
        let created_at: String?
    }

    struct Activation: Decodable, Identifiable {
        struct Person: Decodable { let name: String?; let email: String? }

        let id: String
        let users: Person?
    }

    let tokens: Balance
    let transactions: [Transaction]
    let pendingActivations: [Activation]
}

enum InviteInput: Equatable {
    case token(String)
    case friendCode(String)

    // MARK: Internal

    static func parse(_ text: String) throws -> InviteInput {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let scheme = url.scheme {
            guard ["https", "http", "pulso"].contains(scheme)
            else { throw NativeError.message("Use a Pulso invitation link or friend code.") }
            if scheme != "pulso" {
                guard url.host == "pulso.sh" || url.host == "www.pulso.sh" || url.host == AppEnvironment.baseURL.host
                else {
                    throw NativeError.message("This is not a Pulso invitation link.")
                }
            }
            let isInvite = scheme == "pulso" ? url.host == "invite" : url.path == "/invite"
            let isJoin = scheme == "pulso" ? url.host == "join" : url.path.hasPrefix("/join/")
            guard isInvite || isJoin else { throw NativeError.message("Use a Pulso invitation link or friend code.") }
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
