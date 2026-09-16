import Foundation

@main
struct NativeAgentPresenceChecks {
    static func main() throws {
        let decoder = JSONDecoder()
        let now = ISO8601DateFormatter().date(from: "2026-09-16T12:02:00Z")!
        func person(_ fragment: String) throws -> NativePerson {
            try decoder.decode(NativePerson.self, from: Data("{\"user_id\":\"a\"\(fragment)}".utf8))
        }
        let live = try person(#", "agent_live":{"session_count":5,"observed_at":"2026-09-16T12:02:00Z","tools":[{"tool":"claude_code","session_count":3},{"tool":"codex","session_count":2}]}"#)
        precondition(live.liveAgents(at: now)?.session_count == 5)
        precondition(live.liveAgents(at: now)?.tools?.count == 2)
        precondition(live.liveAgents(at: now)?.label == "5 agents now")
        precondition(live.liveAgents(at: now.addingTimeInterval(120)) != nil)
        precondition(live.liveAgents(at: now.addingTimeInterval(121)) == nil)
        let total = try person(#", "agent_active_at":"2026-09-16T12:02:00Z", "agent_live":{"session_count":1,"observed_at":"2026-09-16T12:02:00Z"}"#)
        precondition(total.liveAgents(at: now)?.tools == nil)
        precondition(total.liveAgents(at: now)?.label == "1 agent now")
        let old = try person(#", "agent":{"tool":"codex","last_active_at":"2026-09-16T12:02:00Z"}"#)
        precondition(old.liveAgents(at: now) == nil, "old presence is not a total count")
        let hidden = try person("")
        precondition(hidden.liveAgents(at: now) == nil)
        let invalid = try person(#", "agent_live":{"session_count":0,"observed_at":"2026-09-16T12:02:00Z"}"#)
        precondition(invalid.liveAgents(at: now) == nil)
        let app = try person(#", "last_active_at":"2026-09-16T12:02:00Z", "active_app":{"bundle_identifier":"app.cursor","name":"Cursor","last_active_at":"2026-09-16T12:02:00Z"}"#)
        precondition(app.activeApp(at: now)?.name == "Cursor")
        precondition(app.activeApp(at: now.addingTimeInterval(121)) == nil)
        precondition(!live.isActive(at: now) && live.liveAgents(at: now) != nil,
                     "an agent does not require human presence")
        print("Native agent presence: decoding, old server fallback, hidden tools, expiry and independent presence passed.")
    }
}
