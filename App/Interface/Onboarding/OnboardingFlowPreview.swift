#if DEBUG
import AppKit
import SwiftUI

/// The whole path from the intro to the menu bar, in the real windows with
/// the real shader, on fixtures instead of Clerk and the network. Every state
/// the plan names can be switched from the fixtures palette beside the window.
/// `--preview-onboarding-flow`; nothing here touches the user's account.
enum OnboardingFlowPreview {
    @MainActor static func showIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--preview-onboarding-flow") else { return false }
        let model = OnboardingFlowPreviewModel.shared
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let raw = value("--flow-invite"), let invite = OnboardingFlowPreviewModel.Fixtures.Invite(rawValue: raw) {
            model.fixtures.invite = invite
        }
        if let raw = value("--flow-name") { model.fixtures.googleName = raw != "no" }
        if let raw = value("--flow-location"),
           let location = OnboardingFlowPreviewModel.Fixtures.Location(rawValue: raw)
        {
            model.fixtures.location = location
        }
        model.start(replayIntro: value("--flow-intro") != "no")
        // A step to land on without a hand at the keyboard, once the window is up.
        if let raw = value("--flow-jump") {
            let step: OnboardingStage.Step? = switch raw {
            case "day": .day
            case "friends": .friends
            case "profile": .profile
            case "privacy": .privacy
            case "invite": .invite
            case "handoff": .handoff
            default: nil
            }
            if let step {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    model.jump(to: step)
                    // A filled form, for a look at the row without typing.
                    if args.contains("--flow-filled") {
                        model.flow.draft.firstName = "Alex"
                        model.flow.draft.bio = "Building a design tool, mostly at night"
                        model.flow.draft.location = "San Francisco"
                    }
                    // A row of a showing chapter to land on.
                    if let row = value("--flow-row").flatMap(Int.init) { model.stage.open(row: row) }
                }
            }
        }
        return true
    }
}

@MainActor
final class OnboardingFlowPreviewModel: ObservableObject {
    // MARK: Internal

    struct Fixtures: Equatable {
        enum Invite: String, CaseIterable, Identifiable {
            case friend, group, none, expired, late

            // MARK: Internal

            var id: String { self.rawValue }
            var title: String {
                switch self {
                case .friend: "From a friend"
                case .group: "To a group"
                case .none: "No invite"
                case .expired: "Link expired"
                case .late: "Answer after the title"
                }
            }
        }

        enum Auth: String, CaseIterable, Identifiable {
            case ok, cancel, error, unavailable

            // MARK: Internal

            var id: String { self.rawValue }
            var title: String {
                switch self {
                case .ok: "Succeeds"
                case .cancel: "Google closed"
                case .error: "Network error"
                case .unavailable: "Google unavailable"
                }
            }
        }

        enum Outcome: String, CaseIterable, Identifiable {
            case ok, error

            // MARK: Internal

            var id: String { self.rawValue }
        }

        enum Location: String, CaseIterable, Identifiable {
            /// The real Location Services prompt and lookup.
            case system, granted, denied

            // MARK: Internal

            var id: String { self.rawValue }
        }

        var invite: Invite = .friend
        var googleName = true
        var auth: Auth = .ok
        var profileFilled = false
        var location: Location = .system
        var save: Outcome = .ok
        var reduceMotion = false
    }

    static let shared = OnboardingFlowPreviewModel()

    let stage = OnboardingStage.shared
    let controller = OnboardingWindowController(
        defaults: UserDefaults(suiteName: "sh.firstlight.onboarding.flow-preview")!
    )

    @Published var fixtures = Fixtures()
    @Published private(set) var signingIn = false
    @Published private(set) var signInLabel = "Opening Google…"
    @Published private(set) var signInError: String?
    @Published private(set) var panelOpen = false

    /// The real flow, on a backend that answers from the fixtures: the same
    /// chapters, saves that wait and fail on request, nothing sent anywhere.
    private(set) lazy var flow = OnboardingFlow(backend: self.backend, stage: self.stage)

    var inviterName: String? {
        switch self.fixtures.invite {
        case .friend,
             .group,
             .late: "Anna"
        case .none,
             .expired: nil
        }
    }

    /// Opens (or reopens) the onboarding window on the current fixtures.
    func start(replayIntro: Bool) {
        self.generation += 1
        WelcomeInvite.fixture = self.inviteFixture
        self.stage.reset()
        self.signingIn = false
        self.signInLabel = "Opening Google…"
        self.signInError = nil
        self.flow.reset()
        self.closePanel()
        self.ensureMenuBar()
        self.controller.onClose = nil
        self.controller.close()
        self.controller.onClose = { NSApp.terminate(nil) }
        self.controller.show(
            content: AnyView(OnboardingFlowPreviewContent(model: self)),
            forceAnimation: replayIntro
        )
        self.showPalette()
    }

