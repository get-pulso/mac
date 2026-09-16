import Alamofire
import Defaults
import Dependencies
import SwiftUI

@MainActor
final class SocialStore: ObservableObject {
    // MARK: Internal

    enum CopiedItem: Equatable { case friendCode, inviteLink }

    enum FeedbackToast: Equatable {
        case loading(String)
        case success(String)

        // MARK: Internal

        var message: String {
            switch self {
            case let .loading(message),
                 let .success(message): message
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }
    }

    enum Screen: Hashable { case list, connect, requests, person(String) }

    /// Which way the last screen change went. Forward pushes deeper (a tap on
    /// a row, on Invite, on Sent requests); back returns (Back, Escape, a
    /// finished flow). The screens drift in that direction, so the eye is
    /// told where it is going: we fly instead of teleport.
    enum Direction { case forward, back }

    /// The last screen change, as a whole: where it came from, where it went
    /// and which way that is. Transitions read this while they run, so the
    /// outgoing screen, which is no longer updated, still drifts the right way.
    struct Navigation {
        var from: Screen = .list
        var to: Screen = .list
        var direction: Direction = .forward
    }

    /// The invite flow, one tray at a time. A tray is a surface that grows out
    /// of the Invite button and sits over the list; each case is one piece of
    /// information or one action, never both. Checking, found and error for a
    /// pasted link are all `.candidate(.token)` and read from the invite
    /// lookup state; your own code is `.candidate(.friendCode)` compared with
    /// `personalInvite`.
    enum Tray: Hashable {
        case home, incoming, candidate(InviteInput), sent, joined(String), sentRequests

        // MARK: Internal

        /// Trays that return somewhere on Back. The others close on ×.
        var canGoBack: Bool {
            switch self {
            case .incoming,
                 .candidate,
                 .sentRequests: true
            case .home,
                 .sent,
                 .joined: false
            }
        }

        /// Trays where the invitation field is on screen. It is one view on
        /// both, so typing carries across the change.
        var showsField: Bool {
            switch self {
            case .home,
                 .candidate: true
            default: false
            }
        }

        /// The screen that showed this content before the tray existed.
        var legacyScreen: Screen {
            switch self {
            case .sentRequests: .requests
            default: .connect
            }
        }
    }

    /// What the tray grows out of. A deep link or the status-item menu opens
    /// the popover and the tray together, so there is nothing to grow from.
    enum TrayOrigin: Hashable { case footerInvite, emptyState, none }

    /// The last tray change, read by transitions while they run, like
    /// `Navigation` for screens. `to == nil` is the tray closing.
    struct TrayNavigation {
        var from: Tray?
        var to: Tray?
        var direction: Direction = .forward
    }

    /// The tray replaces the old Add friends and Sent requests screens. Off,
    /// every tray call falls back to those screens; they stay in the code
    /// until the tray has every step and its edge cases.
    static var inviteTrayEnabled = true

    /// One motion for every screen change, so a tap, Back and Escape all read
    /// the same way. The same spring as an iOS navigation push: about 0.4 s
    /// with a hint of overshoot, so the flying avatar lands instead of stops.
    static let screenTransition: Animation = .spring(duration: 0.42, bounce: 0.16)

    /// Rows finding their new place after a refresh, and rare-flow rows
    /// leaving: shorter than a screen change, no overshoot, so a list settling
    /// never competes with a screen arriving.
    static let settle: Animation = .spring(duration: 0.34, bounce: 0)

    static let shared = SocialStore()

    /// Not published on purpose: it changes together with `screen` or `tab`,
    /// which already redraw, and transitions read it directly while animating.
    private(set) var navigation = Navigation()

    /// +1 when the chosen tab sits to the right of the current one, -1 to the
    /// left. The list slides the same way the finger went along the tab strip.
    private(set) var tabDirection: CGFloat = 1

    /// Requests accepted in this session. Their rows leave towards the list
    /// where the new friend now lives, instead of merely fading.
    private(set) var acceptedRequestIDs = Set<String>()

    /// True from the moment an invitation is sent or accepted until the
    /// field is typed in again. The banner reads it to leave downwards, to
    /// where the sent request is counted; a dismissed banner merely fades.
    private(set) var inviteDeparting = false

