import Defaults
import Dependencies
import Nuke
import NukeUI
import SwiftUI

/// Where a detail screen's own title sits in the scrolling viewport, measured
/// to the middle of it. It falls as the screen scrolls up, and the title is
/// held once it reaches the line the floating buttons sit on.
private struct ProfileTitleCenter: PreferenceKey {
    static var defaultValue: CGFloat { .greatestFiniteMagnitude }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// How one screen gives way to the next, modelled on an iOS push with a hero
/// element. The tapped avatar, name, location and total travel on the
/// navigation spring (set where the screen changes). The screens themselves
/// drift a few points the same way on that spring, so a push reads as going
/// deeper and Back as returning; the one on top moves more than the one
/// underneath, like a room seen past a door.
///
/// The two screens trade opacity on complementary curves — the one leaving
/// holds and drops late, the one arriving comes up at once — so the pair is
/// worth about a full screen the whole way across. That matters for exactly
/// one thing: the morphing avatar is the only object in the panel drawn twice
/// at the same place at the same time, once on each screen. Curving both fades
/// the same way leaves a trough in the middle where neither copy is solid, and
/// the portrait ghosts halfway through its flight and snaps back to full at the
/// end. Nothing else in the panel is doubled, so nothing else pays for the
/// brief overlap, and the two screens are drifting apart while it lasts.
private enum ScreenMotion {
    // MARK: Internal

    /// How far the screen on top travels: in from the side on a push, back
    /// out on a pop. Small on purpose; the popover is 350 pt wide.
    static let topDrift: CGFloat = 16
    /// The screen underneath moves less, the way the floor does.
    static let behindDrift: CGFloat = 7
    /// A tab change slides the whole list the way the tab lies.
    static let tabDrift: CGFloat = 22

    @MainActor static func list(reduceMotion: Bool) -> AnyTransition {
        self.screen(.behind, fade: self.fade(for: SocialStore.shared.navigation), reduceMotion)
    }

    @MainActor static func detail(reduceMotion: Bool) -> AnyTransition {
        self.screen(.navigating, fade: self.fade(for: SocialStore.shared.navigation), reduceMotion)
    }

    /// A tab change is not a push, and nothing in it is doubled: the rows of
    /// one tab share no geometry with the rows of another, so the list leaving
    /// has nothing to hand over and no reason to hold its opacity while it
    /// goes. It drops first and quickly; the one arriving comes up behind it.
    /// Holding both near half — which a push needs, so the one portrait drawn
    /// on both screens stays solid — only prints two lists over each other
    /// here, the same people at two heights, sliding opposite ways.
    static func tab(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: self.drift(.appearing, .tab, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: self.tabInFade))),
            removal: self.drift(.disappearing, .tab, reduceMotion)
                .combined(with: .opacity.animation(.easeIn(duration: self.tabOutFade)))
        )
    }

    // MARK: Private

    /// A little under the navigation curve, so the picture is settled just
    /// before the motion is and the arrival reads as a stop rather than a fade.
    /// The list leaving and the detail arriving are two halves of one push, so
    /// they have to share this number or the halves will not add up — and each
    /// direction keeps the same share of its own length, which is shorter on
    /// the way back than on the way out.
    private static let navigationOpenFade: Double = 0.24
    private static let navigationCloseFade: Double = 0.19
    /// Tabs swap one list for another with nothing travelling between them,
    /// so the swap can be quicker than a push — and the halves are not equal.
    /// The list leaving is gone before the panel has finished moving, which is
    /// what keeps the two out of each other's way; the one arriving takes
    /// longer, so it reads as settling in rather than being cut on.
    private static let tabOutFade: Double = 0.1
    private static let tabInFade: Double = 0.2
    /// A portrait opening has one object travelling and nothing arriving
    /// behind it, so the trade is over almost before it starts: the picture is
    /// solid a frame or two into the flight and the profile is gone from under
    /// it. Any longer and the flight is chasing a fade instead of leading it.
    /// Each side keeps the same share of its own flight, which is longer on
    /// the way out than on the way back.
    private static let photoOpenFade: Double = 0.17
    private static let photoCloseFade: Double = 0.14

    /// Read as the change happens, not captured up front: the screen on its way
    /// out is no longer updated and still has to fade on the same terms as the
    /// one arriving.
    @MainActor private static func fade(for navigation: SocialStore.Navigation) -> Double {
        if navigation.isPhoto {
            return navigation.isOpening ? self.photoOpenFade : self.photoCloseFade
        }
        return navigation.isOpening ? self.navigationOpenFade : self.navigationCloseFade
    }

    private static func screen(_ role: ScreenDrift.Role, fade: Double, _ reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: self.drift(.appearing, role, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: fade))),
            removal: self.drift(.disappearing, role, reduceMotion)
                .combined(with: .opacity.animation(.easeIn(duration: fade)))
        )
    }

    /// The drift carries no animation of its own, so it rides whatever the
    /// screen change was wrapped in: the same spring as the flying avatar.
    private static func drift(_ phase: ScreenDrift.Phase, _ role: ScreenDrift.Role, _ reduceMotion: Bool)
        -> AnyTransition
    {
        .modifier(
            active: ScreenDrift(phase: phase, role: role, reduceMotion: reduceMotion, progress: 1),
            identity: ScreenDrift(phase: phase, role: role, reduceMotion: reduceMotion, progress: 0)
        )
    }
}

/// The sideways travel of a screen while it appears or leaves. Which way is
/// read from the store as the modifier animates, not captured up front: the
/// leaving screen is no longer updated, but it still has to go the right way.
private struct ScreenDrift: ViewModifier, Animatable {
    // MARK: Internal

    enum Phase { case appearing, disappearing }

    enum Role {
        /// The list under every other screen. Always underneath.
        case behind
        /// A detail screen: on top when pushed, underneath when another is
        /// pushed over it, on top again when popped.
        case navigating
        /// A list replaced by the same list for another tab.
        case tab
    }

    let phase: Phase
    let role: Role
    let reduceMotion: Bool
    var progress: Double

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    func body(content: Content) -> some View {
        // Offset alone. A scale was here too, and its factor was one in every
        // case: on a screen this size it bought nothing visible, and it cost a
        // rasterised layer over the whole panel for the length of every push.
        content.offset(x: self.drift * self.progress)
    }

    // MARK: Private

    @MainActor private var drift: CGFloat {
        if self.reduceMotion { return 0 }
        let store = SocialStore.shared
        // The portrait opening is one picture growing, not two screens
        // trading places. A screen sliding out from under it would say the
        // opposite of what the flight is saying.
        if store.navigation.isPhoto { return 0 }
        switch self.role {
        case .behind:
            return -ScreenMotion.behindDrift
        case .tab:
            let sign: CGFloat = self.phase == .appearing ? 1 : -1
            return sign * store.tabDirection * ScreenMotion.tabDrift
        case .navigating:
            let onTop = (self.phase == .appearing) == (store.navigation.direction == .forward)
            return onTop ? ScreenMotion.topDrift : -ScreenMotion.behindDrift
        }
    }
}

struct NativeDashboardView: View {
    // MARK: Internal

    var body: some View {
        let detailScreen = self.store.screen
        // Both screens live in the tree while one replaces the other, so they
        // overlap instead of stacking. They do not share a height while they
        // do: a screen still running its removal transition is drawn but no
        // longer sizes the stack, so the panel takes the arriving screen's
        // height on the very frame of the change. Whatever height a screen
        // asks for, it asks for from the first frame — see `profileFillsPanel`.
        ZStack(alignment: .top) {
            if store.screen == .list {
                people
                    .geometryGroup()
                    .transition(ScreenMotion.list(reduceMotion: self.reduceMotion))
            } else {
                // No bar of its own: a profile starts at the top of the panel
                // and its buttons hang over it, so the height the bar took is
                // the profile's to use. See `profileActions`.
                PopoverContent(
                    maximumHeight: NativeLayout.peopleBodyHeight + NativeLayout.popoverHeaderHeight,
                    reservesMaximumHeight: self.profileFillsPanel,
                    scrollOffset: Binding(
                        get: { self.store.detailScrollOffsets[detailScreen] ?? 0 },
                        set: { self.store.detailScrollOffsets[detailScreen] = $0 }
                    )
                ) {
                    content.disabled(store.busy)
                    // The tray shows its own errors; only with it closed
                    // does a failure belong to the profile underneath.
                    if let error = store.error, store.tray == nil {
                        NativeInlineError(message: error, retry: store.retry)
                    }
                }
                .overlay(alignment: .top) {
                    profileActions
                }
                .onPreferenceChange(ProfileTitleCenter.self) { center in profileTitleCenter = center }
                .onChange(of: store.screen) { _, _ in profileTitleCenter = .greatestFiniteMagnitude }
                .geometryGroup()
                // Keyed on the screen, so Add friends → Sent requests is a
                // push and Back from it a pop, not a swap of the contents.
                .id(store.screen)
                .transition(ScreenMotion.detail(reduceMotion: self.reduceMotion))
            }
        }
        // The invite tray sits over whichever screen is showing, under the
        // toasts, and dims what is beneath it without replacing it.
        .overlay(alignment: .bottom) { self.inviteTrayLayer }
        .animation(
            NativeTrayMorph.animation(isExpanded: self.store.tray != nil, reduceMotion: self.reduceMotion),
            value: self.store.tray != nil
        )
        // A day of somebody's agents sits the same way over the Agents
        // screen, grown out of the record that named it.
        .overlay(alignment: .bottom) { self.agentDayTrayLayer }
        .coordinateSpace(name: AgentTileFrames.space)
        .animation(
            AgentTrayGrow.animation(opening: self.store.agentDayTray != nil, reduceMotion: self.reduceMotion),
            value: self.store.agentDayTray != nil
        )
        .bumpSurface()
        .textFieldStyle(.roundedBorder).controlSize(.regular).font(.system(size: 13))
        .overlay(alignment: .top) {
            if let feedback = store.feedbackToast {
                NativeFeedbackToast(state: feedback)
                    .padding(.top, NativeLayout.popoverHeaderHeight + 7)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            } else if let notice = store.notice {
                NativeFeedbackToast(state: .success(notice))
                    .padding(.top, NativeLayout.popoverHeaderHeight + 7)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.snappy(duration: 0.16), value: store.feedbackToast)
        .animation(.snappy(duration: 0.16), value: store.notice)
        .task { resumeInvite() }
        .task(id: store.listKey) {
            await store.refresh()
            if case .person = store.screen { store.refreshCurrentScreen(force: true) }
            if case .agents = store.screen { store.refreshCurrentScreen(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("FirstlightSharingChanged"))) { _ in
            self.appDirectory.clear()
        }
        .task(id: store.feedbackToast) {
            guard case let .success(message) = store.feedbackToast else { return }
            let expected = SocialStore.FeedbackToast.success(message)
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            guard store.feedbackToast == expected else { return }
            withAnimation(.easeOut(duration: 0.14)) { store.feedbackToast = nil }
        }
        .task(id: store.notice) {
            guard let notice = store.notice else { return }
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }
            guard store.notice == notice else { return }
            withAnimation(.easeOut(duration: 0.14)) { store.notice = nil }
        }
        .onReceive(timer) { _ in refreshVisibleScreen() }
        .onReceive(windowManager.isVisiblePublisher.removeDuplicates().dropFirst()) { visible in
            if visible {
                refreshVisibleScreen()
                if self.showingAppRanking {
                    let bundle = self.visibleAppBundle
                    let period = self.store.period
                    Task { await self.appDirectory.load(bundle, period: period) }
                }
            }
        }
        // The tray answers Escape first: Back where it has somewhere to go,
        // close otherwise. Only with no tray does Escape reach the screens.
        .onExitCommand {
            if BumpEffects.shared.incoming != nil { BumpEffects.shared.dismissIncoming() }
            else if BumpEffects.shared.trayOpen {
                BumpEffects.shared.trayOpen = false
            } else if store.agentDayTray != nil { store.closeAgentDay() }
            else if store.tray != nil { store.trayBack() }
            else if store.screen == .list { windowManager.hide() }
            else { store.goBack() }
        }
        .onChange(of: session.pendingInvite) { _, _ in resumeInvite() }
        .onChange(of: store.inviter) { _, _ in acceptDefaultInvite() }
        .alert(confirmationTitle, isPresented: $confirming) {
            Button("Cancel", role: .cancel) { confirmationAction = nil }
            Button("Confirm", role: .destructive) { confirmationAction?(); confirmationAction = nil }
        }
        #if DEBUG
            .safeAreaInset(edge: .top, spacing: 0) { self.mocksBar }
        #endif
    }

    // MARK: Private

    #if DEBUG
    /// The invite mocks' own strip, above everything including the veil, so
    /// the cases can be switched while a tray is open. Debug builds only, and
    /// only once the mode is on; the status item menu turns it on.
    @ViewBuilder private var mocksBar: some View {
        if InviteMocks.isEnabled {
            HStack(spacing: 6) {
                Image(systemName: "testtube.2").font(.system(size: 11, weight: .medium))
                Text("Mocks").font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                Menu("Paste") {
                    ForEach(InviteMocks.people, id: \.code) { person in
                        Button("\(person.code) · \(person.name)\(person.isFriend ? " (friend)" : "")") {
                            self.pasteMock(person.code)
                        }
                    }
                    Button("\(InviteMocks.unknownCode) · nobody") { self.pasteMock(InviteMocks.unknownCode) }
                    Button("\(InviteMocks.ownCode) · your own code") { self.pasteMock(InviteMocks.ownCode) }
                    Divider()
                    Button("Personal link · makes friends at once") { self.pasteMock(InviteMocks.personalLink) }
                    Button("Group link · Runway") { self.pasteMock(InviteMocks.groupLink) }
                    Button("Group link · expired") { self.pasteMock(InviteMocks.expiredLink) }
                }
                .menuStyle(.button).controlSize(.mini).fixedSize()
                Menu("Cases") {
                    ForEach(InviteMocks.Flake.allCases, id: \.rawValue) { flake in
                        Button {
                            InviteMocks.setFlake(flake, !InviteMocks.flake(flake))
                            self.mocksTick += 1
                        } label: {
                            if InviteMocks.flake(flake) { Label(flake.rawValue, systemImage: "checkmark") }
                            else { Text(flake.rawValue) }
                        }
                    }
                    Divider()
                    Menu("Waiting on you") {
                        ForEach(0 ... 3, id: \.self) { count in
                            Button(count == 0 ? "Nobody" : "\(count)") {
                                InviteMocks.incomingCount = count
                                self.store.reloadForMocks()
                            }
                        }
                    }
                    Menu("Sent by you") {
                        ForEach(0 ... 2, id: \.self) { count in
                            Button(count == 0 ? "None" : "\(count)") {
                                InviteMocks.outgoingCount = count
                                self.store.reloadForMocks()
                            }
                        }
                    }
                    Divider()
                    Button("Start over") { InviteMocks.reset(); self.store.reloadForMocks() }
                    Button("Turn mocks off") {
                        InviteMocks.isEnabled = false
                        self.store.reloadForMocks()
                        self.mocksTick += 1
                    }
                }
                .menuStyle(.button).controlSize(.mini).fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.16))
            .overlay(alignment: .bottom) { Divider() }
            .id(self.mocksTick)
        }
    }

    /// Puts a mock code or link in the field as if it had been pasted, opening
    /// the tray first when it is closed.
    private func pasteMock(_ value: String) {
        if self.store.tray == nil { self.store.openTray(.home, from: .footerInvite) }
        self.store.query = value
        self.store.queryChanged()
        self.inviteFieldFocused = true
    }
    #endif

    private struct GroupDrag {
        let id: String
        let index: Int
        var translation: CGFloat = 0
        /// Where the tab would land if released now.
        var target: Int
    }

    /// Every row column shares the avatar's vertical centre, so the name, the
    /// duration and the running app sit on one line whether or not the profile
    /// carries a second line. The divider starts exactly where the text does.
    private static let rowHorizontalPadding: CGFloat = 12
    private static let rowAvatarSize: CGFloat = 40
    private static let rowAvatarSpacing: CGFloat = 10
    /// The place leads a ranked row in a fixed column, so the numbers line up
    /// down the list however many digits they carry.
    private static let rowPlaceWidth: CGFloat = 20
    private static let rowPlaceSpacing: CGFloat = 8
    /// The portrait on a profile, and the circle the photograph opens out of.
    private static let profileAvatarSize: CGFloat = 76
    private static let avatarMorphID = "avatar"
    private static let nameMorphID = "name"
    /// The agents card is one card on the profile and at the top of the
    /// Agents screen, and travels between the two.
    private static let agentsCardMorphID = "agents-card"
    /// The location sits on both screens too, right under the name, so it
    /// travels with it rather than vanishing and reappearing. The active
    /// total does not: it is a trailing note in the row and the headline of
    /// a tile in the profile, and far enough apart that the flight reads as
    /// a number wandering across the popover.
    private static let locationMorphID = "location"
    /// The icon of what a person is in, beside their time in the row.
    private static let appMorphID = "app"
    private static let rowDividerInset = rowHorizontalPadding + rowAvatarSize + rowAvatarSpacing
    private static let rankedRowDividerInset = rowDividerInset + rowPlaceWidth + rowPlaceSpacing

    // MARK: Group reordering

    private static let groupStripSpace = "groupStrip"
    private static let groupTabSpacing: CGFloat = 4

    /// Trays never reach the popover's header; anything taller scrolls inside.
    private static let trayMaximumHeight = NativeLayout.peopleBodyHeight - 8

    /// The line the floating buttons sit on, and where the name comes to rest
    /// once the profile has scrolled it up to them.
    private static let profileTitleRow: CGFloat = NativeLayout.popoverHeaderHeight / 2
    /// The last stretch of scrolling before that line, over which the name
    /// shrinks to the size it keeps in the row. Read off the scroll, never
    /// animated: an animation would still be playing while the wheel turned,
    /// which is what blinks.
    private static let profileTitleTravel: CGFloat = 26
    /// What the name comes down to: the 13 pt the row's own labels are, as a
    /// share of the 20 pt the profile gives it.
    private static let profileTitleRowScale: CGFloat = 13.0 / 20.0
    /// How late in that travel the band comes in. By then the name is within
    /// a few points of its place, so the band arrives rather than slides.
    private static let profileBandStart: Double = 0.55
    /// The band is the row's, not the name's, so it is drawn wider than the
    /// panel and cut to the edges by the scroll view.
    private static let profileBandWidth: CGFloat = 420
    /// The portrait starts under the floating buttons, not against the top of
    /// the panel: the buttons hang over the profile, they do not sit on it.
    /// `PopoverContent` already pads by 14, so this is what it takes on top.
    private static let profileTopInset: CGFloat = 26

    @ObservedObject private var store = SocialStore.shared
    @StateObject private var appDirectory = NativeAppDirectory()
    @Namespace private var appMorph
    @Namespace private var inviteMorph
    @State private var appMorphSources: [String: String] = [:]
    /// False while the skeleton stands in for the list, so the rows that
    /// replace it have somewhere to come up from.
    @State private var rowsRevealed = true
    @ObservedObject private var session = NativeSession.shared
    @ObservedObject private var bumps = BumpCenter.liveValue
    @Dependency(\.windowManager) private var windowManager
    /// The chart column the pointer is on, shared by the two numbers above it.
    @State private var agentsHovered: AgentBucket?
    /// The open day's natural height, once it has laid itself out.
    @State private var agentDayHeight: CGFloat?
    /// Where the record tiles stand, and the one the open day grew out of.
    @State private var agentTileFrames = AgentTileFrames()
    @State private var agentDaySource: CGRect?
    /// How far the tray's title starts from its place, over the tile's own
    /// title, and whether it has been sent home yet.
    @State private var agentDayTitleTravel: CGSize?
    @State private var agentDayTitleLanded = false
    @State private var confirming = false
    @State private var confirmationTitle = ""
    @State private var confirmationAction: (() -> Void)?
    @State private var headerScrollFades = HorizontalScrollFades()
    /// The group tab being dragged along the strip, if any.
    @State private var groupDrag: GroupDrag?
    /// Where each group tab sits in the strip while nothing is dragged; the
    /// drag reads these to tell which neighbours the pointer has crossed.
    @State private var groupTabFrames: [String: CGRect] = [:]
    /// The AppKit view the period menu pops up from, and the object its
    /// items call back into. Both live as long as the view does.
    @State private var profileTitleCenter = CGFloat.greatestFiniteMagnitude
    /// The row whose avatar flies into the profile. A person can sit in the
    /// list and in the pinned row at once, so the origin is part of the key:
    /// only one row may claim the shared geometry at a time.
    @State private var morphSource: String?
    @Namespace private var morph
    /// The tab strip's one selection pill, shared between the tabs so it
    /// slides from the old tab to the new instead of switching off and on.
    @Namespace private var tabPill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The tray's field takes focus when Home opens, so a code can be pasted
    /// without a click. It keeps focus across Home ↔ Send request because the
    /// field is the same view on both.
    @FocusState private var inviteFieldFocused: Bool
    /// The height the tray's step area is showing, moved on the tray spring
    /// towards the arriving step's natural height. Nil until the first step
    /// has laid itself out; the frame is then whatever it needs.
    @State private var trayStepHeight: CGFloat?
    /// Natural heights as the steps reported them, one per tray.
    @State private var trayStepNatural: [SocialStore.Tray: CGFloat] = [:]
    #if DEBUG
    /// Bumped whenever a mock switch is flipped: the settings live in
    /// `UserDefaults`, which nothing here observes.
    @State private var mocksTick = 0
    #endif
    /// The mark on a result tray: it lands with a bounce, once.
    @State private var resultCheckShown = false
    /// True for a beat as a request lands in the Sent pill.
    @State private var pillLanding = false
    /// The Joined tray's mark: lands, waits for the new group's tab to be
    /// there, then flies up into it while the list moves to the group.
    @State private var joinedCheckShown = false
    @State private var joinedCheckLanded = false
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// How far the name has moved from the profile into the floating row: 0
    /// while it is the profile's own title, 1 once the row is carrying it.
    /// Read straight off where the name is, so the hand-over follows the
    /// wheel: the profile's name dims as the row's comes up, both crossing at
    /// half strength within a few points of the same spot. One name shrinking
    /// into its place in the row, rather than one view leaving and another
    /// arriving on a timer of its own.
    private var profileTitleProgress: Double {
        Self.progress(
            self.profileTitleCenter,
            from: Self.profileTitleRow + Self.profileTitleTravel,
            to: Self.profileTitleRow
        )
    }

