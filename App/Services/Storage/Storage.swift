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

    func deletePendingActivity(for userID: String) throws {
        try self.write(to: .activity) { realm in
            let records = realm.objects(PendingActivityObject.self).where { $0.userID == userID }
            realm.delete(records)
        }
    }

    // MARK: Agent usage

    func agentUsageDays(for userID: String) throws -> [AgentUsageDayRecord] {
        try self.read(from: .activity) { realm in
            realm.objects(AgentUsageDayObject.self).where { $0.userID == userID }
                .compactMap { AgentUsageDayRecord(object: $0) }
        }
    }

    func dirtyAgentUsageDays(for userID: String) throws -> [AgentUsageDayRecord] {
        try self.read(from: .activity) { realm in
            realm.objects(AgentUsageDayObject.self).where { $0.userID == userID && $0.dirty == true }
                .sorted(by: \.date, ascending: true)
                .compactMap { AgentUsageDayRecord(object: $0) }
        }
    }

    /// Adds token and request deltas to the stored day rows and unions the
    /// session keys, so `sessions` stays the count of distinct transcripts.
    func mergeAgentUsage(
        for userID: String,
        days: [AgentUsageDayKey: AgentUsageDay],
        sessionKeys: [AgentUsageDayKey: Set<String>]
    ) throws {
        guard !days.isEmpty else { return }
        try self.write(to: .activity) { realm in
            for (key, delta) in days {
                let id = AgentUsageDayRecord.id(userID: userID, key: key)
                let object: AgentUsageDayObject
                if let existing = realm.object(ofType: AgentUsageDayObject.self, forPrimaryKey: id) {
                    object = existing
                } else {
                    object = AgentUsageDayObject(record: .init(userID: userID, key: key, day: .init(), sessionKeys: []))
                    realm.add(object)
                }
                var day = object.day
                day.add(AgentUsageTokens(
                    input: delta.input,
                    cacheWrite: delta.cacheWrite,
                    cacheRead: delta.cacheRead,
                    output: delta.output,
                    reasoning: delta.reasoning
                ))
                day.requests += delta.requests
                if let cents = delta.reportedCostCents { day.reportedCostCents = (day.reportedCostCents ?? 0) + cents }
                let known = Set(object.sessionKeys)
                for sessionKey in sessionKeys[key] ?? [] where !known.contains(sessionKey) {
                    object.sessionKeys.append(sessionKey)
                }
                day.sessions = object.sessionKeys.count
                object.apply(day)
                object.dirty = true
                object.revision += 1
                object.updatedAt = .now
            }
        }
    }

    /// Cursor is re-read as a whole: rows become the given absolute values and
    /// are marked dirty only when something changed.
    func replaceAgentUsage(
        for userID: String,
        tool: AgentTool,
        days: [AgentUsageDayKey: AgentUsageDay],
        sessionKeys: [AgentUsageDayKey: Set<String>]
    ) throws {
        try self.write(to: .activity) { realm in
            for (key, day) in days where key.tool == tool {
                let id = AgentUsageDayRecord.id(userID: userID, key: key)
                if let existing = realm.object(ofType: AgentUsageDayObject.self, forPrimaryKey: id) {
                    guard existing.day != day else { continue }
                    existing.apply(day)
                    existing.sessionKeys.removeAll()
                    existing.sessionKeys.append(objectsIn: sessionKeys[key] ?? [])
                    existing.dirty = true
                    existing.revision += 1
                    existing.updatedAt = .now
                } else {
                    let record = AgentUsageDayRecord(
                        userID: userID,
                        key: key,
                        day: day,
                        sessionKeys: sessionKeys[key] ?? []
                    )
                    realm.add(AgentUsageDayObject(record: record))
                }
            }
        }
    }

    /// Clears `dirty` only when the row was not touched since the snapshot.
    func markAgentUsageUploaded(_ records: [AgentUsageDayRecord]) throws {
        guard !records.isEmpty else { return }
        try self.write(to: .activity) { realm in
            for record in records {
                guard let object = realm.object(ofType: AgentUsageDayObject.self, forPrimaryKey: record.id),
                      object.revision == record.revision else { continue }
                object.dirty = false
            }
        }
    }

    func deleteAgentUsageDays(for userID: String, dates: Set<String>) throws {
        try self.write(to: .activity) { realm in
            let rows = realm.objects(AgentUsageDayObject.self).where { $0.userID == userID }
                .filter { dates.contains($0.date) }
            realm.delete(rows)
        }
    }

    func pendingAgentActivity(for userID: String) throws -> [PendingAgentActivity] {
        try self.read(from: .activity) { realm in
            realm.objects(PendingAgentActivityObject.self).where { $0.userID == userID }
                .sorted(by: \.startedAt, ascending: true)
                .compactMap { PendingAgentActivity(object: $0) }
        }
    }

    /// Upserts minutes; a minute seen again keeps the larger concurrency and
    /// stays human-active once it was.
    func store(agentActivity: [PendingAgentActivity]) throws {
        guard !agentActivity.isEmpty else { return }
        try self.write(to: .activity) { realm in
            for minute in agentActivity {
                if let existing = realm.object(ofType: PendingAgentActivityObject.self, forPrimaryKey: minute.id) {
                    existing.sessionCount = max(existing.sessionCount, minute.sessionCount)
                    existing.humanActive = existing.humanActive || minute.humanActive
                    existing.userID = minute.userID
                } else {
                    realm.add(PendingAgentActivityObject(activity: minute))
                }
            }
        }
    }

    func deletePendingAgentActivity(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try self.write(to: .activity) { realm in
            let rows = realm.objects(PendingAgentActivityObject.self).where { $0.id.in(ids) }
            realm.delete(rows)
        }
    }

    func agentParseState(id: String) throws -> AgentParseState? {
        try self.read(from: .activity) { realm in
            realm.object(ofType: AgentParseStateObject.self, forPrimaryKey: id).flatMap(AgentParseState.init(object:))
        }
    }

    func agentParseStates(for userID: String) throws -> [AgentParseState] {
        try self.read(from: .activity) { realm in
            realm.objects(AgentParseStateObject.self).where { $0.userID == userID }
                .compactMap { AgentParseState(object: $0) }
        }
    }

    func store(parseStates: [AgentParseState]) throws {
        guard !parseStates.isEmpty else { return }
        try self.write(to: .activity) { realm in
            for state in parseStates {
                realm.add(AgentParseStateObject(state: state), update: .all)
            }
        }
    }

    func deleteAgentParseStates(for userID: String) throws {
        try self.write(to: .activity) { realm in
            realm.delete(realm.objects(AgentParseStateObject.self).where { $0.userID == userID })
        }
    }

    /// Everything the agent layer holds for one account: day rows, queued
    /// minutes and parse progress.
    func deleteAgentUsage(for userID: String) throws {
        try self.write(to: .activity) { realm in
            realm.delete(realm.objects(AgentUsageDayObject.self).where { $0.userID == userID })
            realm.delete(realm.objects(PendingAgentActivityObject.self).where { $0.userID == userID })
            realm.delete(realm.objects(AgentParseStateObject.self).where { $0.userID == userID })
        }
    }

    // MARK: Friends

    func friendsStream(filter: TimeFilter) -> AnyPublisher<[Friend], Error> {
        do {
            return try self.read(from: .friends) { realm in
                realm.objects(FriendObject.self)
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
        schemaVersion: 4,
        migrationBlock: { _, _ in },
        objectTypes: [
            PendingActivityObject.self,
            AgentUsageDayObject.self,
            PendingAgentActivityObject.self,
            AgentParseStateObject.self,
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
