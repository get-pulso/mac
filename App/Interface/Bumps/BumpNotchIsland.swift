import AppKit
import SwiftUI

/// What arrives while the popover is closed is said by the notch: a black
/// island grows out of it with a face and words, a ring round the face runs
/// down the time left, and the island goes back in. On a screen without a
/// notch it grows out of the top edge instead.
///
/// Three things are said this way, one island each. A bump, whose animated
/// emoji pops in on the right. A friend request, with Accept on the right,
/// because it waits on an answer; accepting there turns the island into a
/// confirmation. A new friend — a request of yours accepted, or somebody who
/// followed your link — with your own face arriving beside theirs and a
/// handshake. When several arrive together they are said in that order:
/// requests, new friends, bumps.
///
/// Clicking an island opens where it leads and quiets whatever was still to
/// be said, since the popover now shows it. Left alone, a bump still plays
/// when the popover opens, and a request still waits in it.
@MainActor
final class BumpNotchIsland {
    // MARK: Internal

    /// A face beside a name, for the person the island is about and for you.
    struct Face: Equatable {
        let name: String
        let avatarURL: String?
    }

    static let shared = BumpNotchIsland()

    /// How Accept reaches the server. A preview swaps in one that only waits.
    var acceptRequest: (_ requestID: String, _ requesterID: String) async throws -> Void = { requestID, requesterID in
        try await SocialStore.shared.acceptFromNotch(requestID: requestID, requesterID: requesterID)
    }

    /// The same for an invitation into a group.
    var acceptGroupInvitation: (_ invitationID: String) async throws -> Void = { invitationID in
        try await SocialStore.shared.acceptGroupInvitationFromNotch(invitationID)
    }

    /// Whose face joins a new friend's: yours, read as each island opens. A
    /// preview has no account to read it from.
    var me: () -> Face = {
        let account = NativeSession.shared.welcomeAccount
        return Face(name: account?.name ?? "You", avatarURL: account?.avatarURL)
    }

    /// Nothing on screen and nothing waiting to be.
    var isIdle: Bool { !self.presenting && self.queue.isEmpty }

    /// `bumps` newest first: one island says the newest and counts the rest.
    /// `friendEvents` in the order they are to be said, one island each.
    func show(_ bumps: [NativeBump], friendEvents: [NativeFriendEvent] = []) {
        var items = friendEvents.prefix(NativeFriendEvent.islandLimit).compactMap(Content.init(event:))
        if let bumps = Content(bumps: bumps) { items.append(bumps) }
        guard !items.isEmpty else { return }
        self.queue.append(contentsOf: items)
        if !self.presenting { self.presentNext() }
    }

    /// The popover opened, and what was still waiting to be said is on show
    /// there now. The island already out finishes on its own.
    func popoverOpened() {
        self.queue.removeAll()
    }

    #if DEBUG
    /// Accept, as if clicked, for a preview nobody is clicking in.
    func pressAccept() { self.accept() }
    #endif

    // MARK: Fileprivate

    /// Long enough to read the words and watch the emoji loop at least twice.
    fileprivate static let holdDuration = 6.5
    /// A request is a decision rather than a reaction: a little longer, to
    /// see who is asking.
    fileprivate static let requestHold = 8.0
    /// Once accepted, the island only confirms.
    fileprivate static let confirmationHold = 4.0

    fileprivate func open() {
        guard let content = self.model.content else { return }
        let accepted = self.model.acceptance == .accepted
        self.queue.removeAll()
        self.collapse()
        let store = SocialStore.shared
        switch content.kind {
        case .bump:
            // Seen here, so opening the popover must not play them again.
            BumpEffects.shared.markSeen(content.bumpIDs)
            store.showList()
            if let person = store.people.first(where: { $0.id == content.personID }) {
                store.openPerson(person)
            }
        case .request where content.group != nil:
            // Answered: the group itself. Not yet: where it is answered.
            if accepted, let group = content.group {
                store.openJoinedGroup(group.id)
            } else {
                store.openFriendEvent(
                    .groupInvite, personID: content.personID, name: content.name, avatarURL: content.avatarURL
                )
            }
        case .request,
             .newFriend:
            store.openFriendEvent(
                content.kind == .request && !accepted ? .request : .accepted,
                personID: content.personID,
                name: content.name,
                avatarURL: content.avatarURL
            )
        }
        WindowManager.liveValue.show()
    }

