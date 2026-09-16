import AppKit
import SwiftUI

enum NativeGroupsPage: Equatable {
    case list, create, details(String), addMembers(String)

    // MARK: Internal

    var groupID: String? {
        switch self {
        case let .details(id),
             let .addMembers(id): id
        default: nil
        }
    }
}

/// Injectable operations keep Settings independent of the popover's navigation.
struct NativeGroupsClient {
    var list: () async throws -> [NativeGroup]
    var members: (String) async throws -> NativeMembers
    var create: (String) async throws -> NativeGroup
    var rename: (String, String) async throws -> Void
    var remove: (String, Bool) async throws -> Void
    var removeMember: (String, String) async throws -> Void
    var addMembers: (String, [String]) async throws -> Void
    var eligibleMembers: (String) async throws -> [NativePerson]
    var invite: (String, Int) async throws -> String
    var copy: (String) -> Bool
    var didChange: ([NativeGroup]) -> Void
    /// The groups the popover already has. Settings and the popover ask the
    /// same question of the same account, so the second one to open should not
    /// draw a skeleton over an answer that is already in the process.
    var knownGroups: () -> [NativeGroup] = { [] }
}

@MainActor
final class NativeGroupsModel: ObservableObject {
    // MARK: Lifecycle

    init(client: NativeGroupsClient) {
        self.client = client
        let known = client.knownGroups().filter { $0.id != "global" }
        if !known.isEmpty {
            self.groups = known
            // Seeded, not fetched: it still revalidates on the first open.
            self.groupsCache.insert(known, for: "groups", now: .distantPast)
        }
    }

    // MARK: Internal

    @Published private(set) var page = NativeGroupsPage.list
    @Published private(set) var groups: [NativeGroup] = []
    @Published private(set) var members: NativeMembers?
    @Published private(set) var eligibleMembers: [NativePerson] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var error: String?
    @Published private(set) var operation: String?
    @Published private(set) var copied = false
    @Published var name = ""
    @Published var selectedMembers = Set<String>()

    @Published var usageLimit = 1 {
        didSet { if oldValue != self.usageLimit { self.clearInvite() } }
    }

