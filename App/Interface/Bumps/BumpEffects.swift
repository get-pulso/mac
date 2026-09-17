import AppKit
import Defaults
import os
import SwiftUI

struct BumpEffectRun: Identifiable {
    let id = UUID()
    let effect: BumpEffect
    let started = Date()
    let reduced: Bool
    let slow: Bool
    var incoming = false
    var frozenTime: Double?

    var duration: Double { self.reduced ? 1.2 : self.effect.duration }

    func elapsed(at date: Date = Date()) -> Double {
        self.frozenTime ?? date.timeIntervalSince(self.started) / (self.slow ? 3 : 1)
    }
}

@MainActor final class BumpEffects: ObservableObject {
    // MARK: Internal

    static let shared = BumpEffects()

    @Published private(set) var run: BumpEffectRun?
    @Published private(set) var sending = false
    @Published private(set) var sendingTo: String?
    @Published private(set) var sent: [String: BumpSentReceipt] = [:]
    @Published private(set) var incoming: BumpReceivedMoment?
    @Published private(set) var recent: [BumpReceivedMoment] = []
    @Published private(set) var unreadCount = 0
    @Published private(set) var states: [String: NativeBumpState] = [:]
    @Published private(set) var stateLoading = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published var avatarFrame = CGRect(x: 137, y: 40, width: 76, height: 76)
    @Published var buttonFrame = CGRect(x: 240, y: 354, width: 98, height: 39)
    @Published var emojiBurst = true
    @Published var trayOpen = false
    @Published var reduceMotion = false
    @Published var slowMotion = false
    @Published var hapticsEnabled = true
    @Published var rendererFailure: String?
    private(set) var visible = false

    var emissionOrigin: CGPoint {
        self.incoming == nil ? CGPoint(x: self.buttonFrame.midX, y: self.buttonFrame.midY) : CGPoint(x: 175, y: 143)
    }

    func activateAccount(_ id: String?) {
        guard self.account != id else { return }
        self.stop(); self.sendTask?.cancel(); self.sendTask = nil; self.sending = false; self.sendingTo = nil
        self.echoTasks.values.forEach { $0.cancel() }; self.echoTasks = [:]
        self.testJournal = BumpJournal(); self.optimisticSent = [:]
        self.states = [:]; self.errors = [:]; self.stateLoading = []; self.queue = []
        self.account = id; self.stateRevision = [:]; self.journal = BumpJournal(); self.journalFile = nil
        if let id, let file = try? BumpJournal.file(for: id) {
            self.journalFile = file
            // A damaged cache is never acknowledged as if it were recovered.
            self.journal = (try? BumpJournal.load(from: file)) ?? BumpJournal()
        }
        self.publishJournal()
    }

    func setVisible(_ value: Bool) {
        self.visible = value
        if !value { self.stop(); self.trayOpen = false; self.queue = [] }
        else { self.enqueuePending() }
    }

    func ingest(_ bumps: [NativeBump]) throws -> [BumpReceivedMoment] {
        guard self.account == Defaults[.currentUserID], let journalFile else { throw CancellationError() }
        var next = self.journal
        let fresh = next.ingest(bumps.map(BumpReceivedMoment.init))
        try next.save(to: journalFile)
        self.journal = next; self.publishJournal()
        return fresh
    }

    func enqueue(_ moments: [BumpReceivedMoment]) {
        guard self.visible else { return }
        for moment in moments.sorted(by: { $0.receivedAt < $1.receivedAt })
            where self.incoming?.id != moment.id && self.preparingIncomingID != moment.id && !self.queue
            .contains(where: { $0.id == moment.id })
        {
            queue.append(moment)
        }
        self.playNext()
    }

    /// Seen somewhere else, the notch island: nothing left to play for them.
    func markSeen(_ ids: some Sequence<String>) {
        let ids = Set(ids)
        guard !ids.isEmpty else { return }
        self.queue.removeAll { ids.contains($0.id) }
        self.journal.unread.subtract(ids); self.testJournal.unread.subtract(ids)
        self.persistJournal()
    }

    func enqueuePending() {
        self
            .enqueue(
                self.recent
                    .filter { self.journal.unread.contains($0.id) || self.testJournal.unread.contains($0.id) }
            )
    }

