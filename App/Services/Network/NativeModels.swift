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
    /// The coding agent that wrote to its log most recently, when that was
    /// within the last few minutes. Absent for people without agent data.
    let agent: NativeAgentPresence?
    /// The ranking's figure when the board is not by active time: agent
    /// minutes or tokens over the period. Absent on the default board.
    let score: Double?

    var id: String { self.user_id }
    var displayName: String { self.name?.isEmpty == false ? self.name! : "Firstlight user" }
    var minutes: Int { DurationLabel.wholeMinutes(self.active_minutes ?? 0) }
    var timeLabel: String { DurationLabel.minutes(self.active_minutes ?? 0) }
    var isActiveNow: Bool {
        guard let raw = last_active_at, let date = Self.timestamp(raw) else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= -30 && age <= 120
    }

    /// An agent counts as working for two minutes after its last write, the
    /// same window as a person's own presence.
    var isAgentWorkingNow: Bool {
        guard let raw = agent?.last_active_at, let date = Self.timestamp(raw) else { return false }
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
        let inviterAvatarUrl: String?
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

/// Which coding agent a person's Mac last saw writing, and when.
struct NativeAgentPresence: Decodable {
    let tool: String
    let last_active_at: String
}

/// `/api/users/:id/agent-summary`: a person's coding agents over the period.
/// Everything past `has_data` is optional so an older server, or a person
/// with nothing to show, decodes to an empty summary instead of an error.
struct NativeAgentSummary: Decodable {
    struct Tokens: Decodable {
        let total: Double
        let input: Double?
        let cache_write: Double?
        let cache_read: Double?
        let output: Double?
        let reasoning: Double?
    }

    struct ToolUsage: Decodable, Identifiable {
        let tool: String
        let tokens_total: Double
        let requests: Int?
        let sessions: Int?
        let agent_minutes: Double?
        let top_model: String?
        let estimated_cost_micro_usd: Double?
        let reported_cost_cents: Int?

        var id: String { self.tool }
    }

    /// Consecutive minutes of one tool with gaps of at most two minutes: a
    /// shift, from the first write to the last.
    struct Run: Decodable, Identifiable {
        let tool: String
        let start_time: String
        let end_time: String
        let minutes: Double
        let peak_sessions: Int?
        let unattended_minutes: Double?

        var id: String { self.tool + self.start_time }
    }

    /// A stretch of the person's own presence at the Mac, clipped to a day.
    struct Presence: Decodable {
        let start_time: String
        let end_time: String
    }

    /// The run in progress, when the last write was moments ago.
    struct Now: Decodable {
        let tool: String
        let started_at: String
        let minutes: Double
        let sessions: Int?
    }

    /// One local day, oldest first. Empty days are present with zeros so a
    /// week always has seven bars.
    struct Day: Decodable, Identifiable {
        let date: String
        let human_minutes: Double
        let agent_minutes: Double
        let agent_only_minutes: Double
        let runs: [Run]?
        let presence: [Presence]?

        var id: String { self.date }
    }

    let period: String
    let has_data: Bool
    let agent_minutes: Double?
    let agent_only_minutes: Double?
    let max_concurrency: Int?
    let tokens: Tokens?
    let by_tool: [ToolUsage]?
    let top_tool: String?
    let top_model: String?
    /// Present only for yourself, or for a friend who chose to share it.
    let estimated_cost_micro_usd: Double?
    let cost_shared: Bool?
    let days: [Day]?
    let last_agent_active_at: String?
    let active_tool: String?
    let now: Now?
    /// Over the last thirty days whatever the period, so a record is a record.
    let longest_run_minutes: Double?
    let longest_run_started_at: String?
}

/// Display names and glyphs for the tools a summary can name. Unknown tools
/// keep their raw name so a newer server never renders as nothing.
enum NativeAgentToolLabel {
    /// The tool an app belongs to: the Claude app is Claude Code's home,
    /// ChatGPT is Codex's, Cursor is its own. When the app in front and the
    /// agent writing are the same family, saying both says one thing twice.
    static func tool(forApp bundleIdentifier: String?, name: String?) -> String? {
        let bundle = bundleIdentifier?.lowercased() ?? ""
        let title = name?.lowercased() ?? ""
        if bundle.contains("anthropic") || bundle.contains("claude") || title == "claude" { return "claude_code" }
        if bundle.contains("openai") || bundle.contains("chatgpt") || title == "chatgpt" { return "codex" }
        if bundle.contains("cursor") || title == "cursor" { return "cursor" }
        return nil
    }

    static func name(_ tool: String) -> String {
        switch tool {
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Asset catalog template image, or nil for a tool without a glyph.
    static func glyph(_ tool: String) -> String? {
        switch tool {
        case "claude_code": "ToolClaude"
        case "codex": "ToolCodex"
        case "cursor": "ToolCursor"
        default: nil
        }
    }
}

struct NativeAck: Decodable {}

/// Who a personal friend link belongs to, from `/api/join/[code]`. Public,
/// so the tray can show the face before anyone is signed in.
struct NativeJoinInfo: Decodable {
    struct Inviter: Decodable, Equatable {
        let code: String
        /// Optional: an older server answers without it, and the tray then
        /// cannot tell a friend from a stranger until the request is sent.
        let inviterId: String?
        let inviterName: String
        let inviterAvatarUrl: String?
    }

    let invite: Inviter
}

/// The answer to a friend request by code. `connected` is true when the code
/// came from the owner's own link and the two are friends at once.
struct NativeFriendRequestResult: Decodable {
    struct Target: Decodable { let id: String; let name: String? }

    let success: Bool
    let connected: Bool?
    let targetUser: Target?
}

struct NativeDirectFriends: Decodable {
    let directFriendIds: [String]
}

/// Who someone is, with nothing counted: what they wrote about themselves and
/// where to find them. Shown in the invite trays for a person who has asked to
/// be your friend, or whose code you hold, before you answer.
struct NativePersonCard: Decodable, Equatable {
    let id: String
    let name: String
    let avatar_url: String?
    let bio: String?
    let location: String?
    let website: String?
    let twitter: String?
    let telegram: String?

    /// True when the person has written nothing at all: the tray then says so
    /// rather than showing a face over empty space.
    var isBare: Bool {
        [self.bio, self.location, self.website, self.twitter, self.telegram]
            .allSatisfy { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
    }
}

enum InviteInput: Hashable {
    case token(String)
    case friendCode(String)

    // MARK: Internal

    /// What sort of invitation this is, without the text: a group link or a
    /// friend code. The tray keys on this, so typing does not change trays.
    enum Kind: Hashable { case token, friendCode }

    var kind: Kind {
        switch self {
        case .token: .token
        case .friendCode: .friendCode
        }
    }

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
