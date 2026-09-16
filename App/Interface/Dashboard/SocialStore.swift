import Alamofire
import Defaults
import Dependencies
import SwiftUI

@MainActor
final class SocialStore: ObservableObject {
    // MARK: Internal

    enum ConnectMode: String, CaseIterable { case useInvite, shareMine }

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

    enum Screen: Equatable { case list, connect, requests, person(String), history, tokens
    }

    static let shared = SocialStore()

    @Published var screen: Screen = .list
    @Published var connectMode = ConnectMode.useInvite
    @Published var tab = "friends"
    @Published var period = "24h"
    @Published var groups: [NativeGroup] = []
    @Published var people: [NativePerson] = []
    @Published var requests = NativeRequests()
    @Published var personalInvite: NativePersonalInvite?
    @Published var inviteInfo: NativeInviteInfo?
    @Published var inviteHistory: [NativeInviteHistory.Invite] = []
    @Published var tokens: NativeTokens?
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
    @Published var input = ""
    @Published var inviteGroup = ""
    @Published var usageLimit = 1
    @Published var generatedLink = ""
    @Published private(set) var copiedItem: CopiedItem?
    @Published var selectedPerson: NativePerson?
    @Dependency(\.network) var network

    var canAcceptInvite: Bool {
        guard let inspectedInvite, inspectedInvite == (try? InviteInput.parse(self.input)) else { return false }
        if case .token = inspectedInvite { return self.inviteInfo != nil }
        return true
    }

    var inspectedInviteIsFriendCode: Bool {
        if case .friendCode = self.inspectedInvite { return true }
        return false
    }

    var previousScreen: Screen? { self.navigationHistory.previous }
    var hasLoadedCurrentList: Bool { self.listCache.contains(self.tab + self.period) }

    func hasLoaded(_ screen: Screen) -> Bool {
        switch screen {
        case .requests: self.requestsCache.contains("requests")
        case .connect: self.personalInviteCache.contains("invite")
        case .history: self.historyCache.contains("history")
        case .tokens: self.tokensCache.contains("tokens")
        default: true
        }
    }

    func openConnect(_ mode: ConnectMode, groupID: String? = nil) {
        self.connectMode = mode
        if let groupID { self.inviteGroup = groupID }
        else if self.screen != .connect { self.inviteGroup = "" }
        self.open(.connect)
    }

    func goBack() {
        guard let previous = navigationHistory.pop() else {
            self.showList()
            return
        }
        self.navigate(to: previous, resetsTransientState: false)
    }

    func showList(notice: String? = nil) {
        self.navigationHistory.removeAll()
        self.navigate(to: .list, resetsTransientState: true)
        self.notice = notice
    }

    func refresh(force: Bool = false) async {
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let key = selectedTab + selectedPeriod
        if self.displayedListKey != key {
            self.people = self.listCache.value(for: key) ?? []
            self.displayedListKey = key
            self.listError = nil
        }
        if let cachedGroups = self.groupsCache.value(for: "groups") { self.groups = cachedGroups }
        if !force,
           self.listCache.isFresh(key, for: Self.cacheLifetime),
           self.groupsCache.isFresh("groups", for: Self.cacheLifetime)
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
        async let loadedPeople: [NativePerson] = self.network.request(
            path: "/api/friends/leaderboard", method: .get,
            query: [
                "period": selectedPeriod,
                "group_id": selectedTab == "friends" ? nil : selectedTab,
                "profiles": "true",
            ]
        )

        var newGroups: [NativeGroup]?
        var newPeople: [NativePerson]?
        var failures: [String] = []
        do { newGroups = try await loadedGroups }
        catch { if !(error is CancellationError) { failures.append(error.localizedDescription) } }
        do { newPeople = try await loadedPeople }
        catch { if !(error is CancellationError) { failures.append(error.localizedDescription) } }

        guard self.refreshID == id, Defaults[.currentUserID] != nil else { return }
        if let newGroups {
            self.groups = newGroups.filter { $0.id != "global" }
            self.groupsCache.insert(self.groups, for: "groups")
            if selectedTab != "friends", selectedTab != "global",
               !self.groups.contains(where: { $0.id == selectedTab })
            {
                self.listError = nil
                self.tab = "friends"
                return
            }
        }
        if let newPeople {
            self.people = newPeople
            self.listCache.insert(newPeople, for: key)
            if let selectedID = self.selectedPerson?.id,
               let refreshedPerson = newPeople.first(where: { $0.id == selectedID })
            {
                self.selectedPerson = refreshedPerson
            }
        }
        self.listError = failures.first
    }

    func open(_ next: Screen) {
        if next == .list {
            self.showList()
            return
        }
        self.navigationHistory.record(self.screen, before: next)
        self.navigate(to: next, resetsTransientState: next != self.screen)
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
        else {
            let input = self.input
            self.navigate(to: self.screen, resetsTransientState: false, forceRefresh: true)
            self.input = input
        }
    }

