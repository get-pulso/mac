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
        Self.seedPreferredPosition()
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusBarItem.autosaveName = Self.autosaveName
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

    /// The name the bar files our place under. It never changes: rename it and
    /// everyone who has dragged the icon somewhere loses where they put it.
    private static let autosaveName = "Firstlight"

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

    /// The bar reads a preferred position as points from the right edge, where
    /// smaller is further right and 0 reads as no preference at all, and drops
    /// the item into the nearest free slot. We ask for the far right once, so
    /// that a bar too crowded to show everyone hides someone else's icon under
    /// the app menus and never ours. The number belongs to the user after that:
    /// the bar writes their own place back here whenever they ⌘-drag the icon.
    private static func seedPreferredPosition() {
        let defaults = UserDefaults.standard
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        // Until the item had a name of its own the bar filed it under AppKit's,
        // so an icon already placed by hand stays exactly where it was placed.
        if let placed = defaults.object(forKey: "NSStatusItem Preferred Position Item-0") {
            defaults.set(placed, forKey: key)
        } else {
            defaults.set(1, forKey: key)
        }
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

    /// The icon holds faces, and a tile Clerk or Google drew for someone with no
    /// photograph is not one: it is passed over like a missing photo, and the
    /// next person online takes the place. Google's are only known once loaded,
    /// so one can take a place for a single refresh and give it up at the next.
    private func updateAvatarURLs(now: Date) {
        let online = StatusPresenceSelection.avatarURLs(
            from: self.presenceCandidates,
            excluding: Defaults[.currentUserID],
            now: now,
            limit: .max
        )
        self.setAvatarURLs(Array(
            online.filter { !AvatarTile.isKnownDrawn($0.absoluteString) }.prefix(Self.maxAvatars)
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
                    (index, AvatarTile.isDrawn(url.absoluteString, image: response.image) ? nil : response.image)
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
        // The build on the local API wears the mark inverted; see `StatusIcon`.
        let inverted = AppEnvironment.isLocalBackend
        let width = StatusIcon.totalWidth(
            forAvatarCount: avatars.count, iconSize: Self.iconSize, inverted: inverted
        )
        let view = StatusIcon(
            avatars: avatars,
            iconSize: Self.iconSize,
            markColor: asTemplate ? .black : self.menuBarMarkColor,
            inverted: inverted
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
            inverted ? "Firstlight, development build" : "Firstlight"
        } else {
            "Firstlight, \(avatars.count) friends online"
        }
        self.statusBarItem.button?.image = image
        self.statusBarItem.button?.setAccessibilityLabel(label)
        self.statusBarItem.button?.toolTip = "\(label) · Right-click for options"
    }
}
