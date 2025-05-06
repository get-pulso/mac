import AppKit
import CryptoKit
import Foundation
import IsCameraOn

final class Tracker {
    // MARK: Lifecycle

    init(storage: Storage) {
        self.storage = storage
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

    private let storage: Storage
    private var pendingActivityStart: Date?
    private var timer: Timer?

    private func startTracking() {
        if self.timer?.isValid == true {
            print("skipping timer starting")
            return
        }

        self.timer?.invalidate()

        let timer = Timer(timeInterval: Constants.hearbeatInterval, repeats: true) { [weak self] _ in
            try? self?.heartbeat()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        try? self.heartbeat()
    }

    private func stopTracking() throws {
        self.timer?.invalidate()
        self.timer = nil

        guard let pendingActivityStart else { return }
        self.pendingActivityStart = nil

        let activity = Activity(id: pendingActivityStart.id, startedAt: pendingActivityStart, endedAt: .now)
        try self.storage.update(activity: activity)
    }

    @objc private func handleSystemSleep() throws {
        print("sleep")
        try self.stopTracking()
    }

    @objc private func hanleSystemWakeUp() {
        print("wake")
        self.startTracking()
    }

    @objc private func handleScreenLock() throws {
        print("screen lock")
        try self.stopTracking()
    }

    @objc private func handleScreenUnlock() {
        print("screen unlock")
        self.startTracking()
    }

    private func heartbeat() throws {
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
            self.pendingActivityStart = nil
            print("idle")
            return
        }

        print("heartbeat: \(minTime)")
        let now = Date.now

        let startDate: Date
        if let pendingActivityStart {
            startDate = pendingActivityStart
        } else {
            startDate = now
            self.pendingActivityStart = startDate
        }

        if Calendar.current.isDate(startDate, inSameDayAs: now) {
            let activity = Activity(id: startDate.id, startedAt: startDate, endedAt: now)
            try self.storage.update(activity: activity)
            return
        }

        self.pendingActivityStart = nil

        guard now > startDate else {
            return
        }

        let activity = Activity(
            id: startDate.id,
            startedAt: startDate,
            endedAt: Calendar.current.endOfTheDay(for: startDate)
        )
        try self.storage.update(activity: activity)
    }
}

private extension Tracker {
    enum Constants {
        static let hearbeatInterval = 30.0
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