    /// Jumps straight to a step, with the state that step assumes.
    func jump(to step: OnboardingStage.Step) {
        self.controller.finishAnimation()
        switch step {
        case .welcome: self.start(replayIntro: false)
        case .day,
             .friends,
             .profile,
             .privacy,
             .invite:
            if step > .profile, !self.flow.hasName { self.flow.draft.firstName = "Alex" }
            self.stage.advance(to: step)
        case .handoff: self.handoff()
        }
    }

    func signIn() {
        guard !self.signingIn else { return }
        let ticket = self.generation
        self.signInError = nil
        self.signingIn = true
        self.signInLabel = "Opening Google…"
        self.after(0.7) { [self] in
            guard ticket == self.generation else { return }
            self.signInLabel = "Waiting for Google…"
        }
        self.after(1.7) { [self] in
            guard ticket == self.generation else { return }
            switch self.fixtures.auth {
            case .cancel: self.signingIn = false
            case .error:
                self.signingIn = false
                self.signInError = "Cannot connect to Firstlight. Check your connection and try again."
            case .ok,
                 .unavailable:
                self.signInLabel = "Signing in…"
                self.after(0.9) {
                    guard ticket == self.generation else { return }
                    self.signingIn = false
                    self.next()
                }
            }
        }
    }

    func locate() async -> String? {
        switch self.fixtures.location {
        case .system: return await OnboardingCityLookup.city()
        case .granted:
            try? await Task.sleep(for: .seconds(1.2))
            return "San Francisco"
        case .denied:
            try? await Task.sleep(for: .seconds(1.2))
            return nil
        }
    }

    /// The end of the path, in real windows: the content rises out, the name
    /// goes, the mark flies to the status item and the panel opens on the
    /// person the story began with.
    func handoff() {
        let ticket = self.generation
        self.stage.advance(to: .handoff)
        self.after(0.25) { [self] in
            guard ticket == self.generation,
                  let start = self.controller.headerMarkScreenRect(),
                  let icon = self.statusIcon, let button = icon.statusBarButton,
                  let image = RayLogoImage.cropped
            else {
                self.controller.close()
                self.openPanel()
                return
            }
            let reduceMotion = self.fixtures.reduceMotion || NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
            self.stage.markInFlight = true
            icon.dim()
            OnboardingHandoff.fly(
                image: image, from: start, to: button, iconSide: icon.iconSide,
                reduceMotion: reduceMotion
            ) {
                guard ticket == self.generation else { return }
                icon.arrive()
                self.openPanel()
            }
            self.after(0.05) {
                guard ticket == self.generation else { return }
                self.controller.fadeOut(duration: reduceMotion ? 0.12 : 0.35) {}
            }
        }
    }

    func togglePanel() {
        if self.panelOpen { self.closePanel() } else { self.openPanel() }
    }

    // MARK: Private

    private var generation = 0
    private var statusIcon: StatusIconAnimator?
    private var panel: AppWindow?
    private var palette: NSPanel?

