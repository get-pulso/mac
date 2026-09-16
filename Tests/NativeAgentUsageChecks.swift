import Foundation
import SQLite3

@main
struct NativeAgentUsageChecks {
    static func main() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        var tbilisi = Calendar(identifier: .gregorian)
        tbilisi.timeZone = TimeZone(identifier: "Asia/Tbilisi")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        // MARK: Claude: duplicates, skipped line types, truncated tail.

        let claudeData = try Data(contentsOf: fixtures.appending(path: "claude-session.jsonl"))
        var seen = Set<String>()
        let claude = ClaudeUsageParser.parse(data: claudeData, from: 0, sessionKey: "claude-1", seen: &seen)
        precondition(claude.events.count == 3, "duplicate message.id counted once: \(claude.events.count)")
        precondition(seen.count == 3)
        precondition(claude.consumedOffset < claudeData.count, "truncated line must not be consumed")
        precondition(claudeData[claude.consumedOffset - 1] == 0x0A)
        let first = claude.events[0]
        precondition(first.model == "claude-fable-5-1" && first.isRequest)
        precondition(first.tokens == AgentUsageTokens(input: 2, cacheWrite: 22404, cacheRead: 49551, output: 361, reasoning: 105))
        precondition(claude.events[2].timestamp == AgentUsageDates.parseTimestamp("2026-09-14T21:31:40Z"))