    /// The ring stops where it is while the pointer is on the island, and
    /// runs on from there once it leaves.
    fileprivate func hoverChanged(_ hovering: Bool) {
        guard self.model.expanded else { return }
        self.hovering = hovering
        // While Accept is on its way the ring stays stopped either way.
        guard self.model.acceptance != .sending else { return }
        if hovering {
            self.hideTask?.cancel()
            self.model.pausedFraction = self.model.remainingFraction(at: Date())
        } else {
            let remaining = (self.model.pausedFraction ?? 0) * self.model.hold
            self.model.pausedFraction = nil
            self.scheduleHide(after: max(remaining, 0.8))
        }
    }

    fileprivate func accept() {
        guard let content = self.model.content, content.kind == .request, let requestID = content.requestID,
              self.model.acceptance == .idle, self.model.expanded else { return }
        self.hideTask?.cancel()
        self.model.pausedFraction = self.model.remainingFraction(at: Date())
        withAnimation(.easeOut(duration: 0.15)) { self.model.acceptance = .sending }
        let send = self.acceptRequest
        let join = self.acceptGroupInvitation
        self.acceptTask = Task { [weak self] in
            do {
                if content.group != nil { try await join(requestID) } else {
                    try await send(requestID, content.personID)
                }
                // Clicked away meanwhile: the friendship stands, there is just
                // nobody left to tell.
                guard let self, self.model.content == content, self.model.expanded else { return }
                self.confirm(content)
            } catch {
                guard let self, self.model.content == content, self.model.expanded,
                      !(error is CancellationError) else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.model.acceptance = .failed }
                self.restartCountdown(hold: Self.confirmationHold)
            }
        }
    }

    // MARK: Private

    private let model = BumpNotchIslandModel()
    private var panel: NSPanel?
    private var queue: [Content] = []
    /// From an island's first frame until it has gone back in.
    private var presenting = false
    private var hideTask: Task<Void, Never>?
    private var emojiTask: Task<Void, Never>?
    private var pairTask: Task<Void, Never>?
    private var acceptTask: Task<Void, Never>?
    private var hovering = false

    /// The screen the menu bar lives on, preferring one with a notch.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func presentNext() {
        guard !self.queue.isEmpty else { return }
        let content = self.queue.removeFirst()
        guard let screen = Self.targetScreen() else {
            self.queue.removeAll()
            return
        }
        self.presenting = true
        let geometry = Geometry(screen: screen)
        let panel = self.panel ?? self.makePanel()
        panel.setFrame(geometry.panelFrame, display: false)
        self.hideTask?.cancel()
        self.emojiTask?.cancel()
        self.pairTask?.cancel()
        self.acceptTask?.cancel()
        self.model.geometry = geometry
        self.model.content = content
        self.model.me = self.me()
        self.model.hold = content.kind == .request ? Self.requestHold : Self.holdDuration
        self.model.pausedFraction = nil
        self.model.clip = nil
        self.model.emojiShown = false
        self.model.clipSettled = false
        self.model.paired = false
        self.model.acceptance = .idle
        self.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.orderFrontRegardless()

        // One runloop turn collapsed first, so the growth is animated even
        // when the panel was just created.
        DispatchQueue.main.async {
            withAnimation(self.model.growth) { self.model.expanded = true }
        }
        switch content.kind {
        case .bump:
            self.loadEmoji(content)
        case .newFriend:
            // Your face arrives a beat after the island, the handshake after it.
            self.pairTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                guard let self, self.model.content == content, self.model.expanded else { return }
                withAnimation(self.model.pop) { self.model.paired = true }
                self.loadEmoji(content)
            }
        case .request:
            break
        }
        self.scheduleHide(after: self.model.hold)
    }

    /// Accepted: your face arrives beside theirs, the handshake takes Accept's
    /// place, and from here the island only confirms.
    private func confirm(_ content: Content) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .drawCompleted)
        withAnimation(self.model.pop) {
            self.model.acceptance = .accepted
            self.model.paired = true
        }
        self.loadEmoji(content)
        self.restartCountdown(hold: Self.confirmationHold)
    }

    /// The ring starts over for `hold` seconds, or waits full while the
    /// pointer is still on the island.
    private func restartCountdown(hold: Double) {
        self.model.hold = hold
        if self.hovering {
            self.model.pausedFraction = 1
        } else {
            self.model.pausedFraction = nil
            self.scheduleHide(after: hold)
        }
    }

    /// The same pre-rendered Telegram frames the popover plays, decoded on
    /// their own so the popover's library keeps what it has prepared. Without
    /// a clip, an island that has a system emoji shows that instead; a bump
    /// that has neither keeps the emoji in its words.
    private func loadEmoji(_ content: Content) {
        self.emojiTask?.cancel()
        self.model.clip = nil
        let url = content.clip.flatMap {
            Bundle.main.url(forResource: $0, withExtension: "webp", subdirectory: "BumpEmoji")
        }
        self.emojiTask = Task { [weak self] in
            var clip: BumpEmojiClip?
            if let url {
                clip = await Task.detached(priority: .userInitiated) { BumpEmojiClip.load(url) }.value
            }
            guard let self, !Task.isCancelled, self.model.content == content,
                  clip != nil || content.glyph != nil else { return }
            self.model.clip = clip
            self.model.clipStart = Date()
            // A beat after the island opens, so the eye goes to the words first.
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard self.model.expanded else { return }
            withAnimation(self.model.pop) { self.model.emojiShown = true }
            // Held from its end, not looped. Reduce Motion is already holding
            // a single frame and has nothing to finish.
            guard content.clipPlaysOnce, let clip, !self.model.reduceMotion else { return }
            let remaining = clip.duration - Date().timeIntervalSince(self.model.clipStart)
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard self.model.content == content, self.model.expanded else { return }
            self.model.clipSettled = true
        }
    }

    private func scheduleHide(after delay: Double) {
        self.hideTask?.cancel()
        self.model.hideAt = Date().addingTimeInterval(delay)
        self.hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !self.hovering else { return }
            self.collapse()
        }
    }

    private func collapse() {
        self.hideTask?.cancel()
        self.emojiTask?.cancel()
        self.pairTask?.cancel()
        withAnimation(.easeIn(duration: 0.14)) { self.model.emojiShown = false }
        withAnimation(self.model.shrink) { self.model.expanded = false }
        self.hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(0.45)) } catch { return }
            guard let self, !self.model.expanded else { return }
            self.panel?.orderOut(nil)
            // A clip is ~15 MB of frames; nothing keeps it once the island is gone.
            self.model.clip = nil
            self.hovering = false
            self.presenting = false
            // The next island waits for this one to have gone in, and a breath.
            guard !self.queue.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !self.presenting else { return }
            self.presentNext()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Firstlight Bump"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        // Above the menu bar, so the island can start inside the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: BumpNotchIslandView(model: self.model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

