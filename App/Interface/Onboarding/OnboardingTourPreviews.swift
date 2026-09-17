import SwiftUI

/// Which way the panel inside the previews is moving, read while a
/// transition runs rather than when it was declared: the screen on its way
/// out is no longer updated, and still has to leave the right way.
private final class OnboardingPanelMotion {
    var opening = true
    var tabDirection: CGFloat = 1
}

/// The sideways travel of a screen of the mock panel. The panel's own
/// numbers: the screen that ends up on top travels 16 pt, the one underneath
/// 7, a tab 22 the way the tab lies.
private struct OnboardingPanelDrift: ViewModifier, Animatable {
    enum Kind { case screen, tab }

    let kind: Kind
    let appearing: Bool
    let motion: OnboardingPanelMotion
    let reduceMotion: Bool
    var progress: Double

    var animatableData: Double {
        get { self.progress }
        set { self.progress = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(x: self.drift * self.progress)
    }

    private var drift: CGFloat {
        if self.reduceMotion { return 0 }
        switch self.kind {
        case .screen:
            let onTop = self.appearing == self.motion.opening
            return onTop ? 16 : -7
        case .tab:
            return (self.appearing ? 1 : -1) * self.motion.tabDirection * 22
        }
    }
}

// MARK: - The panel

/// The right side of both showing chapters: one popover, the app's own size
/// and look, that is never rebuilt between them. Your day walks in — the
/// profile, then the Agents screen its card opens — and Friends walks back
/// out to the list, by the panel's own push and pop. So the two chapters
/// read as one app being used, not as two pictures.
struct OnboardingPanelPreview: View {
    // MARK: Internal

    @ObservedObject var flow: OnboardingFlow
    let step: OnboardingStage.Step
    let row: Int
    var onOpen: (Int) -> Void
    /// The bump has played and been looked at: the chapter is over.
    var onFinished: () -> Void