        // Re-parsing from the stored offset consumes nothing new until the line completes.
        let again = ClaudeUsageParser.parse(data: claudeData, from: claude.consumedOffset, sessionKey: "claude-1", seen: &seen)
        precondition(again.events.isEmpty && again.consumedOffset == claude.consumedOffset)
        let remainder = #"","message":{"id":"msg_fixtureD","model":"claude-fable-5-1","type":"message","role":"assistant","usage":{"input_tokens":1,"cache_creation_input_tokens":10,"cache_read_input_tokens":100,"output_tokens":20,"output_tokens_details":{"thinking_tokens":5}}}}"#
        // Replace the truncated tail with a complete line built from the same message id.
        let completed = claudeData.prefix(claude.consumedOffset)
            + Data(#"{"type":"assistant","timestamp":"2026-09-14T21:32:05.000Z","requestId":"req_fixtureD"#.utf8)
            + Data(remainder.utf8) + Data("\n".utf8)
        let finished = ClaudeUsageParser.parse(data: completed, from: claude.consumedOffset, sessionKey: "claude-1", seen: &seen)
        precondition(finished.events.count == 1 && finished.consumedOffset == completed.count)
        precondition(finished.events[0].tokens.output == 20 && seen.count == 4)
        // Same bytes again: the seen set keeps the count stable.
        let replay = ClaudeUsageParser.parse(data: completed, from: 0, sessionKey: "claude-1", seen: &seen)
        precondition(replay.events.isEmpty && replay.consumedOffset == completed.count)

        // Resuming a session copies the earlier transcript into a second file
        // beside the first, ids and all. One set across the files counts each
        // message once; a set per file would count the copied ones twice.
        var perFile = Set<String>()
        let firstFile = ClaudeUsageParser.parse(data: claudeData, from: 0, sessionKey: "claude-1", seen: &perFile)
        var secondFileOwnSet = Set<String>()
        let copiedAlone = ClaudeUsageParser.parse(
            data: claudeData,
            from: 0,
            sessionKey: "claude-2",
            seen: &secondFileOwnSet
        )
        precondition(copiedAlone.events.count == firstFile.events.count)
        let copiedShared = ClaudeUsageParser.parse(data: claudeData, from: 0, sessionKey: "claude-2", seen: &perFile)
        precondition(copiedShared.events.isEmpty)

        // MARK: Codex: cumulative deltas, null info, repeated totals, model from turn_context.

        let codexData = try Data(contentsOf: fixtures.appending(path: "codex-rollout.jsonl"))
        var state = CodexCumulative()
        let codex = CodexUsageParser.parse(data: codexData, from: 0, sessionKey: "codex-1", state: &state)
        precondition(codex.consumedOffset == codexData.count)
        precondition(codex.events.count == 2, "two token_count deltas expected, got \(codex.events.count)")
        precondition(state.originator == "Codex Desktop" && state.model == "gpt-5.6-sol" && state.hasCounters)
        precondition(codex.events[0].tokens == AgentUsageTokens(input: 600, cacheWrite: 0, cacheRead: 400, output: 50, reasoning: 20))
        precondition(codex.events[1].tokens == AgentUsageTokens(input: 1000, cacheWrite: 100, cacheRead: 1000, output: 100, reasoning: 40))
        precondition(codex.events.allSatisfy { $0.model == "gpt-5.6-sol" && $0.tool == .codex })
        // The persisted state carries across an incremental parse of the same bytes: nothing new.
        let codexAgain = CodexUsageParser.parse(data: codexData, from: codex.consumedOffset, sessionKey: "codex-1", state: &state)
        precondition(codexAgain.events.isEmpty)
        precondition(state.input == 3000 && state.cached == 1400)

        // MARK: opencode: one file per message, counted once the turn ended.

        let opencodeData = try Data(contentsOf: fixtures.appending(path: "opencode-message.json"))
        var opencodeSeen = Set<String>()
        let opencode = OpencodeUsageParser.parse(data: opencodeData, seen: &opencodeSeen)
        precondition(opencode.count == 3, "the counted message plus the minutes it ran: \(opencode.count)")
        precondition(opencode[0].tokens == AgentUsageTokens(input: 12, cacheWrite: 2200, cacheRead: 50000, output: 340, reasoning: 8))
        precondition(opencode[0].isRequest && opencode[0].model == "claude-sonnet-4-5")
        precondition(opencode.allSatisfy { $0.tool == .opencode })
        precondition(Set(opencode.map(\.sessionKey)).count == 1)
        precondition(!opencode[0].sessionKey.contains("ses_fixtureOpencode"), "the session id is hashed")
        // The rest of the span marks time without being counted again.
        precondition(opencode.dropFirst().allSatisfy { !$0.isRequest && $0.tokens == AgentUsageTokens() })
        precondition(opencode[1].timestamp == opencode[0].timestamp.addingTimeInterval(60))
        precondition(opencode[2].timestamp == opencode[0].timestamp.addingTimeInterval(120))
        // The same file again: the id kept beside it holds the count steady.
        precondition(OpencodeUsageParser.parse(data: opencodeData, seen: &opencodeSeen).isEmpty)
        precondition(opencodeSeen == ["msg_fixtureOpencodeA"])

        // A turn still running has no end and no final counters: nothing is
        // counted and nothing is remembered, so the next pass reads it again.
        var runningSeen = Set<String>()
        let running = Data(#"{"id":"msg_running","sessionID":"ses_fixtureOpencode","role":"assistant","time":{"created":1789421400000},"modelID":"claude-sonnet-4-5","tokens":{"input":1,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#.utf8)
        precondition(OpencodeUsageParser.parse(data: running, seen: &runningSeen).isEmpty && runningSeen.isEmpty)
        let settled = Data(#"{"id":"msg_running","sessionID":"ses_fixtureOpencode","role":"assistant","time":{"created":1789421400000,"completed":1789421430000},"modelID":"claude-sonnet-4-5","tokens":{"input":1,"output":7,"reasoning":0,"cache":{"read":0,"write":0}}}"#.utf8)
        let landed = OpencodeUsageParser.parse(data: settled, seen: &runningSeen)
        precondition(landed.count == 1 && landed[0].tokens.output == 7 && runningSeen == ["msg_running"])
        // What the person wrote is not work the agent did.
        let prompt = Data(#"{"id":"msg_prompt","sessionID":"ses_fixtureOpencode","role":"user","time":{"created":1789421400000}}"#.utf8)
        precondition(OpencodeUsageParser.parse(data: prompt, seen: &runningSeen).isEmpty)
        // A turn left open for hours marks the cap, not the evening.
        var longSeen = Set<String>()
        let abandoned = Data(#"{"id":"msg_long","sessionID":"ses_fixtureOpencode","role":"assistant","time":{"created":1789421400000,"completed":1789439400000},"modelID":"claude-sonnet-4-5","tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}"#.utf8)
        precondition(OpencodeUsageParser.parse(data: abandoned, seen: &longSeen).count == OpencodeUsageParser.spanLimit + 1)

        var opencodeDays = AgentUsageAggregator(calendar: tbilisi)
        opencodeDays.add(contentsOf: opencode)
        let opencodeKey = AgentUsageDayKey(date: "2026-09-15", tool: .opencode, model: "claude-sonnet-4-5")
        precondition(opencodeDays.days[opencodeKey]?.requests == 1, "the span is one request, not three")
        precondition(opencodeDays.days[opencodeKey]?.sessions == 1)
        precondition(opencodeDays.days[opencodeKey]?.totalTokens == 12 + 2200 + 50000 + 340)
        precondition(opencodeDays.minutes.count == 3 && opencodeDays.minutes.allSatisfy { $0.sessionCount == 1 })

        // MARK: Local-date attribution across midnight.

        var local = AgentUsageAggregator(calendar: tbilisi)
        local.add(contentsOf: claude.events + codex.events)
        var zulu = AgentUsageAggregator(calendar: utc)
        zulu.add(contentsOf: claude.events + codex.events)
        let claudeKeyLocal = AgentUsageDayKey(date: "2026-09-15", tool: .claudeCode, model: "claude-fable-5-1")
        let claudeKeyUTC = AgentUsageDayKey(date: "2026-09-14", tool: .claudeCode, model: "claude-fable-5-1")
        precondition(local.days[claudeKeyLocal]?.requests == 3 && local.days[claudeKeyUTC] == nil)
        precondition(zulu.days[claudeKeyUTC]?.requests == 3 && zulu.days[claudeKeyLocal] == nil)
        precondition(local.days[claudeKeyLocal]?.sessions == 1)
        precondition(local.days[claudeKeyLocal]?.cacheRead == 49551 + 70000 + 70100)
        // Codex: 23:59:30 local stays on the 14th, 00:00:10 local moves to the 15th.
        precondition(local.days[AgentUsageDayKey(date: "2026-09-14", tool: .codex, model: "gpt-5.6-sol")]?.input == 600)
        precondition(local.days[AgentUsageDayKey(date: "2026-09-15", tool: .codex, model: "gpt-5.6-sol")]?.input == 1000)
        precondition(zulu.days[AgentUsageDayKey(date: "2026-09-14", tool: .codex, model: "gpt-5.6-sol")]?.input == 1600)
        precondition(AgentUsageDates.localDate(Date(timeIntervalSince1970: 0), calendar: utc) == "1970-01-01")

        // MARK: Minute bucketing and concurrency.

        var bucketer = AgentMinuteBucketer()
        let stamp = AgentUsageDates.parseTimestamp("2026-09-14T21:31:10.500Z")!
        bucketer.add(tool: .claudeCode, sessionKey: "a", timestamp: stamp)
        bucketer.add(tool: .claudeCode, sessionKey: "b", timestamp: stamp.addingTimeInterval(20))
        bucketer.add(tool: .claudeCode, sessionKey: "a", timestamp: stamp.addingTimeInterval(30))
        bucketer.add(tool: .codex, sessionKey: "c", timestamp: stamp.addingTimeInterval(5))
        bucketer.add(tool: .claudeCode, sessionKey: "a", timestamp: stamp.addingTimeInterval(60))
        let minutes = bucketer.minutes
        precondition(minutes.count == 3, "expected 3 minutes, got \(minutes.count)")
        let minuteStart = AgentUsageDates.parseTimestamp("2026-09-14T21:31:00Z")!
        precondition(minutes[0] == AgentMinute(minuteStart: minuteStart, tool: .claudeCode, sessionCount: 2))
        precondition(minutes[1] == AgentMinute(minuteStart: minuteStart, tool: .codex, sessionCount: 1))
        precondition(minutes[2] == AgentMinute(minuteStart: minuteStart.addingTimeInterval(60), tool: .claudeCode, sessionCount: 1))
        // The aggregator's own minutes come from the fixture events: 21:30, 21:31 for Claude.
        let claudeMinutes = local.minutes.filter { $0.tool == .claudeCode }
        precondition(claudeMinutes.count == 2 && claudeMinutes.allSatisfy { $0.sessionCount == 1 })

        // MARK: Cursor: usageData parsed from a throwaway SQLite database.

        let directory = FileManager.default.temporaryDirectory.appending(path: "firstlight-agent-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appending(path: "state with space.vscdb").path
        try Self.writeCursorFixture(at: databasePath)

        let rows = CursorUsageReader.read(databasePath: databasePath, calendar: tbilisi)
        precondition(rows.count == 3, "expected 3 cursor rows, got \(rows.count)")
        let thinking = rows.first { $0.model == "claude-4.5-sonnet-thinking" && $0.requests == 29 }
        precondition(thinking != nil && thinking?.costCents == 81)
        precondition(thinking?.date == "2026-09-15", "lastUpdatedAt wins over createdAt: \(thinking?.date ?? "")")
        precondition(rows.contains { $0.model == "gpt-5" && $0.requests == 2 && $0.costCents == 0 })
        precondition(!rows.contains { $0.composerKey.contains("composerData") })
        precondition(Set(rows.map(\.composerKey)).count == 2)
        precondition(CursorUsageReader.read(databasePath: directory.appending(path: "missing.vscdb").path, calendar: utc).isEmpty)

        var cursorDays = AgentUsageAggregator(calendar: tbilisi)
        for row in rows { cursorDays.add(cursor: row) }
        let cursorKey = AgentUsageDayKey(date: "2026-09-15", tool: .cursor, model: "claude-4.5-sonnet-thinking")
        precondition(cursorDays.days[cursorKey]?.requests == 29 + 20)
        precondition(cursorDays.days[cursorKey]?.reportedCostCents == 81 + 77)
        precondition(cursorDays.days[cursorKey]?.sessions == 2)
        precondition(cursorDays.days[cursorKey]?.totalTokens == 0)

        precondition(AgentUsageHash.key(for: "/a/b") == AgentUsageHash.key(for: "/a/b"))
        precondition(AgentUsageHash.key(for: "/a/b") != AgentUsageHash.key(for: "/a/c"))
        precondition(AgentTool.allCases.map(\.rawValue) == ["claude_code", "codex", "cursor", "opencode"])
        precondition(AgentTool.opencode.transcriptExtension == "json" && AgentTool.codex.transcriptExtension == "jsonl")

        print("Native agent usage checks passed")
    }

    private static func writeCursorFixture(at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let statements = [
            "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
            """
            INSERT INTO cursorDiskKV VALUES ('composerData:11111111-aaaa', '{"composerId":"11111111-aaaa","createdAt":1789380000000,"lastUpdatedAt":1789421400000,"name":"fixture","modelConfig":{"modelName":"claude-4.5-sonnet-thinking","maxMode":true},"usageData":{"claude-4.5-sonnet-thinking":{"costInCents":81,"amount":29},"gpt-5":{"costInCents":0,"amount":2}}}')
            """,
            """
            INSERT INTO cursorDiskKV VALUES ('composerData:22222222-bbbb', '{"composerId":"22222222-bbbb","createdAt":1789421500000,"lastUpdatedAt":null,"modelConfig":{"modelName":"claude-4.5-sonnet-thinking","maxMode":true},"usageData":{"claude-4.5-sonnet-thinking":{"costInCents":77,"amount":20}}}')
            """,
            """
            INSERT INTO cursorDiskKV VALUES ('composerData:33333333-cccc', '{"composerId":"33333333-cccc","createdAt":1789421500000,"lastUpdatedAt":null,"modelConfig":{"modelName":"default","maxMode":false},"usageData":{}}')
            """,
            "INSERT INTO cursorDiskKV VALUES ('bubbleId:44444444', '{\"tokenCount\":{\"inputTokens\":0,\"outputTokens\":0}}')",
        ]
        for statement in statements {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}
