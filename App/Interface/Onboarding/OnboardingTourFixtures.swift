import AppKit

/// What the showing chapters draw: a week and a month of somebody's agents,
/// a few apps and a short list of friends. Built in the API's own shapes and
/// dated back from today, so the real card, the real sections and the real
/// labels ("Today", "Sep 9") draw them with nothing special-cased.
enum OnboardingTourFixtures {
    struct Friend: Identifiable {
        let id: String
        let name: String
        let location: String?
        let app: String?
        let agents: Int
        /// The line a person wrote about themselves: shown while they are away.
        let bio: String
        let minutes: Double

        /// The portrait shipped for this fixture, as a URL the avatar can load.
        var avatarURL: String? {
            Bundle.main.url(forResource: self.id, withExtension: "jpg", subdirectory: "OnboardingFaces")?
                .absoluteString
        }
    }

    /// The Friends tab. Austin and Yurii are real friends of the author's who
    /// use Firstlight and agreed to stand here; the others are made up, with
    /// stock portraits — and one with none, as somebody in every list is.
    static let friends: [Friend] = [
        .init(id: "austin", name: "Austin", location: "San Francisco", app: "Cursor", agents: 4, bio: "", minutes: 412),
        .init(
            id: "yurii", name: "Yurii", location: nil, app: nil, agents: 0,
            bio: "Building Fluently (YC W24)", minutes: 338
        ),
        .init(id: "alex", name: "Alex", location: "Lisbon", app: "Cursor", agents: 2, bio: "", minutes: 261),
        .init(id: "anika", name: "Anika", location: "Berlin", app: "Figma", agents: 0, bio: "", minutes: 204),
        .init(
            id: "dan", name: "Dan", location: nil, app: nil, agents: 0,
            bio: "Building a sauna app, slowly", minutes: 72
        ),
    ]

    /// The global board: friends and strangers alike, and you among them.
    static let board: [Friend] = [
        .init(id: "austin", name: "Austin", location: "San Francisco", app: "Cursor", agents: 4, bio: "", minutes: 412),
        .init(
            id: "yurii", name: "Yurii", location: nil, app: nil, agents: 0,
            bio: "Building Fluently (YC W24)", minutes: 338
        ),
        .init(id: "alex", name: "Alex", location: "Lisbon", app: "Cursor", agents: 2, bio: "", minutes: 261),
        .init(
            id: "mia", name: "Mia", location: "Tokyo", app: nil, agents: 0,
            bio: "Shipping a calendar app", minutes: 188
        ),
    ]

    /// Your own minutes, which put you third on the board above.
    static let ownMinutes: Double = 305

