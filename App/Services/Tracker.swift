import AppKit
import CryptoKit
import Defaults
import Foundation
import IsCameraOn
import Logging

final class Tracker {
    // MARK: Lifecycle

    init(
        storage: Storage,
        network: Network
    ) {
        self.storage = storage
        self.network = network
    }

    // MARK: Internal

    func activate() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.hanleSystemWakeUp),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.handleSystemSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(self.handleApplicationActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(self.handleScreenLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(self.handleScreenUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        self.startTracking()
    }

    func stop() throws {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        try self.stopTracking()
    }

    @MainActor func resetActivity() async throws {
        guard let userID = Defaults[.currentUserID] else { throw URLError(.userAuthenticationRequired) }
        try self.stopTracking()
        defer { self.startTracking() }
        // Drain in-flight uploads before deleting history so queued data cannot
        // reappear after the server confirms a reset.
        await self.publishingTask?.value
        guard Defaults[.currentUserID] == userID else { throw CancellationError() }
        let _: NativeAck = try await self.network.request(
            path: "/api/user/activity/reset",
            method: .delete,
            expectedUserID: userID
        )
        try self.storage.deletePendingActivity(for: userID)
    }

    // MARK: Private

    private let logger = Logger(label: "firstlight.tracker")
    private let storage: Storage
    private let network: Network
    private var timer: Timer?
    private var publishing = false
    private var publishingTask: Task<Void, Never>?
    private var lastExternalApplication: NSRunningApplication?

    /// The app's icon as a PNG, resampled once from the largest pixels it has.
    ///
    /// Drawing the `NSImage` itself would leave that to AppKit, which picks a
    /// representation by point size — Launch Services hands these out at 32 pt
    /// — and sharpens on the way down, leaving a light rim along every edge.
    /// Taking the pixels and resampling them once does neither, and the PNG
    /// comes out about a third smaller for it.
    private static func iconPNGBase64(_ image: NSImage?) -> String? {
        guard let image else { return nil }
        var proposed = NSRect(x: 0, y: 0, width: Constants.iconSide, height: Constants.iconSide)
        let source = image.representations
            .max { $0.pixelsWide < $1.pixelsWide }?
            .cgImage(forProposedRect: &proposed, context: nil, hints: nil)
            ?? image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        guard let source,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: Int(Constants.iconSide),
                  height: Int(Constants.iconSide),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: Constants.iconSide, height: Constants.iconSide))
        guard let resampled = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: resampled)
        bitmap.size = NSSize(width: Constants.iconSide, height: Constants.iconSide)
        guard let data = bitmap.representation(using: .png, properties: [:]),
              data.count <= Constants.iconByteLimit else { return nil }
        return data.base64EncodedString()
    }

    private func startTracking() {
        if self.timer?.isValid == true {
            return
        }

        self.timer?.invalidate()

        let timer = Timer(timeInterval: Constants.hearbeatInterval, repeats: true) { [weak self] _ in
            try? self?.heartbeat()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTracking() throws {
        self.timer?.invalidate()
        self.timer = nil
    }

    @objc private func handleSystemSleep() throws {
        try self.stopTracking()
    }

    @objc private func hanleSystemWakeUp() {
        self.startTracking()
    }

    @objc private func handleScreenLock() throws {
        try self.stopTracking()
    }

    @objc private func handleScreenUnlock() {
        self.startTracking()
    }

    @objc private func handleApplicationActivation(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
            self.isTrackable(application)
        else { return }
        self.lastExternalApplication = application
    }

    private func heartbeat() throws {
        guard let userID = Defaults[.currentUserID],
              !UserDefaults.standard.bool(forKey: "firstlight.trackingPaused") else { return }
        self.logger.info("Heartbeat")

        let trackedEvents: [CGEventType] = [.mouseMoved, .keyDown, .scrollWheel]

        var minTime = Double.greatestFiniteMagnitude
        for event in trackedEvents {
            let elapsedTime = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: event
            )
            minTime = min(minTime, elapsedTime)
        }

        if minTime > Constants.idleTimeout, !isCameraOn() {
            self.logger.info("App is idle")
            return
        }

        let now = Date.now
        let start = now.addingTimeInterval(-Constants.hearbeatInterval)
        self.recordHumanPresence(from: start, to: now)
        let trackedApp = self.trackedApplication()
        let activity = PendingActivity(
            id: start.id,
            startedAt: start,
            endedAt: now,
            userID: userID,
            appBundleIdentifier: trackedApp?.bundleIdentifier,
            appName: trackedApp?.name,
            appVersion: trackedApp?.version,
            appIconPNGBase64: trackedApp?.iconPNGBase64
        )
        try self.storage.store(activity: activity)

        guard !self.publishing else { return }
        self.publishing = true
        self.publishingTask = Task { @MainActor in
            defer { self.publishing = false }
            do {
                for activity in try self.storage.pendingActivity() where activity.userID == userID {
                    guard Defaults[.currentUserID] == userID else { return }
                    self.logger.info("Publishing activity \(activity.startedAt) - \(activity.endedAt)")
                    let response = try await self.network.publishActivity(activity, userID: userID)

                    if response.success == true {
                        self.logger.info("Successfully published activity: \(activity.startedAt) - \(activity.endedAt)")
                    }
                    if let error = response.error {
                        self.logger.error(
                            "Failed to publish activity \(activity.startedAt) - \(activity.endedAt)",
                            metadata: [
                                "error": .string(error),
                            ]
                        )
                    }
                    if response.success == true {
                        self.updateIconCache(for: activity, needsIcon: response.needs_app_icon == true)
                        try self.storage.deletePendingActivity(with: activity.id)
                    }
                }
            } catch {
                self.logger.warning("Activity upload deferred; queued data is retained.")
            }
        }
    }

    private func trackedApplication() -> TrackedApplication? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           self.isTrackable(frontmostApplication)
        {
            self.lastExternalApplication = frontmostApplication
        }

        guard let application = self.lastExternalApplication,
              !application.isTerminated,
              let bundleIdentifier = application.bundleIdentifier,
              let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }

        let version = application.bundleURL.flatMap(Bundle.init(url:))?.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let iconCacheKey = self.iconCacheKey(for: bundleIdentifier)
        let iconVersion = version ?? "unknown"
        let needsIcon = Defaults[.uploadedAppIconVersions][iconCacheKey] != iconVersion
        return TrackedApplication(
            bundleIdentifier: bundleIdentifier,
            name: name,
            version: version,
            iconPNGBase64: needsIcon ? Self.iconPNGBase64(application.icon) : nil
        )
    }

    private func isTrackable(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return bundleIdentifier != Bundle.main.bundleIdentifier && !application.isTerminated
    }

    private func updateIconCache(for activity: PendingActivity, needsIcon: Bool) {
        guard let bundleIdentifier = activity.appBundleIdentifier else { return }
        let cacheKey = self.iconCacheKey(for: bundleIdentifier)
        var versions = Defaults[.uploadedAppIconVersions]
        if needsIcon {
            versions.removeValue(forKey: cacheKey)
        } else if activity.appIconPNGBase64 != nil {
            versions[cacheKey] = activity.appVersion ?? "unknown"
        }
        Defaults[.uploadedAppIconVersions] = versions
    }

    private func iconCacheKey(for bundleIdentifier: String) -> String {
        "\(AppEnvironment.baseURL.host ?? "unknown")|\(bundleIdentifier)"
    }
}