    /// How far the name is being held back from the scroll that carries it: 0
    /// until it reaches the row's line, then exactly what the profile has gone
    /// past it, which is what leaves it standing there.
    private var profileTitleStick: CGFloat {
        max(0, Self.profileTitleRow - self.profileTitleCenter)
    }

    /// The band's share of the same travel: the tail of it.
    private var profileBandStrength: Double {
        let progress = self.profileTitleProgress
        return min(max((progress - Self.profileBandStart) / (1 - Self.profileBandStart), 0), 1)
    }

    /// Whether this profile is one that fills the panel.
    ///
    /// A person with time on the clock gets the agents card with its chart and
    /// an app breakdown under it, and that profile runs past the height the
    /// popover is allowed; a person with nothing recorded gets neither card nor
    /// breakdown, and that profile should not sit in a tall empty panel. So the
    /// screen takes one of two shapes, and which one is read from the
    /// leaderboard row the list was built from — in hand before the screen
    /// changes, so the panel has its height on the first frame of the push and
    /// keeps it until the screen is left.
    ///
    /// The alternative is to measure the profile and follow the measurement,
    /// and it cannot settle: the agents card grows when the summary lands and
    /// the app rows replace a skeleton that guessed how many there would be, so
    /// the height only stops moving once the request has answered. Reserving
    /// the panel's full height *while loading* only hides that from the push
    /// and hands it to the response instead — the popover then holds the list's
    /// height through the whole navigation and drops a quarter second later,
    /// on the window's own spring, as a second motion with nothing to do with
    /// the tap that caused it. A profile that has some slack under it reads as
    /// a panel with room; a panel that resizes after it has arrived reads as a
    /// mistake.
    private var profileFillsPanel: Bool {
        if case .app = self.store.screen { return true }
        if case .agents = self.store.screen { return true }
        guard case .person = self.store.screen, let person = self.store.selectedPerson else { return false }
        // Either board's figure counts: on the agent board a person can have
        // agent minutes and no time of their own, and the card still fills.
        return (person.active_minutes ?? 0) > 0 || (person.score ?? 0) > 0
    }

    /// Whether the app breakdown is still on its way, and the rows standing in
    /// for it should show. Only ever true on a profile that fills the panel, so
    /// the skeleton always lands in height that is already spoken for.
    private var isLoadingProfileActivity: Bool {
        self.profileFillsPanel && self.store.screenLoading && self.store.activity == nil
    }