    /// Apps for the profile, taken from what this Mac really has, so every
    /// row gets its real icon: a fixture app that is not installed would be
    /// a name beside an empty square.
    static let apps: [NativeAppActivity] = {
        let candidates: [(String, String)] = [
            ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "Code"),
            ("com.apple.dt.Xcode", "Xcode"), ("com.figma.Desktop", "Figma"), ("dev.zed.Zed", "Zed"),
            ("com.linear", "Linear"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.apple.Terminal", "Terminal"),
            ("com.apple.Safari", "Safari"), ("com.apple.Notes", "Notes"), ("com.apple.finder", "Finder"),
        ]
        let installed = candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }
        return zip(installed.prefix(3), [680.0, 365, 220]).map { app, minutes in
            NativeAppActivity(
                bundle_identifier: app.0, name: app.1, active_minutes: minutes, last_active_at: "", icon_url: nil
            )
        }
    }()

    /// The app in front, in the line under the name: the first of the above.
    static var frontApp: String { self.apps.first?.name ?? "Safari" }

    static let live = NativeAgentLive(
        session_count: 3, observed_at: "",
        tools: [.init(tool: "claude_code", session_count: 2), .init(tool: "codex", session_count: 1)]
    )

    /// The week the card is about.
    static let week: NativeAgentSummary? = summary(days: 7, period: "7d")
    /// The thirty days the cost, the streak and the records are about.
    static let month: NativeAgentSummary? = summary(days: 30, period: "30d")

    /// The week as the card's chart cuts it: a column a day. What the pointer
    /// names when it is over a column, so a pointer of ours can name one too.
    static let weekBuckets: [AgentBucket] = (week?.days ?? []).enumerated().map { index, day in
        var tools: [String: Double] = [:]
        for run in day.runs ?? [] { tools[run.tool, default: 0] += run.minutes }
        return AgentBucket(
            id: day.date, label: NativeAgentTime.dayLabel(day.date),
            tick: NativeAgentTime.weekdayLetter(day.date), hoverTick: NativeAgentTime.shortDate(day.date),
            agent: day.agent_minutes, human: day.human_minutes, tools: tools, dayIndex: index,
            rankHuman: day.rank_active, rankAgent: day.rank_agent
        )
    }

    /// The person's own minutes over the week, beside the agents' on the card.
    static var weekOwnMinutes: Double { (self.week?.days ?? []).reduce(0) { $0 + $1.human_minutes } }

    // MARK: Private

    /// Agent hours by day, oldest first, ending today: two quiet weekends, a
    /// gap that ends a streak, and a heavy day to hold the records.
    private static let agentHours: [Double] = [
        3, 5, 0, 6, 8, 4, 0, 0, 7, 9, 5, 6, 8, 0, 0, 4, 6, 9, 10, 7, 3, 9.2, 5, 7, 3, 10, 8, 4, 6, 5,
    ]
    private static let humanHours: [Double] = [
        5, 6, 1, 6, 7, 5, 0, 2, 6, 7, 6, 5, 7, 1, 0, 5, 6, 7, 8, 6, 4, 7, 5, 6, 4, 7, 6, 1, 3, 3.7,
    ]

    private static func summary(days count: Int, period: String) -> NativeAgentSummary? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let stamp = ISO8601DateFormatter()

        let agent = Array(self.agentHours.suffix(count))
        let human = Array(self.humanHours.suffix(count))
        var days: [[String: Any]] = []
        var claudeMinutes = 0.0, codexMinutes = 0.0, tokens = 0.0, cost = 0.0
        for index in 0 ..< count {
            guard let date = calendar.date(byAdding: .day, value: index - (count - 1), to: today) else { continue }
            let minutes = agent[index] * 60
            // Two shifts on a working day: a long one in the morning with
            // Claude Code, a shorter one after lunch with Codex.
            var runs: [[String: Any]] = []
            if minutes > 0 {
                let first = minutes * 0.68, second = minutes - first
                let morning = date.addingTimeInterval(9.5 * 3600)
                let afternoon = date.addingTimeInterval(15 * 3600)
                runs = [
                    [
                        "tool": "claude_code", "start_time": stamp.string(from: morning),
                        "end_time": stamp.string(from: morning.addingTimeInterval(first * 60 / 1.6)),
                        "minutes": first, "peak_sessions": agent[index] >= 9 ? 6 : 2,
                    ],
                    [
                        "tool": "codex", "start_time": stamp.string(from: afternoon),
                        "end_time": stamp.string(from: afternoon.addingTimeInterval(second * 60)),
                        "minutes": second, "peak_sessions": 1,
                    ],
                ]
                claudeMinutes += first
                codexMinutes += second
            }
            let dayTokens = minutes * 42_000
            let dayCost = minutes * 0.024
            tokens += dayTokens
            cost += dayCost
            days.append([
                "date": dayFormatter.string(from: date),
                "human_minutes": human[index] * 60,
                "agent_minutes": minutes,
                "agent_only_minutes": max(minutes - human[index] * 60, 0),
                "runs": runs,
                "tokens_total": dayTokens,
                "cost_usd": dayCost,
                "rank_active": 4,
                "rank_agent": 2,
            ])
        }
        let body: [String: Any] = [
            "period": period,
            "has_data": true,
            "agent_minutes": claudeMinutes + codexMinutes,
            "agent_only_minutes": 0,
            "max_concurrency": 6,
            "tokens": ["total": tokens],
            "shared": "detail",
            "by_tool": [
                [
                    "tool": "claude_code", "tokens_total": tokens * 0.7, "sessions": count * 2,
                    "agent_minutes": claudeMinutes, "top_model": "claude-opus-5",
                ],
                [
                    "tool": "codex", "tokens_total": tokens * 0.3, "sessions": count,
                    "agent_minutes": codexMinutes, "top_model": "gpt-5-codex",
                ],
            ],
            "by_model": [
                ["tool": "claude_code", "model": "claude-opus-5", "tokens_total": tokens * 0.62, "cost_usd": cost * 0.72],
                ["tool": "codex", "model": "gpt-5-codex", "tokens_total": tokens * 0.3, "cost_usd": cost * 0.24],
                [
                    "tool": "claude_code", "model": "claude-haiku-4-5", "tokens_total": tokens * 0.08,
                    "cost_usd": cost * 0.04,
                ],
            ],
            "cost_usd": cost,
            "days": days,
            "rank_active": 4,
            "rank_agent": 2,
            "contenders": 9,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return try? JSONDecoder().decode(NativeAgentSummary.self, from: data)
    }
}
