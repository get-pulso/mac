import Foundation

/// Pure value types for the AI coding agent usage layer. This file imports only
/// Foundation so the native checks can compile it standalone.

enum AgentTool: String, CaseIterable, Codable {
    case claudeCode = "claude_code"
    case codex
    case cursor

    // MARK: Internal

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var iconAsset: String {
        switch self {
        case .claudeCode: "ToolClaude"
        case .codex: "ToolCodex"
        case .cursor: "ToolCursor"
        }
    }
}

struct AgentUsageTokens: Equatable {
    var input: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0

    var total: Int64 { self.input + self.cacheWrite + self.cacheRead + self.output }
}

/// One counted unit of agent work: a Claude assistant message or a Codex
/// token-count delta. `sessionKey` is a hash of the transcript path; the path
/// itself never appears in an event.
struct AgentUsageEvent: Equatable {
    let tool: AgentTool
    let sessionKey: String
    let timestamp: Date
    let model: String
    let tokens: AgentUsageTokens
    let isRequest: Bool
}

struct AgentUsageDayKey: Hashable {
    /// Local calendar date, `yyyy-MM-dd`.
    let date: String
    let tool: AgentTool
    let model: String
}

struct AgentUsageDay: Equatable {
    var input: Int64 = 0
    var cacheWrite: Int64 = 0
    var cacheRead: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var requests = 0
    var sessions = 0
    var reportedCostCents: Int?

    var totalTokens: Int64 { self.input + self.cacheWrite + self.cacheRead + self.output }

    mutating func add(_ tokens: AgentUsageTokens) {
        self.input += tokens.input
        self.cacheWrite += tokens.cacheWrite
        self.cacheRead += tokens.cacheRead
        self.output += tokens.output
        self.reasoning += tokens.reasoning
    }
}

struct AgentMinute: Equatable {
    let minuteStart: Date
    let tool: AgentTool
    let sessionCount: Int
}

/// Buckets (tool, session, timestamp) observations into minutes; concurrency is
/// the number of distinct sessions written in that minute.
struct AgentMinuteBucketer {
    // MARK: Internal

    var minutes: [AgentMinute] {
        self.buckets
            .map { AgentMinute(minuteStart: $0.key.minuteStart, tool: $0.key.tool, sessionCount: $0.value.count) }
            .sorted { ($0.minuteStart, $0.tool.rawValue) < ($1.minuteStart, $1.tool.rawValue) }
    }

    var isEmpty: Bool { self.buckets.isEmpty }

    mutating func add(tool: AgentTool, sessionKey: String, timestamp: Date) {
        let key = Key(minuteStart: AgentUsageDates.minuteStart(of: timestamp), tool: tool)
        self.buckets[key, default: []].insert(sessionKey)
    }

    // MARK: Private

    private struct Key: Hashable {
        let minuteStart: Date
        let tool: AgentTool
    }

    private var buckets: [Key: Set<String>] = [:]
}

/// Folds events into daily aggregates and minute buckets. Dates are local to
/// the calendar passed in, so the checks can pin a timezone.
struct AgentUsageAggregator {
    // MARK: Lifecycle

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: Internal

    let calendar: Calendar
    private(set) var days: [AgentUsageDayKey: AgentUsageDay] = [:]
    private(set) var sessionKeys: [AgentUsageDayKey: Set<String>] = [:]
    private(set) var bucketer = AgentMinuteBucketer()

    var minutes: [AgentMinute] { self.bucketer.minutes }
    var isEmpty: Bool { self.days.isEmpty && self.bucketer.isEmpty }

    mutating func add(_ event: AgentUsageEvent) {
        let key = AgentUsageDayKey(
            date: AgentUsageDates.localDate(event.timestamp, calendar: self.calendar),
            tool: event.tool,
            model: event.model
        )
        var day = self.days[key] ?? AgentUsageDay()
        day.add(event.tokens)
        if event.isRequest { day.requests += 1 }
        self.sessionKeys[key, default: []].insert(event.sessionKey)
        day.sessions = self.sessionKeys[key]?.count ?? 0
        self.days[key] = day
        self.bucketer.add(tool: event.tool, sessionKey: event.sessionKey, timestamp: event.timestamp)
    }

    /// Cursor has no token log: one row per conversation and model with the
    /// request count and the cents Cursor itself reported.
    mutating func add(cursor: CursorComposerUsage) {
        let key = AgentUsageDayKey(date: cursor.date, tool: .cursor, model: cursor.model)
        var day = self.days[key] ?? AgentUsageDay()
        day.requests += cursor.requests
        day.reportedCostCents = (day.reportedCostCents ?? 0) + cursor.costCents
        self.sessionKeys[key, default: []].insert(cursor.composerKey)
        day.sessions = self.sessionKeys[key]?.count ?? 0
        self.days[key] = day
    }

    mutating func add(contentsOf events: [AgentUsageEvent]) {
        for event in events { self.add(event) }
    }
}

struct CursorComposerUsage: Equatable {
    /// Hash of the composer id.
    let composerKey: String
    /// Local date of `lastUpdatedAt ?? createdAt`.
    let date: String
    let model: String
    let requests: Int
    let costCents: Int
    let createdAt: Date
    let updatedAt: Date
}

enum AgentUsageDates {
    // MARK: Internal

    static func minuteStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    static func minuteIndex(of date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 60))
    }

    static func localDate(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// ISO 8601 with or without fractional seconds, `Z` or an offset.
    static func parseTimestamp(_ value: String) -> Date? {
        self.fractional.date(from: value) ?? self.plain.date(from: value)
    }

    static func isoString(_ date: Date) -> String {
        self.fractional.string(from: date)
    }

    // MARK: Private

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum AgentUsageHash {
    /// FNV-1a 64-bit, hex. Stable across launches and never reversible to the
    /// path it was derived from, which is all a session key needs.
    static func key(for text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
