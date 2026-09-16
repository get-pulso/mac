import AppKit
import Combine
import Defaults
import Foundation
import Logging
import os
import UserNotifications

/// Poll, persist to the account inbox, present, then acknowledge. System banners
/// are optional delivery surfaces; the durable local inbox is the receipt.
@MainActor
final class BumpCenter: NSObject, ObservableObject {
    // MARK: Lifecycle

    nonisolated init(network: Network) {
        self.network = network
        super.init()
    }

    // MARK: Internal

    /// The phrases the send menu offers. Seeded with the list this build was
    /// written against so the menu is never empty, and replaced by the
    /// server's list on the first inbox read.
    @Published private(set) var phrases: [NativeBumpPhrase] = BumpCenter.builtInPhrases

    func activate(popoverVisible: AnyPublisher<Bool, Never>) {
        guard self.subscriptions.isEmpty else { return }
        UNUserNotificationCenter.current().delegate = self
        BumpEffects.shared.activateAccount(Defaults[.currentUserID])

        // Signing in is the first moment there is an inbox to ask for. The
        // poll at launch almost always runs before the stored session has
        // been restored, so without this the first read waits a whole tick.
        Defaults.publisher(.currentUserID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                BumpEffects.shared.activateAccount(Defaults[.currentUserID])
                self?.poll()
            }
            .store(in: &self.subscriptions)

        // Opening the popover is as good as a tick: it is the moment somebody
        // is looking, and it makes a bump sent seconds ago arrive at once.
        popoverVisible
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.popoverVisible = visible
                BumpEffects.shared.setVisible(visible)
                if visible { self?.poll() }
            }
            .store(in: &self.subscriptions)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.poll() }
            .store(in: &self.subscriptions)

        let timer = Timer(timeInterval: Constants.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        self.poll()
    }

    /// Asks once, shows what came back, says so. Overlapping calls — a tick
    /// landing on an opened popover — are dropped rather than queued.
    func poll() {
        guard !self.polling, let userID = Defaults[.currentUserID] else { return }
        self.polling = true
        self.task = Task {
            defer { self.polling = false }
            // Asked for the first time only once somebody is signed in: a
            // permission sheet before there is anyone to hear from would be
            // asking for something the app cannot yet use.
            do {
                let inbox = try await self.network.bumpInbox()
                guard Defaults[.currentUserID] == userID else { return }
                if !inbox.phrases.isEmpty { self.phrases = inbox.phrases }
                let fresh = try BumpEffects.shared.ingest(inbox.bumps)
                if self.popoverVisible { BumpEffects.shared.enqueue(fresh) }
                if !fresh.isEmpty {
                    await self.requestAuthorizationIfNeeded()
                    guard Defaults[.currentUserID] == userID else { return }
                    if !self.popoverVisible {
                        let freshIDs = Set(fresh.map(\.id))
                        await self.present(inbox.bumps.filter { freshIDs.contains($0.id) }, account: userID)
                    }
                }
                guard Defaults[.currentUserID] == userID else { return }
                if !inbox.bumps.isEmpty { try await self.network.acknowledgeBumps(inbox.bumps.map(\.id)) }
                self.logger.info("Bump inbox saved: \(fresh.count) new, \(inbox.bumps.count) acknowledged")
                await self.writeDiagnostics(event: "poll")
            } catch {
                guard !(error is CancellationError) else { return }
                // Nothing is lost by a failed poll: the bumps stay undelivered
                // and the next tick asks again.
                self.logger.info("Bump poll deferred: \(error.localizedDescription)")
                await self.writeDiagnostics(event: "poll-failed")
            }
        }
    }

    /// Exercises the normal arrival surfaces without POST, ACK or another person's inbox.
    func receiveTestBump(_ bump: NativeBump, account: String) async {
        guard BumpLocalTestMode.isEnabled, Defaults[.currentUserID] == account else { return }
        let fresh = BumpEffects.shared.ingestTestBump(bump)
        guard !fresh.isEmpty else { return }
        if self.popoverVisible {
            BumpEffects.shared.enqueue(fresh)
        } else {
            await self.requestAuthorizationIfNeeded()
            guard Defaults[.currentUserID] == account else { return }
            await self.post(bump, account: account)
        }
        await self.writeDiagnostics(event: "local-test-echo")
    }

    // MARK: Private

    private enum Constants {
        /// Between the tracker's own minute and something that would feel like
        /// polling. A bump is a nice thing, not an alert; a minute late is fine.
        static let pollInterval = 45.0
        /// How many banners one poll may raise before they stop being news and
        /// start being a wall. The rest arrive as a single line.
        static let bannerLimit = 3
    }

    /// The phrases as they stood when this app was built. The server's list
    /// wins whenever one has been read; this is what the menu shows before
    /// the first poll, and if the inbox has never answered.
    private nonisolated static let builtInPhrases: [NativeBumpPhrase] = [
        .init(kind: "good_job", label: "Good job", message: "says good job 👏"),
        .init(kind: "hard_worker", label: "Hard worker", message: "says you're a hard worker 💪"),
        .init(kind: "on_fire", label: "On fire", message: "says you're on fire 🔥"),
        .init(kind: "keep_going", label: "Keep going", message: "says keep going 🚀"),
        .init(kind: "respect", label: "Respect", message: "respects the grind 🫡"),
        .init(kind: "touch_grass", label: "Touch grass", message: "says go touch grass 🌱"),
    ]

    private nonisolated static let thread = "firstlight.bumps"

    private let logger = Logger(label: "firstlight.bumps")
    private let network: Network
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var polling = false
    private var subscriptions = Set<AnyCancellable>()
    private var popoverVisible = false
    private var askedForAuthorization = false
    private var notificationError: String?

    #if DEBUG
    private var diagnosticEvents: [String] = []
    private var diagnosticText = ""

    #endif

    /// The sender's face beside their words. Written to a temporary file
    /// because that is the only thing an attachment accepts; a miss, a slow
    /// network or an unreadable image simply leaves the banner plain.
    private static func avatarAttachment(_ sender: NativeBump.Sender) async -> UNNotificationAttachment? {
        guard let raw = sender.avatar_url, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true
        else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return nil }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("bump-\(sender.id)-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try png.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try UNNotificationAttachment(identifier: "", url: file, options: nil)
        } catch {
            return nil
        }
    }

    /// Asks macOS once per launch. A refusal and a failure are different
    /// things and both are logged. Pending overlays remain in the durable inbox
    /// even when system notifications are unavailable.
    private func requestAuthorizationIfNeeded() async {
        guard !self.askedForAuthorization else { return }
        self.askedForAuthorization = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            self.logger.info("Bump notifications \(granted ? "allowed" : "turned off for Firstlight")")
        } catch {
            self
                .notificationError =
                "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)"
            self.logger.warning("Could not ask to show bumps: \(error.localizedDescription)")
        }
    }

    private func present(_ bumps: [NativeBump], account: String) async {
        let shown = bumps.prefix(Constants.bannerLimit)
        for bump in shown {
            guard Defaults[.currentUserID] == account else { return }
            await self.post(bump, account: account)
        }

        let remaining = bumps.count - shown.count
        guard remaining > 0 else { return }
        let senders = Set(bumps.dropFirst(shown.count).map(\.from.id)).count
        let content = UNMutableNotificationContent()
        content.title = "More bumps"
        content.body = senders == 1
            ? "And \(remaining) more from the same friend"
            : "And \(remaining) more from \(senders) friends"
        content.threadIdentifier = Self.thread
        content.userInfo = ["accountID": account]
        guard Defaults[.currentUserID] == account else { return }
        await self.deliver(content, id: "bumps-overflow-\(bumps.first?.id ?? "batch")")
    }

    private func post(_ bump: NativeBump, account: String) async {
        let content = UNMutableNotificationContent()
        content.title = bump.from.displayName
        content.body = bump.message
        content.sound = .default
        // One thread, so a run of bumps stacks into a group in Notification
        // Centre instead of filling it.
        content.threadIdentifier = Self.thread
        content.userInfo = ["bumpID": bump.id, "fromID": bump.from.id, "accountID": account]
        if let attachment = await Self.avatarAttachment(bump.from) {
            content.attachments = [attachment]
        }
        guard Defaults[.currentUserID] == account else { return }
        await self.deliver(content, id: "bump-\(bump.id)")
    }

    private func deliver(_ content: UNMutableNotificationContent, id: String) async {
        do {
            // No trigger: the banner is raised as the request is added, which
            // is what "immediately" means to UNUserNotificationCenter.
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil)
            )
        } catch {
            self
                .notificationError =
                "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)"
            self.logger.warning("Could not show a bump: \(error.localizedDescription)")
        }
    }

    private func writeDiagnostics(event: String) async {
        #if DEBUG
        guard CommandLine.arguments.contains("--bump-diagnostics") else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let delivered = await center.deliveredNotifications()
        self.diagnosticEvents.append("\(ISO8601DateFormatter().string(from: Date())) \(event)")
        self.diagnosticEvents = Array(self.diagnosticEvents.suffix(30))
        let snapshot: [String: Any] = [
            "event": event, "at": ISO8601DateFormatter().string(from: Date()),
            "account": Defaults[.currentUserID] ?? "", "visible": self.popoverVisible,
            "authorization": settings.authorizationStatus.rawValue,
            "notificationError": self.notificationError ?? "",
            "alert": settings.alertSetting.rawValue, "sound": settings.soundSetting.rawValue,
            "delivered": delivered.map { ["id": $0.request.identifier, "title": $0.request.content.title,
                                          "body": $0.request.content.body,
                                          "attachments": $0.request.content.attachments.count] },
            "history": BumpEffects.shared.recent.map(\.id), "unread": BumpEffects.shared.unreadCount,
            "incoming": BumpEffects.shared.incoming?.id ?? "",
            "events": self.diagnosticEvents,
            "decodedClips": BumpEmojiLibrary.shared.clips.mapValues { $0.frames.count },
            "rendererFailure": BumpEffects.shared.rendererFailure ?? "",
            "sending": BumpEffects.shared.sending,
            "cooldowns": BumpEffects.shared.sent.mapValues { ISO8601DateFormatter().string(from: $0.nextAllowedAt) },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            self.diagnosticText = String(decoding: data, as: UTF8.self)
            NSLog("FirstlightBumpDiagnostic %@", self.diagnosticText)
            os_log(
                "%{public}@",
                log: OSLog(subsystem: "sh.firstlight.mac", category: "bump-e2e"),
                type: .default,
                self.diagnosticText
            )
            try? data.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("firstlight-bump-diagnostics.json"),
                options: .atomic
            )
        }
        #endif
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BumpCenter: UNUserNotificationCenterDelegate {
    /// The open popover plays the overlay; only background delivery needs a banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { self.popoverVisible ? [] : [.banner, .sound] }
    }

    /// Clicking a bump opens the popover. It deliberately does not jump to the
    /// person: the list is what somebody wants to see after being told they
    /// are doing well, and a profile opened from a notification would have to
    /// load from nothing behind the flying portrait.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let account = info["accountID"] as? String
        let id = info["bumpID"] as? String
        await MainActor.run {
            guard account == Defaults[.currentUserID], account != nil else { return }
            SocialStore.shared.showList()
            WindowManager.liveValue.show()
            if let moment = BumpEffects.shared.recent.first(where: { $0.id == id }) {
                BumpEffects.shared.receive(
                    moment,
                    systemReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    replay: true
                )
            } else { BumpEffects.shared.enqueuePending() }
        }
        await self.writeDiagnostics(event: "notification-opened")
    }
}