    func loadState(for id: String) async {
        guard !self.stateLoading.contains(id), self.sendingTo != id,
              let user = account else { return }
        self.stateLoading.insert(id)
        let revision = self.stateRevision[id, default: 0]
        defer { if account == user { stateLoading.remove(id) } }
        do {
            let state = try await Network.liveValue.bumpState(for: id)
            guard self.account == user, self.stateRevision[id, default: 0] == revision else { return }
            self.states[id] = state; self.errors[id] = nil
            if let raw = state.next_allowed_at, let date = BumpJournal.timestamp(raw) {
                self.journal.sent[id] = BumpSentReceipt(
                    effect: .forKind(state.last_kind ?? "good_job"),
                    nextAllowedAt: date,
                    daily: state.daily_limited == true
                )
            } else { self.journal.sent.removeValue(forKey: id) }
            self.persistJournal()
        } catch {
            guard self.account == user, self.stateRevision[id, default: 0] == revision,
                  !(error is CancellationError) else { return }
            self.errors[id] = "Couldn’t check bumps. Try again."
        }
    }

    func canSend(to person: NativePerson) -> Bool {
        guard person.id != Defaults[.currentUserID] else { return false }
        return self.states[person.id]?.can_send == true
    }

    func schedule(_ effect: BumpEffect, systemReduced: Bool) {
        guard let person = SocialStore.shared.selectedPerson else { return }
        self.send(effect, to: person, systemReduced: systemReduced)
    }

