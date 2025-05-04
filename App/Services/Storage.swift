import Combine
import Foundation
import Realm
import RealmSwift

final class Storage {
    // MARK: Internal

    func activity(in day: Date) throws -> [Activity] {
        let startDay = Calendar.current.startOfDay(for: day)
        var components = DateComponents()
        components.day = 1
        let nextDay = Calendar.current.date(byAdding: components, to: startDay) ?? day

        return try self.read { realm in
            realm.objects(ActivityObject.self)
                .where { $0.startedAt >= startDay && $0.endedAt < nextDay }
                .sorted(by: \.startedAt, ascending: false)
                .map { Activity(object: $0) }
        }
    }

    func activityStream(in day: Date) -> AnyPublisher<[Activity], Error> {
        do {
            let startDay = Calendar.current.startOfDay(for: day)
            var components = DateComponents()
            components.day = 1
            let nextDay = Calendar.current.date(byAdding: components, to: startDay) ?? day

            return try self.read { realm in
                realm.objects(ActivityObject.self)
                    .where { $0.startedAt >= startDay && $0.endedAt < nextDay }
                    .sorted(by: \.startedAt, ascending: false)
                    .collectionPublisher
                    .map { $0.map { Activity(object: $0) } }
                    .eraseToAnyPublisher()
            }
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    func update(activity: Activity) throws {
        try self.write { realm in
            let object = ActivityObject(activity: activity)
            realm.add(object, update: .all)
        }
    }

    // MARK: Private

    private func write(action: (Realm) -> some Any) throws {
        let realm = try Realm(configuration: .pulso)

        try realm.write {
            action(realm)
        }
    }

    private func read<Result>(action: (Realm) -> Result) throws -> Result {
        let realm = try Realm(configuration: .pulso)
        return action(realm)
    }
}

private extension Realm.Configuration {
    static let pulso: Realm.Configuration = .init(
        encryptionKey: nil,
        schemaVersion: 1,
        objectTypes: [
            ActivityObject.self,
        ]
    )
}

@objc(ActivityObject)
private final class ActivityObject: Object {
    // MARK: Lifecycle

    convenience init(activity: Activity) {
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

private extension Activity {
    init(object: ActivityObject) {
        self.id = object.id
        self.startedAt = object.startedAt
        self.endedAt = object.endedAt
    }
}
