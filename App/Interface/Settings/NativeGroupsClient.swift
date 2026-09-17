import AppKit
import Dependencies

extension NativeGroupsClient {
    @MainActor static var live: Self {
        @Dependency(\.network) var network
        return Self(
            list: { try await network.request(path: "/api/groups", method: .get) },
            members: { id in try await network.request(path: "/api/groups/\(id)/members", method: .get) },
            create: { name in try await network.request(path: "/api/groups", method: .post, body: ["name": name]) },
            rename: { id, name in
                let _: NativeAck = try await network.request(
                    path: "/api/groups/\(id)/update", method: .patch, body: ["name": name]
                )
            },
            remove: { id, owner in
                let _: NativeAck = try await network.request(
                    path: "/api/groups/\(id)/\(owner ? "delete" : "leave")", method: .delete
                )
            },
            removeMember: { id, person in
                let _: NativeAck = try await network.request(
                    path: "/api/groups/\(id)/members/\(person)",
                    method: .delete
                )
            },
            addMembers: { id, people in
                let _: NativeAck = try await network.request(
                    path: "/api/groups/\(id)/invitations", method: .post, body: ["userIds": people]
                )
            },
            // Who can still be added is one question. It used to be asked as
            // three — the whole friends leaderboard, the caller's connections
            // and the group's roster — and answered by throwing nearly all of
            // it away. The server now answers it directly.
            eligibleMembers: { id in
                try await network.request(path: "/api/groups/\(id)/addable-members", method: .get)
            },
            invite: { id in
                let result: NativeInviteLink = try await network.request(
                    path: "/api/groups/\(id)/invite", method: .post
                )
                return result.inviteLink
            },
            copy: { link in
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(link, forType: .string)
            },
            didChange: { _ in
                // Refresh the popover without changing its navigation or opening it.
                Task {
                    await SocialStore.shared.refresh(force: true)
                }
            },
            knownGroups: { SocialStore.shared.groups }
        )
    }
}
