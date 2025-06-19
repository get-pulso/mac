import Foundation
import RealmSwift

struct Friend: Identifiable {
    let id: String
    let isGlobal: Bool
    let name: String
    let avatar: URL?
    let rank24h: Int
    let rank7d: Int
    let minutes24h: Int?
    let minutes7d: Int?
    let lastActiveAt: Date?
}

final class FriendObject: Object {
    // MARK: Lifecycle

    convenience init(friend: Friend) {
        self.init()
        self.id = friend.id
        self.isGlobal = friend.isGlobal
        self.name = friend.name
        self.avatar = friend.avatar?.absoluteString
        self.rank24h = friend.rank24h
        self.rank7d = friend.rank7d
        self.minutes24h = friend.minutes24h
        self.minutes7d = friend.minutes7d
        self.lastActiveAt = friend.lastActiveAt
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted var isGlobal: Bool
    @Persisted var name: String
    @Persisted var avatar: String?
    @Persisted var rank24h: Int
    @Persisted var rank7d: Int
    @Persisted var minutes24h: Int?
    @Persisted var minutes7d: Int?
    @Persisted var lastActiveAt: Date?
}

extension Friend {
    init(object: FriendObject) {
        self.id = object.id
        self.isGlobal = object.isGlobal
        self.name = object.name
        self.avatar = object.avatar.flatMap { URL(string: $0) }
        self.rank24h = object.rank24h
        self.rank7d = object.rank7d
        self.minutes24h = object.minutes24h
        self.minutes7d = object.minutes7d
        self.lastActiveAt = object.lastActiveAt
    }
}
