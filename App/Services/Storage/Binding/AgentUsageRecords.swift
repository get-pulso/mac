import Foundation
import RealmSwift

// MARK: - Daily aggregate

struct AgentUsageDayRecord {
    // MARK: Lifecycle

    init(userID: String, key: AgentUsageDayKey, day: AgentUsageDay, sessionKeys: Set<String>) {
        self.id = Self.id(userID: userID, key: key)
        self.userID = userID
        self.key = key
        self.day = day
        self.sessionKeys = sessionKeys
        self.dirty = true
        self.revision = 0
        self.updatedAt = .now
    }

    // MARK: Internal

    let id: String
    let userID: String
    let key: AgentUsageDayKey
    var day: AgentUsageDay
    var sessionKeys: Set<String>
    var dirty: Bool
    var revision: Int
    var updatedAt: Date

    static func id(userID: String, key: AgentUsageDayKey) -> String {
        "\(userID)|\(key.date)|\(key.tool.rawValue)|\(key.model)"
    }
}

final class AgentUsageDayObject: Object {
    // MARK: Lifecycle

    convenience init(record: AgentUsageDayRecord) {
        self.init()
        self.id = record.id
        self.userID = record.userID
        self.date = record.key.date
        self.tool = record.key.tool.rawValue
        self.model = record.key.model
        self.apply(record.day)
        self.sessionKeys.append(objectsIn: record.sessionKeys)
        self.dirty = record.dirty
        self.revision = record.revision
        self.updatedAt = record.updatedAt
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted(indexed: true) var userID: String = ""
    @Persisted var date: String = ""
    @Persisted var tool: String = ""
    @Persisted var model: String = ""
    @Persisted var input: Int = 0
    @Persisted var cacheWrite: Int = 0
    @Persisted var cacheRead: Int = 0
    @Persisted var output: Int = 0
    @Persisted var reasoning: Int = 0
    @Persisted var requests: Int = 0
    @Persisted var sessions: Int = 0
    @Persisted var reportedCostCents: Int?
    @Persisted var sessionKeys: List<String>
    @Persisted var dirty: Bool = true
    @Persisted var revision: Int = 0
    @Persisted var updatedAt: Date = .now

    var day: AgentUsageDay {
        AgentUsageDay(
            input: Int64(self.input),
            cacheWrite: Int64(self.cacheWrite),
            cacheRead: Int64(self.cacheRead),
            output: Int64(self.output),
            reasoning: Int64(self.reasoning),
            requests: self.requests,
            sessions: self.sessions,
            reportedCostCents: self.reportedCostCents
        )
    }

    func apply(_ day: AgentUsageDay) {
        self.input = Int(day.input)
        self.cacheWrite = Int(day.cacheWrite)
        self.cacheRead = Int(day.cacheRead)
        self.output = Int(day.output)
        self.reasoning = Int(day.reasoning)
        self.requests = day.requests
        self.sessions = day.sessions
        self.reportedCostCents = day.reportedCostCents
    }
}

extension AgentUsageDayRecord {
    init?(object: AgentUsageDayObject) {
        guard let tool = AgentTool(rawValue: object.tool) else { return nil }
        self.id = object.id
        self.userID = object.userID
        self.key = AgentUsageDayKey(date: object.date, tool: tool, model: object.model)
        self.day = object.day
        self.sessionKeys = Set(object.sessionKeys)
        self.dirty = object.dirty
        self.revision = object.revision
        self.updatedAt = object.updatedAt
    }
}

// MARK: - Agent minute awaiting upload

struct PendingAgentActivity {
    // MARK: Lifecycle

    init(
        minuteID: String,
        startedAt: Date,
        endedAt: Date,
        tool: AgentTool,
        sessionCount: Int,
        humanActive: Bool,
        userID: String
    ) {
        self.id = "\(minuteID)|\(tool.rawValue)"
        self.minuteID = minuteID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.tool = tool
        self.sessionCount = sessionCount
        self.humanActive = humanActive
        self.userID = userID
    }

    // MARK: Internal

    let id: String
    let minuteID: String
    let startedAt: Date
    let endedAt: Date
    let tool: AgentTool
    var sessionCount: Int
    var humanActive: Bool
    var userID: String
}

final class PendingAgentActivityObject: Object {
    // MARK: Lifecycle