// MARK: - Content

/// One island's worth of words.
private struct Content: Equatable {
    // MARK: Lifecycle

    init?(bumps: [NativeBump]) {
        guard let bump = bumps.first else { return nil }
        self.id = "bump-\(bump.id)"
        self.kind = .bump
        self.personID = bump.from.id
        self.name = bump.from.displayName
        self.message = bump.message
        self.avatarURL = bump.from.avatar_url
        self.more = bumps.count - 1
        self.clip = Self.clip(forBump: bump.kind)
        self.clipPlaysOnce = false
        self.glyph = nil
        self.requestID = nil
        self.group = nil
        self.bumpIDs = bumps.map(\.id)
    }

    init?(event: NativeFriendEvent) {
        guard let kind = event.knownKind else { return nil }
        self.id = "friend-\(event.id)"
        // An invitation into a group waits on the same answer a request does,
        // and is no news at all without the group it is to.
        if kind == .groupInvite, event.group == nil || event.group_invitation_id == nil { return nil }
        self.kind = kind.waitsOnAnswer ? .request : .newFriend
        self.personID = event.from.id
        self.name = event.from.displayName
        self.message = event.message
        self.avatarURL = event.from.avatar_url
        self.more = 0
        // The Telegram handshake, the one clip no bump effect asks for. The
        // system emoji is kept behind it for a decode that fails.
        self.clip = "handshake"
        // Hands meet once. Looped, they would come apart at the seam to shake
        // again, which reads as the deal coming undone.
        self.clipPlaysOnce = true
        self.glyph = "🤝"
        self.requestID = kind == .groupInvite ? event.group_invitation_id : event.request_id
        self.group = kind == .groupInvite ? event.group : nil
        self.bumpIDs = []
    }