    var busy: Bool { self.operation != nil }
    var normalizedName: String { self.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var validName: Bool { !self.normalizedName.isEmpty && self.normalizedName.count <= 80 }
    var hasChanges: Bool {
        switch self.page {
        case .create: !self.normalizedName.isEmpty
        case .details: self.members?.group.is_user_creator == true && self.normalizedName != self.members?.group.name
        default: false
        }
    }

    var title: String {
        switch self.page {
        case .list: "Groups"
        case .create: "New Group"
        case .addMembers: "Add Friends"
        case let .details(id): self.members?.group.name ?? self.groups.first { $0.id == id }?.name ?? "Group"
        }
    }

    func open(_ destination: NativeGroupsPage) {
        self.loadTask?.cancel()
        self.page = destination
        self.error = nil
        self.loadError = nil
        self.selectedMembers = []
        self.clearInvite()
        self.usageLimit = 1
        self.restoreCachedValue(for: destination)
        self.load(force: false)
        self.prefetch(for: destination)
    }

    func discardChanges() {
        self.name = self.page == .create ? "" : self.members?.group.name ?? ""
    }

    func reload() {
        self.load(force: true)
    }

    func invalidateList() {
        self.groupsCache.invalidate("groups")
    }

    func create(completion: @escaping (String) -> Void) {
        guard self.validName, self.page == .create else { return }
        let submittedName = self.normalizedName
        self.run("create") {
            let group = try await self.client.create(submittedName)
            if let refreshed = try? await self.client.list() {
                self.groups = refreshed.filter { $0.id != "global" }
                self.groupsCache.insert(self.groups, for: "groups")
            } else if self.groupsCache.contains("groups") {
                self.groups.append(group)
                self.groupsCache.insert(self.groups, for: "groups")
            }
            if let snapshot = try? await self.client.members(group.id) {
                self.membersCache.insert(snapshot, for: group.id)
            }
            self.name = ""
            self.client.didChange(self.groups)
            self.operation = nil
            completion(group.id)
        }
    }

    /// Saving leaves the form the way creating one does: the list is where the
    /// name that was just changed can be read back, and staying put left the
    /// person on a screen with nothing left to do on it.
    func save(completion: @escaping () -> Void) {
        guard self.validName, self.hasChanges, let members, members.group.is_user_creator else { return }
        let submittedName = self.normalizedName
        self.run("save") {
            try await self.client.rename(members.group.id, submittedName)
            let updatedMembers = NativeMembers(members: members.members, group: .init(
                id: members.group.id, name: submittedName, is_user_creator: true
            ))
            self.members = updatedMembers
            self.membersCache.insert(updatedMembers, for: members.group.id)
            self.name = submittedName
            self.groups = self.groups.map { group in
                group.id == members.group.id ? NativeGroup(
                    id: group.id, name: submittedName, created_by: group.created_by, is_creator: group.is_creator
                ) : group
            }
            if self.groupsCache.contains("groups") { self.groupsCache.insert(self.groups, for: "groups") }
            self.client.didChange(self.groups)
            self.operation = nil
            completion()
        }
    }

    func remove(completion: @escaping () -> Void) {
        guard let members else { return }
        self.run("remove") {
            try await self.client.remove(members.group.id, members.group.is_user_creator)
            if let refreshed = try? await self.client.list() {
                self.groups = refreshed.filter { $0.id != "global" }
                self.groupsCache.insert(self.groups, for: "groups")
            } else if self.groupsCache.contains("groups") {
                self.groups.removeAll { $0.id == members.group.id }
                self.groupsCache.insert(self.groups, for: "groups")
            }
            self.membersCache.removeValue(for: members.group.id)
            self.eligibleMembersCache.removeValue(for: members.group.id)
            self.members = nil
            self.name = ""
            self.client.didChange(self.groups)
            self.operation = nil
            completion()
        }
    }

    func removeMember(_ person: NativeContact) {
        guard let members, members.group.is_user_creator, person.is_creator != true else { return }
        self.run("remove-\(person.id)") {
            try await self.client.removeMember(members.group.id, person.id)
            let updatedMembers = NativeMembers(
                members: members.members.filter { $0.id != person.id },
                group: members.group
            )
            self.members = updatedMembers
            self.membersCache.insert(updatedMembers, for: members.group.id)
            self.eligibleMembersCache.invalidate(members.group.id)
            self.client.didChange(self.groups)
        }
    }

    func addMembers(completion: @escaping (String) -> Void) {
        guard case let .addMembers(id) = self.page, !self.selectedMembers.isEmpty else { return }
        let selected = Array(selectedMembers)
        self.run("add-members") {
            try await self.client.addMembers(id, selected)
            if let snapshot = try? await self.client.members(id) {
                self.membersCache.insert(snapshot, for: id)
            } else {
                self.membersCache.removeValue(for: id)
            }
            let remaining = self.eligibleMembers.filter { !self.selectedMembers.contains($0.id) }
            self.eligibleMembers = remaining
            self.eligibleMembersCache.insert(remaining, for: id)
            self.selectedMembers = []
            self.client.didChange(self.groups)
            self.operation = nil
            completion(id)
        }
    }

    func copyInvite() {
        guard let id = page.groupID else { return }
        let limit = self.usageLimit
        self.run("invite") {
            let link: String
            if let cached = self.inviteLink { link = cached }
            else {
                link = try await self.client.invite(id, limit)
                self.inviteLink = link
            }
            guard self.client.copy(link) else { throw NativeError.message("Couldn't copy the link. Try again.") }
            self.copied = true
            self.copyTask?.cancel()
            self.copyTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.copied = false
            }
        }
    }

    // MARK: Private

    private static let cacheLifetime: TimeInterval = 30
    /// How many group rosters to fetch ahead. Enough for the groups a person
    /// actually keeps, without a burst of requests for a long list.
    private static let prefetchLimit = 8

    private let client: NativeGroupsClient
    private var loadTask: Task<Void, Never>?
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var copyTask: Task<Void, Never>?
    private var inviteLink: String?
    private var groupsCache = NativeResourceCache<String, [NativeGroup]>()
    private var membersCache = NativeResourceCache<String, NativeMembers>()
    private var eligibleMembersCache = NativeResourceCache<String, [NativePerson]>()