    private var header: some View {
        HStack(spacing: 7) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        tab("Friends", id: "friends")
                        ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                            tab(group.name, id: group.id)
                                .contextMenu {
                                    Button {
                                        SettingsWindowController.shared.show(
                                            section: .groups,
                                            groupsPage: .details(group.id)
                                        )
                                    } label: {
                                        Label("Group settings", systemImage: "gearshape")
                                    }
                                    Button {
                                        store.copyGroupInvite(group.id)
                                    } label: {
                                        Label("Copy invite link", systemImage: "doc.on.doc")
                                    }
                                    .disabled(store.busy)
                                    Divider()
                                    Button {
                                        self.moveGroup(group.id, to: index - 1)
                                    } label: {
                                        Label("Move left", systemImage: "arrow.left")
                                    }
                                    .disabled(index == 0)
                                    Button {
                                        self.moveGroup(group.id, to: index + 1)
                                    } label: {
                                        Label("Move right", systemImage: "arrow.right")
                                    }
                                    .disabled(index == store.groups.count - 1)
                                }
                                .modifier(self.groupTabDragging(group.id, at: index))
                        }
                        tab("Leaderboard", id: "global")
                    }
                    .coordinateSpace(name: Self.groupStripSpace)
                    // The pill and the label colours move on a short, flat
                    // curve of their own: a tab change is frequent, so it gets
                    // the small touch, not the navigation spring.
                    .animation(self.reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0), value: store.tab)
                    // A tab arriving or leaving (a group joined, left or
                    // deleted) moves its neighbours on the settling spring.
                    .animation(self.reduceMotion ? nil : SocialStore.settle, value: store.groups.map(\.id))
                }
                .scrollIndicators(.hidden)
                // ⌘⇧[ and ⌘⇧], the Mac's previous and next tab. Invisible
                // buttons carry the shortcuts; the tabs themselves answer.
                .background {
                    Group {
                        Button("Previous tab") { store.selectAdjacentTab(-1) }
                            .keyboardShortcut("[", modifiers: [.command, .shift])
                        Button("Next tab") { store.selectAdjacentTab(1) }
                            .keyboardShortcut("]", modifiers: [.command, .shift])
                    }
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
                .onScrollGeometryChange(for: HorizontalScrollFades.self) { geometry in
                    HorizontalScrollFades(geometry: geometry)
                } action: { _, fades in
                    self.headerScrollFades = fades
                }
                .mask { HorizontalScrollFadeMask(fades: self.headerScrollFades) }
                .onChange(of: store.tab) { _, value in withAnimation { reader.scrollTo(value, anchor: .center) } }
                // A strip built afresh starts at its leading edge: returning
                // from a profile, or opening the panel again, would leave a tab
                // chosen further right cut off or off screen. Put the chosen
                // tab back in view before the first frame, without animating.
                .onAppear { reader.scrollTo(store.tab, anchor: .center) }
                .onReceive(windowManager.isVisiblePublisher.removeDuplicates().dropFirst()) { visible in
                    if visible { reader.scrollTo(store.tab, anchor: .center) }
                }
            }
            .frame(maxWidth: .infinity)

            periodPicker
        }
        .padding(.horizontal, Self.rowHorizontalPadding)
        .frame(height: NativeLayout.popoverHeaderHeight)
    }

    /// A button, not a SwiftUI Menu. A Menu opens on mouse down, and a label
    /// that shrinks on that same mouse down breaks its tracking, so every
    /// other click did nothing. Here the press is the button's own, like a
    /// tab's, and the choices come up as a native menu on release.
    private var periodPicker: some View {
        NativePeriodPicker(
            period: self.store.period, metric: self.store.metric,
            apps: self.showingAppRanking,
            canChooseBoard: self.store.screen == .list && self.store.tab == "global",
            periodOnly: { if case .agents = self.store.screen { true } else { false } }(),
            appScope: self.appDirectory.context(for: self.visibleAppBundle).scope,
            appGroups: self.store.groups.map { (id: $0.id, name: $0.name) },
            onPeriod: self.store.setPeriod, onMetric: self.store.setMetric,
            onApps: { apps in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.store.showsApps = apps }
            },
            onAppScope: { self.appDirectory.setScope($0, for: self.visibleAppBundle) }
        )
    }

    private var periodLabel: String {
        switch self.store.period {
        case "7d": "Week"
        case "30d": "Month"
        default: "Day"
        }
    }

    private var metricLabel: String {
        self.store.metric == "agent" ? "agent time" : "active time"
    }

    /// A profile already carries its own title: the portrait, and the name
    /// under it. A bar above that repeated nothing and pushed the whole
    /// profile 50 pt down the panel, so the two buttons hang over the content
    /// instead, in the corners the portrait leaves empty. Once the name has
    /// scrolled up under them a band fades in behind, carrying the name — the
    /// move a Mac window makes when its title joins the toolbar, and what
    /// keeps the buttons legible over a profile scrolled past its top.
    private var profileActions: some View {
        HStack(spacing: 0) {
            HStack {
                NativeBackButton(title: backDestinationTitle, help: "Back to \(backDestinationTitle)") { store.goBack()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Nothing in the middle: the name that lands between the two
            // buttons is the profile's own, scrolled up to them. See
            // `profileName`.

            HStack {
                if case .app = store.screen { periodPicker }
                else if case .agents = store.screen { periodPicker }
                else if case let .person(id) = store.screen {
                    if id == Defaults[.currentUserID] {
                        profileAction("Edit") {
                            SettingsWindowController.shared.show(section: .account, page: "edit")
                        }
                    } else if store.directFriendIDs.contains(id), let person = store.selectedPerson {
                        profileAction(
                            "Remove",
                            isLoading: store.isRunning("remove-friend-\(id)")
                        ) {
                            removeFriend(person, id: id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: NativeLayout.popoverHeaderHeight)
    }

    /// The band the name brings with it to the row. Material that ends in a
    /// fade rather than on a line, so a profile passing under goes out of
    /// sight instead of being cut, and the buttons keep something to sit on.
    private var profileNameBand: some View {
        Rectangle()
            .fill(.thinMaterial)
            .mask(LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.62),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            ))
            .frame(width: Self.profileBandWidth, height: NativeLayout.popoverHeaderHeight)
            .opacity(self.profileBandStrength)
            .allowsHitTesting(false)
    }

    @ViewBuilder private var people: some View {
        Group {
            if #available(macOS 26.0, *) {
                peopleList
                    .contentMargins(.bottom, NativeLayout.peopleFooterHeight, for: .scrollContent)
                    .safeAreaBar(edge: .top, spacing: 0) { header }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .scrollEdgeEffectHidden(true, for: .bottom)
            } else {
                peopleList
                    .contentMargins(.bottom, NativeLayout.peopleFooterHeight, for: .scrollContent)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        legacyPeopleBar(edge: .top) { header }
                    }
            }
        }
        .frame(height: NativeLayout.popoverHeaderHeight + NativeLayout.peopleBodyHeight)
        // Only the controls float above the list. The bottom margin belongs
        // to the scrollable content, so it never clips rows into a footer bar.
        .overlay(alignment: .bottom) { peopleFooter }
    }

    private var peopleFooter: some View {
        HStack(spacing: 8) {
            dashboardSettingsButton
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 12)
        .frame(height: NativeLayout.peopleFooterHeight)
    }

    @ViewBuilder private var dashboardSettingsButton: some View {
        if #available(macOS 26.0, *) {
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button { SettingsWindowController.shared.show() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .help("Settings")
            .accessibilityLabel("Settings")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    @ViewBuilder private var dashboardInviteButton: some View {
        let waiting = self.store.incomingRequestCount
        let help = waiting == 0 ? "Add a friend" : waiting == 1 ? "Add a friend · 1 request waiting" :
            "Add a friend · \(waiting) requests waiting"
        // The button carries the people waiting on an answer, so a request
        // is visible without opening anything. The count rolls like a total.
        let label = HStack(spacing: 6) {
            Text("Invite").font(.system(size: 12, weight: .medium))
            if waiting > 0 {
                Text("\(waiting)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(waiting)))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(.white.opacity(0.92), in: Capsule())
                    .foregroundStyle(Color.firstlight)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(minWidth: 42, minHeight: 22)
        .animation(self.reduceMotion ? nil : SocialStore.settle, value: waiting)

        NativeTrayMorphButton(morph: self.inviteButtonMorph(from: .footerInvite)) {
            store.openTray(.home, from: .footerInvite)
        } label: { label }
            .help(help)
    }

    private var peopleList: some View {
        ScrollView {
            // A ZStack, so the list for the previous tab and the one for the
            // next overlap while one slides out and the other in, instead of
            // stacking one under the other for the length of the slide.
            ZStack(alignment: .top) {
                VStack(spacing: 0) { directoryRows }
                    // Rows find their new place when a refresh reorders them,
                    // and a new friend settles into the list instead of
                    // appearing in it; never on a tab change, which is a slide.
                    .animation(self.reduceMotion ? nil : SocialStore.settle, value: store.people.map(\.id))
                    .id(store.tab)
                    .transition(ScreenMotion.tab(reduceMotion: self.reduceMotion))
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !self.showingAppRanking, let me = store.peopleList.pinnedMe { pinnedMeRow(me) }
        }
    }

    private var peopleRows: some View {
        LazyVStack(spacing: 0) {
            switch listPhase {
            case .initial:
                // The skeleton lies over the list rather than in it, so it can
                // fade out while the rows come up in the places it held.
                EmptyView()
            case .failedEmpty:
                listFailureMessage
            case .empty:
                emptyListMessage
            case .content,
                 .refreshing,
                 .failedWithContent:
                ForEach(Array(store.people.enumerated()), id: \.element.id) { index, person in
                    let source = self.morphKey(origin: "list", person: person)
                    Button {
                        openPerson(person, from: source)
                    } label: {
                        personRow(
                            person,
                            place: LeaderboardPlace.place(rank: person.rank, loadedIndex: index),
                            morphSource: source
                        )
                    }.buttonStyle(.plain)
                        .contextMenu { bumpMenuItems(person, from: source) }
                        // The pointer reaches a row before the click does.
                        // That is most of what the profile behind it costs.
                        .onHover { inside in if inside { store.warmPerson(person.id) } }
                        .modifier(self.rowReveal(index))
                    if person.id != store.people.last?.id {
                        rowDivider.modifier(self.rowReveal(index))
                    }
                }
                if store.peopleList.hasMore { loadMoreRow }
                if listPhase == .failedWithContent {
                    NativeInlineError(message: store.listFailure?.message ?? "Couldn't refresh activity") {
                        Task { await store.refresh(force: true) }
                    }.padding(12)
                }
            }
        }
        .overlay(alignment: .top) {
            if listPhase == .initial {
                NativePeopleSkeleton(rows: 5, showsPlaces: showsPlaces).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: listPhase == .initial)
        .onChange(of: listPhase == .initial, initial: true) { _, loading in self.rowsRevealed = !loading }
    }

    /// The list could not be loaded and there is nothing older to show. One
    /// line: being offline is named, since the list comes back on its own
    /// once the connection does; anything else is "try again". The error's
    /// own words wait under the pointer for whoever wants them.
    private var listFailureMessage: some View {
        let failure = self.store.listFailure
        let offline = failure?.isOffline ?? false
        return NativeStateMessage(
            symbol: offline ? "wifi.slash" : "exclamationmark.triangle",
            title: offline ? "You're offline" : "Couldn't load activity",
            detail: offline ? nil : failure?.message,
            actionTitle: "Try again",
            action: { Task { await self.store.refresh(force: true) } },
            minHeight: NativeLayout.peopleListHeight
        )
    }

    /// The list loaded and is empty. One line and the way out of it: for
    /// Friends and a group that is people, so the button invites one; for
    /// the Leaderboard it is time, so the button widens the period.
    private var emptyListMessage: some View {
        let longestPeriod = "30d"
        return switch self.store.tab {
        case "global":
            NativeStateMessage(
                symbol: "clock",
                title: "Nothing to rank yet",
                actionTitle: self.store.period == longestPeriod ? nil : "Show the month",
                action: self.store.period == longestPeriod ? nil : { self.store.setPeriod(longestPeriod) },
                minHeight: NativeLayout.peopleListHeight
            )
        case "friends":
            NativeStateMessage(
                symbol: "person.2",
                title: "No friends yet",
                actionTitle: "Invite a friend",
                action: { self.store.openTray(.home, from: .emptyState) },
                actionMorph: self.inviteButtonMorph(from: .emptyState),
                minHeight: NativeLayout.peopleListHeight
            )
        default:
            NativeStateMessage(
                symbol: "person.3",
                title: "Nobody's active yet",
                actionTitle: "Invite someone",
                action: { self.store.openTray(.home, from: .emptyState) },
                actionMorph: self.inviteButtonMorph(from: .emptyState),
                minHeight: NativeLayout.peopleListHeight
            )
        }
    }

    /// Standings belong to the Leaderboard, where the order is the whole
    /// point. Friends and groups are the people you chose, not a race, so
    /// their rows stay as they were.
    private var showsPlaces: Bool {
        if case .app = self.store.screen { return true }
        return self.store.tab == "global"
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, self.showsPlaces ? Self.rankedRowDividerInset : Self.rowDividerInset)
            .opacity(0.55)
    }

    /// Sits under the last loaded row and asks for the next page whenever it is
    /// on screen. The task is keyed on the next offset, so a page that ends
    /// above the fold still pulls the one after it; a failed page waits for Retry.
    @ViewBuilder private var loadMoreRow: some View {
        rowDivider
        if let message = store.loadMoreError {
            NativeInlineError(message: message) { Task { await store.loadMore() } }.padding(12)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .task(id: store.peopleList.nextOffset) { await store.loadMore() }
                .accessibilityLabel("Loading more people")
        }
    }

    // MARK: Invite tray

    /// The tray and the veil under it. The veil is the popover's own colour
    /// at 72 %, so the list fades towards the background rather than going
    /// grey, and a click on it closes the tray like ×.
    /// The veil and the tray are each their own conditional inside a stack
    /// that is always in the tree. Wrapping both in one `if` would hand the
    /// stack a transition of its own, and the tray's would never run: the
    /// whole layer would simply fade in, instead of growing from the button.
    private var inviteTrayLayer: some View {
        ZStack(alignment: .bottom) {
            if store.tray != nil {
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture { store.closeTray() }
                    .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    .accessibilityHidden(true)
            }
            NativeTrayMorphContainer {
                ZStack(alignment: .bottom) {
                    if store.screen == .list {
                        HStack {
                            Spacer()
                            dashboardInviteButton
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 5)
                        .padding(.bottom, 12)
                        .frame(height: NativeLayout.peopleFooterHeight)
                    }
                    if let tray = store.tray {
                        self.inviteTray(tray)
                            .padding(8)
                            .transition(self.trayTransition)
                    }
                }
            }
        }
        .allowsHitTesting(self.store.tray != nil || self.store.screen == .list)
    }

    /// The shared surface carries the geometry; its contents keep their size.
    /// Deep links have no visible source and use the same quick fade.
    private var trayTransition: AnyTransition {
        .opacity
    }

    /// The one field of the flow, sized for a code you read across a room:
    /// taller than a form control, with the text at the card's size.
    private var inviteField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Paste a link or enter a friend code", text: self.$store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .labelsHidden()
                .focused(self.$inviteFieldFocused)
                .onChange(of: self.store.query) { _, _ in self.store.queryChanged() }
                .onSubmit { self.store.addFromQuery() }
                .disabled(self.store.isRunning("accept-invite"))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    self.inviteFieldFocused ? Color.firstlight.opacity(0.7) : Color.primary.opacity(0.09),
                    lineWidth: self.inviteFieldFocused ? 1.5 : 0.5
                )
                .animation(.easeOut(duration: 0.15), value: self.inviteFieldFocused)
        }
        .contentShape(Rectangle())
        .onTapGesture { self.inviteFieldFocused = true }
        // Last, so the fill and the border are inset as one object: between
        // them it would widen the border past the fill. The 8 pt is what the
        // step insets its own content by, which puts the field on the tray's
        // 14 pt line with everything else.
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var sentRequestRows: some View {
        ForEach(self.store.requests.outgoing) { request in
            if let person = request.target_user {
                self.requestRow(person, detail: "Waiting for a response") {
                    TrayCircleAction(
                        symbol: "xmark",
                        help: "Take back the request to \(person.displayName)",
                        isLoading: self.store.isRunning("cancel-request-\(request.id)"),
                        disabled: self.store.busy
                    ) { self.store.respond(request.id, action: "cancel") }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var incomingRequestRows: some View {
        ForEach(self.store.requests.incoming) { request in
            if let person = request.requester {
                self.requestRow(person, detail: "Sent you a friend request") {
                    TrayCircleAction(
                        symbol: "xmark",
                        help: "Decline \(person.displayName)",
                        isLoading: self.store.isRunning("decline-request-\(request.id)"),
                        disabled: self.store.busy
                    ) { self.store.respond(request.id, action: "decline") }
                    TrayCircleAction(
                        symbol: "checkmark",
                        help: "Accept \(person.displayName)",
                        prominent: true,
                        isLoading: self.store.isRunning("accept-request-\(request.id)"),
                        disabled: self.store.busy
                    ) { self.store.respond(request.id, action: "accept") }
                }
                .transition(self.store.acceptedRequestIDs.contains(request.id) ? .acceptedRequest : .opacity)
            }
        }
    }

    @ViewBuilder private var groupInvitationRows: some View {
        ForEach(self.store.requests.groupInvitations) { invitation in
            if let person = invitation.inviter {
                self.requestRow(person, detail: "Invited you to \(invitation.group.name)") {
                    TrayCircleAction(
                        symbol: "xmark",
                        help: "Decline \(invitation.group.name)",
                        isLoading: self.store.isRunning("decline-group-invitation-\(invitation.id)"),
                        disabled: self.store.busy
                    ) { self.store.respondToGroupInvitation(invitation, action: "decline") }
                    TrayCircleAction(
                        symbol: "checkmark",
                        help: "Join \(invitation.group.name)",
                        prominent: true,
                        isLoading: self.store.isRunning("accept-group-invitation-\(invitation.id)"),
                        disabled: self.store.busy
                    ) { self.store.respondToGroupInvitation(invitation, action: "accept") }
                }
                .transition(self.store.acceptedRequestIDs.contains(invitation.id) ? .acceptedRequest : .opacity)
            }
        }
    }

    @ViewBuilder private var yourInviteBlock: some View {
        if let invite = store.personalInvite {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR FRIEND CODE").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(self.displayFriendCode(invite.personalInviteCode))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .tracking(1.5).lineLimit(1).minimumScaleFactor(0.68).textSelection(.enabled)
                    .accessibilityLabel("Your friend code \(invite.personalInviteCode)")
                // Two equal buttons across the card: the code is the thing
                // people act on here, so its actions get room, not a footnote.
                HStack(spacing: 8) {
                    Button { self.store.copyFriendCode(invite.personalInviteCode) } label: {
                        NativeCopyButtonLabel(title: "Copy code", copied: self.store.copiedItem == .friendCode)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 22)
                    }
                    Button { self.store.copyPersonalInviteLink() } label: {
                        NativeCopyButtonLabel(
                            title: "Copy link",
                            copied: self.store.copiedItem == .inviteLink,
                            loadingTitle: "Preparing…",
                            isLoading: self.store.isRunning("copy-invite-link")
                        )
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 22)
                    }
                }
                .modifier(NativeCapsuleGlassButtons())
                .controlSize(.regular)
                .disabled(self.store.busy)
                .padding(.top, 2)
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if store.trayLoading {
            NativeDelayedSkeleton {
                VStack(alignment: .leading, spacing: 10) {
                    NativeSkeletonShape(width: 108, height: 13)
                    NativeSkeletonShape(width: 154, height: 28, radius: 5)
                    NativeSkeletonShape(width: 168, height: 20, radius: 6)
                }.padding(12)
            }
        } else {
            self.quiet("Your friend code isn't available right now.")
        }
    }

    private var accountLabel: String {
        self.session.user?.primaryEmailAddress?.emailAddress ?? "your current account"
    }

    private var listPhase: ContentLoadPhase {
        ContentLoadPhase.resolve(
            isLoading: self.store.loading && !self.store.hasLoadedCurrentList,
            hasContent: !self.store.people.isEmpty,
            hasError: self.store.listFailure != nil
        )
    }

    @ViewBuilder private var content: some View {
        if case let .person(id) = store.screen { personDetail(id) }
        if case .photo = store.screen { photoDetail }
        if case let .app(bundle) = store.screen { appDetail(bundle) }
        if case let .agents(id) = store.screen { agentsDetail(id) }
    }

    private var backDestinationTitle: String {
        self.screenTitle(for: self.store.previousScreen ?? .list)
    }

    /// The arriving step settles in a beat after the leaving one has dimmed,
    /// each drifting a few points down, so the two never sit on top of each
    /// other at half strength. The same rule the screens follow.
    private var trayStepTransition: AnyTransition {
        if self.reduceMotion {
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.2)),
                removal: .opacity.animation(.easeOut(duration: 0.15))
            )
        }
        return .asymmetric(
            insertion: .offset(y: 14).combined(with: .opacity).animation(.easeOut(duration: 0.22).delay(0.06)),
            removal: .offset(y: -10).combined(with: .opacity).animation(.easeOut(duration: 0.18))
        )
    }

    /// How the inviter's code reached the field. A link is their consent, so
    /// it says so; a code is only a code; a link found in the clipboard says
    /// where it came from, since nobody typed it.
    private var inviterDetail: String {
        if self.session.pendingInviteSource == .clipboard, self.store.queryIsLink { return "Found in your clipboard" }
        if self.store.queryIsLink { return "Invited you with a link" }
        if case let .friendCode(code)? = self.store.inviteCandidate {
            return "Friend code \(self.displayFriendCode(code))"
        }
        return "Friend code"
    }

    /// Where a sent request goes to wait, and the only trace it leaves. It
    /// takes the accent and leans forward for a beat as one lands, so the eye
    /// is told where the request went without a screen of its own.
    private var sentRequestsPill: some View {
        let count = self.store.requests.outgoing.count
        let landing = self.pillLanding
        return Button { store.pushTray(.sentRequests) } label: {
            HStack(spacing: 5) {
                NativeSendIcon(size: 12)
                Text("Sent").font(.system(size: 11))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(self.reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: count)
            }
            .foregroundStyle(landing ? Color.firstlight : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                landing ? Color.firstlight.opacity(0.18) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Sent requests")
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .scaleEffect(landing ? 1.16 : 1)
        .onChange(of: count) { previous, value in
            guard value > previous else { return }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.28, bounce: 0.45)) {
                self.pillLanding = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(620))
                withAnimation(.easeOut(duration: 0.35)) { self.pillLanding = false }
            }
        }
    }

    /// The photograph, alone on the screen under the Back button. The person
    /// is the one the profile behind it is about: it is reached from there and
    /// returns there.
    private var photoDetail: some View {
        ProfilePhotoScreen(
            url: self.store.selectedPerson?.avatar_url,
            name: self.store.selectedPerson?.displayName ?? "",
            // Shared with the portrait on the profile behind it, so the
            // picture grows out of that circle and shrinks back into it.
            morph: self.reduceMotion
                ? nil
                : .init(id: self.morphID(Self.avatarMorphID), namespace: self.morph),
            avatarSize: Self.profileAvatarSize,
            // Pulling the picture off the panel is the same move as Back, and
            // lands in the same place: the profile it was opened from.
            close: { self.store.goBack() }
        )
        // Clear of the header: Back hangs over the content on these screens,
        // and a button on top of a face is a button nobody finds.
        .padding(.top, NativeLayout.popoverHeaderHeight - NativeLayout.popoverContentPadding)
        .frame(maxWidth: .infinity)
    }

    /// The day's tray and the veil under it, built the way the invite tray's
    /// layer is: each its own conditional inside a stack that is always in
    /// the tree, so the tray's growth out of its tile is the tray's own
    /// transition and not a fade of the whole layer.
    private var agentDayTrayLayer: some View {
        ZStack(alignment: .bottom) {
            if self.store.agentDayTray != nil {
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture { self.store.closeAgentDay() }
                    .transition(.opacity.animation(.easeOut(duration: 0.14)))
                    .accessibilityHidden(true)
            }
            if let tray = self.store.agentDayTray,
               let day = self.store.agentMonth?.days?.first(where: { $0.date == tray.date })
            {
                self.agentDayTray(tray, day: day)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: AgentTrayGrow(
                                progress: self.reduceMotion ? 1 : 0,
                                source: self.reduceMotion ? nil : self.agentDaySource
                            ),
                            identity: AgentTrayGrow(progress: 1, source: self.agentDaySource)
                        ),
                        removal: .modifier(
                            active: AgentTrayGrow(
                                progress: self.reduceMotion ? 1 : 0,
                                source: self.reduceMotion ? nil : self.agentDaySource, closing: true
                            ),
                            identity: AgentTrayGrow(progress: 1, source: self.agentDaySource, closing: true)
                        )
                    ).combined(with: self.reduceMotion ? .opacity : .identity))
                    .padding(8)
            }
        }
        .allowsHitTesting(self.store.agentDayTray != nil)
    }

    /// Where a value sits between two points, as 0 to 1. `from` is the far
    /// end because the name's distance falls as the profile scrolls up.
    private static func progress(_ value: CGFloat, from: CGFloat, to: CGFloat) -> Double {
        guard from > to else { return value <= to ? 1 : 0 }
        return Double(min(max((from - value) / (from - to), 0), 1))
    }

    private static func joinedCheckMorphID(reduceMotion: Bool) -> String {
        reduceMotion ? "joined-check-still" : "joined-check"
    }

    /// Header, field and paddings: everything in a tray that is not the step.
    private static func trayFixedHeight(_ tray: SocialStore.Tray) -> CGFloat {
        44 + (tray.showsField ? 40 + 12 : 0) + 6 + 14
    }

    private static func firstName(of name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Rows that replace the skeleton come up where its rows were, one after
    /// another from the top. A list that was already there is simply there.
    private func rowReveal(_ index: Int) -> SkeletonRowReveal {
        SkeletonRowReveal(revealed: self.rowsRevealed, index: index, reduceMotion: self.reduceMotion)
    }

    private func inviteButtonMorph(from origin: SocialStore.TrayOrigin) -> NativeTrayMorph {
        NativeTrayMorph(
            id: origin == .footerInvite ? "invite-footer" : "invite-empty",
            namespace: self.inviteMorph,
            isExpanded: self.store.tray != nil && (origin == .footerInvite || self.store.trayOrigin == origin),
            // No glass on this tray: a glass surface around a focused field
            // sends SwiftUI's key-view loop rebuild into a cycle and the app
            // hangs at 100% CPU (2026-09-16, reproduced with the focus
            // deferred too). The bump tray has no field and keeps its glass.
            usesGlass: false
        )
    }

    /// The key that stands for one row, and the tab is part of it. A tab change
    /// swaps the whole list by identity, so the list leaving and the list
    /// arriving are both on screen for the length of the slide: a person in
    /// both tabs would otherwise hand the same id to two rows at once, and a
    /// matched group with two sources has no defined answer. SwiftUI picks one
    /// frame and drops the other row's avatar into it — out of its row, often
    /// past the edge the scroll view cuts at. Keyed by tab, the two rows are
    /// two ids, and each list slides with its own portraits.
    private func morphKey(origin: String, person: NativePerson) -> String {
        "\(origin)-\(self.store.tab)-\(person.id)"
    }

    /// The profile's name and the row's title are one text. It rides the
    /// profile up, shrinks to the row's size over the last stretch of that
    /// ride, and is then held on the row's line while the rest of the profile
    /// goes on under it. Nothing is swapped and nothing cross-fades: there is
    /// one name on the screen at every point of it.
    ///
    /// The three modifiers are in this order for a reason. The scale is the
    /// name's alone, so the band behind it stays the row's size. The offset is
    /// outside both, so name and band are held together. The measurement is
    /// outside the offset, or it would read its own displacement back and run
    /// away with it.
    private func profileName(_ person: NativePerson) -> some View {
        let progress = self.profileTitleProgress
        return Text(person.displayName)
            .font(.system(size: 20, weight: .semibold))
            .lineLimit(1)
            .matchedGeometryEffect(id: self.morphID(Self.nameMorphID), in: self.morph, properties: .position)
            .scaleEffect(1 - CGFloat(progress) * (1 - Self.profileTitleRowScale))
            .background(alignment: .center) { profileNameBand }
            .offset(y: self.profileTitleStick)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: ProfileTitleCenter.self,
                    value: geometry.frame(in: .named(NativeLayout.popoverScrollSpace)).midY
                )
            })
            // Held on the row's line, the name is over the profile rather than
            // in it: above the portrait leaving under it and the lines coming
            // up to it. Until then the portrait keeps the front, so the hero
            // flight from the list passes behind it as it always did.
            .zIndex(progress > 0 ? 2 : 0)
    }

    /// The step a joined group ends on. The mark lands, the refreshed groups
    /// put the new tab into the strip and the list moves to it under the
    /// veil; then the mark flies up into that tab. Closing the tray leaves
    /// the group on screen: the result is already where it lives.
    private func trayJoined(_ groupName: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if !self.joinedCheckLanded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.14), in: Circle())
                        .matchedGeometryEffect(
                            id: Self.joinedCheckMorphID(reduceMotion: self.reduceMotion),
                            in: self.morph
                        )
                        .scaleEffect(self.joinedCheckShown ? 1 : 0.3)
                        .opacity(self.joinedCheckShown ? 1 : 0)
                }
            }
            .frame(height: 36)
            .padding(.bottom, 4)
            Text("You're in \(groupName)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("Its tab is waiting at the top.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task(id: self.store.joinedGroupID) {
            if !self.joinedCheckShown {
                withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.4)) {
                    self.joinedCheckShown = true
                }
            }
            // The tab exists only once the groups have come back; until then
            // there is nowhere to fly. The task runs again when they do.
            guard let groupID = self.store.joinedGroupID, !self.joinedCheckLanded else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self.store.selectTab(groupID)
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.5)) {
                self.joinedCheckLanded = true
            }
            // The mark is in the tab now and the group is on screen behind
            // the veil. Staying would leave a tray with nothing in it, so it
            // shrinks away and lets the group it just joined be seen.
            do { try await Task.sleep(for: .milliseconds(620)) } catch { return }
            if case .joined = self.store.tray { self.store.closeTray() }
        }
    }

    /// The Send request tray: who the code or link belongs to, and the one
    /// action that follows. The old banner's prompts supply the words.
    /// The Send request tray: one card that is the same object from the first
    /// keystroke to the reply. For a code, the person's line waits with a
    /// placeholder and the code sits under it unchanged; when the owner is
    /// known, the face and the name fill the same slots and the button's
    /// last word changes to their name. Nothing moves, nothing is swapped.
    @ViewBuilder private func trayCandidate(_ input: InviteInput) -> some View {
        switch input {
        case let .friendCode(code): self.trayFriendCodeCandidate(code)
        case .token: self.trayLinkCandidate()
        }
    }

    @ViewBuilder private func trayFriendCodeCandidate(_ code: String) -> some View {
        let isOwn = code.caseInsensitiveCompare(self.store.personalInvite?.personalInviteCode ?? "") == .orderedSame
        let inviter: NativeJoinInfo.Inviter? = self.store.inviter?.code == code ? self.store.inviter : nil
        let waiting = !isOwn && inviter == nil && self.store.checkingInviter
        // A friend's code is not an invitation to send: the card says so and
        // the button opens their profile instead of asking again.
        let friendID: String? = inviter?.inviterId.flatMap { self.store.directFriendIDs.contains($0) ? $0 : nil }
        self.candidateCard(
            title: isOwn ? "That's your own code" : inviter?.inviterName ?? (waiting ? nil : "Someone on Firstlight"),
            subtitle: friendID != nil ? "Already friends" : "Friend code \(self.displayFriendCode(code))",
            aboutID: isOwn ? nil : inviter?.inviterId
        ) {
            ZStack {
                if let inviter {
                    FirstlightAvatar(url: inviter.inviterAvatarUrl, name: inviter.inviterName, size: 36)
                        .transition(.opacity)
                } else {
                    Circle().fill(Color.primary.opacity(0.08))
                        .overlay {
                            Image(systemName: isOwn ? "person.crop.circle" : "person")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .transition(.opacity)
                }
            }
            .frame(width: 36, height: 36)
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.25), value: inviter)
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.25), value: waiting)
        if let error = store.error {
            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        // "Add friend" from the first moment; the name arrives into the last
        // word once it is known. A code nobody answers to still sends: the
        // request goes to whoever owns it, or fails with a reason. A friend's
        // code turns the button into the way to their profile.
        if let friendID {
            self.trayActionButton("View profile", isLoading: false) {
                self.store.closeTray()
                // No row was tapped, so no portrait in the list flies into it.
                self.morphSource = nil
                self.store.openFriend(friendID)
            }
        } else {
            self.trayActionButton(
                "Add \(inviter.map { Self.firstName(of: $0.inviterName) } ?? "friend")",
                isLoading: self.store.isRunning("accept-invite"),
                enabled: !isOwn
            ) { self.store.addFromQuery() }
        }
    }

    @ViewBuilder private func trayLinkCandidate() -> some View {
        let prompt = self.invitePrompt(for: .token(""))
        self.candidateCard(title: prompt.title, subtitle: prompt.message) {
            ZStack {
                Circle().fill(Color.primary.opacity(0.08))
                // A found invitation is a ticket; before that it is only a
                // link being read, or a link that no longer opens.
                if self.store.inviteInfo != nil {
                    NativeInviteIcon(size: 17).foregroundStyle(.secondary).transition(.opacity)
                } else {
                    Image(systemName: prompt.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity)
                }
            }
            .frame(width: 36, height: 36)
        }
        .animation(.easeOut(duration: 0.2), value: prompt.title)
        // Shown while the link is still being read as well, so Checking and
        // Found stand at one height and the tray moves once, not twice.
        if self.store.inviteError == nil {
            HStack(spacing: 5) {
                Text("As \(self.accountLabel)").font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Switch…") { self.switchAccountForInvite() }
                    .buttonStyle(.link).font(.system(size: 11)).disabled(self.store.busy)
            }
        }
        if let error = store.error {
            Text(error).font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        // The button is there from the first moment, dimmed while the link
        // is read, so the tray is its final height at once; then the group's
        // name arrives into the label.
        if self.store.inviteError == nil {
            self.trayActionButton(
                "Join \(self.store.inviteInfo?.invite.groupName ?? "group")",
                isLoading: self.store.isRunning("accept-invite"),
                enabled: prompt.actionTitle != nil
            ) { self.store.addFromQuery() }
        } else {
            Button("Try again") { self.store.queryChanged() }
                .controlSize(.small).disabled(self.store.busy)
        }
    }

    /// The candidate's card: a 36 pt slot on the left, a name line and a line
    /// under it. A nil title is the name still being looked up and shows as
    /// a quiet bar of the same height, so the card never changes shape.
    ///
    /// Once the code's owner is known the card leads to who they are, with a
    /// chevron to say so; until then it is only a card.
    private func candidateCard(
        title: String?,
        subtitle: String,
        aboutID: String? = nil,
        @ViewBuilder leading: () -> some View
    ) -> some View {
        let inside = HStack(alignment: .center, spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                ZStack(alignment: .leading) {
                    if let title {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .contentTransition(.opacity)
                            .transition(.opacity)
                    } else {
                        NativeSkeletonShape(width: 118, height: 13, radius: 4)
                            .transition(.opacity)
                    }
                }
                .frame(height: 16)
                // The line keeps its room whether or not it has something to
                // say, so a tile does not change height under the pointer.
                Text(subtitle ?? " ").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.18), value: subtitle)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            if aboutID != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            }
        }

        return Group {
            if let aboutID {
                // A card that leads somewhere lights itself rather than taking
                // a row's highlight: it already has a surface of its own.
                TrayTappableCard(action: { self.store.openAbout(aboutID) }) { inside }
                    .help("About \(title ?? "this person")")
            } else {
                inside.modifier(TrayCardSurface(lit: false))
            }
        }
    }

    /// The step a link-made friendship ends on. No request to wait for: the
    /// mark lands and the new friend's row settles into the list under the
    /// veil, so closing the tray finds them already there.
    private func trayConnected(_ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.14), in: Circle())
                .scaleEffect(self.resultCheckShown ? 1 : 0.3)
                .opacity(self.resultCheckShown ? 1 : 0)
                .padding(.bottom, 4)
            Text("You're friends with \(name)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("Their row is in your list now.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task {
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.4)) {
                self.resultCheckShown = true
            }
        }
    }

    /// The tray's one action. Its words change by the word that changed;
    /// while it works, the words give way to a spinner and the width holds.
    private func trayActionButton(
        _ title: String,
        isLoading: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                MorphingLabel(text: title, reduceMotion: self.reduceMotion)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView().controlSize(.small).tint(.white).transition(.opacity)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .animation(.easeOut(duration: 0.2), value: isLoading)
        }
        .modifier(NativeCapsuleProminentButton())
        .controlSize(.large)
        .tint(.firstlight)
        .disabled(!enabled || self.store.busy)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.25), value: enabled)
        .keyboardShortcut(.defaultAction)
    }

    private func inviteTray(_ tray: SocialStore.Tray) -> some View {
        VStack(spacing: 0) {
            self.trayHeader(tray)
            VStack(alignment: .leading, spacing: 12) {
                if tray.showsField { self.inviteField }
                // The steps overlap while one gives way to the next, inside a
                // frame that moves to the arriving step's height on its own
                // spring. Only long lists ever scroll; the frame is the
                // content's height otherwise, so nothing else can.
                ZStack(alignment: .top) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) { self.trayStep(tray) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                                self.trayStepMeasured(tray, height: height)
                            }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .id(tray)
                    .transition(self.trayStepTransition)
                }
                .frame(height: self.trayStepHeight, alignment: .top)
            }
            // 6 pt, not 14: a row's highlight reaches this far and has to fit
            // inside the scroll view, which clips. Everything that is not a
            // row takes the other 8 pt back, so content still sits at 14.
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .modifier(
            NativeTraySurface(
                morph: self.store.trayOrigin == .none ? nil :
                    self.inviteButtonMorph(from: self.store.trayOrigin),
                backgroundMaterial: .thick
            )
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .onChange(of: tray, initial: true) { previous, value in
            // The field takes the keyboard once the tray has finished growing
            // out of the button. Asked for in the same frame as the glass
            // surface's matched-geometry transition, focus makes SwiftUI
            // rebuild its key-view loop without end and the app hangs.
            if value == .home {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(320))
                    guard self.store.tray == .home else { return }
                    self.inviteFieldFocused = true
                }
            }
            if !value.isConnected { self.resultCheckShown = false }
            if case .joined = value {} else {
                self.joinedCheckShown = false
                self.joinedCheckLanded = false
            }
            // A tray seen before has its height on record: move to it now,
            // without waiting for the arriving step to lay itself out.
            if previous != value { self.applyTrayHeight(for: value) }
        }
        .onDisappear {
            self.trayStepHeight = nil
            self.trayStepNatural.removeAll()
        }
        // An emptied list is not a place to stay: after a beat it returns on
        // its own, before the tray has shrunk to a lone header.
        .task(id: self.trayAutoReturnKey(tray)) {
            guard self.trayAutoReturnKey(tray) != nil else { return }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self.store.trayBack()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(self.trayTitle(tray))
    }

    /// A step's natural height, as it lays itself out. The frame around the
    /// steps follows it on the tray spring; the leaving step's late reports
    /// are ignored so it cannot pull the frame back.
    private func trayStepMeasured(_ tray: SocialStore.Tray, height: CGFloat) {
        guard self.store.tray == tray, height > 0 else { return }
        self.trayStepNatural[tray] = height
        self.applyTrayHeight(for: tray)
    }

    /// Moves the step frame to what the tray needs: its natural height, capped
    /// at the tray's limit, plus the 24 pt of air the rule may add. Called
    /// when a step reports its size and, for a tray seen before, the moment
    /// it comes back, so a return does not wait for a fresh layout or, worse,
    /// keep the leaving tray's height and scroll.
    private func applyTrayHeight(for tray: SocialStore.Tray) {
        guard self.store.tray == tray, let natural = self.trayStepNatural[tray] else { return }
        let maximumStep = Self.trayMaximumHeight - Self.trayFixedHeight(tray)
        // Trays stand at their own height, however close a neighbour is:
        // padding added to tell two apart reads as dead space, not as a
        // change. If two trays ever land within a few points, the content
        // of one of them is what should move, not the frame.
        let step = min(natural, maximumStep)
        guard self.trayStepHeight.map({ abs($0 - step) > 0.5 }) ?? true else { return }
        let animation: Animation? = self.trayStepHeight == nil ? nil :
            self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0.1)
        withAnimation(animation) { self.trayStepHeight = step }
    }

    /// Non-nil while the open tray is a list that has just run out of rows.
    private func trayAutoReturnKey(_ tray: SocialStore.Tray) -> String? {
        guard !self.store.trayLoading, !self.store.busy else { return nil }
        switch tray {
        case .incoming where self.store.requests.waitingCount == 0: return "incoming-empty"
        case .sentRequests where self.store.requests.outgoing.isEmpty: return "sent-empty"
        default: return nil
        }
    }

    private func trayHeader(_ tray: SocialStore.Tray) -> some View {
        HStack(spacing: 10) {
            self.trayDismissButton(back: tray.canGoBack)
            Text(self.trayTitle(tray))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            if tray == .home, !store.requests.outgoing.isEmpty { self.sentRequestsPill }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
    }

    /// One button, two shapes. On the first tray it closes; deeper in it
    /// goes back. The × turns a quarter into the ‹ instead of being swapped.
    @ViewBuilder private func trayDismissButton(back: Bool) -> some View {
        if back {
            NativeBackButton(title: self.trayTitle(self.store.previousTray ?? .home), help: "Back") { store.trayBack() }
        } else {
            Button { store.trayBack() } label: {
                ZStack {
                    Image(systemName: "xmark")
                        .rotationEffect(.degrees(back ? 90 : 0))
                        .opacity(back ? 0 : 1)
                    Image(systemName: "chevron.left")
                        .rotationEffect(.degrees(back ? 0 : -90))
                        .opacity(back ? 1 : 0)
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 22)
            }
            // The same round glass control as Back in a profile and the gear in
            // the footer, so the tray's one button belongs to the same family.
            .modifier(NativeRoundGlassButton())
            .animation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.15), value: back)
            .help(back ? "Back" : "Close")
            .accessibilityLabel(back ? "Back" : "Close")
            .keyboardShortcut("[", modifiers: .command)
        }
    }

    private func trayTitle(_ tray: SocialStore.Tray) -> String {
        switch tray {
        case .home: "Add a friend"
        case .incoming: self.store.requests.groupInvitations.isEmpty ? "Wants to be friends" : "Requests"
        case let .candidate(kind):
            switch kind {
            case .token: "Group invitation"
            case .friendCode:
                if case let .friendCode(code)? = self.store.inviteCandidate,
                   code.caseInsensitiveCompare(self.store.personalInvite?.personalInviteCode ?? "") == .orderedSame
                {
                    "Add a friend"
                } else {
                    "Send request"
                }
            }
        case .connected: "Friends"
        case .joined: "Joined"
        case let .about(personID): self.store.card(for: personID)?.name ?? "About"
        case .sentRequests: "Sent requests"
        }
    }

    /// One step per tray, on the components the old screen already had. The
    /// field lives outside the step so it survives Home ↔ Send request.
    @ViewBuilder private func trayStep(_ tray: SocialStore.Tray) -> some View {
        switch tray {
        case .home:
            self.yourInviteBlock
            if let error = store.error, !store.trayLoading {
                NativeInlineError(message: error) { self.store.refreshTray(force: true) }
            }
            if self.store.requests.waitingCount > 0 {
                Divider()
                self.navigationRow(self.waitingTitle, detail: "Accept or decline") {
                    self.store.pushTray(.incoming)
                }
            }
        case .incoming:
            // Rows carry their own air now, so they stack close: one list, not
            // a column of separate blocks.
            VStack(spacing: 2) { self.incomingRequestRows; self.groupInvitationRows }
            if self.store.requests.waitingCount == 0 { self.quiet("That's everyone.") }
            if let error = store.error { NativeInlineError(message: error) }
        case .candidate:
            // The field may have just emptied; the tray is on its way back.
            if let input = self.store.inviteCandidate { self.trayCandidate(input) }
        case let .about(personID):
            self.trayAbout(personID)
        case let .connected(name):
            self.trayConnected(name)
        case let .joined(groupName):
            self.trayJoined(groupName)
        case .sentRequests:
            if self.store.requests.outgoing.isEmpty { self.quiet("No pending requests.") }
            if let error = store.error { NativeInlineError(message: error) }
            VStack(spacing: 2) { self.sentRequestRows }
        }
    }

    /// What is waiting, in the words of what it is: friends, groups, or both.
    private var waitingTitle: String {
        let friends = self.store.requests.incoming.count
        let groups = self.store.requests.groupInvitations.count
        if groups == 0 { return friends == 1 ? "1 wants to be friends" : "\(friends) want to be friends" }
        if friends == 0 { return groups == 1 ? "1 group invitation" : "\(groups) group invitations" }
        return "\(friends + groups) requests"
    }

    /// The tray a finished flow ends on: a mark, one line, one quiet line.
    private func trayResult(title: String, message: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.14), in: Circle())
                .padding(.bottom, 4)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    /// The shared id for the profile side, or for the one row that was tapped.
    /// Every other row gets an id of its own that matches nothing, and with
    /// reduced motion nothing matches at all, leaving the plain cross-fade.
    /// A row shares geometry with the profile and with nothing else — not with
    /// the same person's row in another tab. The key carries the tab, so the
    /// two are two ids and neither can claim the other's frame. People are not
    /// inherited across a tab change on purpose: the lists slide opposite ways,
    /// and a portrait that stayed put while its row left would be saying the
    /// person is in both places at once.
    private func morphID(_ id: String, row: String? = nil) -> String {
        if self.reduceMotion { return "still-\(id)-\(row ?? "profile")" }
        if let row, self.morphSource != row { return "\(id)-\(row)" }
        return id
    }

    /// The caller's own place in a ranking they have not scrolled down to yet.
    private func pinnedMeRow(_ person: NativePerson) -> some View {
        let source = self.morphKey(origin: "pinned", person: person)
        return VStack(spacing: 0) {
            Divider().opacity(0.55)
            Button {
                openPerson(person, from: source)
            } label: {
                personRow(
                    person,
                    place: LeaderboardPlace.place(rank: person.rank, loadedIndex: nil),
                    morphSource: source
                )
            }.buttonStyle(.plain)
                .onHover { inside in if inside { store.warmPerson(person.id) } }
        }
        .background(Color.primary.opacity(0.035))
    }

    /// Remember which row was tapped before the screen switches, so the
    /// profile avatar knows where to fly from and, on Back, where to return.
    private func openPerson(_ person: NativePerson, from source: String) {
        self.morphSource = source
        self.store.openPerson(person)
    }

    @ViewBuilder private func profileAction(
        _ title: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = NativeLoadingSwap(isLoading: isLoading) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
        }
        .frame(minWidth: 42, minHeight: 22)

        if #available(macOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(store.busy)
                .help(title)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(self.store.busy)
                .help(title)
        }
    }

    /// A bump from the row opens the profile the way a click on the row does.
    /// The profile is drawn from `selectedPerson`, so opening the screen alone
    /// would show whoever was opened last, flying out of their row.
    @ViewBuilder private func bumpMenuItems(_ person: NativePerson, from source: String) -> some View {
        if person.id != Defaults[.currentUserID], person.public_apps_only != true,
           self.store.directFriendIDs.contains(person.id) || self.store.tab != "global"
        {
            Menu("Bump") {
                ForEach(BumpEffect.allCases) { effect in
                    Button(effect.title) {
                        openPerson(person, from: source)
                        BumpEffects.shared.send(effect, to: person, systemReduced: reduceMotion)
                    }
                }
            }
        }
        // Any member may ask their own direct friend. The group whose list
        // this is already has them.
        let invitable = self.store.groups.filter { $0.id != self.store.tab }
        if !invitable.isEmpty, person.id != Defaults[.currentUserID],
           self.store.directFriendIDs.contains(person.id)
        {
            Menu("Invite to group") {
                ForEach(invitable) { group in
                    Button(group.name) { self.store.inviteToGroup(person, group: group) }
                }
            }
            .disabled(self.store.busy)
        }
        // On a group's own list its creator can take anyone but themselves out.
        if let group = self.store.groups.first(where: { $0.id == self.store.tab }), group.is_creator == true,
           person.id != Defaults[.currentUserID]
        {
            Divider()
            Button("Remove from \(group.name)", role: .destructive) {
                self.confirm("Remove \(person.displayName) from \(group.name)?") {
                    self.store.removeFromGroup(person, group: group)
                }
            }
            .disabled(self.store.busy)
        }
    }

    private func removeFriend(_ person: NativePerson, id: String) {
        self.confirm("Remove \(person.displayName) from your friends?") {
            store.run("Removing friend…", key: "remove-friend-\(id)") {
                try await store.mutate("/api/friends/\(id)/delete", method: .delete)
                store.removeDirectFriend(id)
                store.showList(notice: "Friend removed.")
                await store.refresh(force: true)
            }
        }
    }

    private func screenTitle(for screen: SocialStore.Screen) -> String {
        switch screen {
        case .list:
            self.store.tab == "global" ? (self.store.showsApps ? "Top apps" : "Leaderboard") :
                self.store.groups.first(where: { $0.id == self.store.tab })?.name ?? "Friends"
        case let .person(id): self.store.profilePeople[id]?.displayName ?? "Profile"
        case .photo: "Photo"
        case let .app(bundle): self.appDirectory.cards[bundle]?.name ?? "App"
        case .agents: "Agents"
        }
    }

    private func displayFriendCode(_ code: String) -> String {
        guard !code.contains("-"), code.count >= 6, code.count <= 12 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }

    private func legacyPeopleBar(
        edge: VerticalEdge,
        @ViewBuilder content: () -> some View
    ) -> some View {
        content()
            .background(.ultraThinMaterial)
            .background(alignment: edge == .top ? .bottom : .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            colors: edge == .top ? [.black, .clear] : [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 22)
                    .offset(y: edge == .top ? 22 : -22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func moveGroup(_ id: String, to index: Int) {
        guard let from = self.store.groups.firstIndex(where: { $0.id == id }),
              from != index, self.store.groups.indices.contains(index)
        else { return }
        withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0)) {
            self.store.moveGroup(id, to: index)
        }
        NativeHaptics.groupPlaced()
    }

    /// The dragged tab follows the pointer; the neighbours it has crossed
    /// slide aside by its width so the gap shows where it lands. The list
    /// itself changes only on release, so no tab jumps under the pointer.
    private func groupTabDragging(_ id: String, at index: Int) -> some ViewModifier {
        let drag = self.groupDrag
        var shift: CGFloat = 0
        if let drag, drag.id != id, let width = self.groupTabFrames[drag.id]?.width {
            let step = width + Self.groupTabSpacing
            if drag.index < index, index <= drag.target { shift = -step }
            else if drag.target <= index, index < drag.index { shift = step }
        }
        return GroupTabDragModifier(
            isDragged: drag?.id == id,
            offset: drag?.id == id ? (drag?.translation ?? 0) : shift,
            reduceMotion: self.reduceMotion,
            frameChanged: { frame in
                // Frames measured mid-drag include the drag's own offsets.
                if self.groupDrag == nil { self.groupTabFrames[id] = frame }
            },
            tap: { self.store.selectTab(id) },
            dragChanged: { translation in
                if self.groupDrag == nil {
                    self.groupDrag = GroupDrag(id: id, index: index, translation: translation, target: index)
                    NativeHaptics.groupPlaced()
                } else {
                    self.groupDrag?.translation = translation
                }
                guard let frame = self.groupTabFrames[id] else { return }
                let center = frame.midX + translation
                let target = self.store.groups.indices.filter { other in
                    other != index && (self.groupTabFrames[self.store.groups[other].id]?.midX ?? 0) < center
                }.count
                if self.groupDrag?.target != target {
                    withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0)) {
                        self.groupDrag?.target = target
                    }
                    NativeHaptics.groupCrossing()
                }
            },
            dragEnded: {
                let target = self.groupDrag?.target ?? index
                withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0)) {
                    self.groupDrag = nil
                    self.store.moveGroup(id, to: target)
                }
                if target != index { NativeHaptics.groupPlaced() }
            }
        )
    }

    private func tab(_ label: String, id: String) -> some View {
        let selected = self.store.tab == id
        return Button { store.selectTab(id) } label: {
            HStack(spacing: 5) {
                // Where the Joined tray's mark comes to rest: the tab of the
                // group just joined carries it until the tray has closed.
                if self.store.joinedGroupID == id, self.joinedCheckLanded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                        .matchedGeometryEffect(
                            id: Self.joinedCheckMorphID(reduceMotion: self.reduceMotion),
                            in: self.morph
                        )
                        .transition(.opacity)
                }
                Text(label).font(.system(size: 13, weight: .medium)).fixedSize()
            }
            // The label is the same object before and after: only its
            // state changes, so the colour crosses over with the pill.
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.11))
                        .matchedGeometryEffect(id: "pill", in: self.tabPill)
                }
            }
        }
        .buttonStyle(NativeTabButtonStyle(reduceMotion: self.reduceMotion))
        .id(id)
        // A group joined from the tray gets its tab while the strip is on
        // screen: the neighbours make room and the tab grows into the gap.
        .transition(self.reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Two text lines, with the duration centred beside the whole block.
    ///
    /// The local clock expires live data even when the next refresh fails.
    /// It runs every five seconds, not every second: everything it decides —
    /// whether somebody is here, which app is in front, how many agents are
    /// writing — is good for two minutes from the moment it was seen, so
    /// five-second steps put the edge within five seconds of its true place
    /// and cost a fifth of the work. Measured over six seconds on a list of
    /// twenty-five rows: 175 row bodies on a second hand, 50 on this one.
    /// (`.explicit`, which would strike only on the three dates a row can
    /// change on, fires once and then stops — measured too, so the row keeps
    /// a periodic clock.)
    private func personRow(_ person: NativePerson, place: Int?, morphSource: String) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: Self.rowPlaceSpacing) {
                if self.showsPlaces { self.placeColumn(place) }
                HStack(spacing: Self.rowAvatarSpacing) {
                    FirstlightAvatar(
                        url: person.avatar_url,
                        name: person.displayName,
                        size: Self.rowAvatarSize,
                        presence: person.isActive(at: context.date) ? .online : .away,
                        morph: .init(id: self.morphID(Self.avatarMorphID, row: morphSource), namespace: self.morph)
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(person.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                                .help(person.displayName)
                                .matchedGeometryEffect(
                                    id: self.morphID(Self.nameMorphID, row: morphSource),
                                    in: self.morph, properties: .position
                                )
                            if person.id == Defaults[.currentUserID] {
                                Text("You")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
                            if let location = self.profileText(person.location) {
                                HStack(spacing: 3) {
                                    NativeLocationIcon().frame(width: 9)
                                    Text(location)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .matchedGeometryEffect(
                                            id: self.morphID(Self.locationMorphID, row: morphSource),
                                            in: self.morph, properties: .position
                                        )
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 28, maxWidth: 112, alignment: .leading)
                                .help(location)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 17, alignment: .leading)
                        // Room for the count's capsule, which stands a couple
                        // of points taller than the words beside it. Still
                        // inside the portrait's 40, so the row keeps its 60.
                        self.personStatusLine(person, at: context.date)
                            .frame(height: 18, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    AnimatedDuration(
                        minutes: !self.showingAppRanking && self.store.metric == "agent" ? person.score ?? 0 : person
                            .active_minutes ?? 0
                    )
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 70, alignment: .trailing)
                }
                .frame(height: Self.rowAvatarSize)
            }
            .padding(.horizontal, Self.rowHorizontalPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder private func personStatusLine(_ person: NativePerson, at now: Date) -> some View {
        let appName = self.profileText(person.activeApp(at: now)?.name)
        let live = person.liveAgents(at: now)

        // Presence alone may have no activity to show; keep the bio in that case.
        if appName != nil || live != nil {
            // The same phrase the profile carries, from the same view.
            NativePresenceLine(appName: appName, live: live)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let bio = self.profileText(person.bio) {
            Text(bio)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(bio)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// A place every row carries, whether or not the person did anything this
    /// period. A chart numeral: large enough to give the row its structure,
    /// light enough to stay behind the name. The podium is struck in metal by
    /// `LeaderboardPlaceStyle`; everything below it stays grey.
    @ViewBuilder private func placeColumn(_ place: Int?) -> some View {
        Group {
            if let place {
                Text("\(place)")
                    .font(.system(size: 17, weight: LeaderboardPlaceStyle.weight(for: place)))
                    // A place that changes on refresh counts up or down in
                    // step with the row moving, instead of flicking.
                    .contentTransition(.numericText(value: Double(place)))
                    .foregroundStyle(LeaderboardPlaceStyle.numeral(for: place))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .accessibilityLabel("Place \(place)")
            } else {
                Text("–").font(.system(size: 17)).foregroundStyle(.quaternary).accessibilityHidden(true)
            }
        }
        // Centred, not trailing: right alignment pushes a single digit away
        // from the edge and opens a gap the two-digit rows do not have.
        .frame(width: Self.rowPlaceWidth, alignment: .center)
    }

    /// The place this profile holds in the ranking on screen, so a person
    /// opened from the board keeps their standing in view.
    private func placeSummary(for id: String) -> String? {
        guard self.showsPlaces else { return nil }
        return LeaderboardPlace.summary(place: self.store.place(of: id), total: self.store.peopleList.total)
    }

    // Trim optional profile text before reserving space in the shared list row.
    // Social links stay on the person's profile.
    private func profileText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func invitePrompt(for candidate: InviteInput) -> InvitePrompt {
        switch candidate {
        case let .friendCode(code):
            if code.caseInsensitiveCompare(self.store.personalInvite?.personalInviteCode ?? "") == .orderedSame {
                InvitePrompt(
                    icon: "person.crop.circle",
                    title: "That's your own friend code",
                    message: "Send it to someone else so they can add you.",
                    actionTitle: nil,
                    loadingTitle: ""
                )
            } else {
                InvitePrompt(
                    icon: "person.badge.plus",
                    title: "Send a friend request",
                    message: "Code \(self.displayFriendCode(code)). They choose whether to accept.",
                    actionTitle: "Send request",
                    loadingTitle: "Sending…"
                )
            }
        case .token:
            if let info = store.inviteInfo {
                InvitePrompt(
                    icon: "envelope.open",
                    title: info.invite.groupName,
                    message: "Invited by \(info.invite.inviterName) · \(self.memberCount(info.invite.memberCount))",
                    actionTitle: "Accept invitation",
                    loadingTitle: "Joining…"
                )
            } else if let error = store.inviteError {
                InvitePrompt(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't open this invitation",
                    message: error,
                    actionTitle: nil,
                    loadingTitle: ""
                )
            } else {
                InvitePrompt(
                    icon: "link",
                    title: "Checking this invitation…",
                    message: "Reading the link you pasted.",
                    actionTitle: nil,
                    loadingTitle: ""
                )
            }
        }
    }

    private func memberCount(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    private func switchAccountForInvite() {
        let invite = self.store.query
        self.confirm("Sign out and accept this invitation with another account?") {
            session.pendingInvite = invite
            store.run("Signing out…", key: "switch-account") { try await session.signOut() }
        }
    }

    // MARK: Agents screen

    /// A person's agents at length. The card the profile showed is the first
    /// thing here, the same card in the same margins, carried up rather than
    /// drawn again; what follows it is what the card had no room for. The
    /// sections after the card split in two: the cost, the streak and the
    /// records are the last thirty days whatever the period, so a record
    /// stays a record; models and tools follow the period control.
    @ViewBuilder private func agentsDetail(_ id: String) -> some View {
        let person = self.store.selectedPerson
        let summary = self.store.agentSummary
        let month = self.store.agentMonth
        VStack(spacing: 3) {
            self.screenHeadline("Agents")
            Text(self.agentsRangeLabel(summary))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        // Below the row of buttons, not under it: the headline shrinks into
        // that row as it scrolls up, and has to start out of it.
        .padding(.top, NativeLayout.popoverHeaderHeight)
        .zIndex(self.profileTitleProgress > 0 ? 2 : 0)

        AgentsPanel(
            summary: summary,
            period: self.store.period,
            ownTime: self.store.activity?.active_minutes ?? (person?.id == id ? person?.active_minutes : nil),
            loadingOwnTime: self.store.screenLoading,
            hovered: self.$agentsHovered
        )
        .matchedGeometryEffect(id: Self.agentsCardMorphID, in: self.morph)

        if let month, month.has_data {
            let days = month.days ?? []
            if days.contains(where: { $0.tokens_total != nil }) {
                self.sectionHeading(month.cost_usd == nil ? "Tokens by day" : "Cost").padding(.top, 4)
                AgentSpendCard(month: month)
            }
            self.sectionHeading("Streak").padding(.top, 4)
            AgentStreakSection(streak: self.store.agentStreak)
            let records = self.store.agentRecords
            if !records.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    self.sectionHeading("Records")
                    Text("last 30 days").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
                AgentRecordTiles(
                    records: records,
                    openSource: self.store.agentDayTray?.source,
                    frames: self.agentTileFrames
                ) { record in
                    guard let date = record.date else { return }
                    self.agentDaySource = self.agentTileFrames.frames[record.id]
                    self.agentDayTitleTravel = nil
                    self.agentDayTitleLanded = false
                    // The tray is headed by what the tile was headed by, so
                    // the words can travel; the day and the figure follow
                    // under them.
                    self.store.openAgentDay(.init(
                        date: date, title: record.title,
                        note: "\(NativeAgentTime.dayLabel(date)) · \(record.value)", source: record.id
                    ))
                }
            }
        } else if month == nil, self.store.screenLoading {
            NativeSkeletonShape(width: nil, height: 132, radius: 12)
        }

        if let summary, summary.has_data {
            if let models = summary.by_model { AgentModelsSection(models: models).padding(.top, 4) }
            if let tools = summary.by_tool { AgentToolsSection(tools: tools).padding(.top, 4) }
        }
    }

    /// The days the card and the period's sections are about, in words.
    private func agentsRangeLabel(_ summary: NativeAgentSummary?) -> String {
        if self.store.period == "24h" { return "Last 24 hours" }
        return NativeAgentTime
            .rangeLabel(summary?.days) ?? (self.store.period == "30d" ? "Last 30 days" : "Last 7 days")
    }

    /// A screen's own title, handed to the row of buttons the way a profile's
    /// name is: it rides the screen up, shrinks to the row's size over the
    /// last stretch, and is held on the row's line with the band behind it.
    /// See `profileName`, which this is without the flight from a list row.
    private func screenHeadline(_ title: String) -> some View {
        let progress = self.profileTitleProgress
        return Text(title)
            .font(.system(size: 20, weight: .semibold))
            .lineLimit(1)
            .scaleEffect(1 - CGFloat(progress) * (1 - Self.profileTitleRowScale))
            .background(alignment: .center) { profileNameBand }
            .offset(y: self.profileTitleStick)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: ProfileTitleCenter.self,
                    value: geometry.frame(in: .named(NativeLayout.popoverScrollSpace)).midY
                )
            })
            .zIndex(progress > 0 ? 2 : 0)
    }

    /// The tray's title is the tile's title, moved. It is laid out where it
    /// belongs from the first frame; a hidden twin says where that is, and
    /// the one that is seen starts over the tile's own title, at the tile's
    /// size, and flies to its place while the surface opens under it. One
    /// title on screen throughout: the tile hides its own while it is open.
    private func agentDayTitle(_ title: String) -> some View {
        let text = Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
        let travel = self.agentDayTitleLanded || self.reduceMotion ? .zero : (self.agentDayTitleTravel ?? .zero)
        let scale = self.agentDayTitleLanded || self.reduceMotion ? 1 : AgentTileFrames.titleScale
        return text.hidden()
            .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(AgentTileFrames.space)).origin }) { origin in
                guard !self.agentDayTitleLanded, self.agentDayTitleTravel == nil,
                      let source = self.agentDaySource else { return }
                self.agentDayTitleTravel = CGSize(
                    width: source.minX + AgentTileFrames.titleInset - origin.x,
                    height: source.minY + AgentTileFrames.titleInset - origin.y
                )
                // The start is set without animation, then the landing
                // animates from it on the next turn of the run loop.
                DispatchQueue.main.async {
                    withAnimation(NativeTrayMorph.animation(isExpanded: true, reduceMotion: self.reduceMotion)) {
                        self.agentDayTitleLanded = true
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                text.fixedSize()
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(travel)
                    .opacity(
                        self.agentDayTitleTravel == nil && !self.reduceMotion && self
                            .agentDaySource != nil ? 0 : 1
                    )
            }
    }

    /// One day in the invite tray's chrome: thick material, 16 pt corners, a
    /// round close button. Its surface shares geometry with the record tile it
    /// was opened from, so it grows out of that tile and returns into it. The
    /// tile is a flat fill inside a scrolling page, not glass, so the surface
    /// morphs as a shape rather than as a glass effect.
    private func agentDayTray(_ tray: SocialStore.AgentDayTray, day: NativeAgentSummary.Day) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { self.store.closeAgentDay() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 22)
                }
                .modifier(NativeRoundGlassButton())
                .help("Close")
                .accessibilityLabel("Close")
                VStack(alignment: .leading, spacing: 1) {
                    self.agentDayTitle(tray.title)
                    Text(tray.note).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .opacity(self.agentDayTitleLanded || self.reduceMotion ? 1 : 0)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            // The day stands at its own height; only one with many runs
            // reaches the tray's limit, and only then does it scroll. Built
            // once and measured, not built twice to see which fits.
            ScrollView {
                AgentDayTrayContent(day: day)
                    .padding(.horizontal, 14).padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        if abs((self.agentDayHeight ?? 0) - height) > 0.5 { self.agentDayHeight = height }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(self.agentDayHeight ?? 270, Self.trayMaximumHeight - 60))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The surface alone; the travel out of the tile and the shadow that
        // comes with it are `AgentTrayGrow`'s, on the layer.
        .modifier(NativeTraySurface(morph: nil, backgroundMaterial: .thick))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tray.title), \(tray.note)")
    }

    @ViewBuilder private func personDetail(_ id: String) -> some View {
        if let person = store.selectedPerson {
            VStack(spacing: 8) {
                // Flies in from the tapped row. Kept above the name and the rest
                // of the profile so the portrait never passes underneath text.
                FirstlightAvatar(
                    url: person.avatar_url,
                    name: person.displayName,
                    size: Self.profileAvatarSize,
                    presence: id == Defaults[.currentUserID] || person.isActiveNow ? .online : .away,
                    morph: .init(id: self.morphID(Self.avatarMorphID), namespace: self.morph),
                    opensPhoto: { self.store.open(.photo(id)) }
                )
                .bumpAvatarResponse()
                .zIndex(1)

                // The name travels from the row too. Position only: the two
                // sizes cross-fade in place instead of one being stretched.
                // Scrolled up, this same text is the title in the row of
                // buttons.
                self.profileName(person)

                if let location = person.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Travels with the name, from the row's second line. On
                    // the profile it also carries their clock: the week below
                    // is cut at their midnight, so the reader can see which
                    // midnight that is.
                    NativeLocationLabel(text: location, timeZone: self.store.timeZone(for: person.id))
                        .matchedGeometryEffect(
                            id: self.morphID(Self.locationMorphID),
                            in: self.morph,
                            properties: .position
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Self.profileTopInset)
            // zIndex inside a stack only orders that stack, and the name has
            // to be over the bio and the tiles as well as over the portrait.
            // So the block the name is in takes the front too, and only while
            // the name is holding the row.
            .zIndex(self.profileTitleProgress > 0 ? 2 : 0)

            if let bio = person.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }

            // Links sit with the person, right under who they are, as small
            // pills; the numbers below are about what they did.
            self.profileLinks(website: person.website, twitter: person.twitter, telegram: person.telegram)

            // What is happening this minute, in one line of words: the app in
            // front, and the agent writing, with how long it has been at it.
            if person.public_apps_only != true { self.nowLine(person) }

            // One surface for the whole picture: the two numbers, the chart
            // they both read, and the tools. The period control in the header
            // is the zoom; a press on the card, or on More in its corner, is
            // the depth: the same card carried to the top of a screen of its
            // own, with the streak, the records and the tokens under it.
            if person.public_apps_only != true {
                let ownTime = self.store.activity?.active_minutes ?? person.active_minutes
                AgentsPanel(
                    summary: self.store.agentSummary,
                    period: self.store.period,
                    ownTime: ownTime,
                    loadingOwnTime: self.store.screenLoading,
                    hovered: self.$agentsHovered,
                    onMore: { self.store.openAgents(id) }
                )
                .matchedGeometryEffect(id: Self.agentsCardMorphID, in: self.morph)
                .bumpCardResponse()
            }

            if self.isLoadingProfileActivity {
                NativeTrackedAppsSkeleton()
            }
            // Named apps, or only how much of them there was. A person at
            // the middle level is not missing this section, so it keeps its
            // heading and answers in one line instead of a list.
            let apps = self.store.activity?.apps
            if let topApps = store.activity?.top_apps, !topApps.isEmpty, apps?.isOff != true {
                self.sectionHeading("Apps").padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(topApps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        Button { self.openApp(NativeAppCard(activity: app), from: person) } label: {
                            trackedAppRow(app, morphOrigin: person.id)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < min(topApps.count, 5) - 1 { Divider().padding(.leading, 38).opacity(0.5) }
                    }
                }
            } else if let apps, !apps.isDetailed, !apps.isOff, apps.minutes > 0 {
                self.sectionHeading("Apps").padding(.top, 4)
                Text(
                    apps.app_count.map { "\(apps.timeLabel) across \($0) app\($0 == 1 ? "" : "s")" }
                        ?? apps.timeLabel
                )
                .foregroundStyle(.secondary)
            }
            if person.id != Defaults[.currentUserID], person.public_apps_only != true {
                Color.clear.frame(height: 46)
            }
        }
    }

    /// The line under the name, in the words the row used: the app in front,
    /// and the agents writing with how many of them there are. The row this
    /// profile was opened from says exactly this, so the portrait lands over
    /// a line the eye has already read.
    ///
    /// Its own clock, so the count goes at two minutes whether or not the
    /// next refresh lands. The line's presence is settled once per render:
    /// the last live minute to expire under the pointer leaves the profile
    /// a gap until the next one, which is cheaper than a second ticking
    /// through the chart and the shifts below it.
    @ViewBuilder private func nowLine(_ person: NativePerson) -> some View {
        let opened = Date()
        if self.presentApp(person, at: opened) != nil || self.liveAgents(person, at: opened) != nil {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                NativePresenceLine(
                    appName: self.presentApp(person, at: context.date),
                    live: self.liveAgents(person, at: context.date),
                    size: 12
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
        }
    }

    /// The app somebody is in. The person's own record carries the moment it
    /// was seen and expires with the rest of the line; the profile's own
    /// request answers for a list that sends no apps at all — the global
    /// board — and is only believed while the person is still here.
    private func presentApp(_ person: NativePerson, at moment: Date) -> String? {
        if let app = person.activeApp(at: moment) { return app.name }
        guard person.isActive(at: moment) || person.id == Defaults[.currentUserID] else { return nil }
        return self.store.activity?.active_app?.name
    }

    /// The minute's agents. The person record carries the count the list
    /// drew; the summary answers for a profile reached without one — the
    /// global board sends no live data — and for a minute recorded after the
    /// list was built. Both are now cut by the same server helper from the
    /// same rows, so whichever answers, the profile says the number the row
    /// said. It used to build one from `now.sessions`, which counts the tool
    /// that wrote last and not the minute: two agents in the list became one
    /// on the profile.
    private func liveAgents(_ person: NativePerson, at moment: Date) -> NativeAgentLive? {
        if let live = person.liveAgents(at: moment) { return live }
        guard let live = self.store.agentSummary?.agent_live, live.session_count > 0,
              let stamp = NativeAgentTime.date(live.observed_at)
        else { return nil }
        // The same two minutes a row's own count is good for.
        let age = moment.timeIntervalSince(stamp)
        return age >= NativePerson.clockSlack && age <= NativePerson.freshness ? live : nil
    }

    /// A number with its name, in the profile's card tone. `glyph` names a
    /// tool whose mark sits before the title.
    private func profileTile(
        title: String,
        glyph: String? = nil,
        subtitle: String?,
        @ViewBuilder number: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let glyph { NativeAgentGlyph(tool: glyph, size: 11).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            number().font(.system(size: 20, weight: .medium))
            // The line keeps its room whether or not it has something to
            // say, so a tile does not change height under the pointer.
            Text(subtitle ?? " ").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: subtitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Where to find a person. Each pill says the address itself — the site,
    /// the @handle — because the glyph already names the service, and
    /// "Website" or "X" told nobody where the link goes. A pill that does not
    /// fit the row starts a second one rather than cutting a handle short.
    @ViewBuilder private func profileLinks(website: String?, twitter: String?, telegram: String?) -> some View {
        let links = [ProfileLink(.website, website), ProfileLink(.x, twitter), ProfileLink(.telegram, telegram)]
            .compactMap { $0 }
        if !links.isEmpty {
            NativeCenteredFlow(spacing: 6) {
                ForEach(links, id: \.kind) { self.profileLinkPill($0) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func profileLinkPill(_ link: ProfileLink) -> some View {
        let (assetImage, spoken) = switch link.kind {
        case .website: ("ProfileWebsite", link.label)
        case .x: ("ProfileX", "\(link.label) on X")
        case .telegram: ("ProfileTelegram", "\(link.label) on Telegram")
        }
        return Link(destination: link.url) {
            HStack(spacing: 5) {
                Image(assetImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                Text(link.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .contentShape(Capsule())
        }
        // A link is pressed the way a group tab is pressed: the fill firms
        // up under the pointer and the pill gives a little on mouse down.
        // The same style, so the two never drift apart.
        .buttonStyle(NativeTabButtonStyle(reduceMotion: self.reduceMotion, shape: AnyShape(Capsule())))
        .help(link.url.absoluteString)
        .accessibilityLabel("Open \(spoken)")
    }

    private func trackedAppRow(
        _ app: NativeAppActivity,
        morphOrigin: String,
        showsActiveState: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            NativeTrackedAppIcon(url: app.icon_url, bundleIdentifier: app.bundle_identifier, size: 28)
                .matchedGeometryEffect(
                    id: self.appMorphID(app.id, origin: morphOrigin),
                    in: self.appMorph
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .matchedGeometryEffect(
                        id: self.appMorphID(
                            app.id,
                            element: "name",
                            origin: morphOrigin
                        ),
                        in: self.appMorph, properties: .position
                    )
                if showsActiveState {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Active now").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 8)
            if !showsActiveState {
                AnimatedDuration(minutes: app.active_minutes)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    /// A row in a tray that leads to another tray. It lights like a person's
    /// row, because it does the same thing: a click opens what it names.
    private func navigationRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .modifier(TrayRowHighlight())
    }

    /// A person waiting on an answer. The whole row lights up and shows a
    /// chevron under the pointer, because the row opens who they are; the two
    /// round buttons beside it answer without leaving.
    private func requestRow(
        _ person: NativeContact,
        detail: String,
        @ViewBuilder actions: @escaping () -> some View
    ) -> some View {
        TrayPersonRow(
            name: person.displayName,
            avatarURL: person.avatar_url,
            detail: detail,
            open: { self.store.openAbout(person.id) },
            actions: actions
        )
    }

    /// Who someone is, with nothing counted: the face, what they wrote, and
    /// where to find them. Reached from a request or from a pasted code, so
    /// the answer is given knowing who is asking.
    @ViewBuilder private func trayAbout(_ personID: String) -> some View {
        if let card = store.card(for: personID) {
            VStack(spacing: 8) {
                FirstlightAvatar(url: card.avatar_url, name: card.name, size: 56)
                Text(card.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                if let location = self.profileText(card.location) {
                    NativeLocationLabel(text: location)
                }
            }
            .frame(maxWidth: .infinity)
            if let bio = self.profileText(card.bio) {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }
            // The same pills the profile wears, in the same row under the
            // name: one person, one way of showing where to find them.
            self.profileLinks(website: card.website, twitter: card.twitter, telegram: card.telegram)
            if card.isBare {
                Text("They haven't written anything about themselves yet.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        } else if let error = store.error, !store.cardLoading {
            NativeInlineError(message: error) { self.store.openAbout(personID) }
        } else {
            // The same shape the card will take, so the tray settles once.
            VStack(spacing: 8) {
                Circle().fill(Color.primary.opacity(0.08)).frame(width: 56, height: 56)
                NativeSkeletonShape(width: 104, height: 14, radius: 4)
                NativeSkeletonShape(width: 148, height: 11, radius: 4)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func quiet(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func operationButton(
        _ title: String,
        loadingTitle: String,
        key: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Group {
            if prominent {
                Button(action: action) {
                    NativeAsyncButtonLabel(
                        title: title,
                        loadingTitle: loadingTitle,
                        isLoading: store.isRunning(key)
                    )
                }.buttonStyle(.borderedProminent).tint(.firstlight)
            } else {
                Button(action: action) {
                    NativeAsyncButtonLabel(
                        title: title,
                        loadingTitle: loadingTitle,
                        isLoading: store.isRunning(key)
                    )
                }
            }
        }.disabled(self.store.busy)
    }

    private func confirm(_ title: String, action: @escaping () -> Void) {
        self.confirmationTitle = title; self.confirmationAction = action; self.confirming = true
    }

    private func resumeInvite() {
        guard let value = session.pendingInvite else { return }
        self.store.query = value
        // A friend's link opened in the app is their consent and the person's
        // own choice to follow it, so the two are friends without another
        // button. Nothing is asked and nothing is answered, so nothing opens
        // over the list: the first thing after sign-in is the friend in it,
        // and the capsule under the header says who. Only a failure brings
        // the tray up, where the field and the message are.
        if self.session.pendingInviteSource == .link, self.store.queryIsLink,
           case .friendCode? = self.store.inviteCandidate
        {
            self.store.queryChanged()
            self.store.addFromQuery()
            return
        }
        // The popover and the tray arrive together: nothing to grow from.
        self.store.openTray(.home, from: .none)
        self.store.query = value
        self.store.queryChanged()
        // A link found in the clipboard was not followed by anyone, and a
        // group is a bigger step, so both still ask; the landing page's own
        // invitation is the one exception, below.
        self.acceptDefaultInvite()
    }

    /// The landing page hands its own invitation to whoever downloads without
    /// a friend's link, and it reaches the app only through the clipboard.
    /// Welcome has already said the two will be friends, so it is accepted
    /// without a press. Only the lookup can tell it from a friend's link found
    /// there, which still asks, so this runs again when the lookup answers.
    private func acceptDefaultInvite() {
        guard self.session.pendingInviteSource == .clipboard,
              let pending = self.session.pendingInvite, self.store.query == pending,
              let inviter = self.store.inviter, inviter.isDefaultInviter == true,
              case .friendCode(inviter.code)? = self.store.inviteCandidate,
              !(inviter.inviterId.map { self.store.directFriendIDs.contains($0) } ?? false),
              !self.store.isRunning("accept-invite")
        else { return }
        self.store.addFromQuery()
    }

    private func refreshVisibleScreen() {
        guard self.windowManager.isVisible, !self.store.busy else { return }
        self.store.refreshCurrentScreen()
    }
}

private struct HorizontalScrollFades: Equatable {
    // MARK: Lifecycle

    init() {}

    init(geometry: ScrollGeometry) {
        let fadeDistance: CGFloat = 18
        let overflow = max(geometry.contentSize.width - geometry.containerSize.width, 0)
        let offset = min(max(geometry.contentOffset.x, 0), overflow)
        self.leading = min(offset / fadeDistance, 1)
        self.trailing = min((overflow - offset) / fadeDistance, 1)
    }

    // MARK: Internal

    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

private struct HorizontalScrollFadeMask: View {
    let fades: HorizontalScrollFades

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(1 - self.fades.leading), .black],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 18)

            Rectangle().fill(.black)

            LinearGradient(
                colors: [.black, .black.opacity(1 - self.fades.trailing)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 18)
        }
    }
}

/// A row in a tray that stands for a person. The whole row lights under the
/// pointer, edge to edge with the tray's content, rounded on both sides and
/// with the same air all round. The face and the name open who they are; the
/// round actions on the right answer in place.
private struct TrayPersonRow<Actions: View>: View {
    let name: String
    let avatarURL: String?
    let detail: String
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Button(action: self.open) {
                HStack(spacing: 10) {
                    FirstlightAvatar(url: self.avatarURL, name: self.name, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(self.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("About \(self.name)")
            self.actions()
        }
        .modifier(TrayRowHighlight())
    }
}

/// A tray's card: a quiet surface with a hairline, in one place so a card that
/// leads somewhere and one that does not are the same object at rest.
private struct TrayCardSurface: ViewModifier {
    let lit: Bool

    func body(content: Content) -> some View {
        content
            .padding(11)
            .background(
                Color.primary.opacity(self.lit ? 0.09 : 0.055),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(self.lit ? 0.16 : 0.09), lineWidth: 0.5)
            }
    }
}

/// The same card, made to open something: it lights under the pointer the way
/// a row does, and the whole surface is the target.
private struct TrayTappableCard<Content: View>: View {
    // MARK: Internal

    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: self.action) {
            self.content()
                .modifier(TrayCardSurface(lit: self.hovering))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { self.hovering = $0 }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.hovering)
    }

    // MARK: Private

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The lit background every row in a tray shares, and the only place its
/// geometry is written down. The highlight is exactly the row's own bounds, so
/// it is centred whatever the row holds and the scroll view it lives in has
/// nothing of it to clip; the row then takes back the 8 pt the step insets its
/// content by, which keeps the content on the tray's 14 pt line and lets the
/// highlight reach 6 pt from the tray's edge, the same on both sides.
private struct TrayRowHighlight: ViewModifier {
    // MARK: Internal

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                self.hovering ? Color.primary.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .padding(.horizontal, -8)
            .contentShape(Rectangle())
            .onHover { self.hovering = $0 }
            .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.hovering)
    }

    // MARK: Private

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// One row of a list taking over from its skeleton: a short rise and a fade,
/// later for each row down the list. Only the reveal is animated, so a tab
/// that goes back to loading drops its rows without a staggered exit.
private struct SkeletonRowReveal: ViewModifier {
    let revealed: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(self.revealed ? 1 : 0)
            .offset(y: self.revealed || self.reduceMotion ? 0 : 5)
            .animation(
                self.revealed
                    ? (
                        self.reduceMotion
                            ? .easeOut(duration: 0.12)
                            : SocialStore.settle.delay(Double(min(self.index, 6)) * 0.06)
                    )
                    : nil,
                value: self.revealed
            )
    }
}

/// One answer, one round button: a mark to accept, a cross to decline or take
/// back. The shape is the tray's own dismiss button, so the two read as one
/// family of controls.
private struct TrayCircleAction: View {
    let symbol: String
    let help: String
    var prominent = false
    var isLoading = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            NativeLoadingSwap(isLoading: self.isLoading) {
                Image(systemName: self.symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 18, height: 22)
        }
        .modifier(TrayCircleButtonStyle(prominent: self.prominent))
        .disabled(self.disabled)
        .help(self.help)
        .accessibilityLabel(self.help)
    }
}

private struct TrayCircleButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if self.prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.regular)
                    .tint(.firstlight)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            }
        } else {
            if self.prominent {
                content.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.regular)
                    .tint(.firstlight)
            } else {
                content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
            }
        }
    }
}

/// The round Liquid Glass button the app uses for Back and Settings, with the
/// bordered circle where glass is not available.
private struct NativeRoundGlassButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
        }
    }
}

/// The one filled capsule of a tray, the same control as Invite in the footer.
private struct NativeCapsuleProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.firstlight)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.firstlight)
        }
    }
}

/// Capsule glass buttons, like the Invite capsule in the footer, for a row of
/// equal actions; bordered capsules before glass.
private struct NativeCapsuleGlassButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// A label that changes by the word. Words the old and new text share keep
/// their identity and slide to their new place; the words that differ leave
/// upwards and arrive from below. "Join group" becomes "Join Runway" by
/// moving one word, the way Family turns Continue into Confirm.
private struct MorphingLabel: View {
    // MARK: Internal

    let text: String
    var reduceMotion = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(self.words, id: \.id) { word in
                Text(word.text)
                    .fixedSize()
                    .transition(self.reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 8).combined(with: .opacity),
                        removal: .offset(y: -8).combined(with: .opacity)
                    ))
            }
        }
        .animation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.1), value: self.text)
        .accessibilityLabel(self.text)
    }

    // MARK: Private

    /// Words identified by their text and how many times it has already
    /// appeared, so a repeated word still gets an identity of its own.
    private var words: [(id: String, text: String)] {
        var seen: [String: Int] = [:]
        return self.text.split(separator: " ").map { part in
            let word = String(part)
            let count = seen[word, default: 0]
            seen[word] = count + 1
            return (id: "\(word)#\(count)", text: word)
        }
    }
}