    // MARK: Internal

    enum Kind: Equatable {
        case bump, request, newFriend
    }

    let id: String
    let kind: Kind
    let personID: String
    let name: String
    let message: String
    let avatarURL: String?
    /// Bumps beyond the one named.
    let more: Int
    /// A pre-rendered clip in BumpEmoji, when there is one.
    let clip: String?
    /// The clip runs through once and holds its last frame, rather than
    /// looping the way a reaction does.
    let clipPlaysOnce: Bool
    /// The system emoji shown when there is no clip.
    let glyph: String?
    let requestID: String?
    /// The group an invitation is to; nil for a friend request.
    let group: NativeFriendEvent.Group?
    let bumpIDs: [String]

    /// The words without their trailing emoji, for when the animated one is shown.
    var words: String {
        var scalars = Array(self.message.unicodeScalars)
        while let last = scalars.last,
              last.properties.isWhitespace || last.value == 0xFE0F || last.value == 0x200D
              || last.properties.isEmojiModifier || (last.properties.isEmoji && last.value > 0x238C)
        {
            scalars.removeLast()
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let trimmed = String(view)
        return trimmed.isEmpty ? self.message : trimmed
    }

    // MARK: Private

    /// Which animated emoji says a bump's kind.
    private static func clip(forBump kind: String) -> String {
        switch kind {
        case "on_fire": "fire"
        case "hard_worker": "muscle"
        case "keep_going": "star"
        case "respect": "thumb"
        case "touch_grass": "seedling"
        default: "clap"
        }
    }
}

// MARK: - Geometry

private struct Geometry: Equatable {
    // MARK: Lifecycle

    init(screen: NSScreen) {
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            self.collapsed = CGSize(width: frame.width - left.width - right.width, height: notchHeight)
        } else {
            // No notch: grow out of the top edge from nothing.
            self.collapsed = CGSize(width: 140, height: 0)
        }
        self.topInset = max(notchHeight, 6)
        self.expanded = CGSize(width: max(self.collapsed.width + 170, 400), height: self.topInset + 62)
        self.panelFrame = CGRect(
            x: frame.midX - self.expanded.width / 2 - Self.margin,
            y: frame.maxY - self.expanded.height - Self.margin,
            width: self.expanded.width + Self.margin * 2,
            height: self.expanded.height + Self.margin
        )
    }

    init() {
        self.collapsed = CGSize(width: 180, height: 32)
        self.expanded = CGSize(width: 400, height: 94)
        self.topInset = 32
        self.panelFrame = .zero
    }

    // MARK: Internal

    /// Room for the spring to overshoot without clipping.
    static let margin: CGFloat = 12

    let collapsed: CGSize
    let expanded: CGSize
    /// The part of the island hidden by the notch; content sits below it.
    let topInset: CGFloat
    let panelFrame: CGRect
}

// MARK: - Model

@MainActor
private final class BumpNotchIslandModel: ObservableObject {
    enum Acceptance: Equatable {
        case idle, sending, accepted, failed
    }

