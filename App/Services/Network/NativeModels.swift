import Foundation

struct NativeGroup: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let created_by: String?
    let is_creator: Bool?
}

struct NativePerson: Decodable, Identifiable {
    // MARK: Internal

    /// Everything live is good for two minutes after it was seen, the same
    /// window the server counts a minute bucket in. A little slack backwards
    /// for a clock that is not quite ours.
    static let freshness: TimeInterval = 120
    static let clockSlack: TimeInterval = -30

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
    /// within the last few minutes. Absent for people without agent data,
    /// and for the ones who share agents without naming them.
    let agent: NativeAgentPresence?
    /// When an agent last wrote, for somebody who shares that one is
    /// working but not which. Never set beside `agent`.
    let agent_active_at: String?
    /// All recorded tools in one recent minute. Older servers omit this:
    /// their single-tool presence must never be presented as a total count.
    var agent_live: NativeAgentLive? = nil
    var public_apps_only: Bool? = nil
    /// The ranking's figure when the board is not by active time: agent
    /// minutes or tokens over the period. Absent on the default board.
    let score: Double?

    var id: String { self.user_id }
    var displayName: String { self.name?.isEmpty == false ? self.name! : "Firstlight user" }
    var minutes: Int { DurationLabel.wholeMinutes(self.active_minutes ?? 0) }
    var timeLabel: String { DurationLabel.minutes(self.active_minutes ?? 0) }
    var isActiveNow: Bool {
        self.isActive(at: Date())
    }

    func isActive(at now: Date) -> Bool {
        Self.isFresh(self.last_active_at, at: now)
    }

    func liveAgents(at now: Date) -> NativeAgentLive? {
        guard let live = self.agent_live, live.session_count > 0,
              Self.isFresh(live.observed_at, at: now)
        else { return nil }
        return live
    }

