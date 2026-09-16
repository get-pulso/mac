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
}

@MainActor
final class NativeGroupsModel: ObservableObject {
    // MARK: Lifecycle

    init(client: NativeGroupsClient) { self.client = client }

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

    func save() {
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

    private let client: NativeGroupsClient
    private var loadTask: Task<Void, Never>?
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
                case let .details(id):
                    let result = try await client.members(id)
                    try Task.checkCancellation()
                    members = result
                    name = result.group.name
                    membersCache.insert(result, for: id)
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