    convenience init(activity: PendingAgentActivity) {
        self.init()
        self.id = activity.id
        self.minuteID = activity.minuteID
        self.startedAt = activity.startedAt
        self.endedAt = activity.endedAt
        self.tool = activity.tool.rawValue
        self.sessionCount = activity.sessionCount
        self.humanActive = activity.humanActive
        self.userID = activity.userID
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted var minuteID: String = ""
    @Persisted var startedAt: Date
    @Persisted var endedAt: Date
    @Persisted var tool: String = ""
    @Persisted var sessionCount: Int = 0
    @Persisted var humanActive: Bool = false
    @Persisted(indexed: true) var userID: String = ""
}

extension PendingAgentActivity {
    init?(object: PendingAgentActivityObject) {
        guard let tool = AgentTool(rawValue: object.tool) else { return nil }
        self.id = object.id
        self.minuteID = object.minuteID
        self.startedAt = object.startedAt
        self.endedAt = object.endedAt
        self.tool = tool
        self.sessionCount = object.sessionCount
        self.humanActive = object.humanActive
        self.userID = object.userID
    }
}

// MARK: - Per-file parse progress

struct AgentParseState {
    // MARK: Lifecycle

    init(userID: String, path: String, tool: AgentTool) {
        self.id = Self.id(userID: userID, path: path)
        self.userID = userID
        self.path = path
        self.tool = tool
    }

    // MARK: Internal

    static let seenLimit = 4000

    let id: String
    let userID: String
    /// Stays on this Mac: it is only used to find the file again.
    let path: String
    let tool: AgentTool
    var offset = 0
    var seenIDs: [String] = []
    var codex = CodexCumulative()
    var lastModified: Date?
    var fileSize = 0

    var sessionKey: String { AgentUsageHash.key(for: self.path) }

    static func id(userID: String, path: String) -> String {
        "\(userID)|\(AgentUsageHash.key(for: path))"
    }
}

final class AgentParseStateObject: Object {
    // MARK: Lifecycle

    convenience init(state: AgentParseState) {
        self.init()
        self.id = state.id
        self.userID = state.userID
        self.path = state.path
        self.tool = state.tool.rawValue
        self.offset = state.offset
        self.seenIDs.append(objectsIn: state.seenIDs.suffix(AgentParseState.seenLimit))
        self.codexInput = Int(state.codex.input)
        self.codexCached = Int(state.codex.cached)
        self.codexCacheWrite = Int(state.codex.cacheWrite)
        self.codexOutput = Int(state.codex.output)
        self.codexReasoning = Int(state.codex.reasoning)
        self.codexHasCounters = state.codex.hasCounters
        self.codexModel = state.codex.model
        self.codexOriginator = state.codex.originator
        self.lastModified = state.lastModified
        self.fileSize = state.fileSize
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted(indexed: true) var userID: String = ""
    @Persisted var path: String = ""
    @Persisted var tool: String = ""
    @Persisted var offset: Int = 0
    @Persisted var seenIDs: List<String>
    @Persisted var codexInput: Int = 0
    @Persisted var codexCached: Int = 0
    @Persisted var codexCacheWrite: Int = 0
    @Persisted var codexOutput: Int = 0
    @Persisted var codexReasoning: Int = 0
    @Persisted var codexHasCounters: Bool = false
    @Persisted var codexModel: String = "unknown"
    @Persisted var codexOriginator: String = ""
    @Persisted var lastModified: Date?
    @Persisted var fileSize: Int = 0
}

extension AgentParseState {
    init?(object: AgentParseStateObject) {
        guard let tool = AgentTool(rawValue: object.tool) else { return nil }
        self.id = object.id
        self.userID = object.userID
        self.path = object.path
        self.tool = tool
        self.offset = object.offset
        self.seenIDs = Array(object.seenIDs)
        self.codex = CodexCumulative(
            input: Int64(object.codexInput),
            cached: Int64(object.codexCached),
            cacheWrite: Int64(object.codexCacheWrite),
            output: Int64(object.codexOutput),
            reasoning: Int64(object.codexReasoning),
            hasCounters: object.codexHasCounters,
            model: object.codexModel,
            originator: object.codexOriginator
        )
        self.lastModified = object.lastModified
        self.fileSize = object.fileSize
    }
}