    func send(_ effect: BumpEffect, to person: NativePerson, systemReduced: Bool) {
        let recipientID = person.id
        guard !self.sending else { return }
        guard self.account != nil, self.account == Defaults[.currentUserID],
              recipientID != Defaults[.currentUserID] else { return }
        if let receipt = sent[recipientID], receipt.nextAllowedAt > Date() { return }
        self.stop(); self.trayOpen = false
        self.errors[recipientID] = nil
        // A GET started before this POST must not erase its confirmed cooldown.
        self.stateRevision[recipientID, default: 0] += 1
        let user = self.account
        let ready = Date().addingTimeInterval(BumpLocalTestMode.isEnabled ? BumpLocalTestMode.cooldown : 1800)

        if BumpLocalTestMode.isEnabled, let user {
            self.testJournal.sent[recipientID] = BumpSentReceipt(effect: effect, nextAllowedAt: ready)
            self.publishJournal()
            self.play(effect, systemReduced: systemReduced)
            self.scheduleTestEcho(effect, from: person, account: user)
            return
        }

        // Pending receipts are memory-only; a failed request never persists a fake success.
        self.sending = true; self.sendingTo = recipientID
        self.optimisticSent[recipientID] = BumpSentReceipt(effect: effect, nextAllowedAt: ready)
        self.publishJournal()
        self.play(effect, systemReduced: systemReduced)
        let optimisticRunID = self.run?.id
        self.sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.account == user {
                    self.optimisticSent.removeValue(forKey: recipientID); self.publishJournal()
                    self.sending = false; self.sendingTo = nil; self.playNext()
                }
            }
            do {
                guard user != nil, user == Defaults[.currentUserID] else { throw CancellationError() }
                let result = try await Network.liveValue.sendBump(to: recipientID, kind: effect.rawValue)
                guard let raw = result.next_allowed_at, let ready = BumpJournal.timestamp(raw) else {
                    throw NativeError.message("Bump sent. Reopen this profile to check its status.")
                }
                guard !Task.isCancelled, self.account == user else { return }
                self.journal.sent[recipientID] = BumpSentReceipt(effect: effect, nextAllowedAt: ready)
                self.persistJournal()
            } catch {
                guard self.account == user, !(error is CancellationError) else { return }
                if self.run?.id == optimisticRunID { self.stop() }
                if case let NativeError.rateLimited(message, seconds, daily) = error {
                    self.journal
                        .sent[recipientID] = BumpSentReceipt(
                            effect: effect,
                            nextAllowedAt: Date().addingTimeInterval(Double(seconds)),
                            daily: daily
                        )
                    self.persistJournal(); self.errors[recipientID] = message
                } else { self.errors[recipientID] = error.localizedDescription }
            }
        }
    }

    func play(_ effect: BumpEffect, systemReduced: Bool, frozenTime: Double? = nil) {
        self.stop()
        // Light, motion and haptics start on this click; artwork decodes concurrently.
        self.begin(effect, systemReduced: systemReduced, frozenTime: frozenTime, received: nil)
        self.pending = Task { [weak self] in
            await BumpEmojiLibrary.shared.prepare(effect)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.playNext()
        }
    }

    func ingestTestBump(_ bump: NativeBump) -> [BumpReceivedMoment] {
        guard BumpLocalTestMode.isEnabled else { return [] }
        let fresh = self.testJournal.ingest([BumpReceivedMoment(bump)])
        self.publishJournal()
        return fresh
    }

    func receive(_ moment: BumpReceivedMoment, systemReduced: Bool, replay: Bool = false, frozenTime: Double? = nil) {
        self.stop(); self.trayOpen = false
        self.queue.removeAll { $0.id == moment.id }
        self.preparingIncomingID = moment.id
        self.pending = Task { [weak self] in
            await BumpEmojiLibrary.shared.prepare(moment.effect)
            guard let self, !Task.isCancelled else { return }
            self.begin(moment.effect, systemReduced: systemReduced, frozenTime: frozenTime, received: moment)
        }
    }

    /// Visual cancellation never cancels a send already accepted by the server.
    func stop() {
        self.pending?.cancel(); self.pending = nil; self.completion?.cancel(); self.arrivalCompletion?.cancel()
        self.haptics.stop(); self.run = nil; self.preparingIncomingID = nil
        withAnimation(.easeOut(duration: 0.18)) { incoming = nil }
    }

    func dismissIncoming() { self.stop(); self.playNext() }

    // MARK: Private

    private var account: String?
    private var stateRevision: [String: Int] = [:]
    private var journal = BumpJournal()
    private var testJournal = BumpJournal()
    private var optimisticSent: [String: BumpSentReceipt] = [:]
    private var echoTasks: [UUID: Task<Void, Never>] = [:]
    private var journalFile: URL?
    private var queue: [BumpReceivedMoment] = []
    private var preparingIncomingID: String?
    private let haptics = BumpHaptics()
    private var sendTask: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var completion: Task<Void, Never>?
    private var arrivalCompletion: Task<Void, Never>?

    private func publishJournal() {
        self.recent = (self.journal.recent + self.testJournal.recent).sorted { $0.receivedAt > $1.receivedAt }
        let confirmed = BumpLocalTestMode.isEnabled ? self.testJournal.sent : self
            .journal.sent
        self.sent = confirmed.merging(self.optimisticSent) { _, pending in pending }
        self.unreadCount = self.journal.unread.count + self.testJournal.unread.count
    }

    private func scheduleTestEcho(_ effect: BumpEffect, from person: NativePerson, account: String) {
        guard BumpLocalTestMode.isEnabled else { return }
        let token = UUID()
        self.echoTasks[token] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(BumpLocalTestMode.echoDelay)) } catch { return }
            guard let self, self.account == account, Defaults[.currentUserID] == account else { return }
            defer { self.echoTasks.removeValue(forKey: token) }
            let bump = NativeBump(
                id: "local-test-\(token.uuidString)", kind: effect.rawValue,
                message: "says \(effect.title.lowercased())",
                created_at: ISO8601DateFormatter().string(from: Date()),
                from: .init(id: person.id, name: person.displayName, avatar_url: person.avatar_url)
            )
            await BumpCenter.liveValue.receiveTestBump(bump, account: account)
        }
    }

    private func persistJournal() {
        if let journalFile { try? self.journal.save(to: journalFile) }
        self.publishJournal()
    }

    private func playNext() {
        guard self.visible, !self.sending, self.run == nil, self.incoming == nil, self.pending == nil,
              !self.queue.isEmpty else { return }
        self.receive(
            self.queue.removeFirst(),
            systemReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            replay: true
        )
    }

    private func begin(_ effect: BumpEffect, systemReduced: Bool, frozenTime: Double?, received: BumpReceivedMoment?) {
        self.pending = nil; self.trayOpen = false
        if let received {
            self.journal.unread.remove(received.id); self.testJournal.unread.remove(received.id)
            self.persistJournal()
        }
        #if DEBUG
        if CommandLine.arguments.contains("--bump-diagnostics") {
            os_log(
                "playback kind=%{public}@ direction=%{public}@ id=%{public}@",
                log: OSLog(subsystem: "sh.firstlight.mac", category: "bump-e2e"),
                type: .default,
                effect.rawValue,
                received == nil ? "outgoing" : "incoming",
                received?.id ?? "sent"
            )
            NSLog(
                "FirstlightBumpPlayback kind=%@ direction=%@ id=%@",
                effect.rawValue,
                received == nil ? "outgoing" : "incoming",
                received?.id ?? "sent"
            )
        }
        #endif
        let next = BumpEffectRun(
            effect: effect,
            reduced: reduceMotion || systemReduced,
            slow: self.slowMotion,
            incoming: received != nil,
            frozenTime: frozenTime
        )
        withAnimation(.easeOut(duration: 0.2)) { incoming = received }
        self.run = next
        self.preparingIncomingID = nil
        guard frozenTime == nil else { return }
        if self.hapticsEnabled { self.haptics.play(next) }
        self.completion = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(next.duration * (next.slow ? 3 : 1))) } catch { return }
            guard self?.run?.id == next.id else { return }
            self?.run = nil
            if received == nil { self?.playNext() }
        }
        if let received {
            self.arrivalCompletion = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4.2 * (next.slow ? 3 : 1))) } catch { return }
                guard self?.incoming?.id == received.id else { return }
                withAnimation(.easeOut(duration: 0.3)) { self?.incoming = nil }
                self?.playNext()
            }
        }
    }
}

