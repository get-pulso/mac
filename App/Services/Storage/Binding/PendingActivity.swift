import Foundation
import RealmSwift

struct PendingActivity {
    let id: String
    let startedAt: Date
    let endedAt: Date
    var userID: String = ""
    var appBundleIdentifier: String?
    var appName: String?
    var appVersion: String?
    var appIconPNGBase64: String?
}

final class PendingActivityObject: Object {
    // MARK: Lifecycle

    convenience init(activity: PendingActivity) {
        self.init()
        self.id = activity.id
        self.startedAt = activity.startedAt
        self.endedAt = activity.endedAt
        self.userID = activity.userID
        self.appBundleIdentifier = activity.appBundleIdentifier
        self.appName = activity.appName
        self.appVersion = activity.appVersion
        self.appIconPNGBase64 = activity.appIconPNGBase64
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted var startedAt: Date
    @Persisted var endedAt: Date
    @Persisted var userID: String = ""
    @Persisted var appBundleIdentifier: String?
    @Persisted var appName: String?
    @Persisted var appVersion: String?
    @Persisted var appIconPNGBase64: String?
}

extension PendingActivity {
    init(object: PendingActivityObject) {
        self.id = object.id
        self.startedAt = object.startedAt
        self.endedAt = object.endedAt
        self.userID = object.userID
        self.appBundleIdentifier = object.appBundleIdentifier
        self.appName = object.appName
        self.appVersion = object.appVersion
        self.appIconPNGBase64 = object.appIconPNGBase64
    }
}
