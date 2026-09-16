import Foundation

/// Incremental line readers for the Claude Code and Codex transcripts. Both
/// consume only complete lines: a trailing partial line (a file mid-write) is
/// left for the next pass, and the returned offset points at its first byte.
/// Only counters, timestamps, model names and originators are read; prompt and
/// tool text is never decoded into anything that leaves the parser.

enum AgentUsageLines {
    /// Calls `body` with every complete line in `data` from `offset`, and
    /// returns the offset just past the last newline seen.
    static func forEachCompleteLine(in data: Data, from offset: Int, _ body: (Data) -> Void) -> Int {
        let start = min(max(offset, 0), data.count)
        guard start < data.count else { return data.count }
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.baseAddress else { return start }
            var consumed = start
            var lineStart = start
            while lineStart < buffer.count,
                  let found = memchr(base + lineStart, 0x0A, buffer.count - lineStart)
            {
                let newline = UnsafeRawPointer(found) - base
                if newline > lineStart {
                    body(Data(bytes: base + lineStart, count: newline - lineStart))
                }
                consumed = newline + 1
                lineStart = consumed
            }
            return consumed
        }
    }

    static func json(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line), options: [])) as? [String: Any]
    }

    static func int64(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber: number.int64Value
        case let text as String: Int64(text) ?? 0
        default: 0
        }
    }

    static func int(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text) ?? 0
        default: 0
        }
    }
}

enum ClaudeUsageParser {
    // MARK: Internal

    /// `seen` holds `"<message.id>|<requestId>"` keys already counted: the same
    /// message is written on several consecutive lines while streaming.
    static func parse(
        data: Data,
        from offset: Int,
        sessionKey: String,
        seen: inout Set<String>
    ) -> (events: [AgentUsageEvent], consumedOffset: Int) {
        var events: [AgentUsageEvent] = []
        var seenKeys = seen
        let consumed = AgentUsageLines.forEachCompleteLine(in: data, from: offset) { line in
            guard line.range(of: self.assistantMarker) != nil,
                  let object = AgentUsageLines.json(line),
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { return }
            let messageID = (message["id"] as? String) ?? ""
            let requestID = (object["requestId"] as? String) ?? ""
            let key = messageID.isEmpty && requestID.isEmpty ? UUID().uuidString : "\(messageID)|\(requestID)"
            guard !seenKeys.contains(key) else { return }
            guard let stamp = object["timestamp"] as? String,
                  let timestamp = AgentUsageDates.parseTimestamp(stamp) else { return }
            seenKeys.insert(key)
            let details = usage["output_tokens_details"] as? [String: Any]
            let tokens = AgentUsageTokens(
                input: AgentUsageLines.int64(usage["input_tokens"]),
                cacheWrite: AgentUsageLines.int64(usage["cache_creation_input_tokens"]),
                cacheRead: AgentUsageLines.int64(usage["cache_read_input_tokens"]),
                output: AgentUsageLines.int64(usage["output_tokens"]),
                reasoning: AgentUsageLines.int64(details?["thinking_tokens"])
            )
            events.append(AgentUsageEvent(
                tool: .claudeCode,
                sessionKey: sessionKey,
                timestamp: timestamp,
                model: (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
                tokens: tokens,
                isRequest: true
            ))
        }
        seen = seenKeys
        return (events, consumed)
    }

    // MARK: Private

    private static let assistantMarker = Data("\"assistant\"".utf8)
}

/// Last cumulative `total_token_usage` seen in a Codex rollout, plus the model
/// and originator the session announced. Persisted by the caller per file.
struct CodexCumulative: Equatable {
    var input: Int64 = 0
    var cached: Int64 = 0
    var cacheWrite: Int64 = 0
    var output: Int64 = 0
    var reasoning: Int64 = 0
    var hasCounters = false
    var model = "unknown"
    var originator = ""
}

enum CodexUsageParser {
    // MARK: Internal