private struct BumpAvatarFrame: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

private struct BumpButtonFrame: PreferenceKey {
    static var defaultValue: CGRect { .zero }

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

private struct BumpPhysicalResponse: ViewModifier {
    // MARK: Internal

    var avatar: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(
            minimumInterval: 1 / 60,
            paused: self.effects.run == nil || self.effects.run?.frozenTime != nil
        )) { clock in
            let motion = effects.run.map {
                BumpEffectMotion.sample($0.effect, at: $0.elapsed(at: clock.date), reduced: $0.reduced)
            } ?? BumpEffectMotion()
            content
                .scaleEffect(x: avatar ? motion.scaleX : 1, y: avatar ? motion.scaleY : 1)
                .rotationEffect(.degrees(avatar ? motion.rotation : 0))
                .offset(x: avatar ? motion.x : 0, y: avatar ? motion.y : motion.cardY)
        }
    }

    // MARK: Private

    @ObservedObject private var effects = BumpEffects.shared
}

extension View {
    @ViewBuilder func bumpAvatarResponse() -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: BumpAvatarFrame.self, value: geometry.frame(in: .named("bumpSurface")))
        })
        .modifier(BumpPhysicalResponse(avatar: true))
    }

    @ViewBuilder func bumpCardResponse() -> some View {
        modifier(BumpPhysicalResponse(avatar: false))
    }

    func bumpSurface() -> some View { modifier(BumpSurface()) }
}

private struct BumpSurface: ViewModifier {
    // MARK: Internal