    private var inviteFixture: WelcomeInvite.Fixture {
        let anna = WelcomeInvite.Inviter(name: "Anna Lee", avatarURL: nil, destination: "Firstlight")
        switch self.fixtures.invite {
        case .friend: return .init(inviter: anna)
        case .group: return .init(inviter: .init(name: "Anna Lee", avatarURL: nil, destination: "Design Club"))
        case .none: return .init(inviter: nil)
        case .expired: return .init(inviter: nil, expired: true)
        // The title is up at about eight real seconds; this lands well after.
        case .late: return .init(inviter: anna, delay: 12)
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { work() }
    }

    private var backend: OnboardingBackend {
        OnboardingBackend(
            saveProfile: { [unowned self] _ in
                try? await Task.sleep(for: .seconds(1.1))
                if self.fixtures.save == .error { throw NativeError.message("Could not save your profile.") }
            },
            saveSharing: { [unowned self] _ in
                try? await Task.sleep(for: .seconds(0.6))
                if self.fixtures.save == .error { throw NativeError.message("Could not save your choice.") }
            },
            inviteLink: {
                try? await Task.sleep(for: .seconds(0.5))
                return "https://firstlight.sh/join/K7M2QX"
            },
            addByCode: { [unowned self] _ in
                try? await Task.sleep(for: .seconds(0.9))
                if self.fixtures.save == .error { throw NativeError.message("No one has that code.") }
                return self.fixtures.invite == .none ? .requested("Anika") : .connected("Anika")
            },
            locate: { [unowned self] in await self.locate() },
            uploadPhoto: { _ in
                try? await Task.sleep(for: .seconds(1.0))
                return nil
            },
            finish: { [unowned self] in self.handoff() }
        )
    }

    private func next() {
        if self.fixtures.profileFilled {
            self.handoff()
        } else {
            self.flow.draft.firstName = self.fixtures.googleName ? "Alex" : ""
            self.stage.advance(to: .day)
        }
    }

    /// The status item is there from launch, as in the real app; the panel
    /// is built now so it opens loaded, not on a skeleton.
    private func ensureMenuBar() {
        if self.statusIcon == nil {
            self.statusIcon = StatusIconAnimator(menu: StatusItemMenu(
                toggle: { [weak self] in self?.togglePanel() },
                open: { [weak self] in self?.openPanel() },
                invite: {},
                beforeMenu: { [weak self] in self?.closePanel() },
                settings: {},
                canOpenSettings: { false },
                replayOnboarding: { [weak self] in self?.start(replayIntro: true) },
                canReplayOnboarding: { true },
                quit: { NSApp.terminate(nil) }
            ))
        }
        if self.panel == nil {
            self.panel = AppWindow(content: AnyView(OnboardingFlowPreviewPanel(model: self)))
        }
    }

    private func openPanel() {
        guard let panel, let button = statusIcon?.statusBarButton, let window = button.window,
              let screen = window.screen else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: NativeLayout.popoverWidth, height: 360)
        let width = NativeLayout.popoverWidth
        var x = rect.minX - 16
        if x + width > screen.visibleFrame.maxX { x = rect.maxX - width + 16 }
        let top = rect.minY - 5
        let final = NSRect(x: x, y: top - size.height, width: width, height: size.height)
        panel.setFrame(final.offsetBy(dx: 0, dy: 8), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        self.statusIcon?.highlight()
        self.panelOpen = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = self.fixtures.reduceMotion ? 0.12 : 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    private func closePanel() {
        self.panel?.orderOut(nil)
        self.statusIcon?.unhighlight()
        self.panelOpen = false
    }

    /// The fixtures, in a small palette to the right of the window.
    private func showPalette() {
        if self.palette == nil {
            let palette = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 250, height: 420),
                styleMask: [.titled, .utilityWindow, .nonactivatingPanel, .hudWindow],
                backing: .buffered, defer: false
            )
            palette.title = "Preview fixtures"
            palette.isFloatingPanel = true
            palette.isReleasedWhenClosed = false
            palette.hidesOnDeactivate = false
            palette.contentView = NSHostingView(rootView: OnboardingFlowPreviewPalette(model: self))
            self.palette = palette
        }
        guard let palette, let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        palette.setFrameTopLeftPoint(NSPoint(x: area.maxX - 262, y: area.maxY - 12))
        palette.orderFront(nil)
    }
}

// MARK: - Window content

/// What the onboarding window holds after the intro: the sign-in button in
/// Welcome, then the steps, each under the header that stays.
private struct OnboardingFlowPreviewContent: View {
    // MARK: Internal

    @ObservedObject var model: OnboardingFlowPreviewModel