    static func parse(
        data: Data,
        from offset: Int,
        sessionKey: String,
        state: inout CodexCumulative
    ) -> (events: [AgentUsageEvent], consumedOffset: Int) {
        var events: [AgentUsageEvent] = []
        var current = state
        let consumed = AgentUsageLines.forEachCompleteLine(in: data, from: offset) { line in
            let isMeta = line.range(of: self.metaMarker) != nil
            let isTurn = line.range(of: self.turnMarker) != nil
            let isCount = line.range(of: self.countMarker) != nil
            guard isMeta || isTurn || isCount, let object = AgentUsageLines.json(line),
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any] else { return }
            switch type {
            case "session_meta":
                if let originator = payload["originator"] as? String { current.originator = originator }
                if let model = payload["model"] as? String, !model.isEmpty { current.model = model }
            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty { current.model = model }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let stamp = object["timestamp"] as? String,
                      let timestamp = AgentUsageDates.parseTimestamp(stamp)
                else { return }
                var next = current
                next.input = AgentUsageLines.int64(total["input_tokens"])
                next.cached = AgentUsageLines.int64(total["cached_input_tokens"])
                next.cacheWrite = AgentUsageLines.int64(total["cache_write_input_tokens"])
                next.output = AgentUsageLines.int64(total["output_tokens"])
                next.reasoning = AgentUsageLines.int64(total["reasoning_output_tokens"])
                next.hasCounters = true
                let deltaInput = next.input - current.input
                let deltaCached = next.cached - current.cached
                let deltaWrite = next.cacheWrite - current.cacheWrite
                let deltaOutput = next.output - current.output
                let deltaReasoning = next.reasoning - current.reasoning
                current = next
                // A counter that went down means the session restarted its
                // totals; take the new values as the baseline, count nothing.
                guard deltaInput >= 0, deltaCached >= 0, deltaWrite >= 0, deltaOutput >= 0, deltaReasoning >= 0
                else { return }
                guard deltaInput + deltaWrite + deltaOutput > 0 else { return }
                // Codex `input_tokens` includes the cached share.
                let tokens = AgentUsageTokens(
                    input: max(deltaInput - deltaCached, 0),
                    cacheWrite: deltaWrite,
                    cacheRead: deltaCached,
                    output: deltaOutput,
                    reasoning: deltaReasoning
                )
                events.append(AgentUsageEvent(
                    tool: .codex,
                    sessionKey: sessionKey,
                    timestamp: timestamp,
                    model: current.model,
                    tokens: tokens,
                    isRequest: true
                ))
            default:
                return
            }
        }
        state = current
        return (events, consumed)
    }

    // MARK: Private

    private static let metaMarker = Data("\"session_meta\"".utf8)
    private static let turnMarker = Data("\"turn_context\"".utf8)
    private static let countMarker = Data("\"token_count\"".utf8)
}

/// opencode keeps one small JSON object per message under
/// `storage/message/<session>/<message>.json` rather than a growing
/// transcript, and rewrites it while the turn runs. A message is counted only
/// once it carries `time.completed`: until then the file is read again on
/// every change, and the final write is the one that holds the whole turn.
enum OpencodeUsageParser {
    // MARK: Internal

    /// How many minutes past its first one a single message may still mark as
    /// worked. A turn left open and finished much later would otherwise paint
    /// an evening nobody spent.
    static let spanLimit = 60

    /// `seen` holds the message ids already counted for this file, which is
    /// one id: the caller keeps it beside the file so a rewrite of an already
    /// counted message adds nothing.
    static func parse(data: Data, seen: inout Set<String>) -> [AgentUsageEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["role"] as? String == "assistant",
              let id = object["id"] as? String, !id.isEmpty,
              let session = object["sessionID"] as? String, !session.isEmpty,
              let time = object["time"] as? [String: Any],
              let created = Self.date(time["created"]),
              // No end yet: the turn is still running and its counters are not
              // final. Nothing is remembered, so the next pass reads it again.
              let completed = Self.date(time["completed"]),
              !seen.contains(id)
        else { return [] }
        seen.insert(id)
        let counts = object["tokens"] as? [String: Any]
        let cache = counts?["cache"] as? [String: Any]
        let tokens = AgentUsageTokens(
            input: AgentUsageLines.int64(counts?["input"]),
            cacheWrite: AgentUsageLines.int64(cache?["write"]),
            cacheRead: AgentUsageLines.int64(cache?["read"]),
            output: AgentUsageLines.int64(counts?["output"]),
            reasoning: AgentUsageLines.int64(counts?["reasoning"])
        )
        let sessionKey = AgentUsageHash.key(for: session)
        let model = (object["modelID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        var events = [AgentUsageEvent(
            tool: .opencode,
            sessionKey: sessionKey,
            timestamp: created,
            model: model,
            tokens: tokens,
            isRequest: true
        )]
        // One message is a whole turn here, tool calls included, where Claude
        // and Codex write a line per step. The minutes it worked are the ones
        // its span covers; the counters ride on the first of them, so the rest
        // mark the time without being counted again.
        let first = AgentUsageDates.minuteStart(of: created)
        let last = AgentUsageDates.minuteStart(of: max(completed, created))
        let span = min(Int(last.timeIntervalSince(first) / 60), Self.spanLimit)
        for step in stride(from: 1, through: span, by: 1) {
            events.append(AgentUsageEvent(
                tool: .opencode,
                sessionKey: sessionKey,
                timestamp: first.addingTimeInterval(Double(step) * 60),
                model: model,
                tokens: AgentUsageTokens(),
                isRequest: false
            ))
        }
        return events
    }

    // MARK: Private

    /// Milliseconds since the epoch, which is how opencode writes every time.
    private static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds > 0, milliseconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