extension AnyTransition {
    /// A request row accepted: it slides off to the left, where the list is
    /// (Back goes that way), rather than fading on the spot.
    static let acceptedRequest: AnyTransition = .asymmetric(
        insertion: .opacity,
        removal: .offset(x: -28).combined(with: .opacity)
    )

    /// The invitation banner once its request has gone out: it settles down
    /// towards the Sent requests row that counts it from now on.
    static let sentInvite: AnyTransition = .asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
        removal: .offset(y: 26).combined(with: .opacity)
    )
}

private struct InvitePrompt {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let loadingTitle: String
}

private struct NativeFeedbackToast: View {
    // MARK: Internal

    let state: SocialStore.FeedbackToast

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if self.state.isLoading {
                    ProgressView().controlSize(.small).transition(.opacity)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.35).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: self.state)

            Text(self.state.message).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background {
            if #available(macOS 26.0, *), !self.reduceTransparency {
                Color.clear.glassEffect(.regular, in: .capsule)
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.12), value: self.state.message)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
}

struct FirstlightAvatar: View {
    // MARK: Internal

    /// Shared geometry with another avatar, so the portrait flies between a
    /// list row and a profile. The effect sits under the avatar's own fixed
    /// frame: above it the size would be pinned and only the position would move.
    struct Morph {
        let id: String
        let namespace: Namespace.ID
    }

