import Foundation
import RealmSwift

struct PendingActivity {
    let id: String
    let startedAt: Date
    let endedAt: Date
}

final class PendingActivityObject: Object {
    // MARK: Lifecycle

    convenience init(activity: PendingActivity) {
        self.init()
        self.id = activity.id
        self.startedAt = activity.startedAt
        self.endedAt = activity.endedAt
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted var startedAt: Date
    @Persisted var endedAt: Date
}

extension PendingActivity {
    init(object: PendingActivityObject) {
        self.id = object.id
        self.startedAt = object.startedAt
        self.endedAt = object.endedAt
    }
}