    private func load(force: Bool) {
        self.loadTask?.cancel()
        let destination = self.page
        self.loadError = nil
        if destination == .create { self.loaded = true; self.loading = false; return }
        if !force, self.isFresh(destination) {
            self.loading = false
            return
        }
        self.loading = true
        self.loadTask = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                switch destination {
                case .list:
                    let result = try await client.list()
                    try Task.checkCancellation()
                    let visibleGroups = result.filter { $0.id != "global" }
                    groups = visibleGroups
                    groupsCache.insert(visibleGroups, for: "groups")
                    prefetch(for: .list)
                case let .details(id):
                    let result = try await client.members(id)
                    try Task.checkCancellation()
                    members = result
                    name = result.group.name
                    membersCache.insert(result, for: id)
                    prefetch(for: .details(id))
                case let .addMembers(id):
                    let result = try await client.eligibleMembers(id)
                    try Task.checkCancellation()
                    eligibleMembers = result
                    eligibleMembersCache.insert(result, for: id)
                case .create: break
                }
                loaded = true
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
    }

    /// Asks for what the next tap on this screen will need, while the user is
    /// still reading this one. Each of these screens costs a round trip it
    /// spends in front of the reader as a skeleton; fetched a screen early,
    /// that round trip happens where nobody is waiting on it.
    ///
    /// Strictly optional work: it only ever fills caches, never `loading` or
    /// `loadError`. A failure here is the business of the load that the tap
    /// itself starts, and of nothing else. Work already in flight is left to
    /// finish rather than restarted, so returning to a screen does not keep
    /// cancelling the very request that would have made the next tap instant.
    private func prefetch(for destination: NativeGroupsPage) {
        switch destination {
        case .list:
            // Opening any group from the list.
            for group in self.groups.prefix(Self.prefetchLimit)
                where !self.membersCache.isFresh(group.id, for: Self.cacheLifetime)
            {
                self.prefetch(key: "members-" + group.id) { [client] in
                    guard let snapshot = try? await client.members(group.id) else { return }
                    self.membersCache.insert(snapshot, for: group.id)
                }
            }
        case let .details(id):
            // Add Friends, from the group that is open. Only its creator has
            // that button, so only its creator is worth fetching for.
            guard self.members?.group.is_user_creator == true,
                  !self.eligibleMembersCache.isFresh(id, for: Self.cacheLifetime) else { return }
            self.prefetch(key: "eligible-" + id) { [client] in
                guard let people = try? await client.eligibleMembers(id) else { return }
                self.eligibleMembersCache.insert(people, for: id)
            }
        case .create,
             .addMembers:
            break
        }
    }

    private func prefetch(key: String, work: @escaping () async -> Void) {
        guard self.prefetchTasks[key] == nil else { return }
        self.prefetchTasks[key] = Task {
            await work()
            self.prefetchTasks[key] = nil
        }
    }

    private func restoreCachedValue(for destination: NativeGroupsPage) {
        switch destination {
        case .list:
            if let cached = self.groupsCache.value(for: "groups") {
                self.groups = cached
                self.loaded = true
            } else {
                self.loaded = false
            }
        case .create:
            self.name = ""
            self.members = nil
            self.eligibleMembers = []
            self.loaded = true
        case let .details(id):
            self.eligibleMembers = []
            if let cached = self.membersCache.value(for: id) {
                self.members = cached
                self.name = cached.group.name
                self.loaded = true
            } else {
                self.members = nil
                self.name = ""
                self.loaded = false
            }
        case let .addMembers(id):
            self.members = nil
            self.name = ""
            if let cached = self.eligibleMembersCache.value(for: id) {
                self.eligibleMembers = cached
                self.loaded = true
            } else {
                self.eligibleMembers = []
                self.loaded = false
            }
        }
    }

    private func isFresh(_ destination: NativeGroupsPage) -> Bool {
        switch destination {
        case .list: self.groupsCache.isFresh("groups", for: Self.cacheLifetime)
        case .create: true
        case let .details(id): self.membersCache.isFresh(id, for: Self.cacheLifetime)
        case let .addMembers(id): self.eligibleMembersCache.isFresh(id, for: Self.cacheLifetime)
        }
    }

    private func clearInvite() {
        self.inviteLink = nil
        self.copied = false
        self.copyTask?.cancel()
    }

    private func run(_ key: String, action: @escaping () async throws -> Void) {
        guard !self.busy else { return }
        self.operation = key
        self.error = nil
        Task {
            defer { operation = nil }
            do { try await action() }
            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
    }
}
