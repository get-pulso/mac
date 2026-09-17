import SwiftUI

/// What a chapter says on its left: a tag, a title, a line, and — where the
/// chapter shows rather than asks — the rows its right side walks through.
struct OnboardingChapterCopy {
    struct Row: Identifiable {
        let symbol: String
        let title: String
        let detail: String

        var id: String { self.title }
    }

    let tag: String
    let symbol: String
    let title: String
    let subtitle: String
    var rows: [Row] = []

    static func copy(for step: OnboardingStage.Step) -> OnboardingChapterCopy? {
        switch step {
        case .day:
            .init(
                tag: "Your day", symbol: "OnboardingDay", title: "See where the day goes",
                subtitle: "Firstlight keeps time while you work.",
                rows: [
                    .init(
                        symbol: "OnboardingGrid", title: "Time, apps and agents",
                        detail: "Your hours, your agents' and your apps. Never titles or prompts."
                    ),
                    .init(
                        symbol: "OnboardingAgents", title: "Agents, in detail",
                        detail: "Cost, streak, records, models and tools."
                    ),
                ]
            )
        case .friends:
            .init(
                tag: "Friends", symbol: "OnboardingFriends", title: "Work next to friends",
                subtitle: "A quiet list in your menu bar.",
                rows: [
                    .init(
                        symbol: "OnboardingFriends", title: "Live status",
                        detail: "Who's around, and what they're in."
                    ),
                    .init(
                        symbol: "OnboardingLeaderboard", title: "Groups and leaderboard",
                        detail: "A tab per circle, and a global ranking."
                    ),
                    .init(
                        symbol: "OnboardingBump", title: "Bumps",
                        detail: "A friend sees you're on a roll and says so."
                    ),
                ]
            )
        case .profile:
            .init(
                tag: "Your profile", symbol: "person.crop.circle", title: "This is you, to friends",
                subtitle: "Your row in their menu bar."
            )
        case .privacy:
            .init(
                tag: "Your privacy", symbol: "SettingsSharing", title: "Choose what friends see",
                subtitle: "Change it any time in Settings."
            )
        case .invite:
            .init(
                tag: "Your friends", symbol: "SettingsGroups", title: "Better with one friend",
                subtitle: "An empty list is no fun."
            )
        case .welcome,
             .handoff: nil
        }
    }
}

