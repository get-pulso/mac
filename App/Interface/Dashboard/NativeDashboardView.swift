import Defaults
import Dependencies
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

    static func list(reduceMotion: Bool) -> AnyTransition {
        self.screen(.behind, fade: self.navigationFade, reduceMotion)
    }

    static func detail(reduceMotion: Bool) -> AnyTransition {
        self.screen(.navigating, fade: self.navigationFade, reduceMotion)
    }

    static func tab(reduceMotion: Bool) -> AnyTransition {
        self.screen(.tab, fade: self.tabFade, reduceMotion)
    }

    // MARK: Private

    /// A little under the navigation spring, so the picture is settled just
    /// before the motion is and the arrival reads as a stop rather than a fade.
    /// The list leaving and the detail arriving are two halves of one push, so
    /// they have to share this number or the halves will not add up.
    private static let navigationFade: Double = 0.28
    /// Tabs swap one list for another with nothing travelling between them,
    /// so the swap can be quicker than a push.
    private static let tabFade: Double = 0.22

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
                    reservesMaximumHeight: self.profileFillsPanel
                ) {
                    content.disabled(store.busy)
                    // The tray shows its own errors; only with it closed
                    // does a failure belong to the profile underneath.
                    if let error = store.error, store.tray == nil {
                        NativeInlineError(message: error, retry: store.retry)
                    }
                }
                .overlay(alignment: .top) { profileActions }
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
        // A profile's own trays sit the same way, over the profile.
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
        .task(id: store.listKey) { await store.refresh() }
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
            if visible { refreshVisibleScreen() }
        }
        // The tray answers Escape first: Back where it has somewhere to go,
        // close otherwise. Only with no tray does Escape reach the screens.
        .onExitCommand {
            if store.tray != nil { store.trayBack() }
            else if store.screen == .list { windowManager.hide() }
            else { store.goBack() }
        }
        .onChange(of: session.pendingInvite) { _, _ in resumeInvite() }
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
    private static let avatarMorphID = "avatar"
    private static let nameMorphID = "name"
    /// The location sits on both screens too, right under the name, so it
    /// travels with it rather than vanishing and reappearing. The active
    /// total does not: it is a trailing note in the row and the headline of
    /// a tile in the profile, and far enough apart that the flight reads as
    /// a number wandering across the popover.
    private static let locationMorphID = "location"
    /// The "agent working" mark. It travels from the row into the Agents
    /// card, the way a pending spinner moves to where the result will live.
    private static let agentMorphID = "agent"
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
    @ObservedObject private var session = NativeSession.shared
    @Dependency(\.windowManager) private var windowManager
    /// The chart column the pointer is on, shared by the two numbers above it.
    @State private var agentsHovered: AgentBucket?
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
    @State private var periodMenuAnchor = NativeViewBox()
    @State private var periodMenuTarget = NativeMenuTarget()
    @State private var periodMenuOpen = false
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
        Button { self.presentPeriodMenu() } label: {
            HStack(spacing: 4) {
                PeriodLabel(period: self.store.period)
                if self.store.metric != "active" {
                    // A board by something other than active time says so on
                    // the pill, with the metric's glyph, and the label width
                    // animates the same way the period does.
                    NativeMetricMark(metric: self.store.metric)
                        .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
                }
                PeriodChevron(open: self.periodMenuOpen)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .animation(.snappy(duration: 0.22, extraBounce: 0), value: self.store.period)
            .animation(.snappy(duration: 0.22, extraBounce: 0), value: self.store.metric)
        }
        .buttonStyle(NativeTabButtonStyle(reduceMotion: self.reduceMotion))
        .background(NativeMenuAnchor(box: self.periodMenuAnchor))
        .help("Choose activity period and ranking")
        .accessibilityLabel("Activity period and ranking")
        .accessibilityValue("\(periodLabel), by \(self.metricLabel)")
    }

    private var periodLabel: String {
        switch self.store.period {
        case "7d": "Week"
        case "30d": "Month"
        default: "Day"
        }
    }

    private var metricLabel: String {
        switch self.store.metric {
        case "agent": "agent time"
        case "tokens": "tokens"
        default: "active time"
        }
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
                NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Nothing in the middle: the name that lands between the two
            // buttons is the profile's own, scrolled up to them. See
            // `profileName`.

            HStack {
                if case let .person(id) = store.screen {
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
        if #available(macOS 26.0, *) {
            peopleList
                .safeAreaBar(edge: .top, spacing: 0) { header }
                .safeAreaBar(edge: .bottom, spacing: 0) { peopleFooter }
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .frame(height: NativeLayout.popoverHeaderHeight + NativeLayout.peopleBodyHeight)
        } else {
            peopleList
                .safeAreaInset(edge: .top, spacing: 0) {
                    legacyPeopleBar(edge: .top) { header }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    legacyPeopleBar(edge: .bottom) { peopleFooter }
                }
                .frame(height: NativeLayout.popoverHeaderHeight + NativeLayout.peopleBodyHeight)
        }
    }

    private var peopleFooter: some View {
        HStack(spacing: 8) {
            dashboardSettingsButton
            Spacer()
            dashboardInviteButton
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
                    .frame(width: 18, height: 20)
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
                    .frame(width: 18, height: 20)
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
                    .foregroundStyle(Color.accentColor)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(self.reduceMotion ? nil : SocialStore.settle, value: waiting)

        // While the tray is open the button has become the tray: it shrinks
        // into the tray's corner and comes back when the tray does.
        let trayOpen = self.store.tray != nil
        Group {
            if #available(macOS 26.0, *) {
                Button { store.openTray(.home, from: .footerInvite) } label: { label }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .help(help)
            } else {
                Button { store.openTray(.home, from: .footerInvite) } label: { label }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .help(help)
            }
        }
        .opacity(trayOpen ? 0 : 1)
        .scaleEffect(trayOpen && !self.reduceMotion ? 0.6 : 1)
        .allowsHitTesting(!trayOpen)
        .animation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.1), value: trayOpen)
    }

    private var peopleList: some View {
        ScrollView {
            // A ZStack, so the list for the previous tab and the one for the
            // next overlap while one slides out and the other in, instead of
            // stacking one under the other for the length of the slide.
            ZStack(alignment: .top) {
                peopleRows
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
            if let me = store.peopleList.pinnedMe { pinnedMeRow(me) }
        }
    }

    private var peopleRows: some View {
        LazyVStack(spacing: 0) {
            switch listPhase {
            case .initial:
                NativePeopleSkeleton(rows: 5, showsPlaces: showsPlaces)
            case .failedEmpty:
                listFailureMessage
            case .empty:
                emptyListMessage
            case .content,
                 .refreshing,
                 .failedWithContent:
                ForEach(Array(store.people.enumerated()), id: \.element.id) { index, person in
                    let source = Self.morphKey(origin: "list", person: person)
                    Button {
                        openPerson(person, from: source)
                    } label: {
                        personRow(
                            person,
                            place: LeaderboardPlace.place(rank: person.rank, loadedIndex: index),
                            morphSource: source
                        )
                    }.buttonStyle(.plain)
                    if person.id != store.people.last?.id {
                        rowDivider
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
                minHeight: NativeLayout.peopleListHeight
            )
        default:
            NativeStateMessage(
                symbol: "person.3",
                title: "Nobody's active yet",
                actionTitle: "Invite someone",
                action: { self.store.openTray(.home, from: .emptyState) },
                minHeight: NativeLayout.peopleListHeight
            )
        }
    }

    /// Standings belong to the Leaderboard, where the order is the whole
    /// point. Friends and groups are the people you chose, not a race, so
    /// their rows stay as they were.
    private var showsPlaces: Bool { self.store.tab == "global" }

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
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
                    .accessibilityHidden(true)
            }
            if let tray = store.tray {
                self.inviteTray(tray)
                    .padding(8)
                    .transition(self.trayTransition)
            }
        }
        .allowsHitTesting(self.store.tray != nil)
    }

    /// The tray grows out of what was tapped and shrinks back into it. A deep
    /// link or the status-item menu opens popover and tray together, with
    /// nothing to grow from, so those only fade. Closing is quicker than
    /// opening, the way a pop is quicker than a push.
    private var trayTransition: AnyTransition {
        if self.reduceMotion {
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.24)),
                removal: .opacity.animation(.easeIn(duration: 0.2))
            )
        }
        let anchor: UnitPoint
        switch self.store.trayOrigin {
        case .footerInvite: anchor = UnitPoint(x: 0.91, y: 0.94)
        case .emptyState: anchor = UnitPoint(x: 0.5, y: 0.5)
        case .none:
            return .asymmetric(
                insertion: .opacity.animation(.easeOut(duration: 0.24)),
                removal: .opacity.animation(.easeIn(duration: 0.2))
            )
        }
        return .asymmetric(
            insertion: .scale(scale: 0.18, anchor: anchor)
                .combined(with: .opacity.animation(.easeOut(duration: 0.2).delay(0.04))),
            removal: .scale(scale: 0.18, anchor: anchor).combined(with: .opacity)
                .animation(.easeIn(duration: 0.3))
        )
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
                    self.inviteFieldFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.09),
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
            .foregroundStyle(landing ? Color.accentColor : .secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                landing ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
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

    /// Where a value sits between two points, as 0 to 1. `from` is the far
    /// end because the name's distance falls as the profile scrolls up.
    private static func progress(_ value: CGFloat, from: CGFloat, to: CGFloat) -> Double {
        guard from > to else { return value <= to ? 1 : 0 }
        return Double(min(max((from - value) / (from - to), 0), 1))
    }

    private static func joinedCheckMorphID(reduceMotion: Bool) -> String {
        reduceMotion ? "joined-check-still" : "joined-check"
    }

    private static func morphKey(origin: String, person: NativePerson) -> String { "\(origin)-\(person.id)" }

    /// Header, field and paddings: everything in a tray that is not the step.
    private static func trayFixedHeight(_ tray: SocialStore.Tray) -> CGFloat {
        44 + (tray.showsField ? 40 + 12 : 0) + 6 + 14
    }

    private static func firstName(of name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
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

    /// Shows the periods under the button and returns when one is chosen or
    /// the menu is dismissed. The chevron stays turned for exactly that long.
    private func presentPeriodMenu() {
        guard let anchor = self.periodMenuAnchor.view else { return }
        let menu = NSMenu()
        for (title, value) in [("Day", "24h"), ("Week", "7d"), ("Month", "30d")] {
            let item = NSMenuItem(title: title, action: #selector(NativeMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = self.periodMenuTarget
            item.representedObject = "period:" + value
            item.state = self.store.period == value ? .on : .off
            menu.addItem(item)
        }
        // The second half of the same menu: what the board ranks by. One
        // control for the two questions a board answers, when and by what.
        menu.addItem(.separator())
        for (title, value) in [("Active time", "active"), ("Agent time", "agent"), ("Tokens", "tokens")] {
            let item = NSMenuItem(title: title, action: #selector(NativeMenuTarget.choose(_:)), keyEquivalent: "")
            item.target = self.periodMenuTarget
            item.representedObject = "metric:" + value
            item.state = self.store.metric == value ? .on : .off
            menu.addItem(item)
        }
        self.periodMenuTarget.onChoose = { [store] value in
            if value.hasPrefix("metric:") { store.setMetric(String(value.dropFirst(7))) }
            else { store.setPeriod(String(value.dropFirst(7))) }
        }
        self.periodMenuOpen = true
        let below = anchor.isFlipped ? anchor.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: anchor)
        self.periodMenuOpen = false
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
                self.store.open(.person(friendID))
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
        .tint(.accentColor)
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
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .onChange(of: tray, initial: true) { previous, value in
            if value == .home { self.inviteFieldFocused = true }
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
        case .incoming where self.store.requests.incoming.isEmpty: return "incoming-empty"
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
    private func trayDismissButton(back: Bool) -> some View {
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

    private func trayTitle(_ tray: SocialStore.Tray) -> String {
        switch tray {
        case .home: "Add a friend"
        case .incoming: "Wants to be friends"
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
            if !self.store.requests.incoming.isEmpty {
                Divider()
                self.navigationRow(
                    self.store.requests.incoming.count == 1 ? "1 wants to be friends" :
                        "\(self.store.requests.incoming.count) want to be friends",
                    detail: "Accept or decline"
                ) { self.store.pushTray(.incoming) }
            }
        case .incoming:
            // Rows carry their own air now, so they stack close: one list, not
            // a column of separate blocks.
            VStack(spacing: 2) { self.incomingRequestRows }
            if self.store.requests.incoming.isEmpty { self.quiet("That's everyone.") }
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
    private func morphID(_ id: String, row: String? = nil) -> String {
        if self.reduceMotion { return "still-\(id)-\(row ?? "profile")" }
        if let row, self.morphSource != row { return "\(id)-\(row)" }
        return id
    }

    /// The caller's own place in a ranking they have not scrolled down to yet.
    private func pinnedMeRow(_ person: NativePerson) -> some View {
        let source = Self.morphKey(origin: "pinned", person: person)
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
        }
        .background(Color.primary.opacity(0.035))
    }

    /// Remember which row was tapped before the screen switches, so the
    /// profile avatar knows where to fly from and, on Back, where to return.
    private func openPerson(_ person: NativePerson, from source: String) {
        self.morphSource = source
        self.store.selectedPerson = person
        self.store.open(.person(person.id))
    }

    @ViewBuilder private func profileAction(
        _ title: String,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = ZStack {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary)
            }
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
        case .list: "Friends"
        case .person: "Profile"
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
        withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0)) {
            self.store.moveGroup(id, to: index)
        }
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
                }
            },
            dragEnded: {
                let target = self.groupDrag?.target ?? index
                withAnimation(self.reduceMotion ? nil : .snappy(duration: 0.25, extraBounce: 0)) {
                    self.groupDrag = nil
                    self.store.moveGroup(id, to: target)
                }
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

    private func personRow(_ person: NativePerson, place: Int?, morphSource: String) -> some View {
        let location = self.profileText(person.location)
        let bio = self.profileText(person.bio)
        return HStack(spacing: Self.rowPlaceSpacing) {
            if self.showsPlaces { self.placeColumn(place) }
            HStack(spacing: Self.rowAvatarSpacing) {
                // Only the tapped row shares the profile's id. A non-source view
                // with a shared id does not stay put: it takes the source's frame,
                // so every other avatar would pile onto the tapped one.
                FirstlightAvatar(
                    url: person.avatar_url,
                    name: person.displayName,
                    size: Self.rowAvatarSize,
                    showsOnlineIndicator: person.id == Defaults[.currentUserID] || person.isActiveNow,
                    morph: .init(id: self.morphID(Self.avatarMorphID, row: morphSource), namespace: self.morph)
                )
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(person.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                .matchedGeometryEffect(
                                    id: self.morphID(Self.nameMorphID, row: morphSource),
                                    in: self.morph,
                                    properties: .position
                                )
                            if person
                                .id ==
                                Defaults[.currentUserID]
                            {
                                Text("You").foregroundStyle(.tertiary).font(.system(size: 13))
                            }
                        }
                        if location != nil || bio != nil {
                            // The location is its own text so it can travel to
                            // the profile; the bio, which the profile shows
                            // elsewhere, is what gives way when the row is tight.
                            HStack(spacing: 3) {
                                if let location {
                                    NativeLocationIcon().foregroundStyle(.secondary)
                                    Text(location)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                        .matchedGeometryEffect(
                                            id: self.morphID(Self.locationMorphID, row: morphSource),
                                            in: self.morph,
                                            properties: .position
                                        )
                                }
                                if let bio {
                                    Text(location == nil ? bio : "· \(bio)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 2) {
                        Group {
                            // On a board by tokens the figure is a count; on
                            // the others a duration, of the person's own time
                            // or of their agents'.
                            if self.store.metric == "tokens" {
                                Text(TokenLabel.compact(person.score ?? 0))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            } else {
                                AnimatedDuration(
                                    minutes: self.store.metric == "agent" ? person.score ?? 0 : person
                                        .active_minutes ?? 0
                                )
                            }
                        }
                        .foregroundStyle(.secondary).font(.system(size: 12))
                        .fixedSize()
                        let activeApp = person.isActiveNow ? person.active_app : nil
                        let agent = person.isAgentWorkingNow ? person.agent : nil
                        if activeApp != nil || agent != nil {
                            // The list is looked at often, so an agent at work
                            // is only a small mark beside the running app: it
                            // grows out of the app icon's side and fades when
                            // the agent goes quiet. Numbers wait for the profile.
                            // The Claude app with Claude Code inside it is one
                            // thing, not two: then the icon stands for both and
                            // no second mark is drawn beside it. The icon itself
                            // is never dimmed in and out: a pulsing logo in a
                            // list pulls the eye off whatever is being read.
                            let sameFamily = agent != nil && activeApp
                                .flatMap { NativeAgentToolLabel.tool(forApp: $0.bundle_identifier, name: $0.name) } ==
                                agent?.tool
                            HStack(spacing: 5) {
                                if let agent, !sameFamily {
                                    NativeAgentIndicator(tool: agent.tool, size: 11)
                                        .matchedGeometryEffect(
                                            id: self.morphID(Self.agentMorphID, row: morphSource),
                                            in: self.morph,
                                            properties: .position
                                        )
                                        .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                                        .help("\(NativeAgentToolLabel.name(agent.tool)) is working")
                                }
                                if let activeApp {
                                    NativeTrackedAppIcon(
                                        url: activeApp.icon_url,
                                        bundleIdentifier: activeApp.bundle_identifier,
                                        size: 16
                                    )
                                    .matchedGeometryEffect(
                                        id: sameFamily ? self
                                            .morphID(Self.agentMorphID, row: morphSource) : "app-\(morphSource)",
                                        in: self.morph,
                                        properties: .position
                                    )
                                    .help(
                                        sameFamily ? "\(NativeAgentToolLabel.name(agent!.tool)) is working" :
                                            activeApp.name
                                    )
                                    Text(activeApp.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(activeApp.name)
                                }
                            }
                            .frame(maxWidth: 124, alignment: .trailing)
                            .animation(
                                self.reduceMotion ? nil : .snappy(duration: 0.3, extraBounce: 0),
                                value: agent?.tool
                            )
                        }
                    }
                }
                .frame(height: Self.rowAvatarSize)
            }
        }
        .padding(.horizontal, Self.rowHorizontalPadding).padding(.vertical, 10)
        .contentShape(Rectangle())
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

    // Location and bio are the only profile text the list carries. Social links
    // stay on the person's profile. An unfilled profile gets no second line at
    // all, and the single title stays on the avatar's centre either way.
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

    @ViewBuilder private func personDetail(_ id: String) -> some View {
        if let person = store.selectedPerson {
            VStack(spacing: 8) {
                // Flies in from the tapped row. Kept above the name and the rest
                // of the profile so the portrait never passes underneath text.
                FirstlightAvatar(
                    url: person.avatar_url,
                    name: person.displayName,
                    size: 76,
                    showsOnlineIndicator: id == Defaults[.currentUserID] || person.isActiveNow,
                    morph: .init(id: self.morphID(Self.avatarMorphID), namespace: self.morph)
                )
                .zIndex(1)

                // The name travels from the row too. Position only: the two
                // sizes cross-fade in place instead of one being stretched.
                // Scrolled up, this same text is the title in the row of
                // buttons.
                self.profileName(person)

                if let location = person.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Travels with the name, from the row's second line.
                    NativeLocationLabel(text: location)
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
            // pills in one row; the numbers below are about what they did.
            if [person.website, person.twitter, person.telegram].contains(where: { $0?.isEmpty == false }) {
                HStack(spacing: 6) {
                    profileLinkPill("Website", assetImage: "ProfileWebsite", raw: person.website)
                    profileLinkPill(
                        "X",
                        assetImage: "ProfileX",
                        raw: person.twitter.map { $0.hasPrefix("https://") ? $0 : "https://x.com/\($0)" }
                    )
                    profileLinkPill(
                        "Telegram",
                        assetImage: "ProfileTelegram",
                        raw: person.telegram.map { $0.hasPrefix("https://") ? $0 : "https://t.me/\($0)" }
                    )
                }
                .frame(maxWidth: .infinity)
            }

            // What is happening this minute, in one line of words: the app in
            // front, and the agent writing, with how long it has been at it.
            self.nowLine(person)

            // One surface for the whole picture: the two numbers, the chart
            // they both read, and the shifts. Nothing here is pressed; the
            // period control in the header is the only zoom.
            let ownTime = self.store.activity?.active_minutes ?? person.active_minutes
            let hasAgents = self.store.agentSummary?.has_data ?? false
            Group {
                if let summary = store.agentSummary, summary.has_data {
                    AgentsPanel(
                        summary: summary,
                        period: self.store.period,
                        live: summary.now,
                        ownTime: ownTime,
                        place: self.placeSummary(for: id),
                        hovered: self.$agentsHovered
                    )
                    // The card grows out of the lone time tile that stood
                    // here a moment ago, rather than replacing it: the time
                    // stays put and the rest of the surface opens under it.
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: AgentsReveal(progress: 1),
                            identity: AgentsReveal(progress: 0)
                        ).combined(with: .opacity),
                        removal: .opacity
                    ))
                } else {
                    // Nobody's agents, so the person's own time stands alone.
                    self.profileTile(title: "Active time", subtitle: self.placeSummary(for: id)) {
                        if let minutes = ownTime {
                            AnimatedDuration(minutes: minutes).fixedSize()
                        } else if store.screenLoading {
                            NativeSkeletonShape(width: 52, height: 20, radius: 5)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(self.reduceMotion ? nil : SocialStore.settle, value: hasAgents)

            if self.isLoadingProfileActivity {
                NativeTrackedAppsSkeleton()
            }
            if let topApps = store.activity?.top_apps, !topApps.isEmpty {
                self.sectionHeading("Apps").padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(topApps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        trackedAppRow(app)
                        if index < min(topApps.count, 5) - 1 { Divider().padding(.leading, 38).opacity(0.5) }
                    }
                }
            }
        }
    }

    /// The line under the name that says what is happening right now. It is
    /// words, like a status in Family, so a change reads as a change of
    /// state rather than of layout: "In Cursor" stays while "Codex 1h 12m"
    /// arrives beside it, and the glyph is the same one that was in the row.
    @ViewBuilder private func nowLine(_ person: NativePerson) -> some View {
        let appName = self.store.activity?.active_app?.name ?? (person.isActiveNow ? person.active_app?.name : nil)
        let appIcon = self.store.activity?.active_app?.icon_url ?? person.active_app?.icon_url
        let appBundle = self.store.activity?.active_app?.bundle_identifier ?? person.active_app?.bundle_identifier
        let now = self.store.agentSummary?.now
        let liveTool = now?.tool ?? (person.isAgentWorkingNow ? person.agent?.tool : nil)
        // The Claude app with Claude Code in it, ChatGPT with Codex: one
        // family, so the line names the agent once and lets the app go.
        let sameFamily = liveTool != nil && NativeAgentToolLabel.tool(forApp: appBundle, name: appName) == liveTool
        if appName != nil || liveTool != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(spacing: 6) {
                    if let appName, !sameFamily {
                        NativeTrackedAppIcon(url: appIcon, bundleIdentifier: appBundle, size: 14)
                        Text("In \(appName)").lineLimit(1)
                    }
                    if let liveTool {
                        if appName != nil, !sameFamily { Text("·").foregroundStyle(.tertiary) }
                        if sameFamily {
                            // The same icon the row showed, carried over. The
                            // words beside it already say the agent is at work.
                            NativeTrackedAppIcon(url: appIcon, bundleIdentifier: appBundle, size: 14)
                                .matchedGeometryEffect(
                                    id: self.morphID(Self.agentMorphID),
                                    in: self.morph,
                                    properties: .position
                                )
                        } else {
                            NativeAgentIndicator(tool: liveTool, size: 12)
                                .matchedGeometryEffect(
                                    id: self.morphID(Self.agentMorphID),
                                    in: self.morph,
                                    properties: .position
                                )
                        }
                        Text(NativeAgentToolLabel.name(liveTool)).lineLimit(1)
                        if let now, let started = NativeAgentTime.date(now.started_at) {
                            let elapsed = max(now.minutes, context.date.timeIntervalSince(started) / 60)
                            AnimatedDuration(minutes: elapsed).fixedSize()
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
            }
        }
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

    @ViewBuilder private func profileLinkPill(_ label: String, assetImage: String, raw: String?) -> some View {
        if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
            Link(destination: url) {
                HStack(spacing: 5) {
                    Image(assetImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text(label).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel("Open \(label)")
        }
    }

    @ViewBuilder private func profileLink(_ label: String, assetImage: String, raw: String?) -> some View {
        if let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") {
            Link(destination: url) {
                VStack(spacing: 7) {
                    Image(assetImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.primary)
                    Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 70)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .help(label)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Open \(label)")
        }
    }

    private func trackedAppRow(_ app: NativeAppActivity, showsActiveState: Bool = false) -> some View {
        HStack(spacing: 10) {
            NativeTrackedAppIcon(url: app.icon_url, bundleIdentifier: app.bundle_identifier, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
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
            if [card.website, card.twitter, card.telegram].contains(where: { $0?.isEmpty == false }) {
                HStack(spacing: 6) {
                    self.profileLinkPill("Website", assetImage: "ProfileWebsite", raw: card.website)
                    self.profileLinkPill(
                        "X",
                        assetImage: "ProfileX",
                        raw: card.twitter.map { $0.hasPrefix("https://") ? $0 : "https://x.com/\($0)" }
                    )
                    self.profileLinkPill(
                        "Telegram",
                        assetImage: "ProfileTelegram",
                        raw: card.telegram.map { $0.hasPrefix("https://") ? $0 : "https://t.me/\($0)" }
                    )
                }
                .frame(maxWidth: .infinity)
            }
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
                }.buttonStyle(.borderedProminent)
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
        // The popover and the tray arrive together: nothing to grow from.
        self.store.openTray(.home, from: .none)
        self.store.query = value
        self.store.queryChanged()
        // A friend's link opened in the app is their consent and the person's
        // own choice to follow it, so the two are friends without another
        // button: the first thing after sign-in is the friend in the list.
        // A link found in the clipboard was not followed by anyone, and a
        // group is a bigger step, so both still ask.
        if self.session.pendingInviteSource == .link, self.store.queryIsLink,
           case .friendCode? = self.store.inviteCandidate
        {
            self.store.addFromQuery()
        }
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
            ZStack {
                if self.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: self.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .transition(.opacity)
                }
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
                    .tint(.accentColor)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            }
        } else {
            if self.prominent {
                content.buttonStyle(.borderedProminent).buttonBorderShape(.circle).controlSize(.regular)
                    .tint(.accentColor)
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
            content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .animation(.easeOut(duration: 0.12), value: self.state.message)
    }
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

    let url: String?
    let name: String
    var size: CGFloat = 44
    var showsOnlineIndicator = false
    var morph: Morph?

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            // The circle decides how big the portrait is, not the photo's own
            // proportions. scaledToFill alone hands back a frame in the photo's
            // aspect ratio, wider or taller than the one offered, and the mask
            // is drawn in that frame: a portrait photo then turns into an
            // oversized ellipse hanging out of the row. Color.clear takes the
            // offered size, the photo fills it, and the overflow is cut.
            if let image = state.image {
                Color.clear.overlay { image.resizable().scaledToFill() }.clipped()
            } else {
                ZStack {
                    Color.primary.opacity(0.08); Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.35, weight: .medium))
                }
            }
        }
        .mask {
            FirstlightAvatarMask(
                cutsOutOnlineIndicator: showsOnlineIndicator,
                indicatorSize: onlineIndicatorSize,
                indicatorInset: onlineIndicatorInset,
                indicatorGap: onlineIndicatorGap
            )
            .fill()
        }
        .overlay(alignment: .bottomTrailing) {
            if showsOnlineIndicator {
                Circle().fill(Color.green)
                    .frame(width: onlineIndicatorSize, height: onlineIndicatorSize)
                    .offset(x: -onlineIndicatorInset, y: -onlineIndicatorInset)
            }
        }
        // Always applied so the view keeps one identity; without a morph the
        // avatar is alone in its own namespace and matches nothing.
        .matchedGeometryEffect(id: morph?.id ?? "avatar", in: morph?.namespace ?? unmatched)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Private

    @Namespace private var unmatched

    /// The indicator is a badge, not a part of the portrait: it needs a floor to stay
    /// readable on small avatars and a ceiling so it does not turn into an object of its
    /// own on large ones. Whole points keep the edge crisp on Retina.
    private var onlineIndicatorSize: CGFloat {
        min(16, max(8, (8 + (self.size - 24) * 6 / 52).rounded()))
    }

    private var onlineIndicatorGap: CGFloat { self.size <= 32 ? 1.5 : 2 }

    /// Holds the indicator centre on the diagonal at 0.315 x size from the avatar centre,
    /// whatever the diameter, so the badge stays put when its size changes.
    private var onlineIndicatorInset: CGFloat {
        max(0, self.size * 0.1854 - self.onlineIndicatorSize / 2)
    }
}

private struct FirstlightAvatarMask: Shape {
    let cutsOutOnlineIndicator: Bool
    let indicatorSize: CGFloat
    let indicatorInset: CGFloat
    let indicatorGap: CGFloat

    func path(in rect: CGRect) -> Path {
        let avatar = Path(ellipseIn: rect)
        guard self.cutsOutOnlineIndicator else { return avatar }

        let cutoutRadius = self.indicatorSize / 2 + self.indicatorGap
        let indicatorCenter = CGPoint(
            x: rect.maxX - self.indicatorInset - self.indicatorSize / 2,
            y: rect.maxY - self.indicatorInset - self.indicatorSize / 2
        )
        // Subtract instead of an even-odd fill. The cutout reaches past the edge of
        // the avatar, and even-odd turns that overhang into an opaque region: the
        // corner of the photo would show up outside the circle, next to the badge.
        return avatar.subtracting(Path(ellipseIn: CGRect(
            x: indicatorCenter.x - cutoutRadius,
            y: indicatorCenter.y - cutoutRadius,
            width: cutoutRadius * 2,
            height: cutoutRadius * 2
        )))
    }
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

/// "An agent is writing right now": the tool's own mark, breathing. Nothing
/// beside it; the mark is the signal. Still under Reduce Motion.
private struct NativeAgentIndicator: View {
    // MARK: Internal

    let tool: String
    var size: CGFloat = 12

    var body: some View {
        NativeAgentGlyph(tool: self.tool, size: self.size)
            .foregroundStyle(.secondary)
            .opacity(self.reduceMotion ? 1 : (self.breathingIn ? 1 : 0.35))
            .animation(
                self.reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: self.breathingIn
            )
            .onAppear { self.breathingIn = true }
            .accessibilityLabel("\(NativeAgentToolLabel.name(self.tool)) is working")
    }

    // MARK: Private

    @State private var breathingIn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// The small mark on the period pill when the board ranks by agent time or
/// tokens: a glyph with a one-word label, so the pill still reads at a glance.
private struct NativeMetricMark: View {
    let metric: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: self.metric == "tokens" ? "number" : "sparkle")
                .font(.system(size: 9, weight: .semibold))
            Text(self.metric == "tokens" ? "Tokens" : "Agents")
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
        }
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// Token counts as people say them: 842, 12.4K, 1.2M, 3.1B. Short so the
/// width barely moves, and monospaced digits so what moves lines up.
private enum TokenLabel {
    static func compact(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            return scaled < 10 ? String(format: "%.1f%@", scaled, suffix) : String(format: "%.0f%@", scaled, suffix)
        }
        return String(format: "%.0f", value)
    }

    static func dollars(microUSD: Double) -> String {
        let dollars = microUSD / 1_000_000
        return dollars < 10 ? String(format: "$%.2f", dollars) : String(format: "$%.0f", dollars)
    }
}

/// A profile tile answers a press the way a tab does: it gives a little.
private struct ProfileTileStyle: ButtonStyle {
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
private enum NativeAgentToolColor {
    static func color(_ tool: String) -> Color {
        switch tool {
        case "claude_code": Color(red: 0.92, green: 0.41, blue: 0.20)
        case "codex": Color(red: 0.16, green: 0.47, blue: 0.84)
        case "cursor": Color(red: 0.11, green: 0.69, blue: 0.48)
        default: Color.primary.opacity(0.6)
        }
    }
}

/// How the agents' surface arrives once the summary answers: it opens
/// downward from the top edge, so the numbers that were already on screen
/// stay where they are and the rest of the card unfolds beneath them.
private struct AgentsReveal: ViewModifier, Animatable {
    var progress: Double

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: 1 - 0.06 * self.progress, anchor: .top)
            .offset(y: -6 * self.progress)
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
    let agent: Double
    let human: Double
    /// The day this bucket is, when it is exactly one day.
    let dayIndex: Int?
}

/// Everything the profile says about a person's agents, in one place: the
/// chart at the period's own scale, the tools, what was written, and the
/// shifts long enough to have a name. No drill-down, because the period
/// control at the top of the popover is already the zoom.
private struct AgentsPanel: View {
    // MARK: Internal

    let summary: NativeAgentSummary
    let period: String
    let live: NativeAgentSummary.Now?
    /// The person's own minutes over the same period, so both figures sit
    /// together and answer the same pointer.
    let ownTime: Double?
    /// Their place in the ranking, when the board has one.
    let place: String?
    @Binding var hovered: AgentBucket?

    var body: some View {
        let days = self.summary.days ?? []
        let buckets = Self.buckets(days: days, period: self.period)
        VStack(alignment: .leading, spacing: 12) {
            // The two figures, side by side. The pointer on the chart below
            // moves both to that day and takes their captions away, because
            // a caption about the whole period would then be a lie.
            HStack(alignment: .top, spacing: 12) {
                self.figure(
                    "Active time",
                    minutes: self.hovered?.human ?? self.ownTime,
                    note: self.hovered == nil ? self.place : nil
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                self.figure(
                    "Agents",
                    minutes: self.hovered?.agent ?? self.summary.agent_minutes,
                    note: nil
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The day under the pointer names itself here; at rest the line
            // carries the one fact a week of columns cannot show. It never
            // names the period: the control in the header already does.
            HStack {
                Text(self.hovered?.label ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 8)
                if let peak = self.summary.max_concurrency, peak > 1 {
                    Text("up to \(peak) at once")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .opacity(self.hovered == nil ? 1 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: self.hovered)
            .padding(.bottom, -6)

            // A single day is drawn as the day itself: runs across twenty-four
            // hours, with the person's presence under them. Longer periods
            // are columns, one per day or per week.
            if self.period == "24h", let today = days.last, today.runs?.isEmpty == false {
                ProfileDayStrip(day: today, live: self.live)
            } else {
                AgentBucketBars(buckets: buckets, hovered: self.$hovered)
            }

            if let tools = self.summary.by_tool, !tools.isEmpty {
                let total = tools.reduce(0) { $0 + ($1.agent_minutes ?? 0) }
                if total > 0 {
                    GeometryReader { geometry in
                        let gaps = CGFloat(max(tools.count - 1, 0)) * 2
                        HStack(spacing: 2) {
                            ForEach(tools) { tool in
                                Rectangle().fill(NativeAgentToolColor.color(tool.tool))
                                    .frame(width: max(
                                        (geometry.size.width - gaps) * (tool.agent_minutes ?? 0) / total,
                                        0
                                    ))
                            }
                        }
                    }
                    .frame(height: 4)
                    .clipShape(Capsule())
                    HStack(spacing: 12) {
                        ForEach(tools) { tool in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(NativeAgentToolColor.color(tool.tool))
                                    .frame(width: 8, height: 8)
                                Text(
                                    "\(NativeAgentToolLabel.name(tool.tool)) \(DurationLabel.minutes(tool.agent_minutes ?? 0))"
                                )
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            // The shifts worth naming, longest first, with the month's record
            // marked once. A run is where the person's day actually went.
            let shifts = Self.shifts(days: days, period: self.period)
            if !shifts.isEmpty {
                Divider().opacity(0.5).padding(.top, 2)
                ForEach(shifts) { shift in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(NativeAgentToolColor.color(shift.run.tool))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(
                                    "\(NativeAgentTime.clock(shift.run.start_time)) – \(NativeAgentTime.clock(shift.run.end_time))"
                                )
                                .font(.system(size: 12, weight: .medium))
                                if self.isRecord(shift.run) {
                                    Text("Longest this month")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .lineLimit(1)
                            Text(self.shiftDetail(shift))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The duration keeps its own column, so a short time
                        // on the left never drags it out of line.
                        Text(DurationLabel.minutes(shift.run.minutes))
                            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Private

    /// One run with the day it belongs to, so the list can name the day when
    /// the period spans more than one.
    private struct Shift: Identifiable {
        let run: NativeAgentSummary.Run
        let day: String

        var id: String { self.run.id }
    }

    /// Hours for a day, days for a week, whole weeks for a month.
    private static func buckets(days: [NativeAgentSummary.Day], period: String) -> [AgentBucket] {
        guard period == "30d", days.count > 7 else {
            return days.enumerated().map { index, day in
                AgentBucket(
                    id: day.date,
                    label: NativeAgentTime.dayLabel(day.date),
                    tick: NativeAgentTime.weekdayLetter(day.date),
                    agent: day.agent_minutes,
                    human: day.human_minutes,
                    dayIndex: index
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
                tick: "",
                agent: group.reduce(0) { $0 + $1.agent_minutes },
                human: group.reduce(0) { $0 + $1.human_minutes },
                dayIndex: group.count == 1 ? days.firstIndex { $0.date == first.date } : nil
            )
        }
    }

    /// The runs a period should list: a day shows its own, a longer period
    /// shows the longest of the whole window.
    private static func shifts(days: [NativeAgentSummary.Day], period: String) -> [Shift] {
        let source: [NativeAgentSummary.Day] = period == "24h" ? Array(days.suffix(1)) : days
        let all = source.flatMap { day in (day.runs ?? []).map { Shift(run: $0, day: day.date) } }
            .filter { $0.run.minutes >= 15 }
        return Array(all.sorted { $0.run.minutes > $1.run.minutes }.prefix(period == "24h" ? 5 : 3))
    }

    private func isRecord(_ run: NativeAgentSummary.Run) -> Bool {
        guard let longest = self.summary.longest_run_minutes else { return false }
        return abs(longest - run.minutes) < 0.5
    }

    private func shiftDetail(_ shift: Shift) -> String {
        var parts = [NativeAgentToolLabel.name(shift.run.tool)]
        if self.period != "24h" { parts.append(NativeAgentTime.dayLabel(shift.day)) }
        if let unattended = shift.run.unattended_minutes, unattended >= shift.run.minutes / 2 {
            parts.append("unattended")
        } else {
            parts.append("peak \(shift.run.peak_sessions ?? 1)")
        }
        return parts.joined(separator: " · ")
    }

    /// One figure: its name, the number, and a note that only holds while
    /// the number means the whole period.
    @ViewBuilder private func figure(
        _ title: String,
        glyph: String? = nil,
        minutes: Double?,
        note: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let glyph { NativeAgentGlyph(tool: glyph, size: 11).foregroundStyle(.secondary) }
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let minutes {
                AnimatedDuration(minutes: minutes, animation: .snappy(duration: 0.22, extraBounce: 0))
                    .font(.system(size: 20, weight: .medium))
                    .fixedSize()
            } else {
                Text("—").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
            }
            // The line keeps its room either way, so nothing shifts under
            // the pointer.
            Text(note ?? " ")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: note)
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
                ForEach(Array(self.buckets.enumerated()), id: \.element.id) { index, bucket in
                    let dimmed = self.hovered.map { $0.id != bucket.id } ?? false
                    let human = bucket.human > 0 ? min(max(room * bucket.human / scale, 2), room) : 0
                    let agent = bucket.agent > 0 ? min(max(room * bucket.agent / scale, 2), room - human) : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: max(agent, 0))
                        if agent > 0, human > 0 { Color.clear.frame(height: 2) }
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.18))
                            .frame(height: max(human, 0))
                    }
                    .frame(maxWidth: 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: self.height, alignment: .bottom)
                    .clipped()
                    .background(alignment: .bottom) {
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    }
                    .opacity(dimmed ? 0.4 : 1)
                    // Each column grows from the floor, a beat after the one
                    // before it, so the week arrives as a sweep rather than
                    // all at once.
                    .scaleEffect(y: self.revealed ? 1 : 0.02, anchor: .bottom)
                    .animation(
                        self.reduceMotion ? nil
                            : .spring(duration: 0.5, bounce: 0.16).delay(Double(index) * 0.025),
                        value: self.revealed
                    )
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
            if self.buckets.contains(where: { !$0.tick.isEmpty }) {
                HStack(spacing: self.buckets.count > 8 ? 3 : 6) {
                    ForEach(self.buckets) { bucket in
                        Text(bucket.tick)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .onAppear { self.revealed = true }
    }

    // MARK: Private

    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// One day as a strip: twenty-four hours across, runs as bars in their
/// tool's colour, thicker the more sessions ran at once, and the person's
/// own presence as a light band beneath. The pointer reads any moment.
private struct ProfileDayStrip: View {
    // MARK: Internal

    let day: NativeAgentSummary.Day
    let live: NativeAgentSummary.Now?

    var body: some View {
        let runs = self.day.runs ?? []
        let presence = self.day.presence ?? []
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .bottomLeading) {
                    // Presence band, with the day's floor under it.
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 8)
                    ForEach(Array(presence.enumerated()), id: \.offset) { _, stretch in
                        if let a = NativeAgentTime.hour(stretch.start_time),
                           let b = NativeAgentTime.hour(stretch.end_time)
                        {
                            let end = b < a ? 24 : b
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.primary.opacity(0.22))
                                .frame(width: max(width * (end - a) / 24, 2), height: 8)
                                .offset(x: width * a / 24)
                        }
                    }
                    // Runs, standing on the band.
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if let a = NativeAgentTime.hour(run.start_time), let b = NativeAgentTime.hour(run.end_time) {
                            let end = b < a ? 24 : b
                            let thickness = 4 + CGFloat(min(run.peak_sessions ?? 1, 20)) / 20 * 20
                            let isLive = self.live != nil && index == runs.count - 1
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(NativeAgentToolColor.color(run.tool))
                                .frame(width: max(width * (end - a) / 24, 3), height: thickness)
                                .overlay(alignment: .trailing) {
                                    if isLive {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(NativeAgentToolColor.color(run.tool))
                                            .frame(width: 6)
                                            .opacity(self.reduceMotion ? 1 : (self.breathing ? 1 : 0.3))
                                            .animation(
                                                self.reduceMotion ? nil : .easeInOut(duration: 1.1)
                                                    .repeatForever(autoreverses: true),
                                                value: self.breathing
                                            )
                                            .offset(x: 3)
                                    }
                                }
                                .offset(x: width * a / 24, y: -10)
                                .opacity(self.hover.map { h in h.runIndex == index ? 1 : 0.55 } ?? 1)
                        }
                    }
                    if let hover = self.hover {
                        Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1)
                            .offset(x: width * hover.hour / 24)
                    }
                }
                .frame(width: width, height: geometry.size.height, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        let hour = min(max(point.x / max(width, 1) * 24, 0), 24)
                        let runIndex = runs.firstIndex { run in
                            guard let a = NativeAgentTime.hour(run.start_time),
                                  let b = NativeAgentTime.hour(run.end_time) else { return false }
                            return hour >= a && hour <= (b < a ? 24 : b)
                        }
                        let here = presence.contains { stretch in
                            guard let a = NativeAgentTime.hour(stretch.start_time),
                                  let b = NativeAgentTime.hour(stretch.end_time) else { return false }
                            return hour >= a && hour <= (b < a ? 24 : b)
                        }
                        self.hover = Hover(hour: hour, runIndex: runIndex, here: here)
                    case .ended:
                        self.hover = nil
                    }
                }
            }
            .frame(height: 44)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { mark in
                    Text(mark).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                    if mark != "24" { Spacer(minLength: 0) }
                }
            }
            .accessibilityHidden(true)
            Text(self.readout(runs: runs))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.12), value: self.hover?.runIndex)
        }
        .onAppear { self.breathing = true }
    }

    // MARK: Private

    private struct Hover: Equatable {
        let hour: Double
        let runIndex: Int?
        let here: Bool
    }

    @State private var hover: Hover?
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func readout(runs: [NativeAgentSummary.Run]) -> String {
        guard let hover = self.hover else {
            let peak = runs.map { $0.peak_sessions ?? 1 }.max() ?? 0
            return runs.isEmpty ? "No agents this day." : "\(runs.count) runs · up to \(peak) at once"
        }
        let clock = String(
            format: "%02d:%02d",
            Int(hover.hour),
            Int(hover.hour.truncatingRemainder(dividingBy: 1) * 60)
        )
        var parts = [clock]
        if let index = hover.runIndex, let run = runs[safe: index] {
            parts.append("\(NativeAgentToolLabel.name(run.tool)) · \(run.peak_sessions ?? 1) sessions")
        } else {
            parts.append("no agent")
        }
        parts.append(hover.here ? "at the Mac" : "away")
        return parts.joined(separator: " · ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { self.indices.contains(index) ? self[index] : nil }
}

private struct NativeTrackedAppIcon: View {
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

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || self.gesturePressed
        return configuration.label
            // Passed back down so a label can answer the press too, like the
            // period picker's chevron turning while its menu is open.
            .environment(\.tabPressed, pressed)
            .modifier(NativeTabHover(pressed: pressed))
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

    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(self.pressed ? 0.09 : self.hovering ? 0.05 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