    /// The open tray, or nil when the list (or a profile) stands alone.
    @Published private(set) var tray: Tray?
    /// True while the tray's own data (your code, the requests) is loading.
    @Published private(set) var trayLoading = false
    private(set) var trayOrigin: TrayOrigin = .none
    private(set) var trayNavigation = TrayNavigation()

    @Published var screen: Screen = .list
    @Published var tab = "friends"
    @Published private(set) var period = SocialStore.storedPeriod
    @Published var groups: [NativeGroup] = []
    /// The visible tab and period, as far as it has been scrolled. Rows beyond
    /// the first page arrive through `loadMore()`.
    @Published private(set) var peopleList = NativePeopleList.empty
    @Published private(set) var loadingMore = false
    @Published private(set) var loadMoreError: String?
    @Published var requests = NativeRequests()
    @Published var personalInvite: NativePersonalInvite?
    @Published private(set) var inviteInfo: NativeInviteInfo?
    @Published private(set) var checkingInvite = false
    @Published private(set) var inviteError: String?
    @Published var directFriendIDs = Set<String>()
    @Published var activity: NativeActivity?
    @Published var loading = true
    @Published var busy = false
    @Published var screenLoading = false
    @Published var operationLabel = "Saving…"
    @Published var operationKey: String?
    @Published var listError: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var feedbackToast: FeedbackToast?
    @Published var query = ""
    @Published private(set) var copiedItem: CopiedItem?
    @Published var selectedPerson: NativePerson?
    @Dependency(\.network) var network

    /// What the field currently holds, read as an invitation. A code is only
    /// offered once it is long enough to be one, so half-typed input stays quiet.
    var inviteCandidate: InviteInput? {
        let value = self.trimmedQuery
        guard !value.isEmpty else { return nil }
        if value.contains("://") { return try? InviteInput.parse(value) }
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 6, compact.count <= 24,
              compact.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else { return nil }
        return try? InviteInput.parse(compact)
    }