    /// What the portrait says about the person around it: whether they are at
    /// the Mac. Presence belongs to the whole person, so it rings the whole
    /// portrait. What their agents are doing is said in words beside the face
    /// — see `NativePresenceLine` — and never marked on it twice.
    enum Presence: Equatable {
        /// Not a presence surface at all: a form, a member list, an invite.
        case unknown
        case away
        case online
    }

    let url: String?
    let name: String
    var size: CGFloat = 44
    var presence: Presence = .unknown
    var morph: Morph?
    /// Tapping opens the photograph on its own screen, where it is set.
    var opensPhoto: (() -> Void)?

    var body: some View {
        // The portrait first: drawing it is what looks at a loaded picture, and
        // only a photograph is something to open.
        let portrait = self.portrait
        let opensPhoto = self.isPhotograph ? self.opensPhoto : nil
        portrait
            .mask { Circle() }
            .overlay {
                // A ring says "here" about the whole person, where a dot in the
                // corner would be one more object in the row. Outside the frame,
                // so the face keeps its diameter whether or not anyone is at the
                // Mac.
                if self.presence == .online {
                    FirstlightPresenceRing(
                        ringWidth: self.presenceRingWidth,
                        ringGap: self.presenceRingGap
                    )
                    .fill(Color.green)
                    .transition(.opacity)
                }
            }
            .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.24), value: self.presence)
            // Always applied so the view keeps one identity; without a morph the
            // avatar is alone in its own namespace and matches nothing.
            .matchedGeometryEffect(id: morph?.id ?? "avatar", in: morph?.namespace ?? unmatched)
            .frame(width: size, height: size)
            // A portrait says nothing a screen reader needs, until it is a
            // photograph that can be opened.
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(opensPhoto == nil)
            .accessibilityLabel(opensPhoto == nil ? "" : "Photo of \(self.name)")
            .opensPhoto(url: self.url, action: opensPhoto)
    }

    // MARK: Private

    @Namespace private var unmatched
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The address whose picture turned out, once loaded, to be one a service
    /// drew. Read by `body`, so the photo stops being offered the moment that
    /// is known, and kept by address, so a reused portrait for somebody else
    /// is not taken for it.
    @State private var drawnURL: String?

    /// The face, drawn from memory when it is already there and loaded when it
    /// is not. `LazyImage` asks for its picture from `onAppear`, which is a
    /// frame after the first one it draws: a list arriving on a tab change
    /// builds every row anew, so every portrait in it spends that frame as a
    /// placeholder and the rest of the change catching up — a circle filling in
    /// while the row is already sliding. The memory cache answers inside `body`,
    /// so a face that has been seen is on the first frame, and only a face that
    /// has not is loaded. Clerk's own tile is known from its address and never
    /// fetched at all.
    @ViewBuilder private var portrait: some View {
        let link = self.url.flatMap(URL.init(string:))
        if let link, !ProfilePhotoURL.isPlaceholder(self.url) {
            if let cached = ImagePipeline.shared.cache[link]?.image {
                self.face(cached)
            } else {
                LazyImage(url: link) { state in
                    if let image = state.imageContainer?.image { self.face(image) } else { self.monogram }
                }
                .onCompletion { result in
                    if case let .success(response) = result, AvatarTile.isDrawn(self.url, image: response.image) {
                        self.drawnURL = self.url
                    }
                }
            }
        } else {
            self.monogram
        }
    }

    /// Whether the portrait is somebody's photograph, as far as is known: there
    /// is an address, and nothing has shown it to be a tile a service drew.
    private var isPhotograph: Bool {
        guard let url = self.url, !url.isEmpty else { return false }
        return self.drawnURL != url && !AvatarTile.isKnownDrawn(url)
    }

    /// Nobody's photograph: the first letter of the name in the app's rounded
    /// face, on the faint fill every empty portrait here has, or a figure when
    /// the name has no letter to give. A tile a service drew in place of a
    /// photo — Clerk's blue one, Google's coloured squares — is shown as this
    /// too.
    private var monogram: some View {
        let letter = AvatarMonogram.letter(for: self.name)
        return ZStack {
            Color.primary.opacity(0.08)
            // A name being typed changes what stands here: the figure gives
            // way to the first letter, one letter to another. The new mark
            // comes up from below and pushes the old one out through the top,
            // so the face is seen to become the person rather than being
            // swapped under the reader. The portrait's own circle clips both.
            ZStack {
                if let letter {
                    AvatarLetter(letter: letter, size: self.size * 0.44)
                        .id(letter)
                        .transition(self.markTransition)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: self.size * 0.42, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(self.markTransition)
                }
            }
            .animation(self.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.3), value: letter)
        }
    }

    private var markTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(y: self.size * 0.22).combined(with: .opacity).combined(with: .blur),
            removal: .offset(y: -self.size * 0.22).combined(with: .opacity).combined(with: .blur)
        )
    }

    /// The ring sits outside the portrait with a hairline of room, so it reads as
    /// something around the person rather than a border drawn on the photo.
    private var presenceRingWidth: CGFloat { self.size <= 48 ? 1.5 : 2 }

    private var presenceRingGap: CGFloat { self.size <= 48 ? 2 : 3 }

    /// A loaded picture, unless it is one a service drew for someone without a
    /// photograph.
    @ViewBuilder private func face(_ image: NSImage) -> some View {
        if AvatarTile.isDrawn(self.url, image: image) {
            self.monogram
        } else {
            self.fill(Image(nsImage: image))
        }
    }

    /// The circle decides how big the portrait is, not the photo's own
    /// proportions. scaledToFill alone hands back a frame in the photo's
    /// aspect ratio, wider or taller than the one offered, and the mask
    /// is drawn in that frame: a portrait photo then turns into an
    /// oversized ellipse hanging out of the row. Color.clear takes the
    /// offered size, the photo fills it, and the overflow is cut.
    private func fill(_ image: Image) -> some View {
        Color.clear.overlay { image.resizable().scaledToFill() }.clipped()
    }
}

