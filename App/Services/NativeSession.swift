import AppKit
import ClerkKit
import Defaults
import Dependencies
import SwiftUI

/// Persists outside the popover so closing it does not discard authentication.
@MainActor
final class NativeSession: ObservableObject {
    // MARK: Internal

    enum PendingInviteSource { case link, clipboard }

    static let shared = NativeSession()

    @Published var ready = false
    @Published var loading = false
    @Published var error: String?
    @Published var revision = 0
    @Published var pendingInvite: String?
    /// Where the pending invitation came from: the link itself, opened in the
    /// app, or a link waiting in the clipboard after installing from the site.
    @Published private(set) var pendingInviteSource: PendingInviteSource = .link

    @Published private(set) var welcomeAccount: WelcomeAccount?
    @Published private(set) var isCompletingSignIn = false
    private(set) var configured = false

    var user: ClerkKit.User? { self.configured ? Clerk.shared.user : nil }
    var session: Session? { self.configured ? Clerk.shared.session : nil }

    var canContinueFromWelcome: Bool {
        guard let welcomeAccount else { return false }
        return self.session?.status == .active && Defaults[.currentUserID] == welcomeAccount.id
    }

    func start(presentDashboardOnRestore: Bool = true) async {
        guard !self.loading else { return }
        self.loading = true
        self.error = nil
        defer { loading = false }
        do {
            if !self.configured {
                struct Config: Decodable { let publishableKey: String }
                let url = AppEnvironment.baseURL.appending(path: "/api/native/config")
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NativeError
                        .message("Cannot load sign-in configuration. Check that the Firstlight API is running.")
                }
                let config = try JSONDecoder().decode(Config.self, from: data)
                guard config.publishableKey.hasPrefix("pk_")
                else { throw NativeError.message("Invalid sign-in configuration.") }
                Clerk.configure(publishableKey: config.publishableKey, options: .init(
                    redirectConfig: .init(redirectUrl: "firstlight://callback", callbackUrlScheme: "firstlight")
                ))
                self.configured = true
            }
            _ = try await Clerk.shared.refreshEnvironment()
            _ = try await Clerk.shared.refreshClient()
            self.observeEvents()
            if self.session?.status == .active {
                try await self.finishSignIn(
                    presentDashboard: presentDashboardOnRestore && !OnboardingWindowController.shared.isPresented
                )
            } else {
                self.adoptClipboardInvite()
            }
            self.ready = true
        } catch { self.error = error.localizedDescription }
    }

    func token(forceRefresh: Bool = false) async throws -> String? {
        guard self.configured, self.session?.status == .active else { return nil }
        let sessionID = self.session?.id
        let token = try await Clerk.shared.auth.getToken(.init(skipCache: forceRefresh))
        guard self.session?.id == sessionID else { throw CancellationError() }
        return token
    }

    func finishSignIn(presentDashboard: Bool = true) async throws {
        guard !self.isCompletingSignIn else { return }
        guard self.session?.status == .active else {
            throw NativeError.message("Complete the remaining account verification before continuing.")
        }
        self.isCompletingSignIn = true
        self.error = nil
        defer { isCompletingSignIn = false }
        @Dependency(\.network) var network
        @Dependency(\.appRouter) var router
        @Dependency(\.windowManager) var window
        let sessionID = self.session?.id
        // Signed in from the onboarding window: the window stays for the
        // profile steps, and the panel opens at the end, when the mark has
        // flown to the menu bar. Anywhere else, move to the panel before any
        // profile request can suspend.
        let inOnboarding = presentDashboard && OnboardingWindowController.shared.isPresented
        if presentDashboard, !inOnboarding {
            router.move(to: .signInCompletion)
            window.show()
        }
        do {
            let info = try await network.userInfo()
            guard self.session?.id == sessionID, self.session?.status == .active else { throw CancellationError() }
            Defaults[.currentUserID] = info.user.id
            // Heal a prior partial save where Clerk took a new name or photo but
            // the Firstlight profile store was temporarily unavailable. Sign-in
            // itself stays usable if this best-effort reconciliation fails.
            try? await network.syncNativeProfile()
            // The profile steps start from what the person already wrote, which
            // the database keeps; asked while the sign-in button still waits.
            var about: NativeProfileAbout?
            if inOnboarding { about = try? await network.profileAbout() }
            self.welcomeAccount = WelcomeAccount(
                id: info.user.id, firstName: self.user?.firstName, fullName: info.user.name,
                username: self.user?.username, avatarURL: self.user?.imageUrl
            )
            self.revision += 1
            router.move(to: .dashboard)
            // The list the popover opens on is fetched now, while nobody is
            // waiting, instead of on the first click. Both a fresh sign-in and
            // a session restored at launch arrive here.
            SocialStore.shared.warm()
            if inOnboarding { OnboardingFlow.shared.continueAfterSignIn(about: about) }
            // The panel is already open. If the user dismissed it while loading,
            // respect that instead of reopening it when the response arrives.
        } catch {
            if self.session?.id == sessionID { self.error = error.localizedDescription }
            throw error
        }
    }

    func continueFromWelcome() {
        guard self.canContinueFromWelcome else { return }
        if OnboardingFlow.shared.rehearsal {
            OnboardingFlow.shared.startRehearsal()
            return
        }
        @Dependency(\.windowManager) var window
        window.show()
    }

    func signOut() async throws {
        if self.configured { try await Clerk.shared.auth.signOut() }
        self.clearAccount()
    }

    func clearAccount() {
        Defaults[.currentUserID] = nil
        self.welcomeAccount = nil
        LoginViewModel.shared.step = .email
        LoginViewModel.shared.password = ""
        LoginViewModel.shared.code = ""
        @Dependency(\.storage) var storage
        @Dependency(\.appRouter) var router
        try? storage.cleanFriendsStore()
        SettingsWindowController.shared.close()
        SocialStore.shared.reset()
        self.revision += 1
        router.move(to: .login)
        @Dependency(\.windowManager) var window
        window.show()
    }

    /// Someone who installed Firstlight from an invitation page arrives
    /// signed out and with the link no longer anywhere the app can see it,
    /// except the clipboard, where the page left it. A signed-out start
    /// looks there once; the tray then says where the link was found and
    /// Back declines it. Only whole Firstlight links count, never a bare code.
    func adoptClipboardInvite() {
        guard self.pendingInvite == nil,
              let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.contains("://"), text.count <= 512,
              (try? InviteInput.parse(text)) != nil
        else { return }
        self.pendingInviteSource = .clipboard
        self.pendingInvite = text
    }

    func handle(_ url: URL) async {
        if url.scheme == "firstlight", url.host == "invite" || url.host == "join" {
            self.reportHandoff(in: url)
            self.pendingInviteSource = .link
            self.pendingInvite = url.absoluteString
            @Dependency(\.windowManager) var window
            window.show()
            return
        }
        guard self.configured else { return }
        do {
            if try await Clerk.shared.handle(url), self.session?.status == .active { try await self.finishSignIn() }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Private

    private var events: Task<Void, Never>?

    /// The page that sent this link is still open and has no way of its own
    /// to tell whether anything opened: a browser is not told that another
    /// application took the link, and the focus it can watch lies in both
    /// directions. The `h` the page put in the link is a nonce it is asking
    /// the server about; one POST turns its guess into an answer. Nothing
    /// here waits for it, and a failure costs the invitation nothing.
    private func reportHandoff(in url: URL) {
        guard let handoff = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "h" })?.value,
            handoff.count == 36,
            handoff.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return }
        Task.detached {
            var request = URLRequest(url: AppEnvironment.baseURL.appending(path: "/api/handoff/\(handoff)"))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private func observeEvents() {
        guard self.events == nil else { return }
        self.events = Task { [weak self] in
            for await event in Clerk.shared.auth.events {
                guard let self else { return }
                revision += 1
                switch event {
                case .signedOut,
                     .accountDeleted: clearAccount()
                case let .sessionChanged(_, next):
                    if next == nil || next?.status == .revoked || next?.status == .expired { clearAccount() }
                default: break
                }
            }
        }
    }
}
