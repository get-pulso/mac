import AppKit
import ClerkKit
import Combine
import Defaults
import Dependencies
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NativeSettingsModel: ObservableObject {
    // MARK: Lifecycle

    init() {
        self.groupsObservation = self.groupSettings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Internal

    enum Section: String, CaseIterable {
        case account = "Account", general = "General", sharing = "Sharing", groups = "Groups",
             security = "Security", about = "About"

        // MARK: Internal

        var icon: String {
            switch self {
            case .account: "person.crop.circle"; case .general: "gearshape"; case .sharing: "SettingsSharing"
            case .groups: "SettingsGroups"; case .security: "SettingsSecurity"; case .about: "info.circle"
            }
        }

        var keywords: String {
            switch self {
            case .account: "profile name username photo avatar bio location friend code website links sign out"
            case .general: "appearance theme dark light system startup launch login activity period tracking pause history clear quit agents claude codex cursor tokens sound audio onboarding intro preview bass"
            case .sharing: "sharing privacy visible friends apps agents hide private detail total off leaderboard anonymous"
            case .groups: "friends members invite link create rename leaderboard"
            case .security: "sign-in google password email mfa two factor authenticator recovery backup codes delete account sessions devices mac active sign out revoke"
            case .about: "version updates api"
            }
        }

        /// Every whitespace-separated word of the query must appear in the
        /// section title or keywords, so "dark theme" finds General.
        func matches(_ query: String) -> Bool {
            let haystack = self.rawValue + " " + self.keywords
            return query.split(whereSeparator: \.isWhitespace)
                .allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }
    }

    struct Route: Equatable {
        var section: Section
        var page: String = ""
        var groupsPage: NativeGroupsPage = .list
    }

    let groupSettings = NativeGroupsModel(client: .live)

    @Published var route = Route(section: .general)
    @Published var search = ""
    @Published var busy = false
    @Published var operationLabel = "Saving changes…"
    @Published var operationKey: String?
    @Published var sessionsLoading = false
    @Published var sessionsError: String?
    @Published var inviteLoading = false
    @Published var inviteError: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var firstName = ""
    @Published var lastName = ""
    @Published var username = ""
    @Published var bio = ""
    @Published var location = ""
    @Published var website = ""
    @Published var twitter = ""
    @Published var telegram = ""
    @Published var email = ""
    @Published var code = ""
    @Published var password = ""
    @Published var currentPassword = ""
    @Published var confirmation = ""
    @Published var sessions: [Session] = []
    @Published var inviteCode = ""
    @Published var totp: TOTPResource?
    @Published var backupCodes: [String] = []
    @Published var verification: SessionVerification?
    @Published var verificationMethod = ""
    /// `nil` until `GET /api/user/sharing` answered for this window.
    @Published var sharing: NativeSharingSettings?

    var user: ClerkKit.User? { NativeSession.shared.user }
    var canGoBack: Bool { self.historyIndex > 0 }
    var canGoForward: Bool { self.historyIndex < self.history.count - 1 }
    var sessionsLoaded: Bool { self.sessionsLoadedAt != nil }
    var title: String {
        if self.route.section == .groups { return self.groupSettings.title }
        let titles = [
            "edit": "Edit Profile",
            "email": "Change Email",
            "verify-email": "Verify Email",
            "password": "Change Password",
            "totp": "Authenticator",
            "backup-codes": "Recovery Codes",
            "verify-identity": "Verify Identity",
            "delete": "Delete Account",
        ]
        return titles[self.route.page] ?? self.route.section.rawValue
    }

    var profileDraft: ProfileDraft {
        ProfileDraft(
            firstName: self.firstName,
            lastName: self.lastName,
            username: self.username,
            location: self.location,
            bio: self.bio,
            website: self.website,
            twitter: self.twitter,
            telegram: self.telegram
        )
    }

    var hasProfileChanges: Bool { self.savedProfile.map { $0 != profileDraft.normalized } ?? false }

    func attributeEnabled(_ name: String) -> Bool {
        Clerk.shared.environment?.userSettings.attributes[name]?.enabled == true
    }

    /// `keepingSearch` follows the sidebar filter to its first match without
    /// clearing the query the person is still typing.
    func navigate(
        _ section: Section,
        page: String = "",
        groupsPage: NativeGroupsPage = .list,
        keepingSearch: Bool = false
    ) {
        let next = Route(section: section, page: page, groupsPage: groupsPage)
        guard next != self.route else { return }
        guard self.confirmLeavingProfile() else { self.objectWillChange.send(); return }
        if next != self.route {
            self.history = Array(self.history.prefix(self.historyIndex + 1)) + [next]
            self.historyIndex = self.history.count - 1
        }
        self.route = next; self.error = nil; self.notice = nil
        if !keepingSearch { self.search = "" }
        self.password = ""; self.currentPassword = ""; self.code = ""; self.confirmation = ""
        if page == "edit" { self.loadProfile() }
        if section == .security { self.refreshSessions() }
        if section == .sharing { self.loadSharingSettings() }
        if section == .groups { self.groupSettings.open(groupsPage) }
    }

    func navigateGroups(_ page: NativeGroupsPage) { self.navigate(.groups, groupsPage: page) }

    func refreshCurrentRoute() {
        switch self.route.section {
        case .account: Task { await self.load() }
        case .groups: self.groupSettings.open(self.route.groupsPage)
        case .security: self.refreshSessions()
        case .sharing: self.sharing = nil; self.loadSharingSettings()
        default: break
        }
    }

    func travel(_ delta: Int) {
        let target = self.historyIndex + delta
        guard self.history.indices.contains(target) else { return }
        guard self.confirmLeavingProfile() else { return }
        self.historyIndex = target; self.route = self.history[target]; self.error = nil; self.notice = nil
        self.password = ""; self.currentPassword = ""; self.code = ""; self.confirmation = ""
        if self.route.page == "edit" { self.loadProfile() }
        if self.route.section == .security { self.refreshSessions() }
        if self.route.section == .sharing { self.loadSharingSettings() }
        if self.route.section == .groups { self.groupSettings.open(self.route.groupsPage) }
    }

    func loadProfile() {
        self.firstName = self.user?.firstName ?? ""; self.lastName = self.user?.lastName ?? ""; self.username = self
            .user?.username ?? ""
        self.bio = self.metadata("bio"); self.location = self.metadata("location"); self.website = self
            .metadata("website"); self.twitter = self.metadata("twitter"); self.telegram = self.metadata("telegram")
        self.savedProfile = self.profileDraft.normalized
    }

    func confirmLeavingProfile() -> Bool {
        if self.route.section == .groups {
            guard !self.groupSettings.busy else { return false }
            guard self.groupSettings.hasChanges else { return true }
            let alert = NSAlert()
            alert.messageText = "Discard group changes?"
            alert.informativeText = "Your changes haven't been saved."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard Changes")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            self.groupSettings.discardChanges()
            return true
        }
        guard self.route.page == "edit", self.hasProfileChanges else { return true }
        guard !self.busy else { return false }
        let alert = NSAlert()
        alert.messageText = "Discard profile changes?"
        alert.informativeText = "Your changes haven't been saved. Stay here to keep editing, or discard them."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Changes")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        self.loadProfile()
        return true
    }

    func metadata(_ key: String) -> String {
        guard case let .object(fields) = self.user?.unsafeMetadata,
              case let .string(value) = fields[key] else { return "" }
        return value
    }

    func isRunning(_ key: String) -> Bool { self.busy && self.operationKey == key }

    func run(
        _ label: String = "Saving changes…",
        key: String = "action",
        _ action: @escaping () async throws -> Void
    ) {
        guard !self.busy else { return }
        self.operationLabel = label
        self.operationKey = key
        self.busy = true; self.error = nil; self.notice = nil
        Task {
            defer { busy = false; operationKey = nil }
            do {
                try await action()
                NativeSession.shared.revision += 1
            } catch { self.error = error.localizedDescription }
        }
    }

    func load() async {
        if !self.profileReconciliationStarted {
            self.profileReconciliationStarted = true
            do { try await self.network.syncNativeProfile() }
            catch { self.profileReconciliationStarted = false }
        }
        guard self.inviteCode.isEmpty, !self.inviteLoading else { return }
        self.inviteLoading = true
        self.inviteError = nil
        defer { self.inviteLoading = false }
        do {
            let invite: NativePersonalInvite = try await network.request(path: "/api/user/invite-link", method: .get)
            self.inviteCode = invite.personalInviteCode
        } catch { self.inviteError = error.localizedDescription }
    }

    func saveProfile() {
        let draft = self.profileDraft.normalized
        guard self.profileDraft.errors.isEmpty else {
            self.error = "Check the highlighted profile fields."
            return
        }
        guard self.hasProfileChanges else { return }
        self.run("Saving profile…", key: "save-profile") {
            guard let user = self.user else { throw NativeError.message("Sign in again to save your profile.") }
            let attributes = Clerk.shared.environment?.userSettings.attributes ?? [:]
            _ = try await user.update(.init(
                username: attributes["username"]?.enabled == true ? draft.username : nil,
                firstName: attributes["first_name"]?.enabled == true ? draft.firstName : nil,
                lastName: attributes["last_name"]?.enabled == true ? draft.lastName : nil
            ))
            _ = try await user.updateMetadata(unsafeMetadata: .object([
                "bio": .string(draft.bio), "location": .string(draft.location), "website": .string(draft.website),
                "twitter": .string(draft.twitter), "telegram": .string(draft.telegram),
            ]))
            try await self.syncProfile()
            self.savedProfile = draft
            self.navigate(.account)
            self.notice = "Profile saved."
            await SocialStore.shared.refresh(force: true)
        }
    }

    func syncProfile() async throws {
        try await self.network.syncNativeProfile()
        self.profileReconciliationStarted = true
        _ = try await self.user?.reload()
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.run("Uploading photo…", key: "upload-photo") {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 10_000_000 else { throw NativeError.message("Choose an image smaller than 10 MB.") }
            _ = try await self.user?.setProfileImage(imageData: bytes)
            try await self.syncProfile()
            self.notice = "Photo updated."
            await SocialStore.shared.refresh(force: true)
        }
    }

    func changeEmail() {
        self.sensitive(key: "change-email") {
            guard let user = self.user else { return }
            let address = try await user.createEmailAddress(self.email.trimmingCharacters(in: .whitespacesAndNewlines))
            self.pendingEmail = try await address.sendCode()
            self.navigate(.security, page: "verify-email")
        }
    }

    func verifyEmail() {
        self.run("Verifying email…", key: "verify-email") {
            guard let email = self.pendingEmail else { return }
            let verified = try await email.verifyCode(self.code)
            _ = try await self.user?.update(.init(primaryEmailAddressId: verified.id))
            try await self.syncProfile()
            self.pendingEmail = nil
            self.navigate(.security)
            self.notice = "Email updated."
        }
    }

    func changePassword() {
        let current = self.currentPassword, new = self.password
        self.sensitive(key: "change-password") {
            _ = try await self.user?
                .updatePassword(.init(
                    currentPassword: current.isEmpty ? nil : current,
                    newPassword: new,
                    signOutOfOtherSessions: true
                ))
            if self.sessionsLoadedAt != nil { self.sessionsLoadedAt = .distantPast }
            self.navigate(.security)
            self.notice = "Password updated. Other sessions have been signed out."
        }
    }

    func setupTOTP() {
        self.sensitive(key: "setup-totp") {
            self.totp = try await self.user?.createTOTP()
            self.navigate(.security, page: "totp")
        }
    }

    func verifyTOTP() {
        self.run("Enabling authenticator…", key: "verify-totp") {
            let result = try await self.user?.verifyTOTP(code: self.code)
            self.backupCodes = result?.backupCodes ?? []
            self.totp = nil
            _ = try await self.user?.reload()
            self.navigate(.security, page: self.backupCodes.isEmpty ? "" : "backup-codes")
            self.notice = "Two-factor authentication enabled."
        }
    }

    func disableTOTP() {
        self.sensitive(key: "disable-totp") {
            _ = try await self.user?.disableTOTP()
            _ = try await self.user?.reload()
            self.navigate(.security)
            self.notice = "Authenticator removed."
        }
    }

    func regenerateBackupCodes() {
        self.sensitive(key: "backup-codes") {
            self.backupCodes = try await self.user?.createBackupCodes().codes ?? []
            self.navigate(.security, page: "backup-codes")
        }
    }

    func loadSessions() async throws {
        self.sessions = try await self.user?.getSessions() ?? []
        self.sessionsLoadedAt = .now
    }

    func refreshSessions(force: Bool = false) {
        guard !self.sessionsLoading else { return }
        if !force,
           let sessionsLoadedAt,
           Date.now.timeIntervalSince(sessionsLoadedAt) < Self.cacheLifetime { return }
        self.sessionsLoading = true; self.sessionsError = nil
        Task {
            defer { self.sessionsLoading = false }
            do { try await self.loadSessions() } catch { self.sessionsError = error.localizedDescription }
        }
    }

    func resetActivity() {
        self.run("Clearing activity history…", key: "clear-activity") {
            @Dependency(\.tracker) var tracker
            try await tracker.resetActivity()
            @Dependency(\.agentUsage) var agentUsage
            if let userID = Defaults[.currentUserID] { try await agentUsage.drainAndClear(for: userID) }
            self.notice = "Activity history cleared."
            if let userID = Defaults[.currentUserID] {
                SocialStore.shared.invalidateActivity(for: userID)
            }
            await SocialStore.shared.refresh(force: true)
            if let userID = Defaults[.currentUserID] {
                SocialStore.shared.refreshPersonIfVisible(userID)
            }
        }
    }

    // MARK: Sharing

    func loadSharingSettings() {
        guard self.sharing == nil else { return }
        self.run("Loading…", key: "sharing") {
            self.sharing = try await self.network.request(
                path: "/api/user/sharing",
                method: .get
            )
        }
    }

    /// Optimistic: the switch moves at once and returns if the server refuses.
    /// One channel is sent at a time, so a change here never overwrites a
    /// change the other channel just took on another Mac.
    func setSharing(_ channel: NativeSharingChannel, to level: NativeShareLevel) {
        let previous = self.sharing
        self.sharing = (previous ?? NativeSharingSettings()).setting(channel, to: level)
        self.run("Saving changes…", key: "sharing-\(channel.rawValue)") {
            do {
                self.sharing = try await self.network.request(
                    path: "/api/user/sharing",
                    method: .patch,
                    body: NativeSharingSettings().setting(channel, to: level)
                )
            } catch {
                self.sharing = previous
                throw error
            }
        }
    }

    func revoke(_ session: Session) {
        self.sensitive(key: "revoke-session-\(session.id)") {
            _ = try await session.revoke(); try await self.loadSessions(); self.notice = "Session signed out."
        }
    }

    func deleteAccount() {
        guard self.confirmation == "DELETE" else { self.error = "Type DELETE to confirm."; return }
        self.sensitive(key: "delete-account") {
            let _: NativeAck = try await self.network.request(
                path: "/api/native/account",
                method: .delete,
                body: ["confirmation": "DELETE"]
            )
            try? await NativeSession.shared.signOut()
            NativeSession.shared.clearAccount()
        }
    }

    func sensitive(key: String, _ action: @escaping () async throws -> Void) {
        self.run("Verifying your identity…", key: key) {
            guard let session = NativeSession.shared.session
            else { throw NativeError.message("Sign in again to continue.") }
            self.pendingAction = action
            self.verification = try await session.startVerification(level: .multiFactor)
            try await self.advanceVerification()
        }
    }

    func verifyIdentity() {
        self.run("Verifying…", key: "verify-identity") {
            guard let session = NativeSession.shared.session else { return }
            switch self.verificationMethod {
            case "password": self.verification = try await session.verifyWithPassword(self.password)
            case "email": self.verification = try await session.verifyWithEmailCode(code: self.code)
            case "totp": self.verification = try await session.verifyWithTOTP(code: self.code)
            default: self.verification = try await session.verifyWithBackupCode(code: self.code)
            }
            self.password = ""; self.code = ""
            try await self.advanceVerification()
        }
    }

    // MARK: Private

    private static let cacheLifetime: TimeInterval = 30

    private var savedProfile: ProfileDraft?
    private var profileReconciliationStarted = false
    private var sessionsLoadedAt: Date?
    private var groupsObservation: AnyCancellable?
    private var pendingEmail: EmailAddress?
    private var pendingAction: (() async throws -> Void)?
    private var history = [Route(section: .general)]
    @Published private var historyIndex = 0
    @Dependency(\.network) private var network

    private func advanceVerification() async throws {
        guard let session = NativeSession.shared.session, let verification else { return }
        if verification.status == .complete {
            _ = try await session.getToken(.init(skipCache: true))
            let action = self.pendingAction
            self.pendingAction = nil
            self.verification = nil
            if self.route.page == "verify-identity" { self.travel(-1) }
            try await action?()
            return
        }
        if verification.status == .needsFirstFactor {
            if let factor = verification.supportedFirstFactors?.first(where: { $0.strategy == .emailCode }),
               let id = factor.emailAddressId
            {
                self.verification = try await session.sendEmailCode(emailAddressId: id)
                self.verificationMethod = "email"
            } else if verification.supportedFirstFactors?
                .contains(where: { $0.strategy == .password }) == true { self.verificationMethod = "password" }
            else {
                throw NativeError
                    .message(
                        "This account requires a verification method not available here. Sign in again before making this change."
                    )
            }
        } else if verification.status == .needsSecondFactor {
            if verification.supportedSecondFactors?
                .contains(where: { $0.strategy == .totp }) == true { self.verificationMethod = "totp" }
            else { self.verificationMethod = "backup" }
        } else { throw NativeError.message("Start verification again.") }
        self.navigate(.security, page: "verify-identity")
    }
}

/// The two channels a person can share separately.
enum NativeSharingChannel: String, CaseIterable, Identifiable {
    case apps, agents

    // MARK: Internal

    var id: String { self.rawValue }
}

/// How much of a channel friends see. `detail` is everything, `total` the
/// number with nothing named, `off` nothing at all — and, for agents, no
/// place on the boards that rank by agent time or tokens.
enum NativeShareLevel: String, Codable, CaseIterable {
    case detail, total, off
}

/// `GET`/`PATCH /api/user/sharing` body. Both keys are optional so a patch
/// can carry one channel; a `GET` always answers with both.
struct NativeSharingSettings: Codable {
    var apps: NativeShareLevel?
    var agents: NativeShareLevel?

    /// Everything is shared until somebody says otherwise, on an older
    /// server and on a fresh account alike.
    func level(_ channel: NativeSharingChannel) -> NativeShareLevel {
        switch channel {
        case .apps: self.apps ?? .detail
        case .agents: self.agents ?? .detail
        }
    }

    func setting(_ channel: NativeSharingChannel, to level: NativeShareLevel) -> Self {
        var copy = self
        switch channel {
        case .apps: copy.apps = level
        case .agents: copy.agents = level
        }
        return copy
    }
}