    var trimmedQuery: String { self.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var people: [NativePerson] { self.peopleList.items }

    /// People waiting on an answer. Shown on the Invite button itself, so the
    /// only way to learn about a request is not to open the tray.
    var incomingRequestCount: Int { self.requests.incoming.count }

    var previousScreen: Screen? { self.navigationHistory.previous }
    var hasLoadedCurrentList: Bool { self.listCache.contains(self.tab + self.period) }

    /// Where a person stands in the ranking on screen. A loaded row knows its
    /// own place; the caller's pinned row answers for itself when it sits
    /// below everything that has been scrolled in. A profile reached from
    /// anywhere but the ranking has no place to show.
    func place(of id: String) -> Int? {
        if let index = peopleList.items.firstIndex(where: { $0.id == id }) {
            return LeaderboardPlace.place(rank: self.peopleList.items[index].rank, loadedIndex: index)
        }
        guard let me = peopleList.me, me.id == id else { return nil }
        return LeaderboardPlace.place(rank: me.rank, loadedIndex: nil)
    }

    func hasLoaded(_ screen: Screen) -> Bool {
        switch screen {
        case .requests: self.requestsCache.contains("requests")
        case .connect: self.personalInviteCache.contains("invite")
        default: true
        }
    }

    func setPeriod(_ period: String) {
        guard Self.supportedPeriods.contains(period), self.period != period else { return }
        self.period = period
        UserDefaults.standard.set(period, forKey: Self.periodDefaultsKey)
    }

    func goBack() {
        guard let previous = navigationHistory.pop() else {
            self.showList()
            return
        }
        self.navigate(to: previous, direction: .back)
    }

    func showList(notice: String? = nil) {
        self.navigationHistory.removeAll()
        self.navigate(to: .list, direction: .back)
        self.notice = notice
    }

    /// Switches the list to another tab with a slide in the direction the tab
    /// lies: Friends → a group → Leaderboard moves right, and back moves left.
    func selectTab(_ id: String) {
        guard id != self.tab else { return }
        self.tabDirection = self.tabIndex(id) >= self.tabIndex(self.tab) ? 1 : -1
        withAnimation(Self.screenTransition) { self.tab = id }
    }

    /// The tab next to the current one, for ⌘⇧[ and ⌘⇧]. Stops at either
    /// end instead of wrapping, so the slide always matches the key pressed.
    func selectAdjacentTab(_ step: Int) {
        let order = ["friends"] + self.groups.map(\.id) + ["global"]
        guard let index = order.firstIndex(of: self.tab) else { return }
        let next = index + step
        guard order.indices.contains(next) else { return }
        self.selectTab(order[next])
    }

    func refresh(force: Bool = false) async {
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let key = selectedTab + selectedPeriod
        if self.displayedListKey != key {
            self.peopleList = self.listCache.value(for: key) ?? .empty
            self.displayedListKey = key
            self.listError = nil
            self.loadMoreError = nil
        }
        if let cachedGroups = self.groupsCache.value(for: "groups") { self.groups = cachedGroups }
        if !force,
           self.listCache.isFresh(key, for: Self.cacheLifetime),
           self.groupsCache.isFresh("groups", for: Self.cacheLifetime),
           self.requestsCache.isFresh("requests", for: Self.cacheLifetime)
        {
            if !self.refreshingList { self.loading = false }
            return
        }

        let id = UUID()
        self.refreshID = id
        self.refreshingList = true
        self.loading = true
        defer {
            if self.refreshID == id {
                self.loading = false
                self.refreshingList = false
            }
        }

        async let loadedGroups: [NativeGroup] = self.network.request(path: "/api/groups", method: .get)
        // Re-request exactly what is on screen so every loaded row is current
        // and nothing under the cursor moves.
        async let loadedPeople: NativeLeaderboardPage = self.network.request(
            path: "/api/friends/leaderboard", method: .get,
            query: Self.leaderboardQuery(
                tab: selectedTab, period: selectedPeriod, limit: self.peopleList.refreshLimit, offset: 0
            )
        )
        // The Invite button carries the number of people waiting on an
        // answer, so the requests come with the list. Optional: a failure here
        // costs a badge, not the list.
        async let loadedRequests: NativeRequests? = try? self.network
            .request(path: "/api/friends/requests", method: .get)

        var newGroups: [NativeGroup]?
        var newPeople: NativeLeaderboardPage?
        var failures: [String] = []
        do { newGroups = try await loadedGroups }
        catch { if !(error is CancellationError) { failures.append(error.localizedDescription) } }
        do { newPeople = try await loadedPeople }
        catch { if !(error is CancellationError) { failures.append(error.localizedDescription) } }
        let newRequests = await loadedRequests

        guard self.refreshID == id, Defaults[.currentUserID] != nil else { return }
        if let newRequests {
            self.requests = newRequests
            self.requestsCache.insert(newRequests, for: "requests")
        }
        if let newGroups {
            self.groups = newGroups.filter { $0.id != "global" }
            self.groupsCache.insert(self.groups, for: "groups")
            if selectedTab != "friends", selectedTab != "global",
               !self.groups.contains(where: { $0.id == selectedTab })
            {
                self.listError = nil
                self.selectTab("friends")
                return
            }
        }
        if let newPeople {
            self.peopleList = self.peopleList.refreshed(with: newPeople)
            self.listCache.insert(self.peopleList, for: key)
            if let selectedID = self.selectedPerson?.id,
               let refreshedPerson = self.peopleList.items.first(where: { $0.id == selectedID })
               ?? (self.peopleList.me?.id == selectedID ? self.peopleList.me : nil)
            {
                self.selectedPerson = refreshedPerson
            }
        }
        self.listError = failures.first
    }

    /// Appends the next page of the visible list. The sentinel row under the
    /// list calls this whenever it is on screen, so a request cancelled by
    /// scrolling away simply runs again when the row comes back.
    func loadMore() async {
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let key = selectedTab + selectedPeriod
        guard self.displayedListKey == key, !self.loadingMore, let offset = self.peopleList.nextOffset else { return }
        self.loadingMore = true
        self.loadMoreError = nil
        defer { self.loadingMore = false }
        do {
            let page: NativeLeaderboardPage = try await self.network.request(
                path: "/api/friends/leaderboard", method: .get,
                query: Self.leaderboardQuery(
                    tab: selectedTab, period: selectedPeriod, limit: NativePeopleList.pageSize, offset: offset
                )
            )
            guard self.displayedListKey == key, Defaults[.currentUserID] != nil else { return }
            self.peopleList = self.peopleList.appending(page)
            // The list grew, but it is no fresher than its first page.
            self.listCache.update(self.peopleList, for: key)
        } catch {
            guard !(error is CancellationError), self.displayedListKey == key else { return }
            self.loadMoreError = error.localizedDescription
        }
    }

    func open(_ next: Screen) {
        if next == .list {
            self.showList()
            return
        }
        // Opening the screen fresh must not surface the last invitation typed.
        if next == .connect, self.screen != .connect { self.clearQuery() }
        self.navigationHistory.record(self.screen, before: next)
        self.navigate(to: next)
    }

    // MARK: Tray

    /// Opens the tray from wherever the tap came from. With the tray closed
    /// the history starts over and, for Home, so does the field. With it open
    /// this is a push, so `openTray(.candidate)` from a deep link lands on top
    /// of whatever was there.
    func openTray(_ tray: Tray = .home, from origin: TrayOrigin = .none) {
        guard Self.inviteTrayEnabled else {
            self.open(tray.legacyScreen)
            return
        }
        if self.tray == nil {
            self.trayOrigin = origin
            self.trayHistory.removeAll()
            if tray == .home { self.clearQuery() }
            self.restoreCachedValue(for: .connect)
            self.present(tray, direction: .forward)
            self.refreshTray()
        } else {
            self.pushTray(tray)
        }
    }

    /// One tray deeper. Back returns here.
    func pushTray(_ next: Tray) {
        guard Self.inviteTrayEnabled else {
            self.open(next.legacyScreen)
            return
        }
        guard let current = self.tray else {
            self.openTray(next)
            return
        }
        guard current != next else { return }
        self.trayHistory.record(current, before: next)
        self.present(next, direction: .forward)
    }

    /// ← on a tray that has somewhere to go, × otherwise. Escape and ⌘[ both
    /// land here. Leaving a candidate clears the field, so Home comes back
    /// clean and the same code is not offered again.
    func trayBack() {
        guard Self.inviteTrayEnabled else {
            self.goBack()
            return
        }
        guard let current = self.tray else { return }
        guard current.canGoBack, let previous = self.trayHistory.pop() else {
            self.closeTray()
            return
        }
        if case .candidate = current {
            NativeSession.shared.pendingInvite = nil
            self.clearQuery()
        }
        self.present(previous, direction: .back)
    }

    /// Shrinks the tray back into the button. Nothing in flight is cancelled:
    /// closing the tray does not take back a request.
    func closeTray() {
        guard Self.inviteTrayEnabled else {
            self.showList()
            return
        }
        guard let current = self.tray else { return }
        self.trayNavigation = TrayNavigation(from: current, to: nil, direction: .back)
        self.trayHistory.removeAll()
        self.trayTask?.cancel()
        self.trayLoading = false
        self.error = nil
        withAnimation(Self.screenTransition) { self.tray = nil }
    }

    /// Reloads your code and the requests for the open tray.
    func refreshTray(force: Bool = false) {
        guard self.tray != nil else { return }
        if !force, self.isFresh(.connect) { return }
        self.trayTask?.cancel()
        self.trayLoading = true
        self.trayTask = Task {
            defer { if !Task.isCancelled { self.trayLoading = false } }
            do { try await self.loadInviteData() } catch {
                if !Task.isCancelled, self.tray != nil { self.error = error.localizedDescription }
            }
        }
    }

    func isRunning(_ key: String) -> Bool { self.busy && self.operationKey == key }

    func run(_ label: String = "Saving…", key: String = "action", _ operation: @escaping () async throws -> Void) {
        guard !self.busy else { return }
        self.busy = true
        self.operationLabel = label
        self.operationKey = key
        self.error = nil
        let accountID = Defaults[.currentUserID]
        Task {
            defer { busy = false; operationKey = nil }
            do { try await operation() } catch {
                if Defaults[.currentUserID] == accountID,
                   !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func retry() {
        if self.screen == .list { Task { await self.refresh(force: true) } }
        else { self.navigate(to: self.screen, forceRefresh: true) }
    }

    func refreshCurrentScreen(force: Bool = false) {
        if self.screen == .list { Task { await self.refresh(force: force) } }
        else {
            if case .person = self.screen { Task { await self.refresh(force: force) } }
            self.navigate(to: self.screen, forceRefresh: force)
        }
        self.refreshTray(force: force)
    }

    func invalidateActivity(for userID: String) {
        for period in ["24h", "7d", "30d"] { self.activityCache.invalidate(userID + period) }
        if case let .person(id) = self.screen, id == userID { self.activity = nil }
    }

    func refreshPersonIfVisible(_ userID: String) {
        guard case let .person(id) = self.screen, id == userID else { return }
        self.navigate(to: self.screen, forceRefresh: true)
    }

    func removeDirectFriend(_ id: String) {
        self.directFriendIDs.remove(id)
        if self.directFriendsCache.contains("friends") {
            self.directFriendsCache.insert(self.directFriendIDs, for: "friends")
        } else {
            self.directFriendsCache.invalidate("friends")
        }
    }

    /// Moves a group within the strip and stores the arrangement. The strip
    /// changes at once; the server confirms in the background, and a failure
    /// restores the stored order so the strip never lies about what is kept.
    func moveGroup(_ id: String, to index: Int) {
        guard let from = self.groups.firstIndex(where: { $0.id == id }),
              from != index, self.groups.indices.contains(index)
        else { return }
        var reordered = self.groups
        reordered.insert(reordered.remove(at: from), at: index)
        self.groups = reordered
        self.groupsCache.insert(reordered, for: "groups")
        let order = reordered.map(\.id)
        let accountID = Defaults[.currentUserID]
        self.groupOrderTask?.cancel()
        self.groupOrderTask = Task {
            do {
                let saved: [NativeGroup] = try await self.network.request(
                    path: "/api/groups/order", method: .put, body: ["order": order]
                )
                guard !Task.isCancelled, Defaults[.currentUserID] == accountID else { return }
                // A later move already changed the strip; its own request answers for it.
                guard self.groups.map(\.id) == order else { return }
                let visible = saved.filter { $0.id != "global" }
                self.groups = visible
                self.groupsCache.insert(visible, for: "groups")
                SettingsWindowController.shared.invalidateGroups()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      Defaults[.currentUserID] == accountID else { return }
                self.error = "Couldn't save the group order. \(error.localizedDescription)"
                self.groupsCache.invalidate("groups")
                await self.refresh(force: true)
            }
        }
    }

    func mutate(_ path: String, method: HTTPMethod = .post, body: Encodable? = nil) async throws {
        let _: NativeAck = try await network.request(path: path, method: method, body: body)
    }

    func loadRequests() async throws {
        self.requests = try await self.network.request(path: "/api/friends/requests", method: .get)
        self.requestsCache.insert(self.requests, for: "requests")
    }

    func respond(_ id: String, action: String) {
        let accepted = action == "accept" ? self.requests.incoming.first(where: { $0.id == id })?.requester : nil
        // Marked before the request leaves, in its own update, so the row has
        // already picked up its leaving motion by the time it is removed.
        if accepted != nil { self.acceptedRequestIDs.insert(id) }
        self.run("Updating request…", key: "\(action)-request-\(id)") {
            if action == "cancel" { try await self.mutate("/api/friends/requests/\(id)", method: .delete) }
            else { try await self.mutate("/api/friends/requests/\(id)", body: ["action": action]) }
            if let accepted {
                self.directFriendIDs.insert(accepted.id)
                if self.directFriendsCache.contains("friends") {
                    self.directFriendsCache.insert(self.directFriendIDs, for: "friends")
                } else {
                    self.directFriendsCache.invalidate("friends")
                }
            }
            try await self.loadRequests()
            // A new friend is a rare, worthwhile moment: say so, briefly, in the
            // same place a copied link is confirmed.
            if let accepted { self.feedbackToast = .success("Now friends with \(accepted.displayName)") }
            await self.refresh(force: true)
        }
    }

    func copyPersonalInviteLink() {
        if let link = self.personalInvite?.personalInviteLink, !link.isEmpty {
            self.copy(link, feedback: .inviteLink)
            return
        }
        self.run("Preparing link…", key: "copy-invite-link") {
            let result: NativePersonalInvite = try await self.network
                .request(path: "/api/user/invite-link", method: .get)
            self.personalInvite = result
            self.personalInviteCache.insert(result, for: "invite")
            guard !result.personalInviteLink.isEmpty else {
                throw NativeError.message("Your invite link isn't ready yet.")
            }
            self.copy(result.personalInviteLink, feedback: .inviteLink)
        }
    }

    func copyGroupInvite(_ groupID: String) {
        guard !self.busy else { return }
        self.notice = nil
        self.feedbackToast = .loading("Creating link…")
        self.run("Creating invitation…", key: "copy-group-invite-\(groupID)") {
            do {
                struct Options: Encodable { let usageLimit: Int }
                let result: NativeInviteLink = try await self.network.request(
                    path: "/api/groups/\(groupID)/invite",
                    method: .post,
                    body: Options(usageLimit: 1)
                )
                self.writeToPasteboard(result.inviteLink)
                self.feedbackToast = .success("Copied")
            } catch {
                self.feedbackToast = nil
                throw error
            }
        }
    }

    func copyFriendCode(_ code: String) {
        self.copy(code, feedback: .friendCode)
    }

    /// A pasted link is looked up as soon as it lands, so the list can offer the
    /// invitation itself instead of a separate screen with a check button.
    func queryChanged() {
        self.inviteLookup?.cancel()
        self.inviteError = nil
        self.checkingInvite = false
        self.inviteDeparting = false
        self.syncCandidateTray()
        guard case let .token(token)? = self.inviteCandidate else {
            self.inviteInfo = nil
            self.lookedUpToken = nil
            return
        }
        guard self.lookedUpToken != token else { return }
        self.inviteInfo = nil
        self.lookedUpToken = nil
        self.checkingInvite = true
        self.inviteLookup = Task {
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            do {
                let info: NativeInviteInfo = try await self.network
                    .request(path: "/api/invite/info", method: .get, query: ["token": token])
                guard !Task.isCancelled else { return }
                self.inviteInfo = info
                self.lookedUpToken = token
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.inviteError = error.localizedDescription
            }
            self.checkingInvite = false
        }
    }

    func addFromQuery() {
        guard let candidate = self.inviteCandidate else { return }
        // Set before the request, in its own update, so the banner already
        // carries its leaving motion when the reply removes it.
        self.inviteDeparting = true
        switch candidate {
        case let .friendCode(code):
            self.run("Sending request…", key: "accept-invite") {
                do { try await self.mutate("/api/friends/request", body: ["inviteCode": code]) }
                catch { self.inviteDeparting = false; throw error }
                self.finishInvite(notice: "Friend request sent.", tray: .sent)
                try? await self.loadRequests()
                await self.refresh(force: true)
            }
        case let .token(token):
            let groupName = self.inviteInfo?.invite.groupName ?? "the group"
            self.run("Joining…", key: "accept-invite") {
                do { try await self.mutate("/api/invite/accept", body: ["token": token]) }
                catch { self.inviteDeparting = false; throw error }
                SettingsWindowController.shared.invalidateGroups()
                self.finishInvite(notice: "Invitation accepted.", tray: .joined(groupName))
                await self.refresh(force: true)
            }
        }
    }

    /// Dismissing a shared invite must not revoke the sender's link for others.
    func dismissInvite() {
        NativeSession.shared.pendingInvite = nil
        self.inviteDeparting = false
        self.clearQuery()
    }

    func clearQuery() {
        self.inviteLookup?.cancel()
        self.query = ""
        self.inviteInfo = nil
        self.inviteError = nil
        self.checkingInvite = false
        self.lookedUpToken = nil
    }

    func reset() {
        self.refreshID = UUID()
        self.screenTask?.cancel(); self.screenLoading = false; self.activityCache.removeAll(); self.listError = nil
        self.listCache.removeAll(); self.groupsCache.removeAll(); self.displayedListKey = ""; self.navigationHistory
            .removeAll()
        self.screen = .list; self.tab = "friends"; self.groups = []; self.peopleList = .empty
        self.navigation = Navigation(); self.tabDirection = 1; self.acceptedRequestIDs = []; self
            .inviteDeparting = false
        self.trayTask?.cancel(); self.tray = nil; self.trayLoading = false; self.trayOrigin = .none
        self.trayNavigation = TrayNavigation(); self.trayHistory.removeAll()
        self.loadingMore = false; self.loadMoreError = nil
        self.requests = NativeRequests()
        self.personalInvite = nil; self.selectedPerson = nil
        self.activity = nil
        self.inviteLookup?.cancel(); self.query = ""; self.inviteInfo = nil
        self.inviteError = nil; self.checkingInvite = false; self.lookedUpToken = nil
        self.error = nil; self.notice = nil; self.feedbackToast = nil
        self.copiedItem = nil
        self.copyFeedbackTask?.cancel()
        self.directFriendIDs = []
        self.requestsCache.removeAll(); self.personalInviteCache.removeAll(); self.directFriendsCache.removeAll()
        self.loading = true
        self.refreshingList = false
        self.busy = false; self.operationKey = nil
    }

    // MARK: Private

    private static let cacheLifetime: TimeInterval = 30
    private static let periodDefaultsKey = "firstlight.activityPeriod"
    private static let supportedPeriods = Set(["24h", "7d", "30d"])

    private static var storedPeriod: String {
        let stored = UserDefaults.standard.string(forKey: self.periodDefaultsKey) ?? "24h"
        return self.supportedPeriods.contains(stored) ? stored : "24h"
    }

    private var screenTask: Task<Void, Never>?
    private var trayTask: Task<Void, Never>?
    private var navigationHistory = NativeNavigationHistory<Screen>()
    private var trayHistory = NativeNavigationHistory<Tray>()
    private var listCache = NativeResourceCache<String, NativePeopleList>()
    private var groupsCache = NativeResourceCache<String, [NativeGroup]>()
    private var displayedListKey = ""
    private var activityCache = NativeResourceCache<String, NativeActivity>()
    private var requestsCache = NativeResourceCache<String, NativeRequests>()
    private var personalInviteCache = NativeResourceCache<String, NativePersonalInvite>()
    private var directFriendsCache = NativeResourceCache<String, Set<String>>()
    private var refreshID = UUID()
    private var refreshingList = false
    private var groupOrderTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
    private var inviteLookup: Task<Void, Never>?
    private var lookedUpToken: String?

    private static func leaderboardQuery(tab: String, period: String, limit: Int, offset: Int) -> [String: String?] {
        [
            "period": period,
            "group_id": tab == "friends" ? nil : tab,
            "profiles": "true",
            "limit": String(limit),
            "offset": String(offset),
        ]
    }

    /// Position along the tab strip: Friends, then the groups in order, then
    /// the Leaderboard. A group that has already gone counts as Friends.
    private func tabIndex(_ id: String) -> Int {
        switch id {
        case "friends": 0
        case "global": self.groups.count + 1
        default: self.groups.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        }
    }

    /// With the tray open, the result is its own tray and needs no toast. It
    /// is shown before the field clears, so the emptied field does not pull
    /// Home back over it.
    private func finishInvite(notice: String, tray: Tray) {
        NativeSession.shared.pendingInvite = nil
        if Self.inviteTrayEnabled, self.tray != nil {
            self.trayHistory.removeAll()
            self.present(tray, direction: .forward)
        } else {
            self.notice = notice
        }
        self.clearQuery()
    }

    private func copy(_ value: String, feedback: CopiedItem) {
        self.writeToPasteboard(value)
        self.notice = nil
        self.copiedItem = feedback
        self.copyFeedbackTask?.cancel()
        self.copyFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, self?.copiedItem == feedback else { return }
            self?.copiedItem = nil
        }
    }

    private func writeToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func navigate(to next: Screen, direction: Direction = .forward, forceRefresh: Bool = false) {
        self.screenTask?.cancel()
        // Recorded before the screen changes: the transitions of both the
        // leaving and the arriving screen read it as they run.
        if next != self.screen { self.navigation = Navigation(from: self.screen, to: next, direction: direction) }
        // Screens cross-fade and the tapped avatar flies between the list row
        // and the profile, so the switch itself has to carry an animation.
        withAnimation(Self.screenTransition) { self.screen = next }
        self.error = nil
        self.notice = nil
        self.feedbackToast = nil
        self.screenLoading = false
        self.restoreCachedValue(for: next)
        if next == .list { return }
        if !forceRefresh, self.isFresh(next) { return }
        self.screenLoading = true
        self.screenTask = Task {
            defer { if self.screen == next, !Task.isCancelled { self.screenLoading = false } }
            do {
                switch next {
                case .requests:
                    try await self.loadRequests()
                case .connect:
                    try await self.loadInviteData()
                case let .person(id):
                    // The leaderboard already supplies the visible total. Treat
                    // this fresher detail request as an optional enhancement so
                    // an empty/transient response never replaces known data with
                    // a low-level serialization error.
                    async let details: NativeActivity? = try? self.network.request(
                        path: "/api/user/activity",
                        method: .get,
                        query: ["user_id": id, "period": self.period]
                    )
                    async let direct: NativeDirectFriends? = try? self.network.request(
                        path: "/api/user/direct-friends",
                        method: .get
                    )
                    if let details = await details {
                        self.activity = details
                        self.activityCache.insert(details, for: id + self.period)
                    }
                    if let connections = await direct {
                        let ids = Set(connections.directFriendIds)
                        self.directFriendIDs = ids
                        self.directFriendsCache.insert(ids, for: "friends")
                    }
                default: break
                }
            } catch {
                if !Task.isCancelled, self.screen == next { self.error = error.localizedDescription }
            }
        }
    }

    /// The invite surface shows incoming requests and the user's own code, so
    /// it needs both before it is fully populated. Shared by the old Add
    /// friends screen and the tray.
    private func loadInviteData() async throws {
        async let loadedInvite: NativePersonalInvite = self.network
            .request(path: "/api/user/invite-link", method: .get)
        async let loadedRequests: NativeRequests = self.network
            .request(path: "/api/friends/requests", method: .get)
        let invite = try await loadedInvite
        let requests = try await loadedRequests
        self.personalInvite = invite
        self.personalInviteCache.insert(invite, for: "invite")
        self.requests = requests
        self.requestsCache.insert(requests, for: "requests")
    }

    /// The field decides the tray: a code or link long enough to be an
    /// invitation pushes Send request over Home, a changed one replaces it in
    /// place, and an emptied field comes back. Typing anywhere else, or with
    /// the tray closed, moves nothing.
    private func syncCandidateTray() {
        guard Self.inviteTrayEnabled, let current = self.tray else { return }
        switch (current, self.inviteCandidate) {
        case let (.home, candidate?):
            self.pushTray(.candidate(candidate))
        case let (.candidate(shown), candidate?) where shown != candidate:
            self.present(.candidate(candidate), direction: .forward)
        case (.candidate, nil):
            self.present(self.trayHistory.pop() ?? .home, direction: .back)
        default:
            break
        }
    }

    /// Moves to another tray. Recorded before the change, like `navigation`,
    /// so both the leaving and the arriving step read the same direction.
    private func present(_ next: Tray, direction: Direction) {
        self.trayNavigation = TrayNavigation(from: self.tray, to: next, direction: direction)
        self.error = nil
        withAnimation(Self.screenTransition) { self.tray = next }
    }

    private func restoreCachedValue(for screen: Screen) {
        switch screen {
        case .requests:
            if let cached = self.requestsCache.value(for: "requests") { self.requests = cached }
        case .connect:
            if let cached = self.personalInviteCache.value(for: "invite") { self.personalInvite = cached }
            if let cached = self.requestsCache.value(for: "requests") { self.requests = cached }
        case let .person(id):
            self.activity = self.activityCache.value(for: id + self.period)
            if let cached = self.directFriendsCache.value(for: "friends") { self.directFriendIDs = cached }
        case .list: break
        }
    }

    private func isFresh(_ screen: Screen) -> Bool {
        switch screen {
        case .list: true
        case .requests: self.requestsCache.isFresh("requests", for: Self.cacheLifetime)
        case .connect:
            self.personalInviteCache.isFresh("invite", for: Self.cacheLifetime) &&
                self.requestsCache.isFresh("requests", for: Self.cacheLifetime)
        case let .person(id):
            self.activityCache.isFresh(id + self.period, for: Self.cacheLifetime) &&
                self.directFriendsCache.isFresh("friends", for: Self.cacheLifetime)
        }
    }
}
