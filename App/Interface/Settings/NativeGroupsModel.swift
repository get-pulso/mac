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
        self.loaded = false
        self.name = ""
        self.members = nil
        self.eligibleMembers = []
        self.selectedMembers = []
        self.clearInvite()
        self.usageLimit = 1
        self.reload()
    }

    func discardChanges() {
        self.name = self.page == .create ? "" : self.members?.group.name ?? ""
    }

    func reload() {
        self.loadTask?.cancel()
        let destination = self.page
        self.loadError = nil
        if destination == .create { self.loaded = true; self.loading = false; return }
        self.loading = true
        self.loadTask = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                switch destination {
                case .list:
                    let result = try await client.list()
                    try Task.checkCancellation()
                    groups = result.filter { $0.id != "global" }
                case let .details(id):
                    let result = try await client.members(id)
                    try Task.checkCancellation()
                    members = result
                    name = result.group.name
                case let .addMembers(id):
                    let result = try await client.eligibleMembers(id)
                    try Task.checkCancellation()
                    eligibleMembers = result
                case .create: break
                }
                loaded = true
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
        }
    }

    func create(completion: @escaping (String) -> Void) {
        guard self.validName, self.page == .create else { return }
        let submittedName = self.normalizedName
        self.run("create") {
            let group = try await self.client.create(submittedName)
            self.groups.append(group)
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
            self.members = NativeMembers(members: members.members, group: .init(
                id: members.group.id, name: submittedName, is_user_creator: true
            ))
            self.name = submittedName
            self.groups = self.groups.map { group in
                group.id == members.group.id ? NativeGroup(
                    id: group.id, name: submittedName, created_by: group.created_by, is_creator: group.is_creator
                ) : group
            }
            self.client.didChange(self.groups)
        }
    }

    func remove(completion: @escaping () -> Void) {
        guard let members else { return }
        self.run("remove") {
            try await self.client.remove(members.group.id, members.group.is_user_creator)
            self.groups.removeAll { $0.id == members.group.id }
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
            self.members = NativeMembers(members: members.members.filter { $0.id != person.id }, group: members.group)
            self.client.didChange(self.groups)
        }
    }

    func addMembers(completion: @escaping (String) -> Void) {
        guard case let .addMembers(id) = self.page, !self.selectedMembers.isEmpty else { return }
        let selected = Array(selectedMembers)
        self.run("add-members") {
            try await self.client.addMembers(id, selected)
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

    private let client: NativeGroupsClient
    private var loadTask: Task<Void, Never>?
    private var copyTask: Task<Void, Never>?
    private var inviteLink: String?

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
