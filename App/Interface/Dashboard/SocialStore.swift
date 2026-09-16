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

    func hasLoaded(_ screen: Screen) -> Bool {
        switch screen {
        case .requests: self.requestsLoaded
        case .history: self.historyLoaded
        case .tokens: self.tokens != nil
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

    func refresh() async {
        let id = UUID()
        self.refreshID = id
        self.loading = true
        let selectedTab = self.tab
        let selectedPeriod = self.period
        let key = selectedTab + selectedPeriod
        if self.displayedListKey != key {
            self.people = self.listCache[key] ?? []
            self.displayedListKey = key
            self.listError = nil
        }
        do {
            async let loadedGroups: [NativeGroup] = self.network.request(path: "/api/groups", method: .get)
            async let loadedPeople: [NativePerson] = self.network.request(
                path: "/api/friends/leaderboard", method: .get,
                query: [
                    "period": selectedPeriod,
                    "group_id": selectedTab == "friends" ? nil : selectedTab,
                    "profiles": "true",
                ]
            )
            let (newGroups, newPeople) = try await (loadedGroups, loadedPeople)
            guard self.refreshID == id, Defaults[.currentUserID] != nil else { return }
            self.groups = newGroups.filter { $0.id != "global" }
            self.people = newPeople
            self.listCache[key] = newPeople
            self.listError = nil
            if selectedTab != "friends", selectedTab != "global",
               !self.groups.contains(where: { $0.id == selectedTab }) { self.tab = "friends" }
        } catch {
            if self.refreshID == id, !(error is CancellationError) { self.listError = error.localizedDescription }
        }
        if self.refreshID == id { self.loading = false }
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
        if self.screen == .list { Task { await self.refresh() } }
        else {
            let input = self.input
            self.navigate(to: self.screen, resetsTransientState: false)
            self.input = input
        }
    }

    func rescueToken() {
        self.run("Getting token…", key: "rescue-token") {
            try await self.mutate("/api/user/tokens/rescue")
            self.tokens = try await self.network.request(path: "/api/user/tokens", method: .get)
            self.notice = "Rescue token received."
        }
    }

    func mutate(_ path: String, method: HTTPMethod = .post, body: Encodable? = nil) async throws {
        let _: NativeAck = try await network.request(path: path, method: method, body: body)
    }

    func loadRequests() async throws {
        self.requests = try await self.network.request(path: "/api/friends/requests", method: .get)
    }

    func respond(_ id: String, action: String) {
        self.run("Updating request…", key: "\(action)-request-\(id)") {
            if action == "cancel" { try await self.mutate("/api/friends/requests/\(id)", method: .delete) }
            else { try await self.mutate("/api/friends/requests/\(id)", body: ["action": action]) }
            try await self.loadRequests()
            await self.refresh()
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
                success = "Invitation accepted."
            }
            NativeSession.shared.pendingInvite = nil
            self.showList(notice: success)
            await self.refresh()
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
        self.screenTask?.cancel(); self.screenLoading = false; self.activityCache = [:]; self.listError = nil
        self.listCache = [:]; self.displayedListKey = ""; self.navigationHistory.removeAll()
        self.screen = .list; self.connectMode = .useInvite; self.tab = "friends"; self.groups = []; self.people = []
        self.requests = NativeRequests()
        self.personalInvite = nil; self.inviteInfo = nil; self.inviteHistory = []; self
            .selectedPerson = nil
        self.input = ""; self.generatedLink = ""; self.error = nil; self.notice = nil; self.feedbackToast = nil
        self.copiedItem = nil
        self.copyFeedbackTask?.cancel()
        self.tokens = nil; self.directFriendIDs = []
        self.requestsLoaded = false; self.historyLoaded = false
        self.loading = true
        self.busy = false; self.operationKey = nil
    }

    // MARK: Private

    private var screenTask: Task<Void, Never>?
    private var navigationHistory = NativeNavigationHistory<Screen>()
    private var listCache: [String: [NativePerson]] = [:]
    private var displayedListKey = ""
    private var activityCache: [String: NativeActivity] = [:]
    private var requestsLoaded = false
    private var historyLoaded = false
    @Published private var inspectedInvite: InviteInput?
    private var refreshID = UUID()
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

    private func navigate(to next: Screen, resetsTransientState: Bool) {
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
        switch next {
        case .list: return
        case .connect:
            if resetsTransientState { self.clearGeneratedInvite() }
        case let .person(id): self.activity = self.activityCache[id + self.period]
        default: break
        }
        self.screenLoading = true
        self.screenTask = Task {
            defer { if self.screen == next, !Task.isCancelled { self.screenLoading = false } }
            do {
                switch next {
                case .requests:
                    try await self.loadRequests()
                    self.requestsLoaded = true
                case .connect:
                    self.personalInvite = try await self.network.request(path: "/api/user/invite-link", method: .get)
                case .history:
                    let result: NativeInviteHistory = try await self.network.request(
                        path: "/api/user/invites",
                        method: .get
                    )
                    self.inviteHistory = result.recentInvites
                    self.historyLoaded = true
                case .tokens:
                    self.tokens = try await self.network.request(path: "/api/user/tokens", method: .get)
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
                        self.activityCache[id + self.period] = details
                    }
                    if let connections = await direct { self.directFriendIDs = Set(connections.directFriendIds) }
                default: break
                }
            } catch {
                if !Task.isCancelled, self.screen == next { self.error = error.localizedDescription }
            }
        }
    }
}
