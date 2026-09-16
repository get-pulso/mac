import AppKit
import Foundation

/// Runs the actual Settings model against an in-memory client. No account,
/// group, clipboard, or network mutation is performed.
@main
struct NativeGroupsChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0 ..< 500 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(2))
            }
            preconditionFailure("Model operation did not settle")
        }

        let owner = NativeContact(id: "owner", name: "Owner", email: nil, avatar_url: nil, is_creator: true)
        let friend = NativeContact(id: "friend", name: "Friend", email: nil, avatar_url: nil, is_creator: false)
        let eligibleFriend = NativePerson(
            user_id: "friend", name: "Friend", avatar_url: nil, rank: nil, active_minutes: nil,
            last_active_at: nil, bio: nil, location: nil, website: nil, twitter: nil, telegram: nil, active_app: nil, agent: nil, score: nil
        )
        var group = NativeGroup(id: "one", name: "Studio", created_by: "owner", is_creator: true)
        var currentMembers = [owner, friend]
        var ownerAccess = true
        var failList = true
        var failRename = false
        var slowDetails = false
        var listRequests = 0
        var memberRequests = 0
        var eligibleRequests = 0
        var createdNames: [String] = []
        var renames: [String] = []
        var inviteLimits: [Int] = []
        var copiedLinks: [String] = []
        var removed: [Bool] = []
        var removedMembers: [String] = []
        var added: [String] = []
        var refreshes = 0
        let client = NativeGroupsClient(
            list: {
                listRequests += 1
                if failList { throw NativeError.message("Offline") }
                return [group, NativeGroup(id: "global", name: "Global", created_by: nil, is_creator: nil)]
            },
            members: { id in
                memberRequests += 1
                if slowDetails { try await Task.sleep(for: .milliseconds(40)) }
                return NativeMembers(
                    members: currentMembers,
                    group: .init(id: id, name: group.name, is_user_creator: ownerAccess)
                )
            },
            create: { name in createdNames.append(name); return group },
            rename: { _, name in
                if failRename { throw NativeError.message("Couldn't save") }
                renames.append(name)
                group = NativeGroup(id: "one", name: name, created_by: "owner", is_creator: true)
            },
            remove: { _, isOwner in removed.append(isOwner) },
            removeMember: { _, id in removedMembers.append(id); currentMembers.removeAll { $0.id == id } },
            addMembers: { _, ids in added = ids },
            eligibleMembers: { _ in
                eligibleRequests += 1
                return currentMembers.contains(where: { $0.id == eligibleFriend.id }) ? [] : [eligibleFriend]
            },
            invite: { _, limit in inviteLimits.append(limit); return "https://example.invalid/invite/\(limit)" },
            copy: { copiedLinks.append($0); return true },
            didChange: { _ in refreshes += 1 }
        )
        let model = NativeGroupsModel(client: client)
        model.open(.list)
        try await settle { !model.loading }
        expect(!model.loaded && model.loadError == "Offline", "Initial failure must show retry, not empty state")
        failList = false
        model.reload()
        try await settle { model.loaded }
        expect(model.groups.count == 1, "Global leaderboard isn't a managed group")
        let loadedListRequests = listRequests
        model.open(.create)
        model.open(.list)
        expect(model.loaded && !model.loading, "A cached list renders synchronously")
        expect(listRequests == loadedListRequests, "A fresh list isn't requested twice")

        model.open(.create)
        model.name = "   "
        model.create { _ in preconditionFailure("Invalid create") }
        expect(!model.validName && !model.busy, "Empty name must not submit")
        model.name = String(repeating: "a", count: 81)
        expect(!model.validName, "Enforce the group-name limit")
        model.name = "  Studio  "
        expect(model.hasChanges, "Draft participates in unsaved-change protection")
        model.discardChanges()
        expect(model.name.isEmpty && !model.hasChanges, "Discard clears a new-group draft")
        model.name = "  Studio  "
        var createdID: String?
        model.create { createdID = $0; model.open(.details($0)) }
        try await settle { createdID != nil && model.loaded }
        expect(createdNames == ["Studio"] && createdID == "one", "Create then open its detail page")
        expect(memberRequests == 1 && !model.loading, "Created group details are prefetched before navigation")
        expect(!model.hasChanges && model.title == "Studio", "Loaded name is the saved baseline")
        model.save()
        expect(!model.busy && renames.isEmpty, "Unchanged name must not save")
        model.name = "  Design team  "
        failRename = true
        model.save()
        try await settle { !model.busy }
        expect(model.hasChanges && model.error != nil, "Save failure retains the draft")
        failRename = false
        model.save()
        try await settle { !model.busy }
        expect(renames == ["Design team"] && !model.hasChanges, "Save normalizes and updates the baseline")
        expect(model.title == "Design team", "Title follows saved group name")

        model.copyInvite()
        try await settle { !model.busy }
        expect(model.copied && copiedLinks.count == 1, "Copy is acknowledged in the button")
        model.copyInvite()
        try await settle { !model.busy }
        expect(inviteLimits == [1] && copiedLinks.count == 2, "Repeated copying reuses the created link")
        model.usageLimit = 5
        expect(!model.copied, "Changing invitation options clears feedback")
        model.copyInvite()
        try await settle { !model.busy }
        expect(inviteLimits == [1, 5], "New options generate a new invitation")

        model.open(.addMembers("one"))
        try await settle { model.loaded && !model.loading }
        let eligibleRequestsBeforeRemoval = eligibleRequests
        model.open(.details("one"))
        model.removeMember(owner)
        expect(!model.busy, "Owner cannot remove themselves as a member")
        model.removeMember(friend)
        try await settle { !model.busy }
        expect(removedMembers == ["friend"] && model.members?.members.count == 1, "Remove updates displayed members")

        model.open(.addMembers("one"))
        expect(model.loaded && model.loading, "Stale eligible friends stay rendered while revalidating")
        try await settle { model.loaded && !model.loading }
        expect(
            eligibleRequests == eligibleRequestsBeforeRemoval + 1 && model.eligibleMembers.map(\.id) == ["friend"],
            "Removing a member invalidates the eligible-friends cache"
        )
        let loadedEligibleRequests = eligibleRequests
        model.open(.details("one"))
        model.open(.addMembers("one"))
        expect(model.loaded && !model.loading, "Cached eligible friends render synchronously")
        expect(eligibleRequests == loadedEligibleRequests, "Fresh eligible friends aren't requested twice")
        model.selectedMembers = ["new-friend"]
        model.addMembers { model.open(.details($0)) }
        try await settle { !model.busy && model.loaded }
        expect(added == ["new-friend"] && model.page == .details("one"), "Adding returns to group details")

        ownerAccess = false
        model.open(.details("one"))
        model.reload()
        try await settle { model.loaded && !model.loading }
        model.name = "Unauthorized rename"
        model.save()
        model.removeMember(friend)
        expect(!model.busy && renames.count == 1 && removedMembers.count == 1, "Members cannot edit owner-only controls")
        model.remove { model.open(.list) }
        try await settle { !model.busy && model.loaded }
        expect(removed == [false] && model.page == .list, "Non-owner leaves instead of deleting")

        slowDetails = true
        model.open(.details("one"))
        model.reload()
        model.open(.create)
        try await Task.sleep(for: .milliseconds(60))
        expect(model.page == .create && model.members == nil && model.name.isEmpty, "Stale reads cannot replace a new page")
        expect(refreshes == 5, "Successful group changes refresh the popover")
        print("Native groups checks passed: \(checks)")
    }
}
