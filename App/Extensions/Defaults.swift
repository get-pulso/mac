import Defaults

extension Defaults.Keys {
    static let sessionCounter = Key("session_counter", default: 0)
    static let currentUserID = Key<String?>("current_user_id", default: nil)
    static let uploadedAppIconVersions = Key<[String: String]>("uploaded_app_icon_versions", default: [:])
    /// Per-account opt-in for the AI coding agent usage layer, keyed by user id.
    static let agentTrackingAccounts = Key<[String: Bool]>("agent_tracking_accounts", default: [:])
    /// Stable identifier for this Mac in agent usage uploads.
    static let agentDeviceID = Key<String?>("agent_device_id", default: nil)
    /// Minute indices (`floor(unixTime / 60)`) the presence heartbeat counted as
    /// human-active, newest last; bounded to two days.
    static let recentHumanMinutes = Key<[String]>("recent_human_minutes", default: [])
    /// Per-account cut-off (unix seconds) after an activity reset: agent events
    /// older than this are never counted again on this Mac.
    static let agentUsageFloor = Key<[String: Double]>("agent_usage_floor", default: [:])
    /// Which version of the counting rules produced the stored agent history,
    /// per account. A newer app rebuilds the window once, so a fix to the
    /// parsers corrects what was already uploaded instead of only new days.
    static let agentCollectorVersion = Key<[String: Int]>("agent_collector_version", default: [:])
}
