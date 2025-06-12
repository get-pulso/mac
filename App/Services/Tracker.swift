import AppKit
import CryptoKit
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

    // MARK: Private

    private let logger = Logger(label: "pulso.tracker")
    private let storage: Storage
    private let network: Network
    private var timer: Timer?

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

    private func heartbeat() throws {
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
        let activity = Activity(id: start.id, startedAt: start, endedAt: now)
        try self.storage.store(activity: activity)

        Task {
            for activity in try self.storage.activity() {
                self.logger.info("Publishing activity \(activity.startedAt) - \(activity.endedAt)")
                let response = try await self.network.publishActivity(
                    start: activity.startedAt,
                    end: activity.endedAt
                )

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
                try self.storage.deleteActivity(with: activity.id)
            }
        }
    }
}

private extension Tracker {
    enum Constants {
        static let hearbeatInterval = 60.0
        static let idleTimeout = 60.0 * 5.0
    }
}

private extension Date {
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
