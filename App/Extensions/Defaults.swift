import Defaults

extension Defaults.Keys {
    static let sessionCounter = Key("session_counter", default: 0)
    static let currentUserID = Key<String?>("current_user_id", default: nil)
    static let uploadedAppIconVersions = Key<[String: String]>("uploaded_app_icon_versions", default: [:])
}
