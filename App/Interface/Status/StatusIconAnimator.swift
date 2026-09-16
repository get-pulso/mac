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
        self.observeLiveUsers()
        self.observeMenuBarAppearance()
        self.renderIcon()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(self.statusBarItem)
        self.appearanceObservation?.invalidate()
    }

    // MARK: Internal

    var statusBarButton: NSStatusBarButton? {
        self.statusBarItem.button
    }

    func highlight() {
        self.statusBarButton?.highlight(true)
    }

    func unhighlight() {
        self.statusBarButton?.highlight(false)
    }

    // MARK: Private

    private static let iconSize: CGFloat = 20
    private static let maxAvatars = 3

    private var statusBarItem: NSStatusItem
    private let menu: StatusItemMenu
    private var avatarImages: [NSImage?] = []
    private var cancellable: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?

    @Dependency(\.storage) private var storage

    private var menuBarMarkColor: Color {
        let appearance = self.statusBarItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
    }

    private func observeLiveUsers() {
        self.cancellable = self.storage.friendsStream(filter: .last24h)
            .replaceError(with: [])
            .map { friends in
                friends
                    .filter { $0.id != Defaults[.currentUserID] }
                    .filter { friend in
                        guard let lastActiveAt = friend.lastActiveAt else { return false }
                        return Date().timeIntervalSince(lastActiveAt) <= 120 // 2 min online threshold
                    }
                    .sorted { ($0.minutes24h ?? 0) > ($1.minutes24h ?? 0) }
                    .map(\.avatar)
                    .compactMap { $0 }
                    .prefix(Self.maxAvatars)
            }
            .flatMap { [weak self] urls -> AnyPublisher<[NSImage?], Never> in
                guard let self else { return Just([]).eraseToAnyPublisher() }
                return self.fetchAvatars(for: Array(urls))
            }
            .sink { [weak self] avatarImages in
                self?.avatarImages = avatarImages
                self?.renderIcon()
            }
    }

    /// A template image follows the menu bar on its own; the avatar row cannot be one,
    /// so the mark is drawn in the bar's own colour instead and redrawn when it flips.
    private func observeMenuBarAppearance() {
        self.appearanceObservation = self.statusBarItem.button?
            .observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.renderIcon() }
            }
    }

    private func fetchAvatars(for urls: [URL]) -> AnyPublisher<[NSImage?], Never> {
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
                results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            .eraseToAnyPublisher()
    }

    private func renderIcon() {
        let avatars = self.avatarImages
        let asTemplate = avatars.isEmpty
        let width = StatusIcon.totalWidth(forAvatarCount: avatars.count, iconSize: Self.iconSize) + Self
            .iconSize * 1.18 // add icon + spacing
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
        self.statusBarItem.button?.image = image
    }
}
