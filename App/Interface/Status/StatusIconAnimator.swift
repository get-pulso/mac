import AppKit
import Combine
import Defaults
import Dependencies
import Nuke
import SwiftUI

@MainActor
final class StatusIconAnimator {
    // MARK: Lifecycle

    init() {
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.observeLiveUsers()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(self.statusBarItem)
        self.iconTimer?.invalidate()
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

    private static let totalFrames = 40
    private static let frameInterval: TimeInterval = 0.1
    private static let maxAvatars = 3

    private var statusBarItem: NSStatusItem
    private var iconFrames: [NSImage] = []
    private var iconFrameIndex: Int = 0
    private var iconTimer: Timer?
    private var cancellable: AnyCancellable?

    @Dependency(\.storage) private var storage

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
            .flatMap { [weak self] urls -> AnyPublisher<[NSImage], Never> in
                guard let self else { return Just([]).eraseToAnyPublisher() }
                return self.fetchAvatars(for: Array(urls))
            }
            .sink { [weak self] avatarImages in
                self?.rerenderIconFrames(with: avatarImages)
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

    private func rerenderIconFrames(with avatarImages: [NSImage]) {
        guard let containerHeight = self.statusBarButton?.bounds.height, containerHeight > 0 else { return }

        let needsAnimation = avatarImages.isEmpty
        let targetFramesCount = needsAnimation ? Self.totalFrames : 1
        self.iconFrames = (0 ..< targetFramesCount).map { frameIndex in
            let phase = Double(frameIndex) / Double(targetFramesCount)
            let view = StatusIcon(
                phase: phase,
                avatars: avatarImages,
                containerHeight: containerHeight
            )
            let renderer = ImageRenderer(content: view)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            return renderer.nsImage ?? NSImage()
        }

        self.iconTimer?.invalidate()
        self.iconTimer = nil

        if needsAnimation {
            self.startAnimationTimer()
        } else {
            let image = self.iconFrames.first
            self.statusBarItem.button?.image = image
        }
    }

    private func startAnimationTimer() {
        self.iconTimer = Timer.scheduledTimer(withTimeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.iconFrames.count == Self.totalFrames else { return }

                self.iconFrameIndex = (self.iconFrameIndex + 1) % Self.totalFrames
                self.statusBarItem.button?.image = self.iconFrames[self.iconFrameIndex]
            }
        }
        RunLoop.main.add(self.iconTimer!, forMode: .common)
    }
}