    var body: some View {
        OnboardingPreviewPlate(height: Self.height) {
            OnboardingMockPopover {
                ZStack(alignment: .top) {
                    ZStack(alignment: .top) {
                        switch self.shown {
                        case .list:
                            self.list.transition(self.screenTransition)
                        case .profile:
                            self.profile.transition(self.screenTransition)
                        case .agents:
                            OnboardingAgentsTour(
                                card: self.card, hovered: self.$hovered, scrolled: self.$scrolled,
                                held: self.pointerInside
                            )
                            .transition(self.screenTransition)
                        }
                        if self.shown != .list { self.bar }
                    }
                    // A bump takes the panel the way it does in the app: what
                    // was there steps back, blurred and dimmed under a veil
                    // of material, and the light plays over it.
                    .blur(radius: self.arrived ? 3 : 0)
                    .opacity(self.arrived ? 0.3 : 1)
                    if self.arrived {
                        Rectangle().fill(.ultraThinMaterial).opacity(0.66)
                            .allowsHitTesting(false).transition(.opacity)
                        BumpMetalSurface(
                            run: self.run, avatar: CGRect(x: 137, y: 105, width: 76, height: 76),
                            origin: CGPoint(x: 175, y: 143), emojiBurst: true, dark: true
                        ) { _ in }
                        .allowsHitTesting(false).accessibilityHidden(true)
                        .transition(.opacity)
                        self.arrival
                    }
                }
            }
            .onHover { self.pointerInside = $0 }
        }
        // The chapter's rows move on the window's spring; the popover inside
        // moves the way the real one does, on the panel's own curve, shorter
        // on the way back than on the way in.
        .onChange(of: self.target, initial: true) { _, target in
            guard target != self.shown else { return }
            self.motion.opening = target.depth > self.shown.depth
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) :
                SocialStore.navigationTransition(opening: self.motion.opening))
            {
                self.shown = target
                if target != .agents { self.scrolled = 0 }
            }
        }
        .task(id: "\(self.step)-\(self.row)") { await self.play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.spoken)
    }

    // MARK: Private

    private enum Screen: Equatable {
        case list, profile, agents

        var depth: Int {
            switch self {
            case .list: 0
            case .profile: 1
            case .agents: 2
            }
        }
    }

    private enum Tab: Int { case friends, board }

    fileprivate struct Person: Identifiable {
        let id: String
        let name: String
        let avatarURL: String?
        let location: String?
        let app: String?
        let live: NativeAgentLive?
        let bio: String
        let minutes: Double
        var isYou = false
    }

    /// One height for every screen, so the panel is the same object throughout.
    private static let height: CGFloat = 440
    private static let bumper = "alex"
    private static let openFade: Double = 0.24
    private static let closeFade: Double = 0.19
    /// Where a screen's title comes to rest: the middle of the row of buttons.
    private static let titleRest: CGFloat = NativeLayout.popoverHeaderHeight / 2
    private static let titleStart: CGFloat = NativeLayout.popoverHeaderHeight + 12
    /// 13 pt in the row against 20 pt on the screen.
    private static let titleRowScale: CGFloat = 13.0 / 20.0

    @Namespace private var card
    @Namespace private var pill
    @State private var motion = OnboardingPanelMotion()
    @State private var shown: Screen = .profile
    @State private var tab: Tab = .friends
    @State private var hovered: AgentBucket?
    @State private var scrolled: CGFloat = 0
    @State private var pointerInside = false
    @State private var arrived = false
    @State private var run: BumpEffectRun?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var target: Screen {
        switch self.step {
        case .day: self.row == 0 ? .profile : .agents
        default: .list
        }
    }

    private var spoken: String {
        switch self.step {
        case .day:
            self.row == 0
                ? "Your profile: active time, agent time, the week as a chart, and your apps."
                : "The Agents screen: cost, streak, records, models and tools."
        default:
            self.row == 0 ? "Your friends, with what each is doing now and their time today." :
                self.row == 1 ? "The global leaderboard, with you in third place." :
                "Alex says: on fire."
        }
    }

    private var displayName: String {
        let name = self.flow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "You" : name
    }

    /// One half of a push or a pop. Which way it goes is read from `motion`
    /// as it runs; the two screens trade opacity on short curves of their own.
    private var screenTransition: AnyTransition {
        guard !self.reduceMotion else { return .opacity }
        let motion = self.motion
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingPanelDrift(kind: .screen, appearing: true, motion: motion, reduceMotion: false, progress: 1),
                identity: OnboardingPanelDrift(kind: .screen, appearing: true, motion: motion, reduceMotion: false, progress: 0)
            ).combined(with: .opacity.animation(.easeOut(duration: Self.openFade))),
            removal: .modifier(
                active: OnboardingPanelDrift(kind: .screen, appearing: false, motion: motion, reduceMotion: false, progress: 1),
                identity: OnboardingPanelDrift(kind: .screen, appearing: false, motion: motion, reduceMotion: false, progress: 0)
            ).combined(with: .opacity.animation(.easeIn(duration: Self.closeFade)))
        )
    }

    /// A tab change: the list leaving drops first and quickly, the one
    /// arriving comes up behind it, both the way the tab lies.
    private var tabTransition: AnyTransition {
        guard !self.reduceMotion else { return .opacity }
        let motion = self.motion
        return .asymmetric(
            insertion: .modifier(
                active: OnboardingPanelDrift(kind: .tab, appearing: true, motion: motion, reduceMotion: false, progress: 1),
                identity: OnboardingPanelDrift(kind: .tab, appearing: true, motion: motion, reduceMotion: false, progress: 0)
            ).combined(with: .opacity.animation(.easeOut(duration: 0.2))),
            removal: .modifier(
                active: OnboardingPanelDrift(kind: .tab, appearing: false, motion: motion, reduceMotion: false, progress: 1),
                identity: OnboardingPanelDrift(kind: .tab, appearing: false, motion: motion, reduceMotion: false, progress: 0)
            ).combined(with: .opacity.animation(.easeIn(duration: 0.1)))
        )
    }

    // MARK: Detail screens

    /// 0 while the title is in the content, 1 once it is held on the row.
    private var titleProgress: CGFloat {
        let travel = Self.titleStart - Self.titleRest
        return min(max((self.scrolled - (travel - 22)) / 22, 0), 1)
    }

    /// The row of buttons that hangs over a detail screen: back on the left,
    /// the period on the right. The screen's own title rides up to it,
    /// shrinks into it over the last stretch and is held there, on a band of
    /// material that ends in a fade rather than on a line.
    private var bar: some View {
        let progress = self.shown == .agents ? self.titleProgress : 0
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(.thinMaterial)
                .mask(LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.62),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(height: NativeLayout.popoverHeaderHeight)
                .opacity(Double(progress))
                .allowsHitTesting(false)
            if self.shown == .agents {
                Text("Agents")
                    .font(.system(size: 20, weight: .semibold))
                    .scaleEffect(1 - progress * (1 - Self.titleRowScale))
                    .position(x: NativeLayout.popoverWidth / 2, y: max(Self.titleStart - self.scrolled, Self.titleRest))
                    .transition(self.screenTransition)
                    .allowsHitTesting(false)
            }
            HStack {
                OnboardingMockBackButton(title: self.shown == .agents ? self.displayName : "Friends") {
                    if self.step == .day, self.row > 0 { self.onOpen(0) }
                }
                Spacer()
                OnboardingMockPeriodPicker(title: "Week")
            }
            .padding(.horizontal, 12)
            .frame(height: NativeLayout.popoverHeaderHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }

    private var profile: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 8) {
                    FirstlightAvatar(url: self.flow.avatarURL, name: self.displayName, size: 76, presence: .online)
                    Text(self.displayName).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    let city = self.flow.draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !city.isEmpty { NativeLocationLabel(text: city, timeZone: .current) }
                }
                .padding(.top, 26)
                NativePresenceLine(
                    appName: OnboardingTourFixtures.frontApp, live: OnboardingTourFixtures.live, size: 12
                )
                .foregroundStyle(.secondary)
                AgentsPanel(
                    summary: OnboardingTourFixtures.week, period: "7d",
                    ownTime: OnboardingTourFixtures.weekOwnMinutes, loadingOwnTime: false,
                    hovered: self.$hovered, onMore: { self.onOpen(1) }
                )
                .matchedGeometryEffect(id: "agents", in: self.card)
                Text("Apps").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(OnboardingTourFixtures.apps.enumerated()), id: \.element.id) { index, app in
                        HStack(spacing: 10) {
                            NativeTrackedAppIcon(url: nil, bundleIdentifier: app.bundle_identifier, size: 28)
                            Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DurationLabel.minutes(app.active_minutes))
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        if index < OnboardingTourFixtures.apps.count - 1 {
                            Divider().padding(.leading, 38).opacity(0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, NativeLayout.popoverContentPadding)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: The list

    private var list: some View {
        VStack(spacing: 0) {
            self.tabs
            ZStack(alignment: .top) {
                self.rows(for: self.tab)
                    .id(self.tab)
                    .transition(self.tabTransition)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            self.footer
        }
    }

    private func people(for tab: Tab) -> [Person] {
        func person(_ friend: OnboardingTourFixtures.Friend) -> Person {
            Person(
                id: friend.id, name: friend.name, avatarURL: friend.avatarURL, location: friend.location,
                app: friend.app,
                live: friend.agents > 0
                    ? .init(
                        session_count: friend.agents, observed_at: "",
                        tools: [.init(tool: "claude_code", session_count: friend.agents)]
                    ) : nil,
                bio: friend.bio, minutes: friend.minutes
            )
        }
        switch tab {
        case .friends: return OnboardingTourFixtures.friends.map(person)
        case .board:
            let you = Person(
                id: "you", name: self.displayName, avatarURL: self.flow.avatarURL, location: nil,
                app: OnboardingTourFixtures.frontApp, live: OnboardingTourFixtures.live, bio: "",
                minutes: OnboardingTourFixtures.ownMinutes, isYou: true
            )
            return (OnboardingTourFixtures.board.map(person) + [you]).sorted { $0.minutes > $1.minutes }
        }
    }

    private func rows(for tab: Tab) -> some View {
        let people = self.people(for: tab)
        let ranked = tab != .friends
        return VStack(spacing: 0) {
            ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                OnboardingPersonRow(person: person, place: ranked ? index + 1 : nil)
                if index < people.count - 1 {
                    Divider().padding(.leading, ranked ? 86 : 62).opacity(0.55)
                }
            }
        }
    }

    /// The list's header as the panel draws it: the tabs on a rounded pill
    /// that travels between them, and the period on the right.
    private var tabs: some View {
        HStack(spacing: 7) {
            HStack(spacing: 4) {
                // The group's tab is in the strip, as a group's is, and is
                // not opened: the chapter goes from friends to the board.
                ForEach([(Tab?.some(.friends), "Friends"), (nil, "YC"), (.board, "Leaderboard")], id: \.1) { tab, title in
                    let selected = tab == self.tab
                    Text(title)
                        .font(.system(size: 13, weight: .medium)).fixedSize()
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.11))
                                    .matchedGeometryEffect(id: "pill", in: self.pill)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OnboardingMockPeriodPicker(title: "Day")
        }
        .padding(.horizontal, 12)
        .frame(height: NativeLayout.popoverHeaderHeight)
    }

    /// Settings on the left, Invite on the right: the list's two buttons.
    private var footer: some View {
        HStack(spacing: 8) {
            OnboardingMockGlass(shape: .circle) {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).frame(width: 22, height: 22)
            }
            Spacer()
            Text("Invite").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .frame(minWidth: 42, minHeight: 22)
                .padding(.horizontal, 12).frame(minHeight: 32)
                .modifier(OnboardingMockTint())
        }
        .padding(.horizontal, 12).padding(.top, 5).padding(.bottom, 12)
        .frame(height: NativeLayout.peopleFooterHeight)
    }

    private func select(_ tab: Tab) {
        guard tab != self.tab else { return }
        self.motion.tabDirection = tab.rawValue > self.tab.rawValue ? 1 : -1
        withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.3, extraBounce: 0)) {
            self.tab = tab
        }
    }

    // MARK: The bump

    /// What the panel shows when a bump lands: who, and their words, with the
    /// burst the app plays around them. It comes over whatever screen is up,
    /// as it does in the app; nothing in the list turns into it.
    private var arrival: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: self.run == nil)) { clock in
            let motion = self.run
                .map { BumpEffectMotion.sample($0.effect, at: $0.elapsed(at: clock.date), reduced: $0.reduced) }
                ?? BumpEffectMotion()
            VStack(spacing: 0) {
                FirstlightAvatar(
                    url: OnboardingTourFixtures.friends.first { $0.id == Self.bumper }?.avatarURL,
                    name: "Alex", size: 76
                )
                .scaleEffect(x: motion.scaleX, y: motion.scaleY)
                .rotationEffect(.degrees(motion.rotation))
                .offset(x: motion.x, y: motion.y)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                Text("Alex says")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.top, 15)
                Text(BumpEffect.onFire.title)
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 105)
        }
        .overlay { BumpEmojiBurst(run: self.run, origin: CGPoint(x: 175, y: 143)) }
        .overlay(alignment: .topTrailing) {
            OnboardingGlassCircleButton(symbol: "arrow.clockwise", size: 20) { Task { await self.burst() } }
                .controlSize(.regular)
                .padding(12)
                .help("Play again")
                .accessibilityLabel("Play the bump again")
        }
        .transition(.opacity)
    }

    // MARK: What plays when

    private func play() async {
        self.run = nil
        guard self.step == .friends else {
            self.arrived = false
            return
        }
        switch self.row {
        case 0:
            withAnimation(.easeOut(duration: 0.2)) { self.arrived = false }
            self.select(.friends)
        case 1:
            withAnimation(.easeOut(duration: 0.2)) { self.arrived = false }
            self.select(.board)
        default:
            await BumpEmojiLibrary.shared.prepare(.onFire)
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.3)) {
                self.arrived = true
            }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            await self.burst()
            // The burst, and a moment with the words after it. Then the
            // chapter moves on by itself: this is its last row, and what
            // follows is the first thing the reader is asked to do. A pointer
            // over the panel — someone playing it again — is left alone.
            try? await Task.sleep(for: .seconds(BumpEffect.onFire.duration + 1.2))
            while self.pointerInside, !Task.isCancelled { try? await Task.sleep(for: .seconds(0.5)) }
            guard !Task.isCancelled else { return }
            self.onFinished()
        }
    }

    private func burst() async {
        self.run = nil
        try? await Task.sleep(for: .milliseconds(30))
        self.run = BumpEffectRun(effect: .onFire, reduced: self.reduceMotion, slow: false, incoming: true)
    }
}