    var body: some View {
        ZStack {
            switch self.stage.step {
            case .welcome:
                self.welcomeEntry
            case .day,
                 .friends,
                 .profile,
                 .privacy,
                 .invite:
                OnboardingChaptersView(flow: self.model.flow)
                    .transition(OnboardingStage.chapters)
            case .handoff:
                Color.clear
            }
        }
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared

    /// The same column `LoginView.welcomeEntry` lays out: an error line when
    /// there is one, and the pill.
    private var welcomeEntry: some View {
        VStack(spacing: 14) {
            if let error = model.signInError {
                NativeInlineError(message: error).frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            if self.model.fixtures.auth == .unavailable {
                Text("Google sign-in is currently unavailable.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                OnboardingContinueButton(
                    isLoading: self.model.signingIn, isEnabled: !self.model.signingIn,
                    loadingTitle: self.model.signInLabel, action: self.model.signIn
                )
            }
        }
        .padding(16)
        .animation(.easeOut(duration: 0.2), value: self.model.signInError)
    }
}

// MARK: - Palette

private struct OnboardingFlowPreviewPalette: View {
    @ObservedObject var model: OnboardingFlowPreviewModel

    var body: some View {
        Form {
            Section("Invite") {
                Picker("Invite", selection: self.$model.fixtures.invite) {
                    ForEach(OnboardingFlowPreviewModel.Fixtures.Invite.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .onChange(of: self.model.fixtures.invite) { self.model.start(replayIntro: false) }
            }
            Section("Sign-in") {
                Picker("Google", selection: self.$model.fixtures.auth) {
                    ForEach(OnboardingFlowPreviewModel.Fixtures.Auth.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Google gives a name", isOn: self.$model.fixtures.googleName)
                Toggle("Profile already filled", isOn: self.$model.fixtures.profileFilled)
            }
            Section("Profile") {
                Picker("Location", selection: self.$model.fixtures.location) {
                    Text("System prompt").tag(OnboardingFlowPreviewModel.Fixtures.Location.system)
                    Text("Granted").tag(OnboardingFlowPreviewModel.Fixtures.Location.granted)
                    Text("Denied").tag(OnboardingFlowPreviewModel.Fixtures.Location.denied)
                }
                Picker("Save", selection: self.$model.fixtures.save) {
                    Text("Succeeds").tag(OnboardingFlowPreviewModel.Fixtures.Outcome.ok)
                    Text("Fails").tag(OnboardingFlowPreviewModel.Fixtures.Outcome.error)
                }
                Toggle("Reduce Motion", isOn: self.$model.fixtures.reduceMotion)
            }
            Section("Jump to") {
                HStack {
                    Button("Welcome") { self.model.jump(to: .welcome) }
                    Button("Day") { self.model.jump(to: .day) }
                    Button("Friends") { self.model.jump(to: .friends) }
                }
                .controlSize(.small)
                HStack {
                    Button("Profile") { self.model.jump(to: .profile) }
                    Button("Privacy") { self.model.jump(to: .privacy) }
                    Button("Invite") { self.model.jump(to: .invite) }
                    Button("Handoff") { self.model.jump(to: .handoff) }
                }
                .controlSize(.small)
            }
            Section {
                HStack {
                    Button("Replay intro") { self.model.start(replayIntro: true) }
                    Button("Restart") { self.model.start(replayIntro: false) }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .frame(width: 250)
    }
}

// MARK: - Menu-bar panel

/// The reward the panel opens on: the person whose face was the first thing
/// on screen, now in the first row. Same rows as the real lists; fixed data.
private struct OnboardingFlowPreviewPanel: View {
    // MARK: Internal

    @ObservedObject var model: OnboardingFlowPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(["Friends", "Design Club", "Leaderboard"], id: \.self) { tab in
                    let active = tab == (self.model.fixtures.invite == .group ? "Design Club" : "Friends")
                    Text(tab)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(active ? Color.primary.opacity(0.12) : .clear, in: Capsule())
                        .foregroundStyle(active ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            if let line = self.tray {
                Label(line, systemImage: "checkmark")
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            if self.model.inviterName != nil {
                self.row(name: "Anna", location: "San Francisco", line: "In Figma · 1 agent now", time: "2h 14m")
            }
            self.row(name: "Max", location: "Berlin", line: "Shipping a game engine", time: "1h 02m")
            self.row(name: "Julia", location: nil, line: "In Xcode · 2 agents now", time: "41m")
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            let draft = self.model.flow.draft
            let bio = draft.bio.trimmingCharacters(in: .whitespacesAndNewlines)
            let city = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
            self.row(
                name: draft.firstName.isEmpty ? "You" : draft.firstName,
                location: city.isEmpty ? nil : city,
                line: bio.isEmpty ? "Add a few words about yourself" : bio, time: "0m"
            )
            Spacer(minLength: 8)
        }
        .frame(width: NativeLayout.popoverWidth)
        .fontDesign(.rounded)
        .onExitCommand { self.model.togglePanel() }
    }

    // MARK: Private

    private var tray: String? {
        switch self.model.fixtures.invite {
        case .friend,
             .late: "You and Anna are now friends"
        case .group: "You joined Design Club"
        case .none,
             .expired: nil
        }
    }

    /// The accepted social row: avatar, name with its location, one line under
    /// it, the time on the right, 60 pt whatever the data.
    private func row(name: String, location: String?, line: String, time: String) -> some View {
        HStack(spacing: 10) {
            FirstlightAvatar(url: nil, name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let location {
                        Label(location, systemImage: "location")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 196, alignment: .leading)
            Spacer(minLength: 0)
            Text(time).font(.system(size: 15, weight: .medium)).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
    }
}
#endif