    @Published var expanded = false
    @Published var content: Content?
    @Published var geometry = Geometry()
    @Published var hideAt = Date()
    /// How long this island stays, for the ring to run down against.
    @Published var hold = BumpNotchIsland.holdDuration
    /// Set while the pointer holds the island open.
    @Published var pausedFraction: Double?
    @Published var clip: BumpEmojiClip?
    @Published var emojiShown = false
    /// A play-once clip has reached its end: the last frame is held and the
    /// 60 fps timeline stops rather than ticking on over a still image.
    @Published var clipSettled = false
    /// Your face beside a new friend's.
    @Published var paired = false
    @Published var acceptance = Acceptance.idle
    @Published var me = BumpNotchIsland.Face(name: "", avatarURL: nil)
    var clipStart = Date()
    var reduceMotion = false

    var growth: Animation { self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.3) }
    var shrink: Animation { self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.38, bounce: 0) }
    /// A small thing landing: the emoji, and your face beside a friend's.
    var pop: Animation { self.reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.55, bounce: 0.45) }

    func remainingFraction(at date: Date) -> Double {
        if let pausedFraction { return pausedFraction }
        return min(1, max(0, self.hideAt.timeIntervalSince(date) / self.hold))
    }
}

// MARK: - View

private struct BumpNotchIslandView: View {
    // MARK: Internal

    @ObservedObject var model: BumpNotchIslandModel

