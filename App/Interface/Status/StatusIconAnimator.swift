import AppKit
import Combine
import Defaults
import Dependencies
import Nuke
import SwiftUI

@MainActor
final class StatusIconAnimator {
    // MARK: Lifecycle

    init(menu: StatusItemMenu) {
        self.menu = menu
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.attach(to: self.statusBarItem)
        self.observePresence()
        self.observeMenuBarAppearance()
        self.renderIcon()
    }

    deinit {
        self.presenceTask?.cancel()
        NSStatusBar.system.removeStatusItem(self.statusBarItem)
        self.appearanceObservation?.invalidate()
    }

    // MARK: Internal

    var statusBarButton: NSStatusBarButton? {
        self.statusBarItem.button
    }

    /// Where the flying mark lands.
    var iconSide: CGFloat { Self.iconSize }

    func highlight() {
        self.statusBarButton?.highlight(true)
    }

    func unhighlight() {
        self.statusBarButton?.highlight(false)
    }

    /// The icon steps aside while the mark is in flight towards it.
    func dim(duration: Double = 0.2) {
        guard let button = statusBarButton else { return }
        button.wantsLayer = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            button.animator().alphaValue = 0
        }
    }

    /// The flying mark has landed: the icon is back, and lights up for a
    /// moment so the eye finds where the app now lives.
    func arrive() {
        guard let button = statusBarButton else { return }
        button.alphaValue = 1
        button.highlight(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.unhighlight() }
    }

    // MARK: Private

    private static let iconSize: CGFloat = 20
    private static let maxAvatars = 3

    private var statusBarItem: NSStatusItem
    private let menu: StatusItemMenu
    private var presenceCandidates: [StatusPresenceCandidate] = []
    private var avatarURLs: [URL] = []
    private var avatarImages: [NSImage] = []
    private var avatarRequest: AnyCancellable?
    private var presenceTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    @Dependency(\.network) private var network

    /// The appearance the icon was last drawn for. Setting the button's image
    /// makes the status item redraw its replicants, and that redraw reports an
    /// appearance change of its own; without this, the two feed each other at
    /// the display rate and the main thread never comes back.
    private var renderedAppearance: NSAppearance.Name?

    private var menuBarAppearance: NSAppearance.Name {
        let appearance = self.statusBarItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
    }

    private var menuBarMarkColor: Color {
        self.menuBarAppearance == .darkAqua ? .white : .black
    }

    private func observePresence() {
        let timer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .map { _ in () }
            .eraseToAnyPublisher()
        let account = Defaults.publisher(.currentUserID)
            .map { _ in () }
            .eraseToAnyPublisher()
        let wake = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .map { _ in () }
            .eraseToAnyPublisher()

        Publishers.Merge3(timer, account, wake)
            .sink { [weak self] in self?.refreshPresence() }
            .store(in: &self.subscriptions)
        self.refreshPresence()
    }

    private func refreshPresence() {
        self.updateAvatarURLs(now: .now)
        self.presenceTask?.cancel()

        guard let userID = Defaults[.currentUserID] else {
            self.presenceCandidates = []
            self.setAvatarURLs([])
            return
        }

        self.presenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let people: [NativePerson] = try await self.network.request(
                    path: "/api/friends/leaderboard",
                    method: .get,
                    query: ["period": "24h"],
                    expectedUserID: userID
                )
                try Task.checkCancellation()
                guard Defaults[.currentUserID] == userID else { return }
                #if DEBUG
                if CommandLine.arguments.contains("--preview-status-avatars") {
                    let urls = people
                        .filter { $0.id != userID }
                        .compactMap { person in
                            person.avatar_url.flatMap(URL.init(string:))
                        }
                        .prefix(Self.maxAvatars)
                    self.setAvatarURLs(Array(urls))
                    return
                }
                #endif
                self.presenceCandidates = people.compactMap {
                    StatusPresenceCandidate(
                        id: $0.id,
                        avatarURL: $0.avatar_url,
                        lastActiveAt: $0.last_active_at
                    )
                }
                self.updateAvatarURLs(now: .now)
            } catch is CancellationError {
                return
            } catch {
                // Keep the last known row during a transient failure. The local
                // clock still removes it as soon as its online window expires.
                self.updateAvatarURLs(now: .now)
            }
        }
    }

    private func updateAvatarURLs(now: Date) {
        self.setAvatarURLs(StatusPresenceSelection.avatarURLs(
            from: self.presenceCandidates,
            excluding: Defaults[.currentUserID],
            now: now,
            limit: Self.maxAvatars
        ))
    }

    private func setAvatarURLs(_ urls: [URL]) {
        guard urls != self.avatarURLs || self.avatarImages.count != urls.count else { return }
        self.avatarURLs = urls
        self.avatarRequest?.cancel()

        guard !urls.isEmpty else {
            self.avatarImages = []
            self.renderIcon()
            return
        }

        self.avatarRequest = self.fetchAvatars(for: urls)
            .sink { [weak self] images in
                guard let self, self.avatarURLs == urls else { return }
                self.avatarImages = images
                self.renderIcon()
            }
    }

    /// A template image follows the menu bar on its own; the avatar row cannot be one,
    /// so the mark is drawn in the bar's own colour instead and redrawn when it flips.
    private func observeMenuBarAppearance() {
        self.appearanceObservation = self.statusBarItem.button?
            .observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self else { return }
                    // A template mark follows the bar by itself; only the
                    // avatar row is drawn in the bar's colour, and only a
                    // colour that actually flipped is worth drawing again.
                    guard !self.avatarImages.isEmpty, self.menuBarAppearance != self.renderedAppearance
                    else { return }
                    self.renderIcon()
                }
            }
    }

    private func fetchAvatars(for urls: [URL]) -> AnyPublisher<[NSImage], Never> {
        let pipeline = ImagePipeline.shared
        let publishers = urls.enumerated().map { index, url -> AnyPublisher<(Int, NSImage?), Never> in
            let request = ImageRequest(url: url)
            return pipeline.imagePublisher(with: request)
                .map { response -> (Int, NSImage?) in
                    (index, response.image)
                }
                .replaceError(with: (index, nil))
                .eraseToAnyPublisher()
        }
        return Publishers.MergeMany(publishers)
            .collect()
            .map { results in
                results.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            .eraseToAnyPublisher()
    }

    private func renderIcon() {
        let avatars = self.avatarImages
        let asTemplate = avatars.isEmpty
        self.renderedAppearance = self.menuBarAppearance
        let width = StatusIcon.totalWidth(forAvatarCount: avatars.count, iconSize: Self.iconSize)
        let view = StatusIcon(
            avatars: avatars,
            iconSize: Self.iconSize,
            markColor: asTemplate ? .black : self.menuBarMarkColor
        )
        .frame(width: width, height: Self.iconSize)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = asTemplate
        self.statusBarItem.length = asTemplate ? NSStatusItem.squareLength : width
        let label = if avatars.count == 1 {
            "Firstlight, 1 friend online"
        } else if avatars.isEmpty {
            "Firstlight"
        } else {
            "Firstlight, \(avatars.count) friends online"
        }
        self.statusBarItem.button?.image = image
        self.statusBarItem.button?.setAccessibilityLabel(label)
        self.statusBarItem.button?.toolTip = "\(label) · Right-click for options"
    }
}