/// The frame every chapter shares, under the header that never moves: words
/// on the left, the thing itself on the right, and one footer that stays put
/// from the first chapter to the last. Only what differs between two
/// chapters leaves and arrives, and it leaves sideways: the words never
/// carry over from one chapter to the next, so the frame turns like a page
/// rather than scrolling. What does carry over — the popover of the showing
/// chapters, the row friends will see behind the two that ask — takes no
/// transition at all: it keeps its place and changes where it stands. The
/// footer's button keeps its place and morphs its label, and the dashes
/// slide rather than being redrawn.
struct OnboardingChaptersView: View {
    // MARK: Internal

    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let compact = size.width < 900 || size.height < 600
            let margin: CGFloat = compact ? 52 : 88
            let gap: CGFloat = compact ? 24 : 48
            let left: CGFloat = compact ? 250 : 340
            let step = self.stage.step
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: gap) {
                    ZStack(alignment: .topLeading) {
                        if let copy = OnboardingChapterCopy.copy(for: step) {
                            self.words(copy, step: step, compact: compact)
                                .id(step)
                                .transition(self.stage.turn(reduceMotion: self.reduceMotion))
                        }
                    }
                    .frame(width: left, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: step.rows > 0 ? .top : .center)

                    ZStack {
                        self.thing(for: step)
                            .id(Self.thingIdentity(step))
                            .transition(self.stage.turn(reduceMotion: self.reduceMotion))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, compact ? 84 : 100)
                .padding(.horizontal, margin)
                .padding(.bottom, 12)

                self.footer
                    .padding(.horizontal, margin - 16)
                    .padding(.bottom, compact ? 20 : 28)
            }
            .frame(width: size.width, height: size.height)
        }
        .foregroundStyle(.white)
        .animation(OnboardingStage.stepAnimation, value: self.stage.step)
        .onChange(of: self.stage.step, initial: true) { _, step in
            if step == .invite { self.flow.prepareInvite() }
        }
    }

    // MARK: Private

    @ObservedObject private var stage = OnboardingStage.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Profile and privacy share their right side: the row friends will see
    /// stays where it is between them and only changes what it says.
    private static func thingIdentity(_ step: OnboardingStage.Step) -> String {
        switch step {
        // The two showing chapters are one popover being used: it stays, and
        // moves between its own screens instead of leaving and coming back.
        case .day,
             .friends: "panel"
        case .profile,
             .privacy: "setup"
        default: "\(step)"
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            OnboardingGlassCircleButton(symbol: "chevron.left", action: self.flow.back)
            .opacity(self.flow.canGoBack ? 1 : 0)
            .disabled(!self.flow.canGoBack || self.flow.saving)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            .accessibilityLabel("Back")

            OnboardingProgressDashes(step: self.stage.step, row: self.stage.row) { self.flow.jump(to: $0) }

            Spacer(minLength: 12)

            if let error = self.flow.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .transition(.opacity)
            }

            Button("Close", action: self.flow.close)
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.5))
                .disabled(self.flow.saving)
                .help("Skip the rest and open Firstlight")

            OnboardingContinueButton(
                isLoading: self.flow.saving,
                loadingTitle: self.flow.buttonLoadingTitle,
                title: self.flow.buttonTitle,
                action: self.flow.next
            )
        }
        .animation(.easeOut(duration: 0.15), value: self.flow.error)
    }

    private func words(_ copy: OnboardingChapterCopy, step: OnboardingStage.Step, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                OnboardingGlyph(name: copy.symbol, size: 13)
                Text(copy.tag).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(copy.rows.isEmpty ? Color.white.opacity(0.7) : Color(red: 0.78, green: 0.72, blue: 1))
            .background(
                copy.rows.isEmpty ? Color.white.opacity(0.08) : Color.firstlight.opacity(0.22),
                in: Capsule()
            )
            Text(copy.title)
                .font(.system(size: compact ? 30 : 40, weight: .medium))
                .tracking(-1.0)
                .lineSpacing(-2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(copy.subtitle)
                .font(.system(size: compact ? 14 : 15))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if !copy.rows.isEmpty {
                OnboardingChapterRows(
                    rows: copy.rows, open: self.stage.row,
                    // A list is read at a glance; a profile takes a moment.
                    dwell: step == .friends ? 3 : 5,
                    onOpen: { self.stage.open(row: $0) },
                    onElapsed: {
                        // The clock opens the next row and stops at the last:
                        // leaving a chapter is the reader's decision.
                        if self.stage.row < copy.rows.count - 1 { self.stage.open(row: self.stage.row + 1) }
                    }
                )
                .padding(.top, 18)
                .padding(.leading, -12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thing(for step: OnboardingStage.Step) -> some View {
        switch step {
        case .day,
             .friends:
            OnboardingPanelPreview(
                flow: self.flow, step: step, row: self.stage.row,
                onOpen: { self.stage.open(row: $0) },
                onFinished: {
                    if self.stage.step == .friends, self.stage.row == OnboardingStage.Step.friends.rows - 1 {
                        self.flow.next()
                    }
                }
            )
        case .profile,
             .privacy: OnboardingSetupColumn(flow: self.flow, step: step)
        case .invite: OnboardingInviteColumn(flow: self.flow)
        case .welcome,
             .handoff: Color.clear
        }
    }
}

/// A round button on the system's glass, the way the panel's own Settings
/// button is; bordered where there is no glass to be had.
struct OnboardingGlassCircleButton: View {
    let symbol: String
    var size: CGFloat = 28
    var action: () -> Void

    var body: some View {
        let label = Image(systemName: self.symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: self.size, height: self.size)
        if #available(macOS 26.0, *) {
            Button(action: self.action) { label }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            Button(action: self.action) { label }
                .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}

/// A chapter's mark: one of the app's own drawn icons where there is one —
/// the chapters' set, or the one Settings uses for the same subject — and an
/// SF Symbol otherwise.
struct OnboardingGlyph: View {
    let name: String
    var size: CGFloat

    var body: some View {
        if NSImage(named: self.name) != nil {
            Image(self.name).renderingMode(.template).resizable().scaledToFit()
                .frame(width: self.size, height: self.size)
        } else {
            Image(systemName: self.name).font(.system(size: self.size * 0.8, weight: .medium))
        }
    }
}

/// One dash per chapter. The current one is longer, and a chapter with rows
/// fills its dash row by row, so a press of Continue that stays inside the
/// chapter still visibly moved something.
struct OnboardingProgressDashes: View {
    let step: OnboardingStage.Step
    let row: Int
    var onSelect: (OnboardingStage.Step) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingStage.Step.chapters, id: \.self) { chapter in
                let current = chapter == self.step
                let width: CGFloat = current ? (chapter.rows > 0 ? 42 : 28) : 12
                let filled: CGFloat = !current ? 0 :
                    chapter.rows > 0 ? width * CGFloat(self.row + 1) / CGFloat(chapter.rows) : width
                Capsule().fill(.white.opacity(0.18))
                    .frame(width: width, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.firstlight).frame(width: filled, height: 4)
                    }
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { self.onSelect(chapter) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((OnboardingStage.Step.chapters.firstIndex(of: self.step) ?? 0) + 1) of 5")
    }
}

/// The rows of a showing chapter. One is open; its surface is a single shape
/// that travels between the rows rather than one drawn per row. A thin line
/// along its foot is the clock that opens the next row; the pointer over the
/// rows holds it.
struct OnboardingChapterRows: View {
    // MARK: Internal

    let rows: [OnboardingChapterCopy.Row]
    let open: Int
    /// How long a row stays open before the clock opens the next.
    var dwell: Double = 5
    var onOpen: (Int) -> Void
    var onElapsed: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(self.rows.enumerated()), id: \.element.id) { index, row in
                let isOpen = index == self.open
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        OnboardingGlyph(name: row.symbol, size: 18)
                            .foregroundStyle(Color(red: 0.72, green: 0.65, blue: 1))
                            .frame(width: 20)
                        Text(row.title).font(.system(size: 14, weight: .medium))
                    }
                    if isOpen {
                        Text(row.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 30)
                            .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isOpen {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.07))
                            .overlay(alignment: .bottomLeading) {
                                if index < self.rows.count - 1 {
                                    GeometryReader { proxy in
                                        Rectangle().fill(.white.opacity(0.35))
                                            .frame(width: proxy.size.width * self.progress, height: 2)
                                            .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .matchedGeometryEffect(id: "open", in: self.surface)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { self.onOpen(index) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .onHover { self.hovering = $0 }
        .onChange(of: self.open, initial: true) { self.restart() }
        .onChange(of: self.hovering) { _, held in held ? self.hold() : self.resume() }
        .onDisappear { self.clock?.cancel() }
    }

    // MARK: Private

    @Namespace private var surface
    @State private var progress: CGFloat = 0
    @State private var hovering = false
    /// How much of the dwell had passed when the clock last started.
    @State private var banked: Double = 0
    @State private var startedAt = Date()
    @State private var clock: Task<Void, Never>?

    private func restart() {
        self.banked = 0
        self.set(progress: 0)
        if !self.hovering { self.resume() }
    }

    private func hold() {
        self.clock?.cancel()
        self.banked = min(self.dwell, self.banked + Date().timeIntervalSince(self.startedAt))
        self.set(progress: self.banked / self.dwell)
    }

    private func resume() {
        self.clock?.cancel()
        guard self.open < self.rows.count - 1 else { return }
        let left = max(self.dwell - self.banked, 0)
        self.startedAt = Date()
        withAnimation(.linear(duration: left)) { self.progress = 1 }
        self.clock = Task {
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            self.onElapsed()
        }
    }

    /// Without an animation, which also stops the one in flight where it is.
    private func set(progress: Double) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { self.progress = progress }
    }
}

/// The right side of a showing chapter: a quiet plate the popover stands on,
/// and the popover itself at its real width, scaled down only when the
/// window is too small to hold it.
struct OnboardingPreviewPlate<Content: View>: View {
    var width: CGFloat = NativeLayout.popoverWidth
    var height: CGFloat = 470
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, (proxy.size.width - 32) / self.width, (proxy.size.height - 32) / self.height)
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04))
                self.content()
                    .frame(width: self.width, height: self.height)
                    .scaleEffect(max(scale, 0.5))
            }
        }
    }
}

/// The popover the previews draw in: the app's own width and corner, dark
/// like the window around it, with the system font the panel uses.
struct OnboardingMockPopover<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        self.content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.13))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .environment(\.colorScheme, .dark)
            .foregroundStyle(.primary)
    }
}
