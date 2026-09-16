import Defaults
import Dependencies
import NukeUI
import SwiftUI

/// Distance from the top of the scrolling viewport to the bottom of a detail
/// screen's own title. Negative once the title has scrolled past the header.
private struct ProfileTitleBottom: PreferenceKey {
    static var defaultValue: CGFloat { .greatestFiniteMagnitude }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = min(value, nextValue()) }
}

/// How one screen gives way to the next, modelled on an iOS push with a hero
/// element. The tapped avatar, name, location and total travel on the
/// navigation spring (set where the screen changes). The screens themselves
/// drift a few points the same way on that spring, so a push reads as going
/// deeper and Back as returning; the one on top moves more than the one
/// underneath, like a room seen past a door. Opacity cross-fades on shorter
/// curves: the outgoing screen dims at once, the incoming one settles in a
/// beat later, so the two never sit at half strength on top of each other.
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
        .asymmetric(
            insertion: self.drift(.appearing, .behind, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.28).delay(0.05))),
            removal: self.drift(.disappearing, .behind, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.2)))
        )
    }

    static func detail(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: self.drift(.appearing, .navigating, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.3).delay(0.06))),
            removal: self.drift(.disappearing, .navigating, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.18)))
        )
    }

    static func tab(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: self.drift(.appearing, .tab, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.24).delay(0.04))),
            removal: self.drift(.disappearing, .tab, reduceMotion)
                .combined(with: .opacity.animation(.easeOut(duration: 0.16)))
        )
    }

    // MARK: Private

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
        let motion = self.motion
        content
            .offset(x: motion.x * self.progress)
            .scaleEffect(1 - motion.shrink * self.progress, anchor: .bottomTrailing)
    }

    // MARK: Private

    @MainActor private var motion: (x: CGFloat, shrink: CGFloat) {
        if self.reduceMotion { return (0, 0) }
        let store = SocialStore.shared
        switch self.role {
        case .behind:
            return (-ScreenMotion.behindDrift, 0)
        case .tab:
            let sign: CGFloat = self.phase == .appearing ? 1 : -1
            return (sign * store.tabDirection * ScreenMotion.tabDrift, 0)
        case .navigating:
            let navigation = store.navigation
            let onTop = (self.phase == .appearing) == (navigation.direction == .forward)
            return onTop ? (ScreenMotion.topDrift, 0) : (-ScreenMotion.behindDrift, 0)
        }
    }
}

struct NativeDashboardView: View {
    // MARK: Internal

