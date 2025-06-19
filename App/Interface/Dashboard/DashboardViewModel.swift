import Combine
import Defaults
import Dependencies
import Foundation
import SwiftUI

@MainActor
final class DashboardViewModel: ObservableObject {
    // MARK: Lifecycle

    init() {
        self.bindData()
    }

    // MARK: Internal

    @Published var filter: TimeFilter = .last24h
    @Published var selectedGroup: String?
    @Published var groups: [UserGroup] = []
    @Published var leaderboard: [DashboardUserItem] = []

    func openSettings() {
        self.router.move(to: .settings)
    }

    func openWebClient() {
        NSWorkspace.shared.open(URL(string: "https://pulso.sh")!)
        self.window.hide()
    }

    // MARK: Private

    @Dependency(\.appRouter) private var router
    @Dependency(\.tracker) private var tracker
    @Dependency(\.storage) private var storage
    @Dependency(\.network) private var network
    @Dependency(\.windowManager) private var window

    private var subscriptions = Set<AnyCancellable>()

    private func bindData() {
        self.storage.groupsStream()
            .ignoreError()
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] groups in
                guard let self else { return }
                self.groups = groups
                if !groups.contains(where: { $0.id == self.selectedGroup }) {
                    self.selectedGroup = nil
                }
            })
            .store(in: &self.subscriptions)

        Publishers.CombineLatest(
            self.$selectedGroup,
            self.$filter
        ).flatMap { group, filter in
            @Dependency(\.storage) var storage
            if let group {
                return storage.friendStream(in: group, filter: filter)
                    .map { $0.map { DashboardUserItem(friend: $0, filter: filter) }}
            } else {
                return storage.friendsStream(filter: filter)
                    .map { $0.map { DashboardUserItem(friend: $0, filter: filter) }}
            }
        }
        .ignoreError()
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] leaderboard in
            withAnimation {
                self?.leaderboard = leaderboard
            }
        })
        .store(in: &self.subscriptions)

        Publishers.CombineLatest(
            self.window.isVisiblePublisher.filter { $0 },
            Timer.publish(every: 60, on: .main, in: .common).autoconnect().map { _ in }.prepend(())
        )
        .sink(receiveValue: { [weak self] _ in
            Task.detached {
                try await self?.sync()
            }
        })
        .store(in: &self.subscriptions)
    }

    private func sync() async throws {
        let userInfo = try await self.network.userInfo()
        Defaults[.currentUserID] = userInfo.user.id
        let leaderboard24h = try await self.network.leaderboard(groupId: "global", filter: .last24h)
        let leaderboard7d = try await self.network.leaderboard(groupId: "global", filter: .last7d)
        let friendIds = try await self.network.leaderboard(filter: .last7d).map(\.id)

        var friends: [Friend] = []
        for friend in leaderboard7d {
            guard let l24h = leaderboard24h.first(where: { $0.id == friend.id }) else {
                continue
            }
            let friend = Friend(
                id: friend.id,
                isGlobal: !friendIds.contains(friend.id),
                name: friend.name,
                avatar: friend.avatar,
                rank24h: l24h.rank,
                rank7d: friend.rank,
                minutes24h: l24h.activeMinutes,
                minutes7d: friend.activeMinutes,
                lastActiveAt: friend.lastActiveAt
            )
            friends.append(friend)
        }

        try self.storage.store(friends: friends)

        var groups = [UserGroup]()
        for (index, group) in userInfo.groups.enumerated() {
            let leaderboard = try await self.network.leaderboard(groupId: group.id, filter: .last24h)
            let group = UserGroup(
                id: group.id,
                name: group.name,
                index: index,
                users: leaderboard.map(\.id)
            )
            groups.append(group)
        }

        try self.storage.store(groups: groups)
    }
}

private extension DashboardUserItem {
    init(friend: Friend, filter: TimeFilter) {
        self.id = friend.id
        self.name = friend.name
        self.avatar = friend.avatar

        if Defaults[.currentUserID] == friend.id {
            self.lastActiveAt = .now
        } else {
            self.lastActiveAt = friend.lastActiveAt
        }
        switch filter {
        case .last24h:
            self.minutes = friend.minutes24h
        case .last7d:
            self.minutes = friend.minutes7d
        }
    }
}