/// The presence ring, as one filled ring rather than a stroked circle: it is
/// drawn outside the portrait's own rect, which a stroke on the frame cannot
/// reach.
private struct FirstlightPresenceRing: Shape {
    let ringWidth: CGFloat
    let ringGap: CGFloat

    func path(in rect: CGRect) -> Path {
        // Drawn in the portrait's own rect and allowed to run outside it, so
        // the face keeps its diameter.
        let outer = rect.insetBy(dx: -(self.ringWidth + self.ringGap), dy: -(self.ringWidth + self.ringGap))
        return Path(ellipseIn: outer)
            .subtracting(Path(ellipseIn: outer.insetBy(dx: self.ringWidth, dy: self.ringWidth)))
    }
}

/// The one line that says what a person is doing this minute: the app they
/// are in, and the agents writing. A list row and a profile draw it from
/// here, so the row somebody taps and the profile it opens say the same
/// thing about the same minute. With neither half the line is nothing at
/// all — no reserved gap.
///
/// The agents take a capsule of their own, and it carries no colour. The
/// panel is a HUD material over whatever window happens to be behind it, so
/// its grey is not ours to know: over a bright window it lands mid-grey, and
/// a coloured wash on that is the same lightness as the coloured text
/// standing on it — blue on blue, which is what a tinted badge turned out to
/// be. A neutral plate is the one ground that cannot clash, because it is cut
/// from the panel's own foreground colour: it lifts whatever it sits on, and
/// the text on it is the plain text colour, which is always readable there.
///
/// So the count reads as a small plaque rather than a light: the shift of
/// tone marks it out, the weight of the figure holds it, and the colour of
/// agents is left to the chart further down the profile. The app's name stays
/// plain text beside it and needs no separator — the capsule's edge is the
/// separator.
struct NativePresenceLine: View {
    // MARK: Internal

    /// The app in front. The caller has already decided it is recent.
    let appName: String?
    /// The agents in the last recorded minute, likewise already checked.
    let live: NativeAgentLive?
    /// The row's size. A profile draws the same line one point larger.
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 7) {
            if let appName {
                Text("In \(appName)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(appName)
            }
            if let live {
                HStack(spacing: 5) {
                    // Two tools at most stand beside the one count; a longer
                    // list, and a person who shares no names, get the neutral
                    // mark instead and keep the number. The split is in `help`.
                    HStack(spacing: 3) {
                        if let tools = live.tools, !tools.isEmpty, tools.count <= 2 {
                            ForEach(tools, id: \.tool) { tool in
                                NativeAgentGlyph(tool: tool.tool, size: self.size + 1)
                            }
                        } else {
                            NativeAgentGlyph(tool: NativeAgentToolLabel.unnamed, size: self.size + 1)
                        }
                    }
                    .accessibilityHidden(true)
                    // With no colour left to mark the badge out, the weight
                    // of the figure does it. The figure is its own text so it
                    // can roll over like the durations elsewhere while the
                    // word beside it holds still.
                    HStack(spacing: 3) {
                        Text(live.countLabel)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(live.session_count)))
                        Text(live.nounLabel)
                    }
                    .fontWeight(.medium)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.12), in: Capsule())
                .fixedSize()
                // Arriving and leaving, rather than appearing and vanishing:
                // the minute's count comes and goes on its own clock, and a
                // badge that blinks in a list reads as a fault.
                .transition(.scale(scale: 0.86, anchor: .leading).combined(with: .opacity))
                // The count is what has to survive a narrow row: an app's name
                // can lose its tail, "128 agents now" cannot lose its digits.
                .layoutPriority(2)
                .help(live.detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(live.detail)
            }
        }
        .font(.system(size: self.size))
        .foregroundStyle(.secondary)
        // One animation for the whole line, keyed on what it is saying: the
        // count turning over, the badge arriving or going, the app's name
        // changing under it. The timeline it is drawn on brings these in
        // without an animation of its own, so this is the only thing standing
        // between a change and a cut.
        .animation(
            self.reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0),
            value: Said(app: self.appName, count: self.live?.session_count)
        )
    }

    // MARK: Private

    /// What the line is saying, as one comparable value.
    private struct Said: Equatable {
        let app: String?
        let count: Int?
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The glyph of one coding tool, drawn from a template asset so it takes the
/// text colour around it. A tool without a glyph gets a generic spark.
private struct NativeAgentGlyph: View {
    let tool: String
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let asset = NativeAgentToolLabel.glyph(self.tool), NSImage(named: asset) != nil {
                Image(asset).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: "sparkle").resizable().scaledToFit()
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

/// A profile tile answers a press the way a tab does: it gives a little.
struct ProfileTileStyle: ButtonStyle {
    // MARK: Internal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !self.reduceMotion ? 0.975 : 1)
            .animation(.snappy(duration: 0.16, extraBounce: 0), value: configuration.isPressed)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// Dates and clocks for the agent surfaces, in the viewer's zone, which is
/// the zone the server cut the days in.
enum NativeAgentTime {
    // MARK: Internal

    static func date(_ raw: String) -> Date? {
        self.fractional.date(from: raw) ?? self.whole.date(from: raw)
    }

    /// Hours into the local day, 0 to 24, for placing a moment on a strip.
    static func hour(_ raw: String) -> Double? {
        guard let date = self.date(raw) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    static func clock(_ raw: String) -> String {
        guard let date = self.date(raw) else { return "" }
        return self.clockFormatter.string(from: date)
    }

    /// "Thu 10 Sep", or "Today" for the day this is.
    static func dayLabel(_ day: String) -> String {
        if self.isToday(day) { return "Today" }
        guard let date = self.dayParser.date(from: day) else { return day }
        return self.dayFormatter.string(from: date)
    }

    /// "10 – 16 Sep" for one stretch of days.
    static func spanLabel(from: String, to: String) -> String {
        guard let a = self.dayParser.date(from: from), let b = self.dayParser.date(from: to) else { return from }
        let da = Calendar.current.component(.day, from: a), db = Calendar.current.component(.day, from: b)
        let monthB = self.monthFormatter.string(from: b)
        if Calendar.current.isDate(a, equalTo: b, toGranularity: .month) { return "\(da) – \(db) \(monthB)" }
        return "\(da) \(self.monthFormatter.string(from: a)) – \(db) \(monthB)"
    }

    static func weekdayLetter(_ day: String) -> String {
        guard let date = self.dayParser.date(from: day) else { return "" }
        return self.weekdayFormatter.string(from: date)
    }

    /// "10 Sep", short enough to stand where one letter stood.
    static func shortDate(_ day: String) -> String {
        guard let date = self.dayParser.date(from: day) else { return "" }
        return self.shortDateFormatter.string(from: date)
    }

    static func isToday(_ day: String) -> Bool {
        self.dayParser.string(from: .now) == day
    }

    /// "10 – 16 Sep" for the days a summary covers.
    static func rangeLabel(_ days: [NativeAgentSummary.Day]?) -> String? {
        guard let first = days?.first?.date, let last = days?.last?.date,
              let a = self.dayParser.date(from: first), let b = self.dayParser.date(from: last) else { return nil }
        let month = self.monthFormatter.string(from: b)
        let da = Calendar.current.component(.day, from: a), db = Calendar.current.component(.day, from: b)
        if Calendar.current.isDate(a, equalTo: b, toGranularity: .month) { return "\(da) – \(db) \(month)" }
        return "\(da) \(self.monthFormatter.string(from: a)) – \(db) \(month)"
    }

    // MARK: Private

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()
}

/// The colour a tool's minutes are drawn in. Identity, never rank: Codex is
/// blue on a day it came first and on a day it came last.
enum NativeAgentToolColor {
    static func color(_ tool: String) -> Color {
        switch tool {
        case "claude_code": Color(red: 0.92, green: 0.41, blue: 0.20)
        case "codex": Color(red: 0.16, green: 0.47, blue: 0.84)
        case "cursor": Color(red: 0.11, green: 0.69, blue: 0.48)
        case "opencode": Color(red: 0.58, green: 0.40, blue: 0.92)
        default: Color.primary.opacity(0.6)
        }
    }
}

/// How the agents arrive: not as a new card but as more of the one that
/// was already there. The person's own time stays put, the surface grows
/// under it, and everything new is uncovered once, left to right, by a
/// soft edge. Nothing scales, bounces or staggers.
private struct WipeReveal: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { geometry in
                let width = geometry.size.width
                let soft = max(width * 0.28, 40)
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: width / (width + soft)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width + soft, height: geometry.size.height + 24)
                .offset(x: -(width + soft) * (1 - self.progress), y: -12)
            }
        }
    }
}