    func refreshCurrentScreen(force: Bool = false) {
        if self.screen == .list { Task { await self.refresh(force: force) } }
        else {
            if case .person = self.screen { Task { await self.refresh(force: force) } }
            self.navigate(to: self.screen, resetsTransientState: false, forceRefresh: force)
        }
    }

    func invalidateInvitationHistory() {
        self.historyCache.invalidate("history")
    }

    func invalidateActivity(for userID: String) {
        for period in ["24h", "7d", "30d"] { self.activityCache.invalidate(userID + period) }
        if case let .person(id) = self.screen, id == userID { self.activity = nil }
    }

    func refreshPersonIfVisible(_ userID: String) {
        guard case let .person(id) = self.screen, id == userID else { return }
        self.navigate(to: self.screen, resetsTransientState: false, forceRefresh: true)
    }

    func removeDirectFriend(_ id: String) {
        self.directFriendIDs.remove(id)
        if self.directFriendsCache.contains("friends") {
            self.directFriendsCache.insert(self.directFriendIDs, for: "friends")
        } else {
            self.directFriendsCache.invalidate("friends")
        }
    }

    func rescueToken() {
        self.run("Getting token…", key: "rescue-token") {
            try await self.mutate("/api/user/tokens/rescue")
            self.tokens = try await self.network.request(path: "/api/user/tokens", method: .get)
            if let tokens = self.tokens { self.tokensCache.insert(tokens, for: "tokens") }
            self.notice = "Rescue token received."
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
        let acceptedPersonID = action == "accept" ? self.requests.incoming
            .first(where: { $0.id == id })?.requester?.id : nil
        self.run("Updating request…", key: "\(action)-request-\(id)") {
            if action == "cancel" { try await self.mutate("/api/friends/requests/\(id)", method: .delete) }
            else { try await self.mutate("/api/friends/requests/\(id)", body: ["action": action]) }
            if let acceptedPersonID {
                self.directFriendIDs.insert(acceptedPersonID)
                if self.directFriendsCache.contains("friends") {
                    self.directFriendsCache.insert(self.directFriendIDs, for: "friends")
                } else {
                    self.directFriendsCache.invalidate("friends")
                }
            }
            try await self.loadRequests()
            await self.refresh(force: true)
        }
    }

    func shareInvite() {
        if !self.generatedLink.isEmpty {
            self.copyInviteLink(self.generatedLink)
            return
        }
        if self.inviteGroup.isEmpty, let link = self.personalInvite?.personalInviteLink, !link.isEmpty {
            self.generatedLink = link
            self.copyInviteLink(link)
            return
        }
        self.run("Creating invitation…", key: "create-invite") {
            struct Options: Encodable { let usageLimit: Int }
            let path = self.inviteGroup.isEmpty ? "/api/invites/universal" : "/api/groups/\(self.inviteGroup)/invite"
            let result: NativeInviteLink = try await self.network.request(
                path: path,
                method: .post,
                body: Options(usageLimit: self.usageLimit)
            )
            self.generatedLink = result.inviteLink
            self.invalidateInvitationHistory()
            self.copyInviteLink(result.inviteLink)
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
                self.invalidateInvitationHistory()
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

    func clearGeneratedInvite() {
        self.generatedLink = ""
        if self.copiedItem == .inviteLink {
            self.copyFeedbackTask?.cancel()
            self.copiedItem = nil
        }
    }

    func inspectInvite() {
        self.run("Checking invitation…", key: "inspect-invite") {
            let parsed = try InviteInput.parse(self.input)
            switch parsed {
            case .friendCode: self.inviteInfo = nil
            case let .token(token): self.inviteInfo = try await self.network
                .request(path: "/api/invite/info", method: .get, query: ["token": token])
            }
            self.notice = nil
            self.inspectedInvite = parsed
        }
    }

    func acceptInvite() {
        self.run("Joining…", key: "accept-invite") {
            guard let parsed = self.inspectedInvite,
                  parsed == (try InviteInput.parse(self.input))
            else { throw NativeError.message("Check the invitation before accepting.") }
            let success: String
            switch parsed {
            case let .friendCode(code):
                try await self.mutate("/api/friends/request", body: ["inviteCode": code])
                success = "Friend request sent."
            case let .token(token):
                try await self.mutate("/api/invite/accept", body: ["token": token])
                SettingsWindowController.shared.invalidateGroups()
                success = "Invitation accepted."
            }
            NativeSession.shared.pendingInvite = nil
            self.showList(notice: success)
            await self.refresh(force: true)
        }
    }

    func declineInvite() {
        // Dismissing a shared invite must not revoke the sender's link for others.
        NativeSession.shared.pendingInvite = nil
        self.goBack()
    }

    func copy(_ value: String) {
        self.writeToPasteboard(value)
        self.notice = "Copied."
    }

    func reset() {
        self.refreshID = UUID()
        self.screenTask?.cancel(); self.screenLoading = false; self.activityCache.removeAll(); self.listError = nil
        self.listCache.removeAll(); self.groupsCache.removeAll(); self.displayedListKey = ""; self.navigationHistory
            .removeAll()
        self.screen = .list; self.connectMode = .useInvite; self.tab = "friends"; self.groups = []; self.people = []
        self.requests = NativeRequests()
        self.personalInvite = nil; self.inviteInfo = nil; self.inviteHistory = []; self
            .selectedPerson = nil
        self.activity = nil; self.inspectedInvite = nil
        self.input = ""; self.inviteGroup = ""; self.usageLimit = 1; self.generatedLink = ""
        self.error = nil; self.notice = nil; self.feedbackToast = nil
        self.copiedItem = nil
        self.copyFeedbackTask?.cancel()
        self.tokens = nil; self.directFriendIDs = []
        self.requestsCache.removeAll(); self.personalInviteCache.removeAll(); self.historyCache.removeAll()
        self.tokensCache.removeAll(); self.directFriendsCache.removeAll()
        self.loading = true
        self.refreshingList = false
        self.busy = false; self.operationKey = nil
    }

    // MARK: Private

    private static let cacheLifetime: TimeInterval = 30

    private var screenTask: Task<Void, Never>?
    private var navigationHistory = NativeNavigationHistory<Screen>()
    private var listCache = NativeResourceCache<String, [NativePerson]>()
    private var groupsCache = NativeResourceCache<String, [NativeGroup]>()
    private var displayedListKey = ""
    private var activityCache = NativeResourceCache<String, NativeActivity>()
    private var requestsCache = NativeResourceCache<String, NativeRequests>()
    private var personalInviteCache = NativeResourceCache<String, NativePersonalInvite>()
    private var historyCache = NativeResourceCache<String, [NativeInviteHistory.Invite]>()
    private var tokensCache = NativeResourceCache<String, NativeTokens>()
    private var directFriendsCache = NativeResourceCache<String, Set<String>>()
    @Published private var inspectedInvite: InviteInput?
    private var refreshID = UUID()
    private var refreshingList = false
    private var copyFeedbackTask: Task<Void, Never>?

    private func copyInviteLink(_ link: String) {
        self.copy(link, feedback: .inviteLink)
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

    private func navigate(to next: Screen, resetsTransientState: Bool, forceRefresh: Bool = false) {
        self.screenTask?.cancel()
        self.screen = next
        self.error = nil
        self.notice = nil
        self.feedbackToast = nil
        if resetsTransientState {
            self.input = ""
            self.inviteInfo = nil
            self.inspectedInvite = nil
        }
        self.screenLoading = false
        self.restoreCachedValue(for: next)
        switch next {
        case .list: return
        case .connect:
            if resetsTransientState { self.clearGeneratedInvite() }
        default: break
        }
        if !forceRefresh, self.isFresh(next) { return }
        self.screenLoading = true
        self.screenTask = Task {
            defer { if self.screen == next, !Task.isCancelled { self.screenLoading = false } }
            do {
                switch next {
                case .requests:
                    try await self.loadRequests()
                case .connect:
                    let result: NativePersonalInvite = try await self.network
                        .request(path: "/api/user/invite-link", method: .get)
                    self.personalInvite = result
                    self.personalInviteCache.insert(result, for: "invite")
                case .history:
                    let result: NativeInviteHistory = try await self.network.request(
                        path: "/api/user/invites",
                        method: .get
                    )
                    self.inviteHistory = result.recentInvites
                    self.historyCache.insert(result.recentInvites, for: "history")
                case .tokens:
                    let result: NativeTokens = try await self.network.request(path: "/api/user/tokens", method: .get)
                    self.tokens = result
                    self.tokensCache.insert(result, for: "tokens")
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

    private func restoreCachedValue(for screen: Screen) {
        switch screen {
        case .requests:
            if let cached = self.requestsCache.value(for: "requests") { self.requests = cached }
        case .connect:
            if let cached = self.personalInviteCache.value(for: "invite") { self.personalInvite = cached }
        case .history:
            if let cached = self.historyCache.value(for: "history") { self.inviteHistory = cached }
        case .tokens:
            if let cached = self.tokensCache.value(for: "tokens") { self.tokens = cached }
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
        case .connect: self.personalInviteCache.isFresh("invite", for: Self.cacheLifetime)
        case .history: self.historyCache.isFresh("history", for: Self.cacheLifetime)
        case .tokens: self.tokensCache.isFresh("tokens", for: Self.cacheLifetime)
        case let .person(id):
            self.activityCache.isFresh(id + self.period, for: Self.cacheLifetime) &&
                self.directFriendsCache.isFresh("friends", for: Self.cacheLifetime)
        }
    }
}