    func body(content: Content) -> some View {
        content
            .blur(radius: self.effects.incoming == nil ? 0 : 3)
            .opacity(self.effects.incoming == nil ? 1 : 0.30)
            .allowsHitTesting(self.effects.incoming == nil)
            .onPreferenceChange(BumpAvatarFrame.self) { frame in
                if frame.width > 0, effects.avatarFrame != frame { effects.avatarFrame = frame }
            }
            .onPreferenceChange(BumpButtonFrame.self) { frame in
                if frame.width > 0, effects.buttonFrame != frame { effects.buttonFrame = frame }
            }
            .overlay {
                if effects.incoming != nil {
                    Rectangle().fill(.ultraThinMaterial).opacity(0.66).allowsHitTesting(false)
                }
            }
            .overlay {
                BumpMetalSurface(
                    run: effects.run,
                    avatar: effects.incoming == nil ? effects.avatarFrame : CGRect(
                        x: 137,
                        y: 105,
                        width: 76,
                        height: 76
                    ),
                    origin: effects.emissionOrigin,
                    emojiBurst: effects.emojiBurst,
                    dark: scheme == .dark
                ) {
                    effects.rendererFailure = $0
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) { controls }
            .overlay {
                if effects.emojiBurst { BumpEmojiBurst(run: effects.run, origin: effects.emissionOrigin) }
            }
            .overlay {
                if let incoming = effects.incoming {
                    BumpArrivalView(moment: incoming).transition(.opacity)
                }
            }
            .coordinateSpace(name: "bumpSurface")
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onDisappear { effects.stop() }
            .task(id: self.store.screen) {
                effects.trayOpen = false
                if case let .person(id) = store.screen { await effects.loadState(for: id) }
            }
            .onReceive(WindowManager.liveValue.isVisiblePublisher.removeDuplicates().dropFirst()) { visible in
                if visible, case let .person(id) = store.screen {
                    Task { await effects.loadState(for: id) }
                }
            }
            .onChange(of: self.systemReduced) { _, enabled in if enabled { effects.stop() } }
            .onChange(of: self.effects.reduceMotion) { _, _ in effects.stop() }
            .onChange(of: self.effects.emojiBurst) { _, _ in effects.stop() }
            .onChange(of: self.effects.hapticsEnabled) { _, enabled in if !enabled { effects.stop() } }
    }

    // MARK: Private

    @ObservedObject private var effects = BumpEffects.shared
    @ObservedObject private var store = SocialStore.shared
    @ObservedObject private var artwork = BumpEmojiLibrary.shared
    @Namespace private var trayMorph
    @State private var trayGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    @Environment(\.colorScheme) private var scheme

    private var controls: some View {
        ZStack(alignment: .bottomTrailing) {
            if effects.trayOpen {
                Color(nsColor: .windowBackgroundColor).opacity(0.64)
                    .onTapGesture { closeTray() }
                    .accessibilityLabel("Dismiss bump choices")
                    .transition(.opacity.animation(.easeOut(duration: 0.14)))
            }
            NativeTrayMorphContainer {
                ZStack(alignment: .bottomTrailing) {
                    if case .person = store.screen, let person = store.selectedPerson,
                       effects.canSend(to: person), store.tray == nil, effects.incoming == nil
                    {
                        outgoingControls
                    }
                    if effects.trayOpen {
                        tray.padding(8)
                            .transition(.opacity)
                    }
                }
            }
            // Rebuilt once the tray has folded back into the button: the
            // glass container keeps the tray's footprint after it closes
            // and swallows the wheel over that part of the profile.
            .id(trayGeneration)
        }
        .onChange(of: effects.trayOpen) { _, open in
            guard !open else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                if !effects.trayOpen { trayGeneration += 1 }
            }
        }
        .transaction { if effects.reduceMotion { $0.disablesAnimations = true } }
        .animation(
            NativeTrayMorph.animation(
                isExpanded: effects.trayOpen,
                reduceMotion: systemReduced || effects.reduceMotion
            ),
            value: effects.trayOpen
        )
    }

    private var buttonMorph: NativeTrayMorph {
        NativeTrayMorph(id: "bump", namespace: self.trayMorph, isExpanded: self.effects.trayOpen)
    }

