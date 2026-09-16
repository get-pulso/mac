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
                    path: "/api/groups/\(id)/members", method: .post, body: ["userIds": people]
                )
            },
            eligibleMembers: { id in
                async let friends: [NativePerson] = network.request(
                    path: "/api/friends/leaderboard", method: .get, query: ["period": "24h"]
                )
                async let direct: NativeDirectFriends = network.request(path: "/api/user/direct-friends", method: .get)
                async let members: NativeMembers = network.request(path: "/api/groups/\(id)/members", method: .get)
                let (people, connections, existing) = try await (friends, direct, members)
                let memberIDs = Set(existing.members.map(\.id))
                return people.filter { connections.directFriendIds.contains($0.id) && !memberIDs.contains($0.id) }
            },
            invite: { id, limit in
                let result: NativeInviteLink = try await network.request(
                    path: "/api/groups/\(id)/invite", method: .post, body: ["usageLimit": limit]
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
                    if let groups: [NativeGroup] = try? await network.request(path: "/api/groups", method: .get) {
                        SocialStore.shared.groups = groups.filter { $0.id != "global" }
                        let tab = SocialStore.shared.tab
                        if tab != "friends", tab != "global", !groups.contains(where: { $0.id == tab }) {
                            SocialStore.shared.tab = "friends"
                        }
                    }
                    await SocialStore.shared.refresh()
                }
            }
        )
    }
}
