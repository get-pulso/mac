import Defaults

extension Defaults.Keys {
    static let sessionCounter = Key("session_counter", default: 0)
    static let currentUserID = Key<String?>("current_user_id", default: nil)
}