    private var outgoingControls: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            let receipt = effects.sent[store.selectedPerson?.id ?? ""]
            let cooling = receipt.map { $0.nextAllowedAt > clock.date } ?? false
            let seconds = max(1, Int(ceil(receipt?.nextAllowedAt.timeIntervalSince(clock.date) ?? 0)))
            let minutes = Int(ceil(Double(seconds) / 60))
            let remaining = seconds < 60 ? "\(seconds)s" : minutes >= 60 ? "\(Int(ceil(Double(minutes) / 60)))h" :
                "\(minutes)m"
            let cooldownTitle = "Next bump in \(remaining)"
            let accessibleCountdown = "Next bump in " + (seconds < 60 ? "\(seconds) seconds" : "\(minutes) minutes")
            VStack(alignment: .trailing, spacing: 6) {
                if !cooling, let error = effects.errors[store.selectedPerson?.id ?? ""] {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 230, alignment: .trailing)
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                NativeTrayMorphButton(morph: self.buttonMorph) {
                    effects.stop()
                    effects.trayOpen = true
                } label: {
                    ZStack {
                        // Hugs its label like Invite. Only a countdown reserves
                        // its widest form, so ticking digits never shift the capsule.
                        if cooling {
                            ForEach(["Next bump in 59s", "Next bump in 59m", "Next bump in 24h"], id: \.self) { title in
                                Text(title).hidden().accessibilityHidden(true)
                            }
                        }
                        HStack(spacing: 5) {
                            if !cooling { bumpIcon }
                            // Only the digit that changed rolls; the words
                            // around it hold still.
                            Text(cooling ? cooldownTitle : "Bump")
                                .contentTransition(cooling ? .numericText(countsDown: true) : .identity)
                                .animation(
                                    cooling ? .snappy(duration: 0.22, extraBounce: 0) : nil,
                                    value: cooldownTitle
                                )
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minHeight: 22)
                }
                .disabled(effects.sending || cooling)
                .help(cooling ? accessibleCountdown : "Send a little encouragement")
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: BumpButtonFrame.self, value: geometry.frame(in: .named("bumpSurface")))
                })
                .accessibilityLabel(
                    cooling ? accessibleCountdown : "Choose a bump effect"
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12).padding(.bottom, 12)
        }
    }

    private var bumpIcon: some View {
        Image("Bump").renderingMode(.template).resizable().scaledToFit()
            .frame(width: 16, height: 16).accessibilityHidden(true)
    }

    /// The same header as the invite tray: one round glass control, then one
    /// title. A popover over the profile, not a page in it, so the button is
    /// a bare chevron with no destination named.
    private var trayHeader: some View {
        HStack(spacing: 10) {
            BumpGlassButton(prominent: false, circular: true, action: closeTray) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 22)
            }
            .help("Back")
            .accessibilityLabel("Back")
            .keyboardShortcut("[", modifiers: .command)
            Text("A little encouragement").font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 0) {
            self.trayHeader
            VStack(alignment: .leading, spacing: 14) {
                self.trayChoices
                Text(
                    BumpLocalTestMode.isEnabled
                        ? "Local test · reply in 10s · next bump in 20s"
                        : "A little boost, once every 30 minutes."
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
        }
        .modifier(NativeTraySurface(morph: self.buttonMorph))
    }

    private var trayChoices: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(BumpEffect.allCases) { effect in
                BumpGlassButton(prominent: false) {
                    withAnimation(.easeOut(duration: 0.18)) { effects.trayOpen = false }
                    effects.schedule(effect, systemReduced: systemReduced)
                } label: {
                    Label { Text(effect.title) } icon: { effectIcon(effect) }
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 31)
                }
                .accessibilityIdentifier("bump-\(effect.rawValue)")
                .onHover { hovered in
                    if hovered { Task { await BumpEmojiLibrary.shared.prepare(effect) } }
                }
            }
        }
    }

    @ViewBuilder private func effectIcon(_ effect: BumpEffect) -> some View {
        switch effect {
        case .keepGoing,
             .touchGrass:
            Image(effect == .keepGoing ? "BumpKeepGoing" : "BumpTouchGrass")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: 16, height: 16).accessibilityHidden(true)
        default:
            Image(systemName: effect.symbol).accessibilityHidden(true)
        }
    }

    private func closeTray() { withAnimation(.easeOut(duration: 0.2)) { effects.trayOpen = false } }
}

struct BumpGlassButton<Label: View>: View {
    var prominent: Bool
    var circular = false
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 26, *) {
            if prominent {
                Button(action: action, label: label).buttonStyle(.glassProminent)
                    .buttonBorderShape(circular ? .circle : .capsule).controlSize(.regular)
                    .tint(.firstlight)
            } else {
                Button(action: action, label: label).buttonStyle(.glass)
                    .buttonBorderShape(circular ? .circle : .capsule).controlSize(.regular)
            }
        } else {
            Button(action: action, label: label).buttonStyle(.bordered)
                .buttonBorderShape(circular ? .circle : .capsule).controlSize(.regular)
        }
    }
}