    var body: some View {
        let geometry = self.model.geometry
        let size = self.model.expanded ? geometry.expanded : geometry.collapsed
        let radius: CGFloat = self.model.expanded ? 24 : 10
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                    .fill(.black)
                if let content = self.model.content {
                    self.row(content)
                        .padding(.top, geometry.topInset + 9)
                        .padding(.leading, 16).padding(.trailing, 12)
                        .opacity(self.model.expanded ? 1 : 0)
                        .blur(radius: self.model.expanded || self.model.reduceMotion ? 0 : 6)
                        .animation(
                            self.model.expanded ? self.model.growth.delay(0.08) : .easeOut(duration: 0.12),
                            value: self.model.expanded
                        )
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onTapGesture { BumpNotchIsland.shared.open() }
            .onHover { BumpNotchIsland.shared.hoverChanged($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // The panel never becomes key, and a control in a window that is not
        // key is drawn inactive: Accept would sit there grey instead of lit.
        .environment(\.controlActiveState, .key)
        // A request keeps Accept its own element; the others read as one button.
        .accessibilityElement(children: self.model.content?.kind == .request ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Private

    /// A wave of the handshake: a shake and a settle, then a rest.
    private struct Shake {
        var angle = 0.0
        var lift = 0.0
    }

    /// How long the island stays: a hairline ring round the face — round both
    /// faces once there are two — that runs down clockwise from the top.
    private var countdown: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: self.model.pausedFraction != nil)) { context in
            ZStack {
                IslandRing().stroke(.white.opacity(0.12), lineWidth: 1.5)
                IslandRing()
                    .trim(from: 0, to: self.model.remainingFraction(at: context.date))
                    .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var emojiArt: some View {
        if let clip = self.model.clip {
            // Run out, and the clip stays where it ended: `frame(at:)` would
            // wrap a whole duration back round to the first frame.
            if self.model.clipSettled, let settled = clip.frames.last {
                Image(decorative: settled, scale: 1).resizable().interpolation(.high).scaledToFit()
            } else {
                let paused = !self.model.emojiShown || self.model.reduceMotion
                TimelineView(.animation(minimumInterval: 1 / 60, paused: paused)) { context in
                    // Reduce Motion holds one full-bodied frame instead of looping.
                    let time = self.model.reduceMotion
                        ? clip.duration * 0.5
                        : context.date.timeIntervalSince(self.model.clipStart)
                    if let frame = clip.frame(at: time) {
                        Image(decorative: frame, scale: 1).resizable().interpolation(.high).scaledToFit()
                    }
                }
            }
        } else if let glyph = self.model.content?.glyph {
            if self.model.reduceMotion {
                Text(verbatim: glyph).font(.system(size: 34))
            } else {
                Text(verbatim: glyph).font(.system(size: 34))
                    .keyframeAnimator(initialValue: Shake(), repeating: true) { view, shake in
                        view
                            .rotationEffect(.degrees(shake.angle), anchor: UnitPoint(x: 0.5, y: 0.6))
                            .offset(y: shake.lift)
                    } keyframes: { _ in
                        KeyframeTrack(\.angle) {
                            CubicKeyframe(-8, duration: 0.18)
                            CubicKeyframe(7, duration: 0.18)
                            CubicKeyframe(-4, duration: 0.18)
                            CubicKeyframe(2, duration: 0.18)
                            CubicKeyframe(0, duration: 0.14)
                            LinearKeyframe(0, duration: 0.94)
                        }
                        KeyframeTrack(\.lift) {
                            CubicKeyframe(-2, duration: 0.18)
                            CubicKeyframe(1, duration: 0.18)
                            CubicKeyframe(-1, duration: 0.18)
                            CubicKeyframe(0, duration: 0.32)
                            LinearKeyframe(0, duration: 0.94)
                        }
                    }
            }
        }
    }

    private var emoji: some View {
        self.emojiArt
            .scaleEffect(self.model.emojiShown ? 1 : 0.2)
            .rotationEffect(.degrees(self.model.emojiShown || self.model.reduceMotion ? 0 : -25))
            .opacity(self.model.emojiShown ? 1 : 0)
            .accessibilityHidden(true)
    }

    private func row(_ content: Content) -> some View {
        HStack(spacing: 10) {
            self.faces(content)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(self.words(content))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            self.trailing(content)
        }
    }

    private func words(_ content: Content) -> String {
        switch content.kind {
        case .bump:
            let words = self.model.clip != nil ? content.words : content.message
            return content.more > 0 ? "\(words) · and \(content.more) more" : words
        case .request where self.model.acceptance == .accepted:
            return content.group.map { "you joined \($0.name)" } ?? "you’re friends now"
        case .request where self.model.acceptance == .failed:
            return "Couldn’t accept. Open it in Firstlight"
        case .request,
             .newFriend:
            return content.message
        }
    }

    /// Their face, and yours arriving beside it once you are friends, with the
    /// ring widening round the two of you.
    private func faces(_ content: Content) -> some View {
        let paired = self.model.paired
        let width: CGFloat = paired ? 54 : 32
        return ZStack(alignment: .leading) {
            if content.kind != .bump {
                FirstlightAvatar(url: self.model.me.avatarURL, name: self.model.me.name, size: 32)
                    .opacity(paired ? 1 : 0)
                    .offset(x: paired || self.model.reduceMotion ? 0 : -12)
            }
            FirstlightAvatar(url: content.avatarURL, name: content.name, size: 32)
                // A hairline of the island between the two faces.
                .background { Circle().fill(.black).padding(-2) }
                .offset(x: paired ? 22 : 0)
        }
        .frame(width: width, height: 32, alignment: .leading)
        .overlay(alignment: .leading) {
            self.countdown
                .frame(width: width + 6, height: 38)
                .offset(x: -3)
        }
    }

    private func trailing(_ content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if content.kind == .request, self.model.acceptance == .idle || self.model.acceptance == .sending {
                self.acceptButton(content)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            self.emoji.frame(width: 46, height: 46)
        }
        .frame(height: 46)
    }

    /// A stock prominent capsule in the Firstlight tint. Not the glass the
    /// popover wears: in a panel that is never key, glass drops its tint even
    /// with the active state forced, and only the bordered style keeps it.
    /// The label keeps its width while the request is on its way.
    private func acceptButton(_ content: Content) -> some View {
        let sending = self.model.acceptance == .sending
        return Button { BumpNotchIsland.shared.accept() } label: {
            NativeLoadingSwap(isLoading: sending, spinner: .mini) { Text("Accept") }
                .font(.system(size: 13, weight: .medium))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(.firstlight)
        .allowsHitTesting(!sending)
        .accessibilityLabel(sending ? "Accepting \(content.name)" : "Accept \(content.name)")
    }
}

// MARK: - Ring

/// A capsule traced clockwise from the middle of its top edge. As wide as it
/// is tall it is a circle, so one ring serves a single face and a pair, and
/// widens from one into the other.
private struct IslandRing: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.midY),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
