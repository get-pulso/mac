import Combine
import Foundation
import Realm
import RealmSwift

final class Storage {
    // MARK: Internal

    // MARK: Activity

    func pendingActivity() throws -> [PendingActivity] {
        try self.read(from: .activity) { realm in
            realm.objects(PendingActivityObject.self)
                .sorted(by: \.startedAt, ascending: true)
                .map { PendingActivity(object: $0) }
        }
    }

    func store(activity: PendingActivity) throws {
        try self.write(to: .activity) { realm in
            let object = PendingActivityObject(activity: activity)
            realm.add(object, update: .all)
        }
    }

    func deletePendingActivity(with id: String) throws {
        try self.write(to: .activity) { realm in
            guard let object = realm.object(ofType: PendingActivityObject.self, forPrimaryKey: id) else {
                return
            }
            realm.delete(object)
        }
    }

    // MARK: Friends

    func friendsStream(filter: TimeFilter) -> AnyPublisher<[Friend], Error> {
        do {
            return try self.read(from: .friends) { realm in
                realm.objects(FriendObject.self)
                    .where { !$0.isGlobal }
                    .sorted(by: filter.friendSortingKeyPath, ascending: true)
                    .collectionPublisher
                    .map { $0.map { Friend(object: $0) }}
                    .eraseToAnyPublisher()
            }
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    func friendStream(in group: String, filter: TimeFilter) -> AnyPublisher<[Friend], Error> {
        do {
            let usersStream = try self.read(from: .friends) { realm in
                realm.objects(UserGroupObject.self)
                    .where { $0.id == group }
                    .collectionPublisher
                    .map { $0.first.flatMap { try? UserGroup(object: $0) } }
                    .compactMap { $0?.users.sorted() }
                    .removeDuplicates()
            }

            return usersStream.flatMap { [weak self] users -> AnyPublisher<[Friend], Error> in
                guard let self else {
                    return Empty().eraseToAnyPublisher()
                }

                do {
                    return try self.read(from: .friends) { realm in
                        realm.objects(FriendObject.self)
                            .where { $0.id.in(users) }
                            .sorted(by: filter.friendSortingKeyPath, ascending: true)
                            .collectionPublisher
                            .map { $0.map { Friend(object: $0) }}
                            .eraseToAnyPublisher()
                    }
                } catch {
                    return Fail(error: error).eraseToAnyPublisher()
                }
            }
            .eraseToAnyPublisher()
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    func store(friends: [Friend]) throws {
        try self.write(to: .friends) { realm in
            for object in realm.objects(FriendObject.self) {
                realm.delete(object)
            }
            for friend in friends {
                let object = FriendObject(friend: friend)
                realm.add(object, update: .all)
            }
        }
    }

    // MARK: Groups

    func groupsStream() -> AnyPublisher<[UserGroup], Error> {
        do {
            return try self.read(from: .friends) { realm in
                realm.objects(UserGroupObject.self)
                    .sorted(by: \.index, ascending: true)
                    .collectionPublisher
                    .map { $0.map { try? UserGroup(object: $0) }.compactMap { $0 } }
                    .eraseToAnyPublisher()
            }
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }

    func store(groups: [UserGroup]) throws {
        try self.write(to: .friends) { realm in
            for object in realm.objects(UserGroupObject.self) {
                realm.delete(object)
            }
            for group in groups {
                let object = try UserGroupObject(group: group)
                realm.add(object, update: .all)
            }
        }
    }

    func cleanFriendsStore() throws {
        try self.write(to: .friends) { realm in
            realm.deleteAll()
        }
    }

    // MARK: Private

    private func write(to store: RealmStore, action: (Realm) throws -> some Any) throws {
        let realm = try Realm(configuration: store.configuration)

        try realm.write {
            try action(realm)
        }
    }

    private func read<Result>(from store: RealmStore, action: (Realm) -> Result) throws -> Result {
        let realm = try Realm(configuration: store.configuration)
        return action(realm)
    }
}

private enum RealmStore {
    case activity
    case friends

    // MARK: Internal

    var configuration: Realm.Configuration {
        switch self {
        case .activity:
            .activity
        case .friends:
            .friends
        }
    }
}

private extension Realm.Configuration {
    static let activity: Realm.Configuration = .init(
        fileURL: URL.applicationSupportDirectory.appending(path: "Activity.realm"),
        encryptionKey: nil,
        schemaVersion: 1,
        deleteRealmIfMigrationNeeded: true,
        objectTypes: [
            PendingActivityObject.self,
        ]
    )

    static let friends: Realm.Configuration = .init(
        fileURL: URL.applicationSupportDirectory.appending(path: "Friends.realm"),
        encryptionKey: nil,
        schemaVersion: 1,
        deleteRealmIfMigrationNeeded: true,
        objectTypes: [
            FriendObject.self,
            UserGroupObject.self,
        ]
    )
}

private extension TimeFilter {
    var friendSortingKeyPath: KeyPath<FriendObject, Int> {
        switch self {
        case .last24h:
            \.rank24h
        case .last7d:
            \.rank7d
        }
    }
}