/// One bucket of the agents chart: a stretch of time with the two figures
/// that belong to it. Hours for a day, days for a week, weeks for a month,
/// so the chart is always about a dozen marks however long the period is.
struct AgentBucket: Identifiable, Equatable {
    let id: String
    /// What the caption calls it: "14:00", "Wed 10 Sep", "10 – 16 Sep".
    let label: String
    /// The letter under the column, where there is room for one.
    let tick: String
    /// What the letter becomes under the pointer: the day's date, or the
    /// week's span.
    let hoverTick: String
    let agent: Double
    let human: Double
    /// The bucket's agent minutes by tool, taken from the runs inside it, so
    /// the split under the chart can narrow to whatever the pointer is on.
    /// Empty where only totals are shared and no run names a tool.
    let tools: [String: Double]
    /// The day this bucket is, when it is exactly one day.
    let dayIndex: Int?
    /// Where the person placed that day, when the bucket is one day and the
    /// day has something to place.
    let rankHuman: Int?
    let rankAgent: Int?
}

/// What the profile says about a person's agents, in one place: the two
/// figures, the chart at the period's own scale, and the tools. The period
/// control at the top of the popover is the zoom; the Agents screen, which
/// this same card opens and then heads, is the depth.
struct AgentsPanel: View {
    // MARK: Internal

    /// Nil, or without data, until the summary answers: the card then holds
    /// only the person's own time, and grows when the agents arrive.
    let summary: NativeAgentSummary?
    let period: String
    /// The person's own minutes over the same period, so both figures sit
    /// together and answer the same pointer.
    let ownTime: Double?
    let loadingOwnTime: Bool
    @Binding var hovered: AgentBucket?
    /// Opens the person's agents at length. Nil where the card already is
    /// that screen's first thing.
    var onMore: (() -> Void)?

    var body: some View {
        let agents = self.summary?.has_data == true ? self.summary : nil
        let hasAgents = agents != nil
        // The own-time figure is drawn twice: once hidden, to hold its room
        // inside the part that gets uncovered, and once on top, so it is the
        // one thing here that never moves.
        let ownFigure = self.figure(
            "Active time",
            minutes: self.hovered?.human ?? self.ownTime,
            loading: self.loadingOwnTime,
            place: self.hovered.map(\.rankHuman) ?? self.summary?.rank_active
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ownFigure.hidden()
                    if let agents {
                        self.figure(
                            "Agents",
                            minutes: self.hovered?.agent ?? agents.agent_minutes,
                            place: self.hovered.map(\.rankAgent) ?? agents.rank_agent
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let agents {
                    self.detail(agents)
                }
            }
            .modifier(WipeReveal(progress: self.uncovered ? 1 : 0))
            ownFigure
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // More sits in the card's corner, on the line of the two titles. It
        // is the button a keyboard and VoiceOver reach; the pointer has the
        // whole card.
        .overlay(alignment: .topTrailing) {
            if let onMore = self.onMore, hasAgents {
                Button(action: onMore) {
                    HStack(spacing: 2) {
                        Text("More")
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(self.uncovered ? 1 : 0)
                .help("Streak, records and tokens")
                .accessibilityLabel("More about agents")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .gesture(self.onMore == nil || !hasAgents ? nil : TapGesture().onEnded { self.onMore?() })
        .animation(self.reduceMotion ? nil : SocialStore.settle, value: hasAgents)
        .onAppear { self.uncovered = hasAgents }
        .onChange(of: hasAgents) { _, now in
            // Data that was already here when the profile opened needs no
            // ceremony; data that arrives later is uncovered once.
            withAnimation(self.reduceMotion || !now ? nil : .timingCurve(0.3, 0.7, 0.2, 1, duration: 0.55)) {
                self.uncovered = now
            }
        }
    }

    // MARK: Private

    /// Whether the part past the person's own time has been uncovered.
    @State private var uncovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hours for a day, days for a week, whole weeks for a month.
    private static func buckets(days: [NativeAgentSummary.Day], period: String) -> [AgentBucket] {
        guard period == "30d", days.count > 7 else {
            return days.enumerated().map { index, day in
                AgentBucket(
                    id: day.date,
                    label: NativeAgentTime.dayLabel(day.date),
                    tick: NativeAgentTime.weekdayLetter(day.date),
                    hoverTick: NativeAgentTime.shortDate(day.date),
                    agent: day.agent_minutes,
                    human: day.human_minutes,
                    tools: Self.split([day]),
                    dayIndex: index,
                    rankHuman: day.rank_active,
                    rankAgent: day.rank_agent
                )
            }
        }
        // Seven-day groups counted back from today, so the last column is
        // always the week in progress.
        var groups: [[NativeAgentSummary.Day]] = []
        var rest = days
        while !rest.isEmpty {
            let take = min(7, rest.count)
            groups.insert(Array(rest.suffix(take)), at: 0)
            rest = Array(rest.dropLast(take))
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return AgentBucket(
                id: first.date,
                label: NativeAgentTime.spanLabel(from: first.date, to: last.date),
                // A week stands under its first day, and under the pointer
                // says the whole stretch, the way a day says its date.
                tick: NativeAgentTime.shortDate(first.date),
                hoverTick: group.count == 1
                    ? NativeAgentTime.shortDate(first.date)
                    : NativeAgentTime.spanLabel(from: first.date, to: last.date),
                agent: group.reduce(0) { $0 + $1.agent_minutes },
                human: group.reduce(0) { $0 + $1.human_minutes },
                tools: Self.split(group),
                dayIndex: group.count == 1 ? days.firstIndex { $0.date == first.date } : nil,
                // A week has no place of its own: the board is by the day.
                rankHuman: group.count == 1 ? first.rank_active : nil,
                rankAgent: group.count == 1 ? first.rank_agent : nil
            )
        }
    }

    /// How a stretch of days divides between the tools: every run in them
    /// counted under the tool that ran it. A run is filed under the day it
    /// began on, which is also where the chart's column puts it.
    private static func split(_ days: [NativeAgentSummary.Day]) -> [String: Double] {
        var minutes: [String: Double] = [:]
        for run in days.flatMap({ $0.runs ?? [] }) { minutes[run.tool, default: 0] += run.minutes }
        return minutes
    }

    /// Everything past the two numbers: the chart, the tools, the shifts.
    @ViewBuilder private func detail(_ summary: NativeAgentSummary) -> some View {
        let days = summary.days ?? []
        let buckets = Self.buckets(days: days, period: self.period)
        VStack(alignment: .leading, spacing: 12) {
            // A single day is drawn as the day itself: runs across twenty-four
            // hours, with the person's presence under them. Longer periods
            // are columns, one per day or per week.
            if self.period == "24h", let today = days.last, today.runs?.isEmpty == false {
                ProfileDayColumns(day: today, hovered: self.$hovered)
            } else {
                AgentBucketBars(buckets: buckets, hovered: self.$hovered)
            }

            if let tools = summary.by_tool, !tools.isEmpty {
                let total = tools.reduce(0) { $0 + ($1.agent_minutes ?? 0) }
                if total > 0 {
                    // The period's split, until the pointer names a stretch of
                    // the chart and it becomes that stretch's.
                    ToolSplitBar(tools: tools, scope: self.hovered?.tools)
                }
            }
        }
    }

    /// One figure: its name, the number, and a note that only holds while
    /// the number means the whole period.
    @ViewBuilder private func figure(
        _ title: String,
        minutes: Double?,
        loading: Bool = false,
        place: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.65))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let minutes {
                    AnimatedDuration(minutes: minutes, animation: .snappy(duration: 0.22, extraBounce: 0))
                        .font(.system(size: 20, weight: .medium))
                        .fixedSize()
                } else if loading {
                    NativeSkeletonShape(width: 52, height: 20, radius: 5).padding(.vertical, 2)
                } else {
                    Text("—").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.primary.opacity(0.65))
                }
                // The place rides beside the number and costs no height. It
                // is the period's until the pointer names a day, and a day
                // nobody worked simply has none.
                if let place {
                    Text("#\(place)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(place <= 3 ? 0.9 : 0.55))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.22, extraBounce: 0), value: place)
        }
    }
}

/// The chart itself: one column per bucket, the agents' time above the
/// person's own. Hovering names the bucket in the caption above; there is
/// nothing to click, because there is nowhere deeper to go.
private struct AgentBucketBars: View {
    // MARK: Internal

    let buckets: [AgentBucket]
    @Binding var hovered: AgentBucket?
    var height: CGFloat = 56

    var body: some View {
        let scale = max(self.buckets.map { $0.agent + $0.human }.max() ?? 0, 1)
        let room = self.height - 2
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: self.buckets.count > 8 ? 3 : 6) {
                ForEach(self.buckets) { bucket in
                    let dimmed = self.hovered.map { $0.id != bucket.id } ?? false
                    let human = bucket.human > 0 ? min(max(room * bucket.human / scale, 2), room) : 0
                    let agent = bucket.agent > 0 ? min(max(room * bucket.agent / scale, 2), room - human) : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.firstlight)
                            .frame(height: max(agent, 0))
                        if agent > 0, human > 0 { Color.clear.frame(height: 2) }
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.32))
                            .frame(height: max(human, 0))
                    }
                    .frame(maxWidth: 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: self.height, alignment: .bottom)
                    .clipped()
                    .background(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
                    }
                    .opacity(dimmed ? 0.4 : 1)
                    .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: dimmed)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(bucket.label): \(DurationLabel.minutes(bucket.agent)) agents, \(DurationLabel.minutes(bucket.human)) at the Mac"
                    )
                }
            }
            .contentShape(Rectangle())
            .overlay {
                // One target over the whole row: sweeping across it never
                // passes through a gap where the reading falls back to the
                // period's total and then jumps to the next day.
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(point):
                                let slot = geometry.size.width / CGFloat(max(self.buckets.count, 1))
                                let index = min(max(Int(point.x / max(slot, 1)), 0), self.buckets.count - 1)
                                self.hovered = self.buckets[safe: index]
                            case .ended:
                                self.hovered = nil
                            }
                        }
                }
            }
            // The row of letters is also where the date lives: the column
            // under the pointer says which day it is, in the place its own
            // letter stood, and its neighbours step back. No line appears
            // and none is held empty.
            if self.buckets.contains(where: { !$0.tick.isEmpty }) {
                HStack(spacing: self.buckets.count > 8 ? 3 : 6) {
                    ForEach(self.buckets) { bucket in
                        let named = self.hovered?.id == bucket.id
                        Text(named ? bucket.hoverTick : bucket.tick)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.primary.opacity(named ? 0.9 : 0.55))
                            .opacity(self.hovered == nil || named ? 1 : 0.45)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.hovered)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// How agent time divides between the tools: a bar in their colours and a
/// line naming them. It reads the whole period until the pointer is on the
/// chart above, and then the one bucket under it. The tools keep their order
/// and their place either way, so only widths and durations move, and a
/// stretch where a tool did nothing leaves it at zero rather than dropping
/// it and shuffling the rest along.
private struct ToolSplitBar: View {
    // MARK: Internal

    let tools: [NativeAgentSummary.ToolUsage]
    /// Minutes per tool for the bucket under the pointer, or nil while the
    /// bar is about the whole period.
    let scope: [String: Double]?

    var body: some View {
        let split: [(tool: String, minutes: Double)] = self.tools.map { tool in
            if let scope = self.scope { return (tool.tool, scope[tool.tool] ?? 0) }
            return (tool.tool, tool.agent_minutes ?? 0)
        }
        let total = split.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                let gaps = CGFloat(max(split.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(split, id: \.tool) { entry in
                        Rectangle().fill(NativeAgentToolColor.color(entry.tool))
                            .frame(
                                width: total > 0
                                    ? max((geometry.size.width - gaps) * entry.minutes / total, 0)
                                    : 0
                            )
                    }
                }
            }
            .frame(height: 4)
            // The track keeps the bar's line where it is on a day nothing
            // ran, instead of leaving a gap the height of nothing.
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
            HStack(spacing: 12) {
                ForEach(split, id: \.tool) { entry in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(NativeAgentToolColor.color(entry.tool))
                            .frame(width: 8, height: 8)
                        HStack(spacing: 3) {
                            Text(NativeAgentToolLabel.name(entry.tool))
                            AnimatedDuration(
                                minutes: entry.minutes,
                                animation: .snappy(duration: 0.22, extraBounce: 0)
                            )
                        }
                    }
                    .opacity(entry.minutes > 0 ? 1 : 0.45)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.75))
        }
        .animation(
            self.reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0),
            value: split.map(\.minutes)
        )
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// One day as columns: forty-eight half hours across, each the agent
/// minutes that fell inside it stacked by tool, and the person's own
/// presence as a row of marks beneath. The scale is fixed, an hour of agent
/// time filling a column, so a quiet day looks quiet. The half hours still
/// to come stand empty, and the pointer reads any one of them into the
/// figures above and the split below, as it does on the longer periods.
struct ProfileDayColumns: View {
    // MARK: Internal

    let day: NativeAgentSummary.Day
    @Binding var hovered: AgentBucket?

    var body: some View {
        let runs = self.day.runs ?? []
        let now = self.now
        let slots = Self.slots(day: self.day, now: now)
        let peak = slots.filter { !$0.future && $0.bucket.agent > 0 }.max { $0.bucket.agent < $1.bucket.agent }
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let pitch = width / CGFloat(Self.count)
                ZStack(alignment: .topLeading) {
                    // The scale, drawn once: half an hour, and the whole
                    // hour that two tools running together would fill.
                    ForEach([0.5, 1.0], id: \.self) { share in
                        let y = Self.labelRoom + Self.chartHeight * (1 - share)
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).offset(y: y)
                        Text(share == 1 ? "60m" : "30m")
                            .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.4))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .offset(y: y + 2)
                    }
                    HStack(alignment: .bottom, spacing: Self.gap) {
                        ForEach(slots) { slot in self.column(slot) }
                    }
                    .frame(height: Self.chartHeight)
                    .offset(y: Self.labelRoom)
                    HStack(spacing: Self.gap) {
                        ForEach(slots) { slot in
                            let tint = slot.future ? 0.04 : 0.06 + 0.6 * slot.presence
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color.primary.opacity(tint))
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.presenceHeight)
                                .opacity(self.dimmed(slot) ? 0.4 : 1)
                        }
                    }
                    .offset(y: Self.labelRoom + Self.chartHeight + 4)
                    .accessibilityHidden(true)
                    // The busiest half hour says how much it held, until the
                    // pointer is reading the columns itself.
                    if let peak {
                        let height = Self.chartHeight * min(peak.bucket.agent / 60, 1)
                        Text("\(Int(peak.bucket.agent.rounded()))m")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .fixedSize()
                            .frame(width: pitch * 5)
                            .offset(
                                x: pitch * (CGFloat(peak.index) + 0.5) - pitch * 2.5,
                                y: Self.labelRoom - 12 + Self.chartHeight - height
                            )
                            .opacity(self.hovered == nil ? 1 : 0)
                    }
                    if let now {
                        let x = width * now / 24
                        Path { path in
                            path.move(to: CGPoint(x: x, y: Self.labelRoom - 2))
                            path
                                .addLine(to: CGPoint(
                                    x: x,
                                    y: Self.labelRoom + Self.chartHeight + 4 + Self.presenceHeight
                                ))
                        }
                        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        Text(Self.clock(now))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .fixedSize()
                            .frame(width: 40)
                            .offset(x: min(max(x - 20, -4), width - 36), y: -1)
                    }
                }
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.hovered)
                // The columns and the presence row are placed by offsets,
                // which move the picture and not the frame: the stack itself
                // is only as tall as the columns' layout. Its own frame makes
                // the target the whole chart, presence row included.
                .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    // One target over the whole chart: sweeping across it
                    // never falls into a gap between columns.
                    switch phase {
                    case let .active(point):
                        let index = min(max(Int(point.x / max(pitch, 1)), 0), Self.count - 1)
                        self.hovered = slots[safe: index]?.bucket
                    case .ended:
                        self.hovered = nil
                    }
                }
            }
            .frame(height: Self.labelRoom + Self.chartHeight + 4 + Self.presenceHeight)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { mark in
                    Text(mark).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                    if mark != "24" { Spacer(minLength: 0) }
                }
            }
            .accessibilityHidden(true)
            Text(self.readout(slots: slots, runs: runs))
                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.12), value: self.hovered?.id)
        }
    }

    // MARK: Private

    /// One half hour of the day, with what the column needs beyond the
    /// bucket the figures read.
    private struct Slot: Identifiable {
        let index: Int
        let bucket: AgentBucket
        /// Minutes by tool, the tool with most of the day first: the order
        /// they stack in, bottom up, the same in every column.
        let stack: [(tool: String, minutes: Double)]
        /// The most sessions any run of each tool had while inside it.
        let sessions: [(tool: String, peak: Int)]
        /// How much of the half hour the person was at the Mac, 0 to 1.
        let presence: Double
        /// Still to come today.
        let future: Bool

        var id: String { self.bucket.id }
    }

    private static let count = 48
    private static let gap: CGFloat = 2
    private static let chartHeight: CGFloat = 56
    private static let presenceHeight: CGFloat = 5
    /// Room above the columns for the clock and the peak's minutes.
    private static let labelRoom: CGFloat = 12

    /// The last few days laid out, by what they were laid out from. The body
    /// runs on every frame of a push and every move of the pointer, and
    /// cutting a day into half hours reads hundreds of timestamps: it is done
    /// once per day and per half hour of the clock, not once per frame.
    private static var slotCache: [String: [Slot]] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hours into the day right now, when the day is today.
    private var now: Double? {
        guard NativeAgentTime.isToday(self.day.date) else { return nil }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    private static func clock(_ hour: Double) -> String {
        String(format: "%02d:%02d", Int(hour), Int((hour - hour.rounded(.down)) * 60))
    }

    /// Start and end as hours into the day; a stretch that crosses midnight
    /// runs to the end of this one.
    private static func span(_ start: String, _ end: String) -> (Double, Double)? {
        guard let a = NativeAgentTime.hour(start), let b = NativeAgentTime.hour(end) else { return nil }
        return (a, b < a ? 24 : b)
    }

    private static func slots(day: NativeAgentSummary.Day, now: Double?) -> [Slot] {
        let runCount = day.runs?.count ?? 0, presenceCount = day.presence?.count ?? 0
        let key = [
            day.date, String(runCount), String(presenceCount),
            day.runs?.last?.end_time ?? "", day.presence?.last?.end_time ?? "",
            String(now.map { Int($0 * 2) } ?? -1),
        ].joined(separator: "|")
        if let cached = self.slotCache[key] { return cached }
        let slots = self.buildSlots(day: day, now: now)
        if self.slotCache.count >= 6 { self.slotCache.removeAll() }
        self.slotCache[key] = slots
        return slots
    }

    private static func buildSlots(day: NativeAgentSummary.Day, now: Double?) -> [Slot] {
        let runs = day.runs ?? []
        // Every timestamp is read once, here, not once per half hour.
        let runSpans = runs.map { self.span($0.start_time, $0.end_time) }
        let presenceSpans = (day.presence ?? []).compactMap { self.span($0.start_time, $0.end_time) }
        var totals: [String: Double] = [:]
        for run in runs { totals[run.tool, default: 0] += run.minutes }
        let order = totals.keys.sorted { a, b in
            let ta = totals[a] ?? 0, tb = totals[b] ?? 0
            return ta != tb ? ta > tb : a < b
        }
        return (0 ..< self.count).map { index in
            let t0 = Double(index) / 2, t1 = t0 + 0.5
            var minutes: [String: Double] = [:]
            var sessions: [String: Int] = [:]
            for (run, span) in zip(runs, runSpans) {
                guard let span else { continue }
                let overlap = min(span.1, t1) - max(span.0, t0)
                guard overlap > 0 else { continue }
                minutes[run.tool, default: 0] += overlap * 60
                sessions[run.tool] = max(sessions[run.tool] ?? 0, run.peak_sessions ?? 1)
            }
            var here = 0.0
            for span in presenceSpans {
                here += max(min(span.1, t1) - max(span.0, t0), 0)
            }
            // A tool cannot run more than the half hour; a run that overlaps
            // itself in the data is not worth a column past the scale.
            let stack = order.compactMap { tool in
                minutes[tool].map { (tool: tool, minutes: min($0, 30)) }
            }
            return Slot(
                index: index,
                bucket: AgentBucket(
                    id: "\(day.date) \(self.clock(t0))",
                    label: "\(self.clock(t0)) – \(self.clock(t1))",
                    tick: "",
                    hoverTick: "",
                    agent: stack.reduce(0) { $0 + $1.minutes },
                    human: here * 60,
                    tools: Dictionary(uniqueKeysWithValues: stack.map { ($0.tool, $0.minutes) }),
                    dayIndex: nil,
                    rankHuman: nil,
                    rankAgent: nil
                ),
                stack: stack,
                sessions: order.compactMap { tool in sessions[tool].map { (tool: tool, peak: $0) } },
                presence: min(here / 0.5, 1),
                future: now.map { t0 >= $0 } ?? false
            )
        }
    }

    private func dimmed(_ slot: Slot) -> Bool {
        self.hovered.map { $0.id != slot.bucket.id } ?? false
    }

    @ViewBuilder private func column(_ slot: Slot) -> some View {
        let room = Self.chartHeight
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if slot.future {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .frame(height: room)
            } else {
                // Drawn top down, so the stack's first tool lands at the
                // bottom, where the eye reads the base.
                ForEach(Array(slot.stack.reversed()), id: \.tool) { part in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(NativeAgentToolColor.color(part.tool))
                        .frame(height: min(max(room * part.minutes / 60, 2), room))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: room, alignment: .bottom)
        .clipped()
        .background(alignment: .bottom) {
            if !slot.future {
                Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1)
            }
        }
        .opacity(self.dimmed(slot) ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(slot.bucket.label): \(DurationLabel.minutes(slot.bucket.agent)) agents, \(DurationLabel.minutes(slot.bucket.human)) at the Mac"
        )
    }

    /// The day's count of runs and its peak, until the pointer names a half
    /// hour: then which tools ran in it, and how many sessions each had at
    /// once.
    private func readout(slots: [Slot], runs: [NativeAgentSummary.Run]) -> String {
        guard let hovered = self.hovered, let slot = slots.first(where: { $0.bucket.id == hovered.id }) else {
            let peak = runs.map { $0.peak_sessions ?? 1 }.max() ?? 0
            return runs.isEmpty ? "No agents this day." : "\(runs.count) runs · \(peak) sessions at the peak"
        }
        var parts = [slot.bucket.label]
        if slot.future {
            parts.append("still to come")
        } else if slot.sessions.isEmpty {
            parts.append("no agents")
        } else {
            // "×6" is the sessions the tool had going at once, kept this
            // short so two tools still fit on the caption's one line.
            parts += slot.sessions.map { entry in "\(NativeAgentToolLabel.name(entry.tool)) ×\(entry.peak)" }
        }
        return parts.joined(separator: " · ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { self.indices.contains(index) ? self[index] : nil }
}

struct NativeTrackedAppIcon: View {
    let url: String?
    /// Used to ask this Mac for the icon when the server has none: a mock
    /// person's apps, or a real one whose Mac has not uploaded the icon yet.
    var bundleIdentifier: String?
    var size: CGFloat = 28

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            // A 128 px icon lands in a 14 to 28 pt frame, so the picture the
            // eye sees is the downscale, not the file: it is worth asking for
            // the good one rather than taking whatever the default is.
            if let image = state.image {
                image.resizable().interpolation(.high).scaledToFit()
            } else if let local = LocalAppIcons.icon(for: self.bundleIdentifier) {
                Image(nsImage: local).resizable().interpolation(.high).scaledToFit()
            } else {
                // No icon from anywhere: hold the space and draw nothing. An
                // outlined placeholder reads as a control with a border round
                // it, and one hanging beside a name says only that something
                // failed to load.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A tab in the group strip that can be picked up and dragged along it.
/// A tab answers the pointer before anything happens: a faint fill under
/// the pointer, a slight press on mouse down, then release does the switch.
/// Three events, three motions, each shorter than the one before.
private struct NativeTabButtonStyle: ButtonStyle {
    // MARK: Internal

    let reduceMotion: Bool
    /// Handed to the fill under the label, so a control that is not a tab can
    /// take this press for its own shape.
    var shape: AnyShape = NativeTabHover.tabShape

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || self.gesturePressed
        return configuration.label
            // Passed back down so a label can answer the press too, like the
            // period picker's chevron turning while its menu is open.
            .environment(\.tabPressed, pressed)
            .modifier(NativeTabHover(pressed: pressed, shape: self.shape))
            .scaleEffect(pressed && !self.reduceMotion ? 0.96 : 1)
            .animation(.snappy(duration: 0.16, extraBounce: 0), value: pressed)
    }

    // MARK: Private

    /// Set by a group tab's reorder gesture, which sees the mouse first.
    @Environment(\.tabPressed) private var gesturePressed
}

/// The fill under a tab: faint under the pointer, firmer while pressed. An
/// unselected tab is only 13 pt of text, and a press with nothing but text
/// to shrink is invisible; the fill gives the press a surface, so pressing
/// any tab looks the same as pressing the selected one with its pill.
private struct NativeTabHover: ViewModifier {
    // MARK: Internal

    /// The group strip's own outline, and the default everywhere.
    static let tabShape = AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

    let pressed: Bool
    /// The outline the fill takes. A tab is a rounded rectangle; a profile
    /// link wears the same fill as a capsule, so both answer alike.
    var shape: AnyShape = Self.tabShape

    func body(content: Content) -> some View {
        content
            .background {
                self.shape
                    .fill(Color.primary.opacity(self.pressed ? 0.09 : self.hovering ? 0.05 : 0))
            }
            .contentShape(self.shape)
            .onHover { self.hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: self.hovering)
            .animation(.easeOut(duration: 0.08), value: self.pressed)
    }

    // MARK: Private

    @State private var hovering = false
}

/// Whether the pointer is down on a tab, as seen by a gesture outside the
/// button. A group tab's reorder gesture takes the mouse before the button
/// does, so the button never learns it is pressed; the gesture tells the
/// button style through the environment instead, and every tab presses alike.
private struct TabPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var tabPressed: Bool {
        get { self[TabPressedKey.self] }
        set { self[TabPressedKey.self] = newValue }
    }
}

/// The period picker's word. A Text that changes its string changes size at
/// once, and the chevron beside it jumped while the pill caught up. Here all
/// three words sit in one stack and cross-fade, and the width is a number,
/// the measured width of the current word, which animates like any other
/// frame: the pill grows or shrinks smoothly and the chevron rides along.
private struct PeriodLabel: View {
    // MARK: Internal

    let period: String

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Self.periods, id: \.value) { entry in
                Text(entry.label)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                    .opacity(entry.value == self.period ? 1 : 0)
                    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width in
                        self.widths[entry.value] = width
                    }
            }
        }
        .frame(width: self.widths[self.period], alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Private

    private static let periods = [("24h", "Day"), ("7d", "Week"), ("30d", "Month")]
        .map { (value: $0.0, label: $0.1) }

    /// Each word's natural width, measured once it is laid out. Until then
    /// the stack takes the widest word, so nothing is ever cut off.
    @State private var widths: [String: CGFloat] = [:]
}

