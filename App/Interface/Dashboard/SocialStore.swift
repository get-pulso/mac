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

    enum Screen: Equatable { case list, connect, requests, person(String) }

    static let shared = SocialStore()

    @Published var screen: Screen = .list
    @Published var tab = "friends"
    @Published private(set) var period = SocialStore.storedPeriod
    @Published var groups: [NativeGroup] = []
    @Published var people: [NativePerson] = []
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

    var previousScreen: Screen? { self.navigationHistory.previous }
    var hasLoadedCurrentList: Bool { self.listCache.contains(self.tab + self.period) }

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
        self.navigate(to: previous)
    }

    func showList(notice: String? = nil) {
        self.navigationHistory.removeAll()
        self.navigate(to: .list)
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
        // Opening the screen fresh must not surface the last invitation typed.
        if next == .connect, self.screen != .connect { self.clearQuery() }
        self.navigationHistory.record(self.screen, before: next)
        self.navigate(to: next)
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
        switch candidate {
        case let .friendCode(code):
            self.run("Sending request…", key: "accept-invite") {
                try await self.mutate("/api/friends/request", body: ["inviteCode": code])
                self.finishInvite(notice: "Friend request sent.")
                try? await self.loadRequests()
                await self.refresh(force: true)
            }
        case let .token(token):
            self.run("Joining…", key: "accept-invite") {
                try await self.mutate("/api/invite/accept", body: ["token": token])
                SettingsWindowController.shared.invalidateGroups()
                self.finishInvite(notice: "Invitation accepted.")
                await self.refresh(force: true)
            }
        }
    }

    /// Dismissing a shared invite must not revoke the sender's link for others.
    func dismissInvite() {
        NativeSession.shared.pendingInvite = nil
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
        self.screen = .list; self.tab = "friends"; self.groups = []; self.people = []
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
    private static let periodDefaultsKey = "pulso.activityPeriod"
    private static let supportedPeriods = Set(["24h", "7d", "30d"])

    private static var storedPeriod: String {
        let stored = UserDefaults.standard.string(forKey: self.periodDefaultsKey) ?? "24h"
        return self.supportedPeriods.contains(stored) ? stored : "24h"
    }

    private var screenTask: Task<Void, Never>?
    private var navigationHistory = NativeNavigationHistory<Screen>()
    private var listCache = NativeResourceCache<String, [NativePerson]>()
    private var groupsCache = NativeResourceCache<String, [NativeGroup]>()
    private var displayedListKey = ""
    private var activityCache = NativeResourceCache<String, NativeActivity>()
    private var requestsCache = NativeResourceCache<String, NativeRequests>()
    private var personalInviteCache = NativeResourceCache<String, NativePersonalInvite>()
    private var directFriendsCache = NativeResourceCache<String, Set<String>>()
    private var refreshID = UUID()
    private var refreshingList = false
    private var copyFeedbackTask: Task<Void, Never>?
    private var inviteLookup: Task<Void, Never>?
    private var lookedUpToken: String?

    private func finishInvite(notice: String) {
        NativeSession.shared.pendingInvite = nil
        self.clearQuery()
        self.notice = notice
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

    private func navigate(to next: Screen, forceRefresh: Bool = false) {
        self.screenTask?.cancel()
        self.screen = next
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
                    // The screen shows incoming requests and the user's own code,
                    // so it needs both before it is fully populated.
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
