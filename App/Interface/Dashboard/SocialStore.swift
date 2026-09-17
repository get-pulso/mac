import Alamofire
import Combine
import Defaults
import Dependencies
import Nuke
import SwiftUI

@MainActor
final class SocialStore: ObservableObject {
    // MARK: Lifecycle

    init() {
        // The connection coming back is the retry nobody has to click: a
        // list that failed for want of it loads again as soon as there is one.
        self.reachabilityWatch = NativeReachability.shared.$isOnline
            .dropFirst().removeDuplicates().filter { $0 }
            .sink { [weak self] _ in self?.reloadAfterReconnect() }
    }

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

    /// What the popover shows under the tray: the list, one profile, or that
    /// person's photograph. Adding friends and the sent requests are trays,
    /// not screens. `.agents` is a person's agents at length: the card on
    /// their profile, opened out into a screen of its own.
    enum Screen: Hashable { case list, person(String), photo(String), app(String), agents(String) }

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

        /// A photograph is not another screen arriving beside this one: it is
        /// this screen's own portrait opening out of the avatar, and back into
        /// it. Nothing slides in either direction while that happens.
        var isPhoto: Bool {
            if case .photo = self.from { return true }
            if case .photo = self.to { return true }
            return false
        }

        /// Opening, as opposed to going back. The two are not the same move:
        /// one has to be followed, the other only has to be believed.
        var isOpening: Bool { self.direction == .forward }
    }

    /// The invite flow, one tray at a time. A tray is a surface that grows out
    /// of the Invite button and sits over the list; each case is one piece of
    /// information or one action, never both. Checking, found and error for a
    /// pasted link are all `.candidate(.token)` and read from the invite
    /// lookup state; your own code is `.candidate(.friendCode)` compared with
    /// `personalInvite`.
    enum Tray: Hashable {
        /// The candidate tray is identified by the kind of input, not by the
        /// text: typing the rest of a code changes the field, not the tray.
        /// What it shows is read from `inviteCandidate` as it is typed.
        case home, incoming, candidate(InviteInput.Kind), about(String), connected(String), joined(String),
             sentRequests

        // MARK: Internal

        /// Trays that return somewhere on Back. The others close on ×.
        var canGoBack: Bool {
            switch self {
            case .incoming,
                 .candidate,
                 .about,
                 .sentRequests: true
            case .home,
                 .connected,
                 .joined: false
            }
        }

        /// A friendship made by following the inviter's own link.
        var isConnected: Bool {
            if case .connected = self { return true }
            return false
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
    }

    /// One day of somebody's agents, open in a tray over the Agents screen.
    /// It grows out of the record that named the day, so it carries which
    /// one: `source` is that tile's id, and the words are the tile's own.
    struct AgentDayTray: Hashable {
        let date: String
        let title: String
        let note: String
        let source: String
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

    /// One motion for a tab change and for the tray. Screens themselves moved
    /// to `navigationTransition`; this is what is left that resizes the panel
    /// without anything flying across it. No overshoot, on purpose: this spring does not just carry
    /// the flying avatar, it drifts both screens and resizes the panel around
    /// them. A container that springs past its mark and comes back reads as a
    /// stutter rather than as weight, and the further a thing travels the wider
    /// that overshoot gets — over the length of the avatar's flight a bounce of
    /// 0.16 was several points of visible wobble. Overshoot belongs to a small
    /// object landing in open space, not to a 350 pt panel settling against its
    /// own edge. Shorter too, so the geometry is finished about when the screens
    /// have finished trading opacity instead of creeping on after them.
    static let screenTransition: Animation = .spring(duration: 0.38, bounce: 0)

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
    /// The group just joined from the tray, once the refreshed groups have
    /// arrived. The Joined tray's mark flies into this group's tab and the
    /// list moves to it under the veil. Cleared when the tray closes.
    @Published private(set) var joinedGroupID: String?

    @Published var screen: Screen = .list
    @Published var tab = "friends"
    @Published var showsApps = false
    private(set) var profilePeople: [String: NativePerson] = [:]
    var detailScrollOffsets: [Screen: CGFloat] = [:]
    @Published private(set) var period = SocialStore.storedPeriod
    /// `active` or `agent`; see `setMetric`.
    @Published private(set) var metric = SocialStore.storedMetric
    @Published var groups: [NativeGroup] = []
    /// The visible tab and period, as far as it has been scrolled. Rows beyond
    /// the first page arrive through `loadMore()`.
    @Published private(set) var peopleList = NativePeopleList.empty
    @Published private(set) var loadingMore = false
    @Published private(set) var loadMoreError: String?
    @Published var requests = NativeRequests()
    @Published var personalInvite: NativePersonalInvite?
    @Published private(set) var inviteInfo: NativeInviteInfo?
    /// Whose friend code sits in the field, once looked up. The tray shows the
    /// person, never the code: the code is the transport.
    @Published private(set) var inviter: NativeJoinInfo.Inviter?
    /// Who the people met through invitations are, once asked. Kept for the
    /// life of the popover, so stepping back into a card is instant.
    @Published private(set) var personCards: [String: NativePersonCard] = [:]
    @Published private(set) var cardLoading = false
    /// True while the code in the field is being looked up. A miss ends it
    /// with `inviter` still nil: the card then stops waiting for a face.
    @Published private(set) var checkingInviter = false
    @Published private(set) var checkingInvite = false
    @Published private(set) var inviteError: String?
    @Published var directFriendIDs = Set<String>()
    @Published var activity: NativeActivity?
    /// The open profile's coding agents. Loaded beside `activity`; nil until
    /// it answers, or when the person has none.
    @Published var agentSummary: NativeAgentSummary?
    private(set) var agentStreak = AgentAnalytics.streak(nil)
    private(set) var agentRecords: [AgentAnalytics.Record] = []
    @Published private(set) var agentDayTray: AgentDayTray?
    @Published var loading = true
    @Published var busy = false
    @Published var screenLoading = false
    @Published var operationLabel = "Saving…"
    @Published var operationKey: String?
    /// Why the visible list could not be loaded, or nil while it can. Set by
    /// `refresh`; cleared when the list changes or a refresh succeeds.
    @Published private(set) var listFailure: NativeLoadFailure?
    @Published var error: String?
    @Published var notice: String?
    @Published var feedbackToast: FeedbackToast?
    @Published var query = ""
    @Published private(set) var copiedItem: CopiedItem?
    /// Whose profile is open. Only the store writes it, and only with the
    /// person the profile screen is about; open a profile with `openPerson`.
    @Published private(set) var selectedPerson: NativePerson?
    @Dependency(\.network) var network

    /// The same person's last thirty days, whatever the period: streaks and
    /// records are read from it, so they do not change with the zoom.
    @Published private(set) var agentMonth: NativeAgentSummary? {
        didSet {
            // Read out of the month once, when it lands. The screen's body
            // runs on every scroll tick and every frame of a push, and going
            // through thirty days of runs there is what made it stall.
            self.agentStreak = AgentAnalytics.streak(self.agentMonth)
            self.agentRecords = self.agentMonth.map(AgentAnalytics.records) ?? []
        }
    }

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

    /// A link is the inviter's own consent, so following one makes friends at
    /// once. A bare code, typed or pasted, still asks its owner.
    var queryIsLink: Bool { self.trimmedQuery.contains("://") }

    /// People waiting on an answer. Shown on the Invite button itself, so the
    /// only way to learn about a request is not to open the tray.
    var incomingRequestCount: Int { self.requests.incoming.count }

    var previousScreen: Screen? { self.navigationHistory.previous }

    var previousTray: Tray? { self.trayHistory.previous }
    var hasLoadedCurrentList: Bool { self.listCache.contains(self.listKey) }

    /// One cached list per tab, period and metric.
    var listKey: String { self.tab + self.period + (self.metric == "active" ? "" : "|" + self.metric) }

    /// How one screen becomes another: the profile opening out of a row, the
    /// portrait out of the profile, and both of them folding back. This is the
    /// curve iOS opens a picture out of its thumbnail with — most of the
    /// distance covered in the first third, then a long flat landing with no
    /// bounce at the end. Every one of these changes has something flying
    /// across the panel, and a spring that settles in its own time leaves the
    /// flight arriving after the screen has stopped.
    ///
    /// Opening and closing take different lengths on purpose, the way every
    /// presentation on iOS does. Opening is the move the eye has to follow —
    /// a face growing to twenty times its area, into a screen that was not
    /// there a moment ago — and rushing it reads as a flicker rather than as
    /// a picture. Closing goes somewhere already known and already looked at,
    /// so it only has to be believed, and the shorter it is the more decisive
    /// it reads.
    static func navigationTransition(opening: Bool) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: opening ? 0.32 : 0.26)
    }

    /// Pulls the faces of a list into the image cache, so the rows that are
    /// built when the tab is chosen have their portraits on the first frame
    /// they draw rather than a frame or two later.
    static func warmPortraits(of people: [NativePerson]) {
        let links = people.compactMap { $0.avatar_url.flatMap(URL.init(string:)) }
        guard !links.isEmpty else { return }
        Self.portraitPrefetcher.startPrefetching(with: links)
    }

    func hasScreenInHistory(_ screen: Screen) -> Bool {
        self.navigationHistory.routes.contains(screen)
    }

    /// Where a person stands in the ranking on screen. A loaded row knows its
    /// own place; the caller's pinned row answers for itself when it sits
    /// below everything that has been scrolled in. A profile reached from
    /// anywhere but the ranking has no place to show.
    /// The zone somebody's own days are cut in, once their profile has been
    /// read. Nil until then, and for people who have never reported one.
    func timeZone(for id: String) -> TimeZone? {
        // Read from the cache by id, never from the open profile: this is
        // asked for a person, and the open one may be somebody else.
        guard let name = agentSummaryCache.value(for: id + self.period)?.time_zone
        else { return nil }
        return TimeZone(identifier: name)
    }

    func place(of id: String) -> Int? {
        if let index = peopleList.items.firstIndex(where: { $0.id == id }) {
            return LeaderboardPlace.place(rank: self.peopleList.items[index].rank, loadedIndex: index)
        }
        guard let me = peopleList.me, me.id == id else { return nil }
        return LeaderboardPlace.place(rank: me.rank, loadedIndex: nil)
    }

    func setPeriod(_ period: String) {
        guard Self.supportedPeriods.contains(period), self.period != period else { return }
        self.period = period
        UserDefaults.standard.set(period, forKey: Self.periodDefaultsKey)
    }

    /// What the ranking is by: a person's own active time, or the time their
    /// coding agents worked. The rows re-sort in place; the reorder is the
    /// whole story of the change.
    func setMetric(_ metric: String) {
        guard Self.supportedMetrics.contains(metric), self.metric != metric else { return }
        self.metric = metric
        UserDefaults.standard.set(metric, forKey: Self.metricDefaultsKey)
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

    /// Loads what the popover will open on, before it is opened.
    ///
    /// Nothing here is free at the moment of the click: every tab, every
    /// profile and the groups behind them are round trips, and a popover
    /// opened cold spends them in front of the user as a skeleton. A list
    /// only draws a skeleton while its cache has no entry at all, so one
    /// warm early in the session is what stands between every later tap and
    /// a spinner — afterwards a stale list is drawn at once and revalidated
    /// behind it.
    ///
    /// Safe to call as often as a signed-in user reaches for the menu bar: a
    /// fresh cache returns immediately, and identical requests already in
    /// flight are coalesced by the network layer.
    func warm() {
        guard Defaults[.currentUserID] != nil else { return }
        if !self.refreshingList,
           !self.listCache.isFresh(self.listKey, for: Self.cacheLifetime)
           || !self.groupsCache.isFresh("groups", for: Self.cacheLifetime)
        {
            Task {
                await self.refresh()
                self.warmOtherTabs()
            }
        } else {
            self.warmOtherTabs()
        }
    }

    /// The tabs beside the one that is showing. Switching tab changes the
    /// list's cache key, so a tab nobody has opened yet is as cold as the
    /// whole popover was: the group Serafim taps is a skeleton even though
    /// Friends came up instantly. These arrive quietly, one at a time, so a
    /// person with many groups does not open a burst of requests.
    func warmOtherTabs() {
        guard Defaults[.currentUserID] != nil, self.tabWarmTask == nil else { return }
        let period = self.period
        let metric = self.metric
        let pending = (["friends"] + self.groups.map(\.id) + ["global"])
            .map { ($0, $0 + period + (metric == "active" ? "" : "|" + metric)) }
            .filter { $0.0 != self.tab && !self.listCache.contains($0.1) }
        guard !pending.isEmpty else { return }
        self.tabWarmTask = Task {
            defer { tabWarmTask = nil }
            for (tab, key) in pending {
                guard Defaults[.currentUserID] != nil, !Task.isCancelled else { return }
                guard let page: NativeLeaderboardPage = try? await self.network.request(
                    path: "/api/friends/leaderboard", method: .get,
                    query: Self.leaderboardQuery(
                        tab: tab, period: period, metric: metric,
                        limit: NativePeopleList.pageSize, offset: 0
                    )
                ) else { continue }
                guard !self.listCache.contains(key) else { continue }
                self.listCache.insert(NativePeopleList.empty.refreshed(with: page), for: key)
                // The rows of a warmed tab are ready before it is asked for;
                // the faces in them were not, and a tab change builds every row
                // anew. Without this the portraits arrive over the slide
                // instead of before it.
                Self.warmPortraits(of: page.items)
            }
        }
    }

    /// The profile behind one row, before it is tapped. Hovering a row is a
    /// few hundred milliseconds of warning, which is most of what the profile
    /// costs; by the time the click lands the answer is usually already here.
    func warmPerson(_ id: String) {
        guard Defaults[.currentUserID] != nil,
              !self.activityCache.isFresh(id + self.period, for: Self.cacheLifetime),
              self.personWarmTasks[id] == nil else { return }
        let period = self.period
        self.personWarmTasks[id] = Task {
            defer { personWarmTasks[id] = nil }
            async let details: NativeActivity? = try? self.network.request(
                path: "/api/user/activity", method: .get,
                query: ["user_id": id, "period": period]
            )
            async let agents: NativeAgentSummary? = try? self.network.request(
                path: "/api/users/\(id)/agent-summary", method: .get,
                query: ["period": period, "tz": TimeZone.current.identifier]
            )
            if let details = await details { self.activityCache.insert(details, for: id + period) }
            if let summary = await agents { self.agentSummaryCache.insert(summary, for: id + period) }
        }
    }

    func refresh(force: Bool = false) async {
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let selectedMetric = self.metric
        let key = self.listKey
        if self.displayedListKey != key {
            self.peopleList = self.listCache.value(for: key) ?? .empty
            self.displayedListKey = key
            self.listFailure = nil
            self.loadMoreError = nil
        }
        if let cachedGroups = self.groupsCache.value(for: "groups") { self.groups = cachedGroups }
        if !force,
           self.listCache.isFresh(key, for: Self.cacheLifetime),
           self.groupsCache.isFresh("groups", for: Self.cacheLifetime),
           self.requestsCache.isFresh("requests", for: Self.cacheLifetime),
           self.personalInviteCache.contains("invite")
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
                tab: selectedTab, period: selectedPeriod, metric: selectedMetric,
                limit: self.peopleList.refreshLimit, offset: 0
            )
        )
        // The Invite button carries the number of people waiting on an
        // answer, so the requests come with the list. Optional: a failure here
        // costs a badge, not the list.
        async let loadedRequests: NativeRequests? = try? self.network
            .request(path: "/api/friends/requests", method: .get)
        // Your own code hardly ever changes, so it is fetched once with the
        // first list and kept: the tray opens with it already in place
        // instead of loading it on every tap. The tray still refreshes it
        // when its own cache goes stale.
        async let loadedInvite: NativePersonalInvite? = self.personalInviteCache.contains("invite") ? nil :
            try? self.network.request(path: "/api/user/invite-link", method: .get)
        // Who you are directly connected to is one answer for the whole
        // account, not one per profile. Fetched here, opening a person costs
        // the two requests that are actually about that person.
        async let loadedDirect: NativeDirectFriends? = self.directFriendsCache
            .isFresh("friends", for: Self.cacheLifetime) ? nil :
            try? self.network.request(path: "/api/user/direct-friends", method: .get)

        var newGroups: [NativeGroup]?
        var newPeople: NativeLeaderboardPage?
        var failures: [Error] = []
        do { newGroups = try await loadedGroups }
        catch { if !(error is CancellationError) { failures.append(error) } }
        do { newPeople = try await loadedPeople }
        catch { if !(error is CancellationError) { failures.append(error) } }
        let newRequests = await loadedRequests
        let newInvite = await loadedInvite
        let newDirect = await loadedDirect

        guard self.refreshID == id, Defaults[.currentUserID] != nil else { return }
        if let newRequests {
            self.requests = newRequests
            self.requestsCache.insert(newRequests, for: "requests")
        }
        if let newInvite {
            self.personalInvite = newInvite
            self.personalInviteCache.insert(newInvite, for: "invite")
        }
        if let newDirect {
            let ids = Set(newDirect.directFriendIds)
            self.directFriendIDs = ids
            self.directFriendsCache.insert(ids, for: "friends")
        }
        if let newGroups {
            self.groups = newGroups.filter { $0.id != "global" }
            self.groupsCache.insert(self.groups, for: "groups")
            if selectedTab != "friends", selectedTab != "global",
               !self.groups.contains(where: { $0.id == selectedTab })
            {
                self.listFailure = nil
                self.selectTab("friends")
                return
            }
        }
        if let newPeople {
            self.peopleList = self.peopleList.refreshed(with: newPeople)
            self.listCache.insert(self.peopleList, for: key)
            if let selectedID = self.selectedPerson?.id, let refreshedPerson = self.loadedPerson(selectedID) {
                self.selectedPerson = refreshedPerson
            }
        }
        // Classified now, not when shown: the path monitor answers for the
        // moment the request failed, not for whenever the list is next drawn.
        self.listFailure = failures.first.map {
            NativeLoadFailure($0.asAFError?.underlyingError ?? $0, online: NativeReachability.shared.isOnline)
        }
        if failures.isEmpty {
            // The tabs beside this one, and the profiles at the top of it:
            // whatever the next tap is likely to be, asked for now rather
            // than then. Bounded on purpose — a warm must not turn into a
            // burst of requests for rows nobody will open.
            self.warmOtherTabs()
            for person in self.peopleList.items.prefix(Self.warmedProfiles) {
                self.warmPerson(person.id)
            }
        }
    }

    /// Appends the next page of the visible list. The sentinel row under the
    /// list calls this whenever it is on screen, so a request cancelled by
    /// scrolling away simply runs again when the row comes back.
    func loadMore() async {
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let selectedMetric = self.metric
        let key = self.listKey
        guard self.displayedListKey == key, !self.loadingMore, let offset = self.peopleList.nextOffset else { return }
        self.loadingMore = true
        self.loadMoreError = nil
        defer { self.loadingMore = false }
        do {
            let page: NativeLeaderboardPage = try await self.network.request(
                path: "/api/friends/leaderboard", method: .get,
                query: Self.leaderboardQuery(
                    tab: selectedTab, period: selectedPeriod, metric: selectedMetric,
                    limit: NativePeopleList.pageSize, offset: offset
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
        if let person = self.selectedPerson { self.profilePeople[person.id] = person }
        if self.navigationHistory.returnTo(next) {
            self.navigate(to: next, direction: .back)
        } else {
            self.navigationHistory.record(self.screen, before: next)
            self.navigate(to: next)
        }
    }

    /// Opens someone's profile. The profile is drawn from `selectedPerson`, so
    /// the person goes in with the screen: one opened by id alone can only be
    /// someone already opened or in the list, and is empty otherwise.
    func openPerson(_ person: NativePerson) {
        if let current = self.selectedPerson { self.profilePeople[current.id] = current }
        self.profilePeople[person.id] = person
        self.selectedPerson = person
        self.open(.person(person.id))
    }

    /// The profile of a friend whose code is in the field. Their row when the
    /// list has one; otherwise who the code and their card say they are, and
    /// the profile asks for the rest by id, as it does for anyone.
    func openFriend(_ id: String) {
        let inviter = self.inviter?.inviterId == id ? self.inviter : nil
        let card = self.personCards[id]
        self.openPerson(self.loadedPerson(id) ?? NativePerson(
            user_id: id, name: inviter?.inviterName ?? card?.name,
            avatar_url: inviter?.inviterAvatarUrl ?? card?.avatar_url, rank: nil, active_minutes: nil,
            last_active_at: nil, bio: card?.bio, location: card?.location, website: card?.website,
            twitter: card?.twitter, telegram: card?.telegram, active_app: nil,
            agent: nil, agent_active_at: nil, score: nil
        ))
    }

    // MARK: Agents

    /// A person's agents at length. The person stays selected: the screen is
    /// theirs, and Back returns to the profile it was opened from.
    func openAgents(_ id: String) { self.open(.agents(id)) }

    func openAgentDay(_ day: AgentDayTray) {
        withAnimation(Self.screenTransition) { self.agentDayTray = day }
    }

    func closeAgentDay() {
        guard self.agentDayTray != nil else { return }
        // The tray's own closing curve, not the panel spring: a spring holds
        // the leaving tray in the tree until it settles. See `AgentTrayGrow`.
        withAnimation(AgentTrayGrow.animation(opening: false, reduceMotion: false)) { self.agentDayTray = nil }
    }

    // MARK: Tray

    /// Opens the tray from wherever the tap came from. With the tray closed
    /// the history starts over and, for Home, so does the field. With it open
    /// this is a push, so `openTray(.candidate)` from a deep link lands on top
    /// of whatever was there.
    func openTray(_ tray: Tray = .home, from origin: TrayOrigin = .none) {
        if self.tray == nil {
            self.trayOrigin = origin
            self.trayHistory.removeAll()
            if tray == .home { self.clearQuery() }
            self.restoreInviteData()
            self.present(tray, direction: .forward)
            self.refreshTray()
        } else {
            self.pushTray(tray)
        }
    }

    /// One tray deeper. Back returns here.
    func pushTray(_ next: Tray) {
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
        guard let current = self.tray else { return }
        self.trayNavigation = TrayNavigation(from: current, to: nil, direction: .back)
        self.trayHistory.removeAll()
        self.trayTask?.cancel()
        self.cardTask?.cancel()
        self.trayLoading = false
        self.cardLoading = false
        self.error = nil
        withAnimation(Self.screenTransition) {
            self.tray = nil
            self.joinedGroupID = nil
        }
    }

    /// Reloads your code and the requests for the open tray.
    func refreshTray(force: Bool = false) {
        guard self.tray != nil else { return }
        if !force, self.isInviteDataFresh { return }
        self.trayTask?.cancel()
        self.trayLoading = true
        self.trayTask = Task {
            defer { if !Task.isCancelled { self.trayLoading = false } }
            do { try await self.loadInviteData() } catch {
                if !Task.isCancelled, self.tray != nil { self.error = error.localizedDescription }
            }
        }
    }

    /// Opens the About tray for someone met through an invitation, and asks
    /// who they are. A card already read is shown at once and not asked for
    /// again; the tray is pushed either way, so Back always returns here.
    func openAbout(_ personID: String) {
        self.pushTray(.about(personID))
        guard self.personCards[personID] == nil else { return }
        self.cardTask?.cancel()
        self.cardLoading = true
        self.cardTask = Task {
            defer { if !Task.isCancelled { self.cardLoading = false } }
            do {
                let card: NativePersonCard = try await self.network
                    .request(path: "/api/users/\(personID)/card", method: .get)
                guard !Task.isCancelled else { return }
                self.personCards[personID] = card
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if self.tray == .about(personID) { self.error = error.localizedDescription }
            }
        }
    }

    func card(for personID: String) -> NativePersonCard? { self.personCards[personID] }

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
        for period in ["24h", "7d", "30d"] {
            self.activityCache.invalidate(userID + period)
            self.agentSummaryCache.invalidate(userID + period)
        }
        if case let .person(id) = self.screen, id == userID {
            self.activity = nil
            self.agentSummary = nil
        }
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

    /// A friendship made out of the popover's sight — accepted in the notch,
    /// or announced by it — goes into the direct set and its cache at once,
    /// as `respond` does for its own.
    func recordDirectFriend(_ id: String) {
        self.directFriendIDs.insert(id)
        if self.directFriendsCache.contains("friends") {
            self.directFriendsCache.insert(self.directFriendIDs, for: "friends")
        } else {
            self.directFriendsCache.invalidate("friends")
        }
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
                let result: NativeInviteLink = try await self.network.request(
                    path: "/api/groups/\(groupID)/invite",
                    method: .post
                )
                self.writeToPasteboard(result.inviteLink)
                self.feedbackToast = .success("Copied")
            } catch {
                self.feedbackToast = nil
                throw error
            }
        }
    }

    /// Adds a direct friend to a group the account created — the same call
    /// Settings makes, reached from the person's row.
    func addToGroup(_ person: NativePerson, group: NativeGroup) {
        guard !self.busy else { return }
        self.notice = nil
        self.feedbackToast = .loading("Adding to \(group.name)…")
        self.run("Adding to group…", key: "add-to-group-\(group.id)-\(person.id)") {
            do {
                try await self.mutate("/api/groups/\(group.id)/members", body: ["userIds": [person.id]])
                self.listCache.invalidateAll()
                SettingsWindowController.shared.invalidateGroups()
                self.feedbackToast = .success("Added to \(group.name)")
            } catch {
                self.feedbackToast = nil
                throw error
            }
        }
    }

    /// Takes a member out of a group the account created, from the group's list.
    func removeFromGroup(_ person: NativePerson, group: NativeGroup) {
        self.notice = nil
        self.run("Removing…", key: "remove-from-group-\(group.id)-\(person.id)") {
            try await self.mutate("/api/groups/\(group.id)/members/\(person.id)", method: .delete)
            self.listCache.invalidateAll()
            SettingsWindowController.shared.invalidateGroups()
            self.feedbackToast = .success("Removed from \(group.name)")
            await self.refresh(force: true)
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
        self.lookUpInviter()
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
            let fromLink = self.queryIsLink
            let name = self.inviter?.code == code ? self.inviter?.inviterName : nil
            self.run(fromLink ? "Adding…" : "Sending request…", key: "accept-invite") {
                let result: NativeFriendRequestResult
                do {
                    result = try await self.network.request(
                        path: "/api/friends/request",
                        method: .post,
                        body: ["inviteCode": code, "source": fromLink ? "link" : "code"]
                    )
                } catch { self.inviteDeparting = false; throw error }
                if result.connected == true {
                    let friend = name ?? result.targetUser?.name ?? "your friend"
                    self.finishInvite(notice: "You're friends now.", tray: .connected(friend))
                } else {
                    // A request is not a place to stand: it goes to where
                    // sent requests wait, and the tray is back where another
                    // one can be sent.
                    self.finishInvite(
                        notice: "Request sent to \(Self.firstName(name ?? result.targetUser?.name ?? "them"))",
                        tray: .home
                    )
                }
                try? await self.loadRequests()
                await self.refresh(force: true)
            }
        case let .token(token):
            let groupName = self.inviteInfo?.invite.groupName ?? "the group"
            let knownGroups = Set(self.groups.map(\.id))
            self.run("Joining…", key: "accept-invite") {
                do { try await self.mutate("/api/invite/accept", body: ["token": token]) }
                catch { self.inviteDeparting = false; throw error }
                SettingsWindowController.shared.invalidateGroups()
                self.finishInvite(notice: "Invitation accepted.", tray: .joined(groupName))
                await self.refresh(force: true)
                // The invitation only names the group; the refreshed list says
                // which one is new. A group known before (a re-used link) is
                // found by its name instead.
                guard self.tray == .joined(groupName) else { return }
                self.joinedGroupID = self.groups.first { !knownGroups.contains($0.id) }?.id
                    ?? self.groups.first { $0.name == groupName }?.id
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
        self.inviterLookup?.cancel()
        self.query = ""
        self.inviteInfo = nil
        self.inviter = nil
        self.inviteError = nil
        self.checkingInvite = false
        self.lookedUpToken = nil
    }

    #if DEBUG
    /// Drops every cached answer and asks again, so switching the invite
    /// mocks on or off swaps the data without signing anyone out.
    func reloadForMocks() {
        self.closeTray()
        self.listCache.removeAll(); self.groupsCache.removeAll(); self.requestsCache.removeAll()
        self.personalInviteCache.removeAll(); self.directFriendsCache.removeAll(); self.activityCache.removeAll()
        self.displayedListKey = ""
        self.peopleList = .empty
        self.personalInvite = nil
        self.requests = NativeRequests()
        self.directFriendIDs = []
        self.inviter = nil
        self.clearQuery()
        self.error = nil
        self.loading = true
        self.tab = "friends"
        Task { await self.refresh(force: true) }
    }
    #endif

    func reset() {
        self.refreshID = UUID()
        self.tabWarmTask?.cancel(); self.tabWarmTask = nil
        for task in self.personWarmTasks.values { task.cancel() }
        self.personWarmTasks.removeAll()
        self.screenTask?.cancel(); self.screenLoading = false; self.activityCache.removeAll(); self.listFailure = nil
        self.listCache.removeAll(); self.groupsCache.removeAll(); self.displayedListKey = ""; self.navigationHistory
            .removeAll()
        self.screen = .list; self.tab = "friends"; self.groups = []; self.peopleList = .empty
        self.showsApps = false; self.profilePeople.removeAll(); self.detailScrollOffsets.removeAll()
        self.navigation = Navigation(); self.tabDirection = 1; self.acceptedRequestIDs = []; self
            .inviteDeparting = false
        self.trayTask?.cancel(); self.cardTask?.cancel(); self.tray = nil; self.trayLoading = false
        self.cardLoading = false; self.personCards = [:]; self.trayOrigin = .none
        self.joinedGroupID = nil
        self.trayNavigation = TrayNavigation(); self.trayHistory.removeAll()
        self.loadingMore = false; self.loadMoreError = nil
        self.requests = NativeRequests()
        self.personalInvite = nil; self.selectedPerson = nil
        self.activity = nil
        self.agentSummary = nil; self.agentMonth = nil; self.agentDayTray = nil; self.agentSummaryCache.removeAll()
        self.inviteLookup?.cancel(); self.inviterLookup?.cancel(); self.query = ""; self.inviteInfo = nil
        self.inviter = nil
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
    /// How many profiles at the top of a list to fetch ahead.
    private static let warmedProfiles = 3
    private static let periodDefaultsKey = "firstlight.activityPeriod"
    private static let supportedPeriods = Set(["24h", "7d", "30d"])
    private static let metricDefaultsKey = "firstlight.leaderboardMetric"
    private static let supportedMetrics = Set(["active", "agent"])

    /// Portraits only, off the visible list's own loading: `.low` so a face
    /// for a tab nobody has opened never delays one that is on screen.
    private static let portraitPrefetcher: ImagePrefetcher = {
        let prefetcher = ImagePrefetcher()
        prefetcher.priority = .low
        return prefetcher
    }()

    private static var storedPeriod: String {
        let stored = UserDefaults.standard.string(forKey: self.periodDefaultsKey) ?? "24h"
        return self.supportedPeriods.contains(stored) ? stored : "24h"
    }

    private static var storedMetric: String {
        let stored = UserDefaults.standard.string(forKey: self.metricDefaultsKey) ?? "active"
        return self.supportedMetrics.contains(stored) ? stored : "active"
    }

    private var reachabilityWatch: AnyCancellable?
    private var screenTask: Task<Void, Never>?
    private var tabWarmTask: Task<Void, Never>?
    private var personWarmTasks: [String: Task<Void, Never>] = [:]
    private var trayTask: Task<Void, Never>?
    private var cardTask: Task<Void, Never>?
    private var navigationHistory = NativeNavigationHistory<Screen>()
    private var trayHistory = NativeNavigationHistory<Tray>()
    private var listCache = NativeResourceCache<String, NativePeopleList>()
    private var groupsCache = NativeResourceCache<String, [NativeGroup]>()
    private var displayedListKey = ""
    private var activityCache = NativeResourceCache<String, NativeActivity>()
    private var agentSummaryCache = NativeResourceCache<String, NativeAgentSummary>()
    private var requestsCache = NativeResourceCache<String, NativeRequests>()
    private var personalInviteCache = NativeResourceCache<String, NativePersonalInvite>()
    private var directFriendsCache = NativeResourceCache<String, Set<String>>()
    private var refreshID = UUID()
    private var refreshingList = false
    private var groupOrderTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
    private var inviteLookup: Task<Void, Never>?
    private var lookedUpToken: String?
    private var inviterLookup: Task<Void, Never>?

    private var isInviteDataFresh: Bool {
        self.personalInviteCache.isFresh("invite", for: Self.cacheLifetime) &&
            self.requestsCache.isFresh("requests", for: Self.cacheLifetime)
    }

    private static func leaderboardQuery(
        tab: String,
        period: String,
        metric: String,
        limit: Int,
        offset: Int
    ) -> [String: String?] {
        [
            "period": period,
            "group_id": tab == "friends" ? nil : tab,
            "profiles": "true",
            "limit": String(limit),
            "offset": String(offset),
            // The server names the metrics after its tables; the app after
            // what a person sees. Active time is the default and sends nothing.
            "metric": metric == "agent" ? "agent_minutes" : nil,
        ]
    }

    /// Enough of a name to speak to someone by.
    private static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Asks who a friend code belongs to, as soon as the field holds one. Own
    /// code and half-typed input are left alone; a miss simply keeps the code
    /// on screen, so a wrong code is never dressed up as a person.
    private func lookUpInviter() {
        self.inviterLookup?.cancel()
        guard case let .friendCode(code)? = self.inviteCandidate,
              code.caseInsensitiveCompare(self.personalInvite?.personalInviteCode ?? "") != .orderedSame
        else {
            self.inviter = nil
            self.checkingInviter = false
            return
        }
        if self.inviter?.code == code { return }
        self.inviter = nil
        self.checkingInviter = true
        self.inviterLookup = Task {
            defer { if !Task.isCancelled { self.checkingInviter = false } }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let info: NativeJoinInfo = try? await self.network
                .request(path: "/api/join/\(code)", method: .get),
                !Task.isCancelled,
                case .friendCode(code)? = self.inviteCandidate
            else { return }
            self.inviter = info.invite
        }
    }

    /// Only a list that failed is fetched again; one that loaded fine before
    /// the connection dropped is refreshed on its usual clock.
    private func reloadAfterReconnect() {
        guard Defaults[.currentUserID] != nil, self.listFailure != nil else { return }
        if self.screen == .list { Task { await self.refresh(force: true) } }
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

    /// Where an accepted invitation leaves the tray. A result with a state of
    /// its own gets a tray and needs no words; a sent request has no state to
    /// show, so it returns to Home and says so in passing. Shown before the
    /// field clears, so the emptied field does not pull Home back over it.
    private func finishInvite(notice: String, tray: Tray) {
        NativeSession.shared.pendingInvite = nil
        if self.tray != nil {
            self.trayHistory.removeAll()
            self.present(tray, direction: tray == .home ? .back : .forward)
            if tray == .home { self.feedbackToast = .success(notice) }
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
        // and the profile, so the switch itself has to carry an animation. A
        // portrait opening carries its own, quicker one.
        withAnimation(Self.navigationTransition(opening: self.navigation.isOpening)) { self.screen = next }
        // A day's tray belongs to the screen it was opened over.
        self.agentDayTray = nil
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
            // The period's summary for the card and the sections that follow
            // the zoom, the month's for the streak and the records, and the
            // person's own time for the figure beside the agents'. A miss
            // leaves whatever the cache had.
            if case let .agents(id) = next {
                let period = self.period
                async let details: NativeActivity? = try? self.network.request(
                    path: "/api/user/activity", method: .get, query: ["user_id": id, "period": period]
                )
                async let current: NativeAgentSummary? = period == "30d" ? nil : try? self.network.request(
                    path: "/api/users/\(id)/agent-summary", method: .get,
                    query: ["period": period, "tz": TimeZone.current.identifier]
                )
                async let month: NativeAgentSummary? = try? self.network.request(
                    path: "/api/users/\(id)/agent-summary", method: .get,
                    query: ["period": "30d", "tz": TimeZone.current.identifier]
                )
                let (loadedActivity, loadedCurrent, loadedMonth) = await (details, current, month)
                guard !Task.isCancelled, self.screen == next, self.period == period else { return }
                if let loadedActivity {
                    self.activity = loadedActivity
                    self.activityCache.insert(loadedActivity, for: self.profileCacheKey(id, period: period))
                }
                if let loadedMonth {
                    self.agentMonth = loadedMonth
                    self.agentSummaryCache.insert(loadedMonth, for: id + "30d")
                }
                if let summary = period == "30d" ? loadedMonth : loadedCurrent {
                    self.agentSummary = summary
                    self.agentSummaryCache.insert(summary, for: id + period)
                }
                return
            }
            // Both requests are optional enhancements to data the list already
            // supplied, so nothing here throws; a miss just leaves the cache.
            if case let .person(id) = next {
                let period = self.period
                let key = self.profileCacheKey(id, period: period)
                if self.selectedPerson?.public_apps_only == true {
                    self.agentSummary = nil
                    do {
                        let details: NativeActivity = try await self.network.request(
                            path: "/api/apps/profile/\(id)", method: .get, query: ["period": period]
                        )
                        guard !Task.isCancelled, self.screen == next, self.period == period else { return }
                        self.activity = details
                        self.activityCache.insert(details, for: key)
                    } catch {
                        guard !Task.isCancelled, self.screen == next, self.period == period else { return }
                        self.activity = nil
                        self.activityCache.invalidate(key)
                        self.error = "Public app activity is unavailable."
                    }
                    return
                }
                async let details: NativeActivity? = try? self.network.request(
                    path: "/api/user/activity", method: .get, query: ["user_id": id, "period": period]
                )
                async let direct: NativeDirectFriends? = try? self.network.request(
                    path: "/api/user/direct-friends",
                    method: .get
                )
                async let agents: NativeAgentSummary? = try? self.network.request(
                    path: "/api/users/\(id)/agent-summary", method: .get,
                    query: ["period": period, "tz": TimeZone.current.identifier]
                )
                let (loadedActivity, loadedAgents, connections) = await (details, agents, direct)
                guard !Task.isCancelled, self.screen == next, self.period == period else { return }
                if let loadedActivity {
                    self.activity = loadedActivity
                    self.activityCache.insert(loadedActivity, for: key)
                }
                if let loadedAgents {
                    self.agentSummary = loadedAgents
                    self.agentSummaryCache.insert(loadedAgents, for: id + period)
                }
                if let connections {
                    let ids = Set(connections.directFriendIds)
                    self.directFriendIDs = ids
                    self.directFriendsCache.insert(ids, for: "friends")
                }
            }
        }
    }

    /// The tray shows incoming requests and the user's own code, so it needs
    /// both before it is fully populated.
    private func loadInviteData() async throws {
        async let loadedInvite: NativePersonalInvite = self.network
            .request(path: "/api/user/invite-link", method: .get)
        async let loadedRequests: NativeRequests = self.network
            .request(path: "/api/friends/requests", method: .get)
        // Who is already a friend, so a friend's code is recognised before
        // anyone offers to add them. Optional: without it the server still
        // answers the request with the reason.
        async let loadedFriends: NativeDirectFriends? = try? self.network
            .request(path: "/api/user/direct-friends", method: .get)
        let invite = try await loadedInvite
        let requests = try await loadedRequests
        self.personalInvite = invite
        self.personalInviteCache.insert(invite, for: "invite")
        self.requests = requests
        self.requestsCache.insert(requests, for: "requests")
        if let friends = await loadedFriends {
            let ids = Set(friends.directFriendIds)
            self.directFriendIDs = ids
            self.directFriendsCache.insert(ids, for: "friends")
        }
    }

    /// The field decides the tray: a code or link long enough to be an
    /// invitation pushes Send request over Home, a changed one replaces it in
    /// place, and an emptied field comes back. Typing anywhere else, or with
    /// the tray closed, moves nothing.
    private func syncCandidateTray() {
        guard let current = self.tray else { return }
        switch (current, self.inviteCandidate) {
        case let (.home, candidate?):
            self.pushTray(.candidate(candidate.kind))
        case let (.candidate(shown), candidate?) where shown != candidate.kind:
            self.present(.candidate(candidate.kind), direction: .forward)
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

    private func profileCacheKey(_ id: String, period: String) -> String {
        id + period + (self.profilePeople[id]?.public_apps_only == true ? "|public-apps" : "")
    }

    /// The person with this id in the loaded ranking, the caller's own row
    /// included.
    private func loadedPerson(_ id: String) -> NativePerson? {
        self.people.first(where: { $0.id == id }) ?? (self.peopleList.me?.id == id ? self.peopleList.me : nil)
    }

    private func restoreCachedValue(for screen: Screen) {
        switch screen {
        case let .person(id):
            // Never left holding someone else: a person not opened before is
            // taken from the list, and one found nowhere leaves it empty.
            self.profilePeople[id] = self.profilePeople[id] ?? self.loadedPerson(id)
            self.selectedPerson = self.profilePeople[id]
            self.activity = self.activityCache.value(for: self.profileCacheKey(id, period: self.period))
            self.agentSummary = self.agentSummaryCache.value(for: id + self.period)
            if let cached = self.directFriendsCache.value(for: "friends") { self.directFriendIDs = cached }
        // The person and their card are the profile's, already in hand; only
        // the month is this screen's own.
        case let .agents(id):
            self.activity = self.activityCache.value(for: self.profileCacheKey(id, period: self.period))
            self.agentSummary = self.agentSummaryCache.value(for: id + self.period)
            self.agentMonth = self.agentSummaryCache.value(for: id + "30d")
        // The picture is the one the profile it was opened from already has.
        case .list,
             .app,
             .photo: break
        }
    }

    /// What the tray can show before its own request answers.
    private func restoreInviteData() {
        if let cached = self.personalInviteCache.value(for: "invite") { self.personalInvite = cached }
        if let cached = self.requestsCache.value(for: "requests") { self.requests = cached }
        if let cached = self.directFriendsCache.value(for: "friends") { self.directFriendIDs = cached }
    }

    private func isFresh(_ screen: Screen) -> Bool {
        switch screen {
        case .list,
             .app,
             .photo: true
        case let .agents(id):
            self.agentSummaryCache.isFresh(id + self.period, for: Self.cacheLifetime) &&
                self.agentSummaryCache.isFresh(id + "30d", for: Self.cacheLifetime)
        case let .person(id):
            self.selectedPerson?.public_apps_only != true && self.activityCache.isFresh(
                self.profileCacheKey(id, period: self.period),
                for: Self.cacheLifetime
            ) &&
                self.directFriendsCache.isFresh("friends", for: Self.cacheLifetime)
        }
    }
}
