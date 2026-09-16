import Foundation

/// What a Firstlight that is already on somebody's Mac can still decode.
///
/// The models below are deliberately frozen copies of the shipped ones, not
/// imports: the point is to hold today's server against yesterday's client,
/// so they must not follow `NativeModels.swift` when it changes. Update one
/// only when that build is genuinely gone from the world.
///
/// The case that brought this file into being: sharing levels gave the
/// leaderboard row an "agent working" mark with no tool named, sent as an
/// `agent` object missing its `tool`. Swift's synthesised decoder throws on
/// a present-but-incomplete object, and `decodeIfPresent` does not soften
/// that — so one person choosing "Just the total" would have failed the
/// decode of the whole list, every row of it, for every friend still on the
/// previous build. An unknown key is ignored instead, which is why the
/// unnamed mark travels as `agent_active_at`.

// MARK: The shipped shapes, frozen

private struct ShippedPresence: Decodable {
    let tool: String
    let last_active_at: String
}

private struct ShippedPerson: Decodable {
    let user_id: String
    let name: String?
    let agent: ShippedPresence?
}

private struct ShippedToolUsage: Decodable {
    let tool: String
    let tokens_total: Double
    let requests: Int?
    let sessions: Int?
    let agent_minutes: Double?
    let top_model: String?
    let estimated_cost_micro_usd: Double?
    let reported_cost_cents: Int?
}

private struct ShippedDay: Decodable {
    let date: String
    let human_minutes: Double
    let agent_minutes: Double
    let agent_only_minutes: Double
    let runs: [ShippedRun]?
    let rank_active: Int?
    let rank_agent: Int?
}

private struct ShippedRun: Decodable {
    let tool: String
    let start_time: String
    let end_time: String
    let minutes: Double
}

private struct ShippedSummary: Decodable {
    let period: String
    let has_data: Bool
    let agent_minutes: Double?
    let by_tool: [ShippedToolUsage]?
    let top_tool: String?
    let top_model: String?
    let estimated_cost_micro_usd: Double?
    let cost_shared: Bool?
    let days: [ShippedDay]?
    let active_tool: String?
}

private struct ShippedActivity: Decodable {
    let active_minutes: Double
    let period: String
    let last_active: String?
    let top_apps: [ShippedApp]?
    let active_app: ShippedApp?
}

private struct ShippedApp: Decodable {
    let bundle_identifier: String
    let name: String
    let active_minutes: Double
    let last_active_at: String
}

// MARK: The checks

private var checks = 0
private var failures = 0

private func decodes<T: Decodable>(_ type: T.Type, _ json: String, _ label: String) {
    checks += 1
    do {
        _ = try JSONDecoder().decode(type, from: Data(json.utf8))
    } catch {
        failures += 1
        print("FAIL \(label): \(error)")
    }
}

/// Every level of every channel, as the routes answer them today.
func runNativeWireCompatChecks() {
    let moment = "2026-09-16T12:00:00Z"

    decodes(
        [ShippedPerson].self,
        #"[{"user_id":"u1","name":"Anya","agent":{"tool":"claude_code","last_active_at":"\#(moment)"}}]"#,
        "row, agents at detail"
    )
    decodes(
        [ShippedPerson].self,
        #"[{"user_id":"u1","name":"Anya","agent_active_at":"\#(moment)"}]"#,
        "row, agents at total"
    )
    decodes([ShippedPerson].self, #"[{"user_id":"u1","name":"Anya"}]"#, "row, agents off")
    decodes(
        [ShippedPerson].self,
        #"""
        [{"user_id":"u1","active_app":{"bundle_identifier":"com.example","name":"Cursor","active_minutes":12,"last_active_at":"\#(moment)"},"agent_active_at":"\#(moment)"}]
        """#,
        "row, apps named while agents are not"
    )

    decodes(
        ShippedSummary.self,
        #"""
        {"period":"7d","shared":"total","has_data":true,"agent_minutes":1044,"agent_only_minutes":800,
         "max_concurrency":3,"tokens":{"total":1,"input":1,"cache_write":0,"cache_read":0,"output":0,"reasoning":0},
         "agent_active_now":true,"days":[{"date":"2026-09-16","human_minutes":10,"agent_minutes":20,
         "agent_only_minutes":5,"runs":[],"presence":[],"rank_active":1,"rank_agent":2}],
         "last_agent_active_at":"\#(moment)","rank_active":1,"rank_agent":2,"contenders":4,
         "longest_run_minutes":90}
        """#,
        "summary, agents at total"
    )
    decodes(
        ShippedSummary.self,
        #"{"period":"7d","shared":"off","has_data":false,"agent_active_now":false}"#,
        "summary, agents off"
    )

    decodes(
        ShippedActivity.self,
        #"""
        {"active_minutes":726,"period":"7d","last_active":"\#(moment)",
         "apps":{"level":"total","total_minutes":726,"app_count":3},"active_app":null,"top_apps":[]}
        """#,
        "activity, apps at total"
    )
    decodes(
        ShippedActivity.self,
        #"""
        {"active_minutes":726,"period":"7d","last_active":"\#(moment)",
         "apps":{"level":"off"},"active_app":null,"top_apps":[]}
        """#,
        "activity, apps off"
    )

    if failures > 0 {
        print("Native wire compatibility checks FAILED: \(failures) of \(checks)")
        exit(1)
    }
    print("Native wire compatibility checks passed: \(checks)")
}

runNativeWireCompatChecks()