/// A person's row at the list's own numbers: 40 pt face, name and city on
/// one line, what they are doing under it, their time on the right.
private struct OnboardingPersonRow: View {
    let person: OnboardingPanelPreview.Person
    let place: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let place {
                Text("\(place)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            FirstlightAvatar(
                url: self.person.avatarURL, name: self.person.name, size: 40,
                presence: self.person.app == nil ? .away : .online
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(self.person.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let location = person.location {
                        HStack(spacing: 3) {
                            NativeLocationIcon().frame(width: 9)
                            Text(location)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(height: 17, alignment: .leading)
                Group {
                    if self.person.app != nil || self.person.live != nil {
                        NativePresenceLine(appName: self.person.app, live: self.person.live)
                    } else {
                        Text(self.person.bio).lineLimit(1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(height: 18, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(DurationLabel.minutes(self.person.minutes))
                .font(.system(size: 16, weight: .medium)).monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background {
            if self.person.isYou {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07))
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// The Agents screen, on a fixture month, drawn with the app's own sections.
/// Once it has arrived it is shown around: a pointer of ours hovers the week's
/// chart, the screen scrolls to the cost and the pointer hovers a day or two
/// of it, then the streak, then down to the end — so someone who only ever
/// presses Continue still sees what each part says when it is asked. The
/// reader's pointer over the popover holds the tour where it is; a scroll of
/// their own takes it over for good.
private struct OnboardingAgentsTour: View {
    // MARK: Internal

    let card: Namespace.ID
    @Binding var hovered: AgentBucket?
    /// How far the screen has been scrolled, for the title riding up with it.
    @Binding var scrolled: CGFloat
    /// The pointer is over the popover.
    let held: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 3) {
                    // The title's room. The title itself is drawn by the row
                    // of buttons, which is where it ends up: one title on
                    // screen, moved rather than swapped for a smaller one.
                    Text("Agents").font(.system(size: 20, weight: .semibold)).hidden()
                    Text(NativeAgentTime.rangeLabel(OnboardingTourFixtures.week?.days) ?? "Last 7 days")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, NativeLayout.popoverHeaderHeight)

                AgentsPanel(
                    summary: OnboardingTourFixtures.week, period: "7d",
                    ownTime: OnboardingTourFixtures.weekOwnMinutes, loadingOwnTime: false,
                    hovered: self.$hovered
                )
                .matchedGeometryEffect(id: "agents", in: self.card)
                .modifier(self.records(.chart))

                if let month = OnboardingTourFixtures.month {
                    self.heading("Cost").id(Stop.cost)
                    AgentSpendCard(month: month, pointed: self.spot.stop == .cost ? self.spot.named : nil)
                        .modifier(self.records(.cost))
                    self.heading("Streak").id(Stop.streak)
                    AgentStreakSection(
                        streak: AgentAnalytics.streak(month),
                        pointed: self.spot.stop == .streak ? self.spot.named : nil
                    )
                    .modifier(self.records(.streak))
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        self.heading("Records")
                        Text("last 30 days").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    AgentRecordTiles(
                        records: AgentAnalytics.records(month).map {
                            // A tile here opens nothing: no day behind it.
                            .init(id: $0.id, title: $0.title, value: $0.value, note: $0.note, date: nil)
                        },
                        openSource: nil, frames: self.frames
                    ) { _ in }
                }
                if let week = OnboardingTourFixtures.week {
                    if let models = week.by_model { AgentModelsSection(models: models).padding(.top, 4) }
                    if let tools = week.by_tool { AgentToolsSection(tools: tools).padding(.top, 4) }
                }
            }
            .padding(.horizontal, NativeLayout.popoverContentPadding)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .scrollPosition(self.$position)
        .coordinateSpace(name: Self.space)
        // One pointer for the whole tour, over the screen and not in it: the
        // content scrolls under it the way it does under a real one, and it
        // goes on from wherever it was left.
        .overlay { self.pointer }
        .onScrollGeometryChange(for: Extent.self) { geometry in
            Extent(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                room: geometry.contentSize.height - geometry.containerSize.height
            )
        } action: { _, extent in
            self.room = max(extent.room, 0)
            self.offset = max(extent.offset, 0)
            self.scrolled = self.offset
        }
        .onScrollPhaseChange { _, phase in
            // A hand on the scroll: the tour is theirs from here on.
            if phase == .interacting || phase == .tracking || phase == .decelerating { self.takeOver() }
        }
        .task { await self.tour() }
    }

    // MARK: Private

    private struct Extent: Equatable {
        var offset: CGFloat
        var room: CGFloat
    }

    /// Where the tour stops to point.
    private enum Stop: Hashable { case chart, cost, streak }

    /// Where the pointer of ours is, in the screen's own space, and which
    /// mark of which section it is naming.
    private struct Spot: Equatable {
        var stop: Stop = .chart
        var x: CGFloat = 0
        var y: CGFloat = 0
        var shown = false
        var landed = false
        var named: Int?
    }

    /// Where each section stands on screen right now. A box and not state:
    /// it changes with every scroll tick and is only read when the pointer
    /// is about to fly.
    private final class Frames { var of: [Stop: CGRect] = [:] }

    private static let space = "onboarding-agents-tour"

    @State private var position = ScrollPosition(y: 0)
    @State private var room: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var takenOver = false
    @State private var frames = AgentTileFrames()
    @State private var spot = Spot()
    @State private var places = Frames()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).padding(.top, 4)
    }

    // MARK: The pointer

    /// A pointer of ours, so the screen is seen answering one. Not the
    /// system's arrow — nobody should reach for a second mouse — but a soft
    /// black arrowhead with a white edge that drifts while it rests.
    private var pointer: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !self.spot.shown)) { clock in
            let t = clock.date.timeIntervalSinceReferenceDate
            OnboardingPointerArrow()
                .frame(width: 19, height: 23)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 4)
                // Heading up and to the left, the way a pointer leans.
                .rotationEffect(.degrees(-30 + sin(t * 1.1) * 4), anchor: .top)
                .scaleEffect(self.spot.landed ? 0.88 : 1, anchor: .top)
                .offset(x: sin(t * 1.4) * 3.2, y: cos(t * 1.05) * 3.6)
        }
        // The arrow's tip, not its middle, is what points.
        .position(x: self.spot.x + 3, y: self.spot.y + 11)
        .opacity(self.spot.shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Keeps where a section stands on screen, for the pointer to fly to.
    private func records(_ stop: Stop) -> some ViewModifier {
        OnboardingFrameRecorder(space: Self.space) { [places] frame in places.of[stop] = frame }
    }

    /// A place in a section, in the screen's space: so far across it, so far
    /// down from its top.
    private func place(in stop: Stop, along: CGFloat, down: CGFloat) -> CGPoint? {
        guard let frame = self.places.of[stop] else { return nil }
        return CGPoint(x: frame.minX + frame.width * along, y: frame.minY + down)
    }

    /// Flies to a place and rests on it. Across and down move on springs of
    /// different lengths, so the path between two places is a curve and not
    /// a rail; the landing is a small press.
    private func fly(to stop: Stop, along: CGFloat, down: CGFloat) async {
        guard let target = self.place(in: stop, along: along, down: down) else { return }
        self.spot.stop = stop
        withAnimation(.spring(duration: 0.7, bounce: 0.18)) {
            self.spot.x = target.x
            self.spot.landed = false
        }
        withAnimation(.spring(duration: 0.9, bounce: 0.3)) { self.spot.y = target.y }
        try? await Task.sleep(for: .seconds(0.42))
    }

    private func land() { withAnimation(.spring(duration: 0.35, bounce: 0.5)) { self.spot.landed = true } }

    /// Comes in once, from the lower corner of the screen.
    private func enter() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { self.spot = Spot(x: NativeLayout.popoverWidth - 60, y: 380) }
        withAnimation(.easeOut(duration: 0.35)) { self.spot.shown = true }
    }

    /// Lets go of what it was naming and lifts, staying on screen: the
    /// content is about to scroll under it.
    private func release() {
        self.hovered = nil
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
            self.spot.named = nil
            self.spot.landed = false
        }
    }

    /// The end of the tour: off to the lower corner it came from.
    private func leave() async {
        withAnimation(.easeIn(duration: 0.6)) {
            self.spot.shown = false
            self.spot.landed = false
            self.spot.x = NativeLayout.popoverWidth - 40
            self.spot.y += 120
        }
        try? await Task.sleep(for: .seconds(0.6))
    }

    // MARK: The tour

    private var stopped: Bool { Task.isCancelled || self.takenOver }

    /// The reader's pointer over the popover: wait for it to go.
    private func waitWhileHeld() async {
        while self.held, !self.stopped { try? await Task.sleep(for: .seconds(0.25)) }
    }

    private func takeOver() {
        guard !self.takenOver else { return }
        self.takenOver = true
        self.hovered = nil
        withAnimation(.easeOut(duration: 0.2)) {
            self.spot.shown = false
            self.spot.named = nil
        }
    }

    private func scroll(to stop: Stop, over seconds: Double) async {
        await self.waitWhileHeld()
        guard !self.stopped else { return }
        withAnimation(.easeInOut(duration: seconds)) {
            // Below the row of buttons and its band, not under them.
            self.position.scrollTo(id: stop, anchor: UnitPoint(x: 0.5, y: 0.17))
        }
        try? await Task.sleep(for: .seconds(seconds + 0.05))
    }

    private func tour() async {
        guard !self.reduceMotion else { return }
        let buckets = OnboardingTourFixtures.weekBuckets
        let days = CGFloat(max(OnboardingTourFixtures.month?.days?.count ?? 30, 1))
        try? await Task.sleep(for: .seconds(0.55))
        await self.waitWhileHeld()
        guard !self.stopped else { return }
        self.enter()

        // The week: two of its columns, each becoming the card's numbers.
        // Brisk throughout: a glance at each part, not a lesson in it.
        if buckets.count >= 6 {
            let count = CGFloat(buckets.count)
            func along(_ column: Int) -> CGFloat { (CGFloat(column) + 0.5) / count * 0.93 + 0.035 }
            for (column, down) in [(2, 92.0), (5, 108.0)] {
                await self.fly(to: .chart, along: along(column), down: down)
                guard !self.stopped, !self.held else { break }
                self.hovered = buckets[column]
                self.land()
                try? await Task.sleep(for: .seconds(0.6))
                guard !self.stopped, !self.held else { break }
            }
        }

        // The cost: two of its thirty days. The pointer stays where it was
        // while the screen moves, and goes on from there.
        guard !self.stopped else { return }
        if !self.held { self.release() }
        await self.scroll(to: .cost, over: 0.9)
        if !self.stopped {
            func along(_ day: Int) -> CGFloat { (CGFloat(day) + 0.5) / days * 0.93 + 0.035 }
            for day in [18, 25] {
                await self.fly(to: .cost, along: along(day), down: day == 18 ? 90 : 98)
                guard !self.stopped, !self.held else { break }
                self.spot.named = day
                self.land()
                try? await Task.sleep(for: .seconds(0.6))
                guard !self.stopped, !self.held else { break }
            }
        }

        // The streak: one day inside it; it is a short way down from the cost.
        guard !self.stopped else { return }
        self.release()
        await self.scroll(to: .streak, over: 0.7)
        if !self.stopped {
            func along(_ day: Int) -> CGFloat { (CGFloat(day) + 0.5) / days }
            for day in [24] {
                await self.fly(to: .streak, along: along(day), down: 40)
                guard !self.stopped, !self.held else { break }
                self.spot.named = day
                self.land()
                try? await Task.sleep(for: .seconds(0.6))
                guard !self.stopped, !self.held else { break }
            }
        }

        // And on down to the end, left to the scroll view to draw: it is
        // stepped on the display's own clock, which a loop of ours is not.
        guard !self.stopped else { return }
        self.release()
        await self.waitWhileHeld()
        guard !self.stopped, self.room > 0 else { return }
        let left = max(self.room - self.offset, 0)
        if left > 1 {
            withAnimation(.easeInOut(duration: max(3.2 * Double(left / self.room), 1.0))) {
                self.position.scrollTo(y: self.room)
            }
        }
        await self.leave()
    }
}

/// Reports where a view stands in a named space, every time that changes.
private struct OnboardingFrameRecorder: ViewModifier {
    let space: String
    let record: (CGRect) -> Void

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(self.space)) } action: { self.record($0) }
    }
}