    func activeApp(at now: Date) -> NativeAppPresence? {
        guard self.isActive(at: now), let app = self.active_app,
              Self.isFresh(app.last_active_at, at: now)
        else { return nil }
        return app
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

    /// One window for every live part of a row, so presence, the app in front
    /// and the minute's agents all go stale on the same terms.
    private static func isFresh(_ raw: String?, at now: Date) -> Bool {
        guard let raw, let date = Self.timestamp(raw) else { return false }
        let age = now.timeIntervalSince(date)
        return age >= Self.clockSlack && age <= Self.freshness
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

    /// The app half of the answer, at whatever level the person shares it.
    /// `detail` carries `top` and `active`, `total` only the two numbers,
    /// `off` neither — so "keeps this private" and "was in nothing" are
    /// told apart instead of both arriving as an empty list.
    struct Apps: Decodable {
        let level: String
        let total_minutes: Double?
        let app_count: Int?
        let top: [NativeAppActivity]?
        let active: NativeAppActivity?

        var isDetailed: Bool { self.level == "detail" }
        var isOff: Bool { self.level == "off" }
        var minutes: Int { DurationLabel.wholeMinutes(self.total_minutes ?? 0) }
        var timeLabel: String { DurationLabel.minutes(self.total_minutes ?? 0) }
    }

    var public_only: Bool? = nil
    let active_minutes: Double
    let period: String
    let last_active: String?
    let intervals: [Interval]?
    let active_app: NativeAppActivity?
    let top_apps: [NativeAppActivity]?
    /// Absent from an older server, which always shared everything.
    let apps: Apps?
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

/// Which coding agent a person's Mac last saw writing, and when. Present
/// only for people who share which tool it is; `agent_active_at` carries
/// the same moment for the ones who share only that one is working.
struct NativeAgentPresence: Decodable {
    let tool: String
    let last_active_at: String
}

struct NativeAgentLive: Decodable {
    struct Tool: Decodable {
        let tool: String
        let session_count: Int
    }

    let session_count: Int
    let observed_at: String
    /// Omitted at the `total` sharing level.
    let tools: [Tool]?

    /// The figure alone, so it can turn over as a number while the words
    /// beside it stay put. One string would make "1 agent" → "2 agents" a
    /// single change and the digit would cut instead of rolling.
    var countLabel: String { "\(self.session_count)" }
    var nounLabel: String { self.session_count == 1 ? "agent now" : "agents now" }
    var label: String { "\(self.countLabel) \(self.nounLabel)" }
    var detail: String {
        guard let tools, !tools.isEmpty else { return "\(self.session_count) recorded sessions in parallel now" }
        return tools.map { "\(NativeAgentToolLabel.name($0.tool)): \($0.session_count)" }.joined(separator: " · ")
            + " sessions in parallel now"
    }
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
        /// Where the day placed among the viewer's friends. Absent on a day
        /// the person spent at zero: everyone there ties for last.
        let rank_active: Int?
        let rank_agent: Int?

        var id: String { self.date }
    }

    /// Whose clock the days below are cut in. The owner's, not the reader's:
    /// a week of bars belongs to the person whose week it was.
    let time_zone: String?

    let period: String
    let has_data: Bool
    let agent_minutes: Double?
    let agent_only_minutes: Double?
    let max_concurrency: Int?
    let tokens: Tokens?
    /// "detail", "total" or "off". At `total` everything that names a tool
    /// or a moment is absent: `by_tool`, `top_tool`, `top_model`,
    /// `active_tool`, `now`, the runs inside the days. The numbers stay.
    let shared: String?
    let by_tool: [ToolUsage]?
    let top_tool: String?
    let top_model: String?
    /// An agent is writing this minute. At `total` this is all that is said
    /// about it; at `detail` `now` says the rest.
    let agent_active_now: Bool?
    /// The live count, in the same shape and from the same server helper as
    /// the one on a leaderboard row: sessions observed in the last recorded
    /// minute, summed across the tools in it. `now.sessions` counts only the
    /// tool that wrote last, so it is not this and must not stand in for it —
    /// a profile drawing from `now` showed a smaller number than the row it
    /// was opened from. Absent from an older server.
    var agent_live: NativeAgentLive? = nil
    let days: [Day]?
    let last_agent_active_at: String?
    let active_tool: String?
    let now: Now?
    /// The same two places over the whole period.
    let rank_active: Int?
    let rank_agent: Int?
    /// How many people those places are out of, the viewer included.
    let contenders: Int?
    /// Over the last thirty days whatever the period, so a record is a record.
    let longest_run_minutes: Double?
    let longest_run_started_at: String?

    /// An older server sends no level and shares everything, which is what
    /// every account starts at anyway.
    var isDetailed: Bool { (self.shared ?? "detail") == "detail" }
    var isOff: Bool { self.shared == "off" }
}

/// Display names and glyphs for the tools a summary can name. Unknown tools
/// keep their raw name so a newer server never renders as nothing.
enum NativeAgentToolLabel {
    /// Stands for "some agent" where the person shares that one is running
    /// but not which. It is not a tool, so it has no glyph of its own and
    /// falls back to the generic mark.
    static let unnamed = "agent"

    static func name(_ tool: String) -> String {
        switch tool {
        case Self.unnamed: "An agent"
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "cursor": "Cursor"
        case "opencode": "opencode"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Asset catalog template image, or nil for a tool without a glyph.
    static func glyph(_ tool: String) -> String? {
        switch tool {
        case "claude_code": "ToolClaude"
        case "codex": "ToolCodex"
        case "cursor": "ToolCursor"
        case "opencode": "ToolOpencode"
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

/// One of the phrases a bump can carry. The list comes from the server with
/// every inbox read, so the menu in a shipped app follows the server's list
/// instead of a copy of it that was frozen at build time.
struct NativeBumpPhrase: Decodable, Identifiable, Hashable {
    let kind: String
    let label: String
    let message: String

    var id: String { self.kind }
}

/// A friend telling you that you are doing well.
///
/// `message` is composed on the server and shown as it arrives: the app never
/// writes the words, which is also why a bump can never carry anybody's own.
struct NativeBump: Decodable, Identifiable {
    struct Sender: Decodable {
        let id: String
        let name: String?
        let avatar_url: String?

        var displayName: String { self.name?.isEmpty == false ? self.name! : "A friend" }
    }

    let id: String
    let kind: String
    let message: String
    let created_at: String
    let from: Sender
}

/// What `/api/bumps` answers: everything this Mac has not shown yet, and the
/// phrases it may send.
struct NativeBumpInbox: Decodable {
    let bumps: [NativeBump]
    let phrases: [NativeBumpPhrase]
}

/// The send endpoint's answer. `next_allowed_at` is when the same friend may
/// be bumped again; the button reads it so the limit is visible rather than
/// only enforced.
struct NativeBumpSent: Decodable {
    let success: Bool?
    let next_allowed_at: String?
}

struct NativeBumpState: Codable {
    let can_send: Bool
    var last_sent_at: String?
    var last_kind: String?
    var next_allowed_at: String?
    var daily_limited: Bool?
}