/// The period picker's chevron. It turns over for as long as the menu is
/// open: the arrow points at the list that came out, and back down when it
/// is gone.
private struct PeriodChevron: View {
    // MARK: Internal

    let open: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(self.open && !self.reduceMotion ? .degrees(180) : .zero)
            .animation(.snappy(duration: 0.2, extraBounce: 0), value: self.open)
            .accessibilityHidden(true)
    }

    // MARK: Private

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// Holds the AppKit view under a SwiftUI control so a native menu can be
/// positioned against it.
private final class NativeViewBox {
    weak var view: NSView?
}

private struct NativeMenuAnchor: NSViewRepresentable {
    let box: NativeViewBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        self.box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        self.box.view = nsView
    }
}

/// What a native menu item calls when chosen. NSMenuItem needs an Objective-C
/// target; the closure is the SwiftUI side of it.
private final class NativeMenuTarget: NSObject {
    var onChoose: ((String) -> Void)?

    @objc func choose(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        self.onChoose?(value)
    }
}

/// One gesture for everything the mouse does to a group tab. Down: the tab
/// presses. Up without moving: the tab is chosen. Moving past a few points:
/// the press lets go and the tab lifts and follows the pointer instead.
private struct GroupTabDragModifier: ViewModifier {
    // MARK: Internal

    let isDragged: Bool
    let offset: CGFloat
    let reduceMotion: Bool
    let frameChanged: (CGRect) -> Void
    let tap: () -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.tabPressed, self.pressed)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("groupStrip"))
            } action: { frame in
                self.frameChanged(frame)
            }
            .scaleEffect(self.isDragged ? 1.04 : 1)
            .shadow(color: .black.opacity(self.isDragged ? 0.18 : 0), radius: 6, y: 2)
            .offset(x: self.offset)
            .zIndex(self.isDragged ? 1 : 0)
            .animation(self.reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0), value: self.isDragged)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("groupStrip"))
                    .onChanged { value in
                        let translation = value.translation.width
                        if !self.dragging, abs(translation) < Self.dragThreshold {
                            self.pressed = true
                            return
                        }
                        self.dragging = true
                        self.pressed = false
                        self.dragChanged(translation)
                    }
                    .onEnded { _ in
                        self.pressed = false
                        if self.dragging {
                            self.dragging = false
                            self.dragEnded()
                        } else {
                            self.tap()
                        }
                    }
            )
            .accessibilityHint("Drag to reorder")
    }

    // MARK: Private

    /// How far the pointer travels before a press turns into a drag.
    private static let dragThreshold: CGFloat = 6

    @State private var pressed = false
    @State private var dragging = false
}

// MARK: App discovery

extension NativeDashboardView {
    private var visibleAppBundle: String? {
        if case let .app(bundle) = self.store.screen { return bundle }
        return nil
    }

    private var showingAppRanking: Bool {
        if case .app = self.store.screen { return true }
        return self.store.screen == .list && self.store.tab == "global" && self.store.showsApps
    }

    // The scroll view and its bars stay mounted when the ranking type changes.
    // Only actual tab changes replace the outer container and slide its rows.
    @ViewBuilder private var directoryRows: some View {
        if self.showingAppRanking {
            appLeaderboardRows.transition(.identity)
        } else {
            peopleRows.transition(.identity)
        }
    }

    private var appScopeTitle: String {
        let scope = self.appDirectory.context(for: self.visibleAppBundle).scope
        if scope == "friends" { return "Friends" }
        if scope == "everyone" { return "Everyone" }
        return self.store.groups.first(where: { $0.id == scope })?.name ?? "Group"
    }

    private var appScopePicker: some View {
        Menu {
            Picker("Audience", selection: Binding(
                get: { self.appDirectory.context(for: self.visibleAppBundle).scope },
                set: { self.appDirectory.setScope($0, for: self.visibleAppBundle) }
            )) {
                Text("Friends").tag("friends")
                Text("Everyone").tag("everyone")
                if !self.store.groups.isEmpty {
                    Divider()
                    ForEach(self.store.groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(self.appScopeTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Whose app activity to show")
        .accessibilityLabel("Ranking audience")
        .accessibilityValue(self.appScopeTitle)
    }

    private func appMorphID(_ bundle: String, element: String = "icon", origin: String? = nil) -> String {
        let base = "app-\(element)-\(bundle)"
        if self.reduceMotion { return base + (origin ?? "header") }
        if let origin, self.appMorphSources[bundle] != origin { return base + origin }
        return base
    }

    private func openApp(_ app: NativeAppCard, from person: NativePerson? = nil) {
        var scope = self.appDirectory.context(for: nil).scope
        if let person {
            if person.public_apps_only == true { scope = "everyone" }
            else if case let .app(parent)? = self.store.previousScreen {
                scope = self.appDirectory.context(for: parent).scope
            } else {
                scope = self.store.tab == "global" ? "friends" : self.store.tab
            }
        }
        self.appMorphSources[app.id] = person?.id ?? "apps"
        self.appDirectory.remember(
            app, from: person, scope: scope,
            returning: self.store.hasScreenInHistory(.app(app.id))
        )
        self.store.open(.app(app.id))
    }

    private var appLeaderboardRows: some View {
        let key = self.appDirectory.key(nil, period: self.store.period)
        let page = self.appDirectory.topPages[key]
        return LazyVStack(alignment: .leading, spacing: 0) {
            if let page {
                if page.items.isEmpty {
                    NativeStateMessage(
                        title: "No shared activity yet",
                        message: "Try a longer period or another audience.",
                        minHeight: NativeLayout.peopleListHeight
                    )
                }
                ForEach(page.items) { app in
                    Button { self.openApp(app) } label: {
                        HStack(spacing: 10) {
                            self.placeColumn(app.rank)
                            NativeTrackedAppIcon(url: app.icon_url, bundleIdentifier: app.id, size: 32)
                                .matchedGeometryEffect(
                                    id: self.appMorphID(app.id, origin: "apps"),
                                    in: self.appMorph
                                )
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    .matchedGeometryEffect(
                                        id: self.appMorphID(app.id, element: "name", origin: "apps"),
                                        in: self.appMorph, properties: .position
                                    )
                                if let category = app.category {
                                    Text(category).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(app.user_count ?? 0)").font(.system(size: 16, weight: .medium))
                                    .monospacedDigit()
                                Text(app.user_count == 1 ? "person" : "people").font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 60).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if page.next_cursor != nil {
                    Button("More apps") {
                        Task { await self.appDirectory.load(nil, period: self.store.period, more: true) }
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(14)
                    .disabled(self.appDirectory.loading.contains(key))
                }
            } else if let message = self.appDirectory.errors[key] {
                NativeStateMessage(
                    title: "Couldn't load apps", detail: message, actionTitle: "Try again",
                    action: { Task { await self.appDirectory.load(nil, period: self.store.period, force: true) } },
                    minHeight: NativeLayout.peopleListHeight
                )
            } else {
                NativeAppRankingSkeleton()
            }
            if page != nil { appLoadError(nil, key: key) }
        }
        .task(id: key) { await self.appDirectory.load(nil, period: self.store.period) }
    }

    private var appEmptyState: some View {
        VStack(spacing: 5) {
            Text("No shared activity yet").font(.system(size: 13, weight: .medium))
            Text("Try a longer period or another audience.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    @ViewBuilder private func appLoadError(_ bundle: String?, key: String) -> some View {
        if let message = self.appDirectory.errors[key] {
            NativeInlineError(message: message) {
                Task { await self.appDirectory.load(bundle, period: self.store.period, force: true) }
            }
        }
    }

    @ViewBuilder private func appDetail(_ bundle: String) -> some View {
        let key = self.appDirectory.key(bundle, period: self.store.period)
        let page = self.appDirectory.peoplePages[key]
        if let app = page?.app ?? self.appDirectory.cards[bundle] {
            VStack(spacing: 8) {
                NativeTrackedAppIcon(url: app.icon_url, bundleIdentifier: bundle, size: 56)
                    .matchedGeometryEffect(id: self.appMorphID(bundle), in: self.appMorph)
                    .zIndex(1)
                self.appName(app.name, bundle: bundle)
                if let category = app.category {
                    Text(category).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let description = app.description {
                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                // The same pill a person's site gets, so the two are pressed
                // the same way and say the address the same way.
                if let link = ProfileLink(.website, app.website_url), link.url.scheme == "https" {
                    self.profileLinkPill(link)
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 30).padding(.bottom, 4)
            // Over the rows coming up to it while the name holds the row of
            // buttons, as on a profile.
            .zIndex(self.profileTitleProgress > 0 ? 2 : 0)

            if let source = page?.source {
                HStack(spacing: 8) {
                    FirstlightAvatar(url: source.avatar_url, name: source.displayName, size: 24)
                    Text(source.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    AnimatedDuration(minutes: source.active_minutes ?? 0).font(.system(size: 13, weight: .medium))
                }
                .padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }

            self.appScopePicker
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let page {
                if page.total == 0 { self.appEmptyState }
                else {
                    let visible = self.appDirectory.expanded.contains(key) ? page.items : Array(page.items.prefix(3))
                    VStack(spacing: 0) {
                        ForEach(visible) { person in
                            appPersonRow(person, bundle: bundle)
                        }
                    }.padding(.horizontal, -14)
                    if page.total > 3 {
                        Button(self.appDirectory.expanded.contains(key) ? "Show less" : "See all \(page.total)") {
                            withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.22)) {
                                if self.appDirectory.expanded.contains(key) { self.appDirectory.expanded.remove(key) }
                                else { self.appDirectory.expanded.insert(key) }
                            }
                        }.buttonStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    if self.appDirectory.expanded.contains(key), page.next_cursor != nil {
                        Button("More people") {
                            Task { await self.appDirectory.load(bundle, period: self.store.period, more: true) }
                        }
                        .disabled(self.appDirectory.loading.contains(key))
                        .buttonStyle(.plain).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    if let me = page.me, !visible.contains(where: { $0.id == me.id }) {
                        Divider()
                        self.appPersonRow(me, bundle: bundle).padding(.horizontal, -14)
                    }
                }
                if page.me == nil {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("You").font(.system(size: 12, weight: .medium))
                            Text(
                                self.appDirectory.context(for: bundle)
                                    .scope == "everyone" ? "Not in public ranking" : "No ranked activity this period"
                            )
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        AnimatedDuration(minutes: page.my_minutes).font(.system(size: 15, weight: .medium))
                    }.padding(.vertical, 6)
                }
            } else if self.appDirectory.errors[key] == nil {
                NativePeopleSkeleton(rows: 3, showsPlaces: true).padding(.horizontal, -14)
            }
            self.appLoadError(bundle, key: key)
            Button {
                self.store.showsApps = true
                self.store.selectTab("global")
                self.store.showList()
            } label: {
                HStack(spacing: 4) { Text("Top apps"); Image(systemName: "chevron.right") }
                    .font(.system(size: 12)).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Color.clear.frame(height: 1)
                .task(id: key) { await self.appDirectory.load(bundle, period: self.store.period) }
        }
    }

    /// The app's name, handed to the row of buttons the way a profile's name
    /// is. See `profileName`: the same text with the same order of modifiers,
    /// flying in from the app's row instead of a person's.
    private func appName(_ name: String, bundle: String) -> some View {
        let progress = self.profileTitleProgress
        return Text(name)
            .font(.system(size: 20, weight: .semibold))
            .lineLimit(1)
            .matchedGeometryEffect(
                id: self.appMorphID(bundle, element: "name"),
                in: self.appMorph, properties: .position
            )
            .scaleEffect(1 - CGFloat(progress) * (1 - Self.profileTitleRowScale))
            .background(alignment: .center) { profileNameBand }
            .offset(y: self.profileTitleStick)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: ProfileTitleCenter.self,
                    value: geometry.frame(in: .named(NativeLayout.popoverScrollSpace)).midY
                )
            })
            .zIndex(progress > 0 ? 2 : 0)
    }

    private func appPersonRow(_ person: NativePerson, bundle: String) -> some View {
        let source = "app-\(bundle)-\(person.id)"
        return Button { self.openPerson(person, from: source) } label: {
            self.personRow(person, place: person.rank, morphSource: source)
        }
        .buttonStyle(.plain)
    }
}

/// Each rendered picker owns its anchor. A departing screen must never replace
/// the arriving screen's weak menu anchor during a navigation transition.
private struct NativePeriodPicker: View {
    // MARK: Internal

    let period: String
    let metric: String
    let apps: Bool
    let canChooseBoard: Bool
    /// On a screen that ranks nothing the menu is the three periods alone.
    var periodOnly = false
    let appScope: String
    let appGroups: [(id: String, name: String)]
    let onPeriod: (String) -> Void
    let onMetric: (String) -> Void
    let onApps: (Bool) -> Void
    let onAppScope: (String) -> Void

    var body: some View {
        Button { presentMenu() } label: {
            HStack(spacing: 4) {
                PeriodLabel(period: self.period)
                PeriodChevron(open: self.open)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NativeTabButtonStyle(reduceMotion: self.reduceMotion))
        .background(NativeMenuAnchor(box: self.anchor))
        .help("Choose period and ranking")
        .accessibilityLabel("Activity period and ranking")
        .accessibilityValue("\(self.period), \(self.apps ? "apps" : self.metric)")
    }

    // MARK: Private

    @State private var anchor = NativeViewBox()
    @State private var target = NativeMenuTarget()
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func presentMenu() {
        guard let view = self.anchor.view, view.window != nil else { return }
        let menu = NSMenu()
        func add(_ title: String, _ value: String, selected: Bool, to parent: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: #selector(NativeMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = self.target
            item.representedObject = value
            item.state = selected ? .on : .off
            (parent ?? menu).addItem(item)
        }
        for (title, value) in [("Day", "24h"), ("Week", "7d"), ("Month", "30d")] {
            add(title, "period:" + value, selected: self.period == value)
        }
        if self.canChooseBoard {
            menu.addItem(.separator())
            add("People", "board:people", selected: !self.apps)
            add("Apps", "board:apps", selected: self.apps)
        }
        if !self.apps, !self.periodOnly {
            menu.addItem(.separator())
            add("Active time", "metric:active", selected: self.metric == "active")
            add("Agent time", "metric:agent", selected: self.metric == "agent")
        } else if self.canChooseBoard {
            menu.addItem(.separator())
            let audience = NSMenuItem(title: "Audience", action: nil, keyEquivalent: "")
            let scopes = NSMenu()
            add("Friends", "scope:friends", selected: self.appScope == "friends", to: scopes)
            add("Everyone", "scope:everyone", selected: self.appScope == "everyone", to: scopes)
            if !self.appGroups.isEmpty {
                scopes.addItem(.separator())
                for group in self.appGroups {
                    add(group.name, "scope:" + group.id, selected: self.appScope == group.id, to: scopes)
                }
            }
            audience.submenu = scopes
            menu.addItem(audience)
        }
        self.target.onChoose = { value in
            if value.hasPrefix("period:") { self.onPeriod(String(value.dropFirst(7))) }
            else if value.hasPrefix("metric:") { self.onMetric(String(value.dropFirst(7))) }
            else if value.hasPrefix("board:") { self.onApps(value == "board:apps") }
            else if value.hasPrefix("scope:") { self.onAppScope(String(value.dropFirst(6))) }
        }
        self.open = true
        defer { self.open = false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}