private struct TrackedApplication {
    let bundleIdentifier: String
    let name: String
    let version: String?
    let iconPNGBase64: String?
}

private extension Tracker {
    enum Constants {
        static let hearbeatInterval = 60.0
        static let idleTimeout = 60.0 * 5.0
        /// Twice the largest size the interface draws an icon at, on a retina
        /// screen. The server keeps one per app, so it is worth the few bytes.
        static let iconSide = 128.0
        static let iconByteLimit = 256_000
    }
}

// MARK: - Human presence per minute

extension Tracker {
    /// Whether the presence heartbeat counted the human as active during the
    /// minute starting at `minuteStart`. Minutes older than the ring (about
    /// two days) are unknown and read as `false`.
    func wasHumanActive(minuteStart: Date) -> Bool {
        let index = String(AgentUsageDates.minuteIndex(of: minuteStart))
        return Self.humanMinutesLock.withLock { Self.humanMinutes().contains(index) }
    }

    private func recordHumanPresence(from start: Date, to end: Date) {
        let first = AgentUsageDates.minuteIndex(of: start)
        let last = AgentUsageDates.minuteIndex(of: end)
        let indices = (min(first, last) ... max(first, last)).map(String.init)
        Self.humanMinutesLock.withLock {
            var ring = Self.humanMinutes()
            for index in indices where !ring.contains(index) { ring.append(index) }
            if ring.count > Self.humanMinutesLimit { ring.removeFirst(ring.count - Self.humanMinutesLimit) }
            Self.humanMinutesCache = ring
            Defaults[.recentHumanMinutes] = ring
        }
    }

    private static let humanMinutesLimit = 2880
    private static let humanMinutesLock = NSLock()
    private nonisolated(unsafe) static var humanMinutesCache: [String]?

    private static func humanMinutes() -> [String] {
        if let cache = self.humanMinutesCache { return cache }
        let stored = Defaults[.recentHumanMinutes]
        self.humanMinutesCache = stored
        return stored
    }
}

extension Date {
    var id: String {
        withUnsafeBytes(
            of: self.timeIntervalSince1970
        ) {
            let data = Data($0)
            let hash = Insecure.SHA1.hash(data: data)
            return hash.reduce(into: "") { $0 += String(format: "%02x", $1) }
        }
    }
}

private extension Calendar {
    func endOfTheDay(for date: Date) -> Date {
        self.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }
}