    var body: some View {
        // Both screens live in the tree while one replaces the other, so they
        // overlap instead of stacking; the popover keeps the taller height,
        // which is the list height either way until the profile has loaded.
        ZStack(alignment: .top) {
            if store.screen == .list {
                people
                    .geometryGroup()
                    .transition(ScreenMotion.list(reduceMotion: self.reduceMotion))
            } else {
                VStack(spacing: 0) {
                    profileHeader
                    PopoverContent(reservesMaximumHeight: self.isLoadingProfileActivity) {
                        content.disabled(store.busy)
                        // The tray shows its own errors; only with it closed
                        // does a failure belong to the profile underneath.
                        if let error = store.error, store.tray == nil {
                            NativeInlineError(message: error, retry: store.retry)
                        }
                    }
                }
                .onPreferenceChange(ProfileTitleBottom.self) { bottom in profileTitleBottom = bottom }
                .onChange(of: store.screen) { _, _ in profileTitleBottom = .greatestFiniteMagnitude }
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
    }

    // MARK: Private

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
    /// The location and the active total also sit on both screens. What is
    /// already on screen and stays should travel, not vanish and reappear.
    private static let locationMorphID = "location"
    private static let timeMorphID = "time"
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

    @ObservedObject private var store = SocialStore.shared
    @ObservedObject private var session = NativeSession.shared
    @Dependency(\.windowManager) private var windowManager
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
    @State private var profileTitleBottom = CGFloat.greatestFiniteMagnitude
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
    /// The whole height of the tray that just left, for the 24 pt rule.
    @State private var trayPreviousTotal: CGFloat?
    /// Natural heights as the steps reported them, one per tray.
    @State private var trayStepNatural: [SocialStore.Tray: CGFloat] = [:]
    /// The Sent tray's mark: it lands with a bounce, then, a beat later,
    /// flies into the Sent pill in the header, where the count turns over.
    @State private var sentCheckShown = false
    @State private var sentCheckLanded = false
    /// How many requests were out before this one, so the pill holds that
    /// number until the mark has arrived, however fast the reply came back.
    @State private var sentBaseline: Int?
    /// The Joined tray's mark: lands, waits for the new group's tab to be
    /// there, then flies up into it while the list moves to the group.
    @State private var joinedCheckShown = false
    @State private var joinedCheckLanded = false
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// The header stays empty until the profile's own name has scrolled out of
    /// the viewport, then takes the name over.
    private var showsProfileHeaderTitle: Bool { self.profileTitleBottom < 2 }

    /// The leaderboard already tells us whether this profile has activity.
    /// Reserve the finished profile height while its app breakdown catches up,
    /// instead of shrinking the popover and expanding it again a moment later.
    private var isLoadingProfileActivity: Bool {
        guard case .person = self.store.screen,
              self.store.screenLoading,
              self.store.activity == nil,
              let minutes = self.store.selectedPerson?.active_minutes
        else { return false }
        return minutes > 0
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

    private var profileHeader: some View {
        HStack(spacing: 0) {
            HStack {
                NativeBackButton(help: "Back to \(backDestinationTitle)") { store.goBack() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if self.showsProfileHeaderTitle {
                    Text(self.store.selectedPerson?.displayName ?? "Profile")
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize()
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
            .animation(.snappy(duration: 0.2), value: self.showsProfileHeaderTitle)

            HStack {
                if case let .person(id) = store.screen {
                    if id == Defaults[.currentUserID] {
                        profileHeaderAction("Edit") {
                            SettingsWindowController.shared.show(section: .account, page: "edit")
                        }
                    } else if store.directFriendIDs.contains(id), let person = store.selectedPerson {
                        profileHeaderAction(
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
    @ViewBuilder private var inviteTrayLayer: some View {
        if let tray = store.tray {
            ZStack(alignment: .bottom) {
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture { store.closeTray() }
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
                    .accessibilityHidden(true)
                self.inviteTray(tray)
                    .padding(8)
                    .transition(self.trayTransition)
            }
        }
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

    /// The step a sent request ends on. The mark lands with the one big
    /// overshoot in the whole flow, waits a beat, then travels up into the
    /// Sent pill, which turns its count over as the mark arrives.
    private var traySent: some View {
        VStack(spacing: 6) {
            ZStack {
                if !self.sentCheckLanded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 36, height: 36)
                        .background(Color.green.opacity(0.14), in: Circle())
                        .matchedGeometryEffect(
                            id: Self.sentCheckMorphID(reduceMotion: self.reduceMotion),
                            in: self.morph
                        )
                        .scaleEffect(self.sentCheckShown ? 1 : 0.3)
                        .opacity(self.sentCheckShown ? 1 : 0)
                }
            }
            .frame(height: 36)
            .padding(.bottom, 4)
            Text("Request sent").font(.system(size: 13, weight: .medium))
            Text("They show up here once they accept.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Add another") { self.store.pushTray(.home) }
                .buttonStyle(.link).font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task {
            if self.sentBaseline == nil { self.sentBaseline = self.store.requests.outgoing.count }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.4)) {
                self.sentCheckShown = true
            }
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.5)) {
                self.sentCheckLanded = true
            }
        }
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
    }

    @ViewBuilder private var incomingRequestRows: some View {
        ForEach(self.store.requests.incoming) { request in
            if let person = request.requester {
                self.requestRow(person, detail: "Sent you a friend request") {
                    self.operationButton(
                        "Accept",
                        loadingTitle: "Accepting…",
                        key: "accept-request-\(request.id)",
                        prominent: true
                    ) { self.store.respond(request.id, action: "accept") }
                    self.operationButton(
                        "Decline",
                        loadingTitle: "Declining…",
                        key: "decline-request-\(request.id)"
                    ) { self.store.respond(request.id, action: "decline") }
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

    /// What the Sent pill says. On the Sent tray it keeps the old number until
    /// the mark has landed in it, so the count turns over as the mark arrives
    /// rather than whenever the server happened to answer.
    private var sentPillCount: Int {
        let count = self.store.requests.outgoing.count
        guard self.store.tray == .sent, !self.sentCheckLanded, let baseline = self.sentBaseline else { return count }
        return min(count, baseline)
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

    /// The Sent tray's mark and the pill's icon share this id; with reduced
    /// motion they get different ones and simply cross-fade.
    private static func sentCheckMorphID(reduceMotion: Bool) -> String {
        reduceMotion ? "sent-check-still" : "sent-check"
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
        }
    }

    private func sentRequestsPill(_ tray: SocialStore.Tray) -> some View {
        let count = self.sentPillCount
        return Button { store.pushTray(.sentRequests) } label: {
            HStack(spacing: 5) {
                ZStack {
                    if tray == .sent, self.sentCheckLanded {
                        // Where the Sent tray's mark comes to rest: the same
                        // shared geometry, so it flies here instead of vanishing.
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .matchedGeometryEffect(
                                id: Self.sentCheckMorphID(reduceMotion: self.reduceMotion),
                                in: self.morph
                            )
                    } else {
                        Image(systemName: "paperplane").font(.system(size: 10, weight: .medium))
                    }
                }
                .frame(width: 12, height: 12)
                Text("Sent").font(.system(size: 11))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(self.reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: count)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Sent requests")
        .transition(.opacity)
    }

    /// The Send request tray: who the code or link belongs to, and the one
    /// action that follows. The old banner's prompts supply the words.
    @ViewBuilder private func trayCandidate(_ input: InviteInput) -> some View {
        let prompt = self.invitePrompt(for: input)
        let isToken: Bool = if case .token = input { true } else { false }
        // The person, not the code: once the code's owner is known the card
        // shows their face and name, and the button says who is being added.
        let inviter: NativeJoinInfo.Inviter? = if case let .friendCode(code) = input,
                                                  let known = self.store.inviter,
                                                  known.code == code { known } else { nil }
        HStack(alignment: .center, spacing: 10) {
            if let inviter {
                FirstlightAvatar(url: inviter.inviterAvatarUrl, name: inviter.inviterName, size: 32)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Image(systemName: prompt.icon)
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(inviter?.inviterName ?? prompt.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .contentTransition(.opacity)
                Text(inviter == nil ? prompt.message : self.inviterDetail).font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 6)
            if self.store.checkingInvite {
                NativeProgress(active: true, label: "Checking invitation")
            }
        }
        .animation(self.reduceMotion ? nil : SocialStore.settle, value: inviter)
        .padding(11)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .animation(.easeOut(duration: 0.2), value: prompt.title)

        // Shown while the link is still being read as well, so Checking and
        // Found stand at one height and the tray moves once, not twice.
        if isToken, self.store.inviteError == nil {
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
        // A link's button is there from the first moment, dimmed while the
        // link is read, so the tray is its final height at once; then the
        // group's name arrives into the label. A code's button says what it
        // does and turns into a spinner while it does it.
        if prompt.actionTitle != nil || (isToken && self.store.inviteError == nil) {
            self.trayActionButton(
                isToken ? "Join \(self.store.inviteInfo?.invite.groupName ?? "group")" :
                    "Add \(inviter.map { Self.firstName(of: $0.inviterName) } ?? "friend")",
                isLoading: self.store.isRunning("accept-invite"),
                enabled: prompt.actionTitle != nil
            ) { self.store.addFromQuery() }
        } else if self.store.inviteError != nil {
            Button("Try again") { self.store.queryChanged() }
                .controlSize(.small).disabled(self.store.busy)
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
                .scaleEffect(self.sentCheckShown ? 1 : 0.3)
                .opacity(self.sentCheckShown ? 1 : 0)
                .padding(.bottom, 4)
            Text("You're friends with \(name)").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("Their row is in your list now.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task {
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.4)) {
                self.sentCheckShown = true
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
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
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
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
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
            if value != .sent, !value.isConnected {
                self.sentCheckShown = false
                self.sentCheckLanded = false
                self.sentBaseline = nil
            }
            if case .joined = value {} else {
                self.joinedCheckShown = false
                self.joinedCheckLanded = false
            }
            // Remember how tall the leaving tray stood, so the arriving one
            // can be told to stand visibly apart from it.
            if previous != value {
                self.trayPreviousTotal = self.trayStepHeight.map { $0 + Self.trayFixedHeight(previous) }
                self.applyTrayHeight(for: value)
            }
        }
        .onDisappear {
            self.trayStepHeight = nil
            self.trayPreviousTotal = nil
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
        var step = min(natural, maximumStep)
        // Neighbouring trays must differ in height, or the change is not
        // seen. Within 24 pt the arriving tray takes 24 pt of air below.
        if let previous = self.trayPreviousTotal,
           abs(step + Self.trayFixedHeight(tray) - previous) < 24
        {
            step = min(step + 24, maximumStep)
        }
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
            if tray == .home || tray == .sent, self.sentPillCount > 0 || self.sentCheckLanded {
                self.sentRequestsPill(tray)
            }
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
        case .sent: "Sent"
        case .connected: "Friends"
        case .joined: "Joined"
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
            self.incomingRequestRows
            if self.store.requests.incoming.isEmpty { self.quiet("That's everyone.") }
            if let error = store.error { NativeInlineError(message: error) }
        case .candidate:
            // The field may have just emptied; the tray is on its way back.
            if let input = self.store.inviteCandidate { self.trayCandidate(input) }
        case .sent:
            self.traySent
        case let .connected(name):
            self.trayConnected(name)
        case let .joined(groupName):
            self.trayJoined(groupName)
        case .sentRequests:
            if self.store.requests.outgoing.isEmpty { self.quiet("No pending requests.") }
            if let error = store.error { NativeInlineError(message: error) }
            ForEach(self.store.requests.outgoing) { request in
                if let person = request.target_user {
                    self.requestRow(person, detail: "Waiting for a response") {
                        self.operationButton(
                            "Cancel",
                            loadingTitle: "Cancelling…",
                            key: "cancel-request-\(request.id)"
                        ) { self.store.respond(request.id, action: "cancel") }
                    }
                    .transition(.opacity)
                }
            }
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

    @ViewBuilder private func profileHeaderAction(
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
                        // The same total the profile leads with: it goes
                        // there, so the eye is sure it is the same number.
                        .matchedGeometryEffect(
                            id: self.morphID(Self.timeMorphID, row: morphSource),
                            in: self.morph,
                            properties: .position
                        )
                        let activeApp = person.isActiveNow ? person.active_app : nil
                        let agent = person.isAgentWorkingNow ? person.agent : nil
                        if activeApp != nil || agent != nil {
                            // The list is looked at often, so an agent at work
                            // is only a small mark beside the running app: it
                            // grows out of the app icon's side and fades when
                            // the agent goes quiet. Numbers wait for the profile.
                            HStack(spacing: 5) {
                                if let agent {
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
                                    NativeTrackedAppIcon(url: activeApp.icon_url, size: 16)
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
                Text(person.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                    .matchedGeometryEffect(id: self.morphID(Self.nameMorphID), in: self.morph, properties: .position)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: ProfileTitleBottom.self,
                            value: geometry.frame(in: .named(NativeLayout.popoverScrollSpace)).maxY
                        )
                    })

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

            if let bio = person.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }

            if [person.website, person.twitter, person.telegram].contains(where: { $0?.isEmpty == false }) {
                HStack(spacing: 8) {
                    profileLink("Website", assetImage: "ProfileWebsite", raw: person.website)
                    profileLink(
                        "X",
                        assetImage: "ProfileX",
                        raw: person.twitter.map { $0.hasPrefix("https://") ? $0 : "https://x.com/\($0)" }
                    )
                    profileLink(
                        "Telegram",
                        assetImage: "ProfileTelegram",
                        raw: person.telegram.map { $0.hasPrefix("https://") ? $0 : "https://t.me/\($0)" }
                    )
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active time").font(.system(size: 13, weight: .medium))
                    Text(
                        store.period == "24h" ? "Last 24 hours" : store
                            .period == "7d" ? "Last 7 days" : "Last 30 days"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // The list already has the total. Keep it visible while a more
                    // recent total loads; never replace known data with a spinner.
                    if let minutes = store.activity?.active_minutes ?? person.active_minutes {
                        // Arrives from the tapped row's total. Position only, so
                        // the two sizes cross-fade instead of one stretching.
                        AnimatedDuration(minutes: minutes).font(.system(size: 20, weight: .medium))
                            .fixedSize()
                            .matchedGeometryEffect(
                                id: self.morphID(Self.timeMorphID),
                                in: self.morph,
                                properties: .position
                            )
                    } else if store.screenLoading {
                        NativeSkeletonShape(width: 52, height: 20, radius: 5)
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                    if let standing = placeSummary(for: id) {
                        Text(standing)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Place \(standing.dropFirst())")
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            // The agents card follows the active-time card only for people
            // with agent data: no empty card, no "0 tokens". It settles in
            // when the summary answers instead of appearing between frames.
            ZStack {
                if let summary = store.agentSummary, summary.has_data {
                    NativeAgentsCard(
                        summary: summary,
                        period: store.period,
                        liveMorph: .init(id: self.morphID(Self.agentMorphID), namespace: self.morph)
                    )
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(
                self.reduceMotion ? nil : .snappy(duration: 0.32, extraBounce: 0),
                value: self.store.agentSummary?.has_data ?? false
            )
            if self.isLoadingProfileActivity {
                NativeTrackedAppsSkeleton()
            }
            if let activeApp = store.activity?.active_app {
                self.trackedAppRow(activeApp, showsActiveState: true)
                    .padding(.horizontal, 4)
            }
            if let topApps = store.activity?.top_apps, !topApps.isEmpty {
                Divider()
                self.sectionHeading("Top apps")
                VStack(spacing: 0) {
                    ForEach(Array(topApps.prefix(5).enumerated()), id: \.element.id) { index, app in
                        trackedAppRow(app)
                        if index < min(topApps.count, 5) - 1 { Divider().padding(.leading, 38).opacity(0.5) }
                    }
                }
            }
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
            NativeTrackedAppIcon(url: app.icon_url, size: 28)
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
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func requestRow(
        _ person: NativeContact,
        detail: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            FirstlightAvatar(url: person.avatar_url, name: person.displayName, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(person.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) { actions() }.controlSize(.small)
        }.padding(.vertical, 3)
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
            if let image = state.image { image.resizable().scaledToFill() }
            else {
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

/// "An agent is writing right now": the tool's glyph with a dot that
/// breathes. Breathing rather than blinking, and still under Reduce Motion,
/// so a list full of working agents never flickers.
private struct NativeAgentIndicator: View {
    // MARK: Internal

    let tool: String
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            NativeAgentGlyph(tool: self.tool, size: self.size).foregroundStyle(.secondary)
            Circle()
                .fill(Color.accentColor)
                .frame(width: self.size * 0.5, height: self.size * 0.5)
                .opacity(self.reduceMotion ? 1 : (self.breathingIn ? 1 : 0.35))
                .animation(
                    self.reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: self.breathingIn
                )
        }
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

/// A person's coding agents over the period. The hero number is the time
/// agents worked while the person was away, the one figure nothing else on
/// the profile tells; the rest is set smaller. Hovering a day of the week
/// bars swaps every number for that day, and leaving swaps them back.
private struct NativeAgentsCard: View {
    // MARK: Internal

    let summary: NativeAgentSummary
    let period: String
    let liveMorph: FirstlightAvatar.Morph

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agents").font(.system(size: 13, weight: .medium))
                    Text(self.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.14), value: self.subtitle)
                }
                Spacer()
                if let live = self.summary.active_tool {
                    // Flew in from the row's small mark: this is where the
                    // "working" status lives once the profile is open.
                    NativeAgentIndicator(tool: live, size: 13)
                        .matchedGeometryEffect(
                            id: self.liveMorph.id,
                            in: self.liveMorph.namespace,
                            properties: .position
                        )
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                self.stat("While away", minutes: self.shown.agentOnly)
                self.stat("Agent time", minutes: self.shown.agent)
                Spacer(minLength: 0)
            }

            if let days = self.summary.days, days.count > 1 {
                NativeAgentWeekBars(days: days, hovered: self.$hoveredDay)
            }

            HStack(spacing: 6) {
                if let tokens = self.summary.tokens {
                    Text("\(TokenLabel.compact(tokens.total)) tokens")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                if let tool = self.summary.top_tool {
                    Text("·").foregroundStyle(.tertiary)
                    NativeAgentGlyph(tool: tool, size: 11)
                    Text(NativeAgentToolLabel.name(tool)).lineLimit(1)
                }
                if let concurrency = self.summary.max_concurrency, concurrency > 1 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("up to \(concurrency) at once").monospacedDigit()
                }
                Spacer(minLength: 4)
                if let cost = self.summary.estimated_cost_micro_usd {
                    // Always an estimate, always marked as one.
                    Text("≈ \(TokenLabel.dollars(microUSD: cost))")
                        .monospacedDigit()
                        .help("Estimated from token counts and public prices")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Private

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    @State private var hoveredDay: Int?

    /// The totals, or the hovered day's share of them.
    private var shown: (agent: Double, agentOnly: Double) {
        if let index = self.hoveredDay, let day = self.summary.days?[safe: index] {
            return (day.agent_minutes, day.agent_only_minutes)
        }
        return (self.summary.agent_minutes ?? 0, self.summary.agent_only_minutes ?? 0)
    }

    private var subtitle: String {
        if let index = self.hoveredDay, let day = self.summary.days?[safe: index],
           let date = Self.dayParser.date(from: day.date)
        {
            return Self.dayLabel.string(from: date)
        }
        switch self.period {
        case "24h": return "Last 24 hours"
        case "7d": return "Last 7 days"
        default: return "Last 30 days"
        }
    }

    private func stat(_ title: String, minutes: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AnimatedDuration(minutes: minutes).font(.system(size: 20, weight: .medium))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Seven (or thirty) columns, one stack each: the person's own time in the
/// light tone, the time agents added while the person was away on top in
/// the dark tone. The pointer picks a day; the card above reads it out.
private struct NativeAgentWeekBars: View {
    // MARK: Internal

    let days: [NativeAgentSummary.Day]
    @Binding var hovered: Int?

    var body: some View {
        let scale = max(self.days.map { $0.human_minutes + $0.agent_only_minutes }.max() ?? 0, 1)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: self.days.count > 7 ? 2 : 4) {
                ForEach(Array(self.days.enumerated()), id: \.element.id) { index, day in
                    let dimmed = self.hovered != nil && self.hovered != index
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.primary.opacity(0.7))
                            .frame(height: Self.height * day.agent_only_minutes / scale)
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.primary.opacity(0.22))
                            .frame(height: Self.height * day.human_minutes / scale)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .frame(height: Self.height, alignment: .bottom)
                    .background(alignment: .bottom) {
                        // A floor so an empty day still has somewhere to hover.
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    }
                    .opacity(dimmed ? 0.45 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { self.hovered = index } else if self.hovered == index { self.hovered = nil }
                    }
                    .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: dimmed)
                    .animation(self.reduceMotion ? nil : .snappy(duration: 0.4, extraBounce: 0), value: scale)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(day.date): \(DurationLabel.minutes(day.agent_minutes)) agents, \(DurationLabel.minutes(day.human_minutes)) you"
                    )
                }
            }
            if self.days.count <= 7 {
                HStack(spacing: 4) {
                    ForEach(self.days) { day in
                        Text(Self.weekdayLetter(day.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Private

    private static let height: CGFloat = 40

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter
    }()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static func weekdayLetter(_ date: String) -> String {
        guard let parsed = self.parser.date(from: date) else { return "" }
        return self.weekday.string(from: parsed)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { self.indices.contains(index) ? self[index] : nil }
}

private struct NativeTrackedAppIcon: View {
    let url: String?
    var size: CGFloat = 28

    var body: some View {
        LazyImage(url: url.flatMap(URL.init(string:))) { state in
            if let image = state.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .padding(size * 0.16)
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
