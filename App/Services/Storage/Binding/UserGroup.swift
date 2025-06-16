import Foundation
import RealmSwift

struct UserGroup: Identifiable {
    let id: String
    let name: String
    let index: Int
    let users: [String]
}

final class UserGroupObject: Object {
    // MARK: Lifecycle

    convenience init(group: UserGroup) throws {
        self.init()
        self.id = group.id
        self.name = group.name
        self.index = group.index
        self.users = try PropertyListEncoder().encode(group.users)
    }

    // MARK: Internal

    @Persisted(primaryKey: true) var id: String
    @Persisted var name: String
    @Persisted var index: Int
    @Persisted var users: Data
}

extension UserGroup {
    init(object: UserGroupObject) throws {
        self.id = object.id
        self.name = object.name
        self.index = object.index
        self.users = try PropertyListDecoder().decode([String].self, from: object.users)
    }
}