// MARK: - The panel's own controls, as pictures

/// The back button of a detail screen: a capsule on the system's glass with
/// where it leads. A picture of `NativeBackButton` that takes a click and
/// no keyboard shortcut, since the window's own Back owns ⌘[.
private struct OnboardingMockBackButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        let label = HStack(spacing: 4) {
            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            Text(self.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: 110, minHeight: 22)
        .fixedSize(horizontal: true, vertical: false)
        if #available(macOS 26.0, *) {
            Button(action: self.action) { label }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular)
        } else {
            Button(action: self.action) { label }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular)
        }
    }
}

/// The period control, at rest: the same rounded pill a chosen tab has.
private struct OnboardingMockPeriodPicker: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(self.title).font(.system(size: 13, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.primary.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A control on plain glass, as the panel's Settings button is.
private struct OnboardingMockGlass<Label: View>: View {
    enum Outline { case circle }

    let shape: Outline
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 26.0, *) {
            Button {} label: { self.label() }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .allowsHitTesting(false)
        } else {
            Button {} label: { self.label() }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.regular)
                .allowsHitTesting(false)
        }
    }
}

/// The Invite button's surface: glass tinted with the app's violet, in the
/// tray's own 16 pt corner.
private struct OnboardingMockTint: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(.firstlight), in: .rect(cornerRadius: 16))
        } else {
            content.background(Color.firstlight, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// The demo pointer: a navigator's arrowhead — a tip, two swept wings and a
/// notch between them — with every corner rounded off. Black, with a white
/// edge, so it reads on the dark panel and on anything lit under it.
private struct OnboardingPointerArrow: View {
    var body: some View {
        ZStack {
            Outline().stroke(.white, style: .init(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            Outline().stroke(.black, style: .init(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
            Outline().fill(.black)
        }
    }

    private struct Outline: Shape {
        func path(in rect: CGRect) -> Path {
            // Drawn inside the frame by the width of its round stroke, which
            // is what softens the corners.
            let box = rect.insetBy(dx: 3.4, dy: 3.4)
            let w = box.width, h = box.height
            var path = Path()
            path.move(to: CGPoint(x: box.minX + w * 0.5, y: box.minY))
            path.addLine(to: CGPoint(x: box.minX + w, y: box.minY + h))
            path.addLine(to: CGPoint(x: box.minX + w * 0.5, y: box.minY + h * 0.76))
            path.addLine(to: CGPoint(x: box.minX, y: box.minY + h))
            path.closeSubpath()
            return path
        }
    }
}
