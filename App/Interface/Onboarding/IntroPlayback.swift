import AppKit
import Combine

enum IntroTiming {
    static let morphStart = 3.6
    static let duration = 5.8

    static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let x = min(1, max(0, (value - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    static func dimming(at time: Double) -> Double {
        0.72 * self.smooth(0, 0.9, time) * (1 - self.smooth(self.morphStart + 0.15, 5.3, time))
    }
}

/// Starts only after the native window is on screen, never during prewarming.
enum WelcomeTiming {
    static let duration = 5.1
    static let logoStart = 0.18
    static let logoVisibleAt = 0.70
    static let logoExitStart = 2.10
    static let logoGoneAt = 2.65
    static let titleStart = 2.80
    static let titleVisibleAt = 3.35
    static let buttonStart = 4.25
    static let interactiveAt = 4.85

    static func logoOpacity(at time: Double) -> Double {
        IntroTiming
            .smooth(self.logoStart, self.logoVisibleAt, time) *
            (1 - IntroTiming.smooth(self.logoExitStart, self.logoGoneAt, time))
    }

    static func titleOpacity(at time: Double) -> Double {
        IntroTiming.smooth(self.titleStart, self.titleVisibleAt, time)
    }

    static func spring(_ time: Double, after delay: Double) -> Double {
        let t = max(0, time - delay)
        let value = 1 - exp(-8.5 * t) * (cos(10 * t) + 0.85 * sin(10 * t))
        return value + (1 - value) * IntroTiming.smooth(0.65, 0.75, t)
    }
}

/// A single clock synchronizes the transparent Metal surface and all displays.
final class IntroPlayback: ObservableObject {
    // MARK: Internal

    @Published private(set) var elapsed = 0.0
    @Published private(set) var welcomeElapsed = 0.0
    @Published var panelRect = CGRect(x: 76, y: 76, width: 868, height: 608)
    @Published private(set) var shaderFailure: String?
    var onFrame: ((Double, Bool) -> Void)?

    var finished: Bool { self.elapsed >= IntroTiming.duration }

    func prepare() {
        self.stop()
        self.elapsed = 0
        self.welcomeElapsed = 0
    }

    func start(animated: Bool) {
        self.stop()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, self.shaderFailure == nil else {
            self.finish()
            return
        }
        self.startedAt = ProcessInfo.processInfo.systemUptime
        self.elapsed = 0
        self.onFrame?(self.elapsed, false)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = min(IntroTiming.duration, ProcessInfo.processInfo.systemUptime - self.startedAt)
            self.onFrame?(self.elapsed, self.finished)
            if self.finished { self.stop() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func fail(_ message: String) {
        self.shaderFailure = message
        NSLog("Onboarding Metal fallback: %@", message)
        self.finish()
    }

    func finish() {
        self.stop()
        self.elapsed = IntroTiming.duration
        self.onFrame?(self.elapsed, true)
    }

    func beginWelcome(animated: Bool = true) {
        self.welcomeTimer?.invalidate()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            self.finishWelcome()
            return
        }
        self.welcomeElapsed = 0
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.welcomeElapsed = min(WelcomeTiming.duration, ProcessInfo.processInfo.systemUptime - start)
            if self.welcomeElapsed >= WelcomeTiming.duration {
                self.welcomeTimer?.invalidate()
                self.welcomeTimer = nil
            }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.welcomeTimer = timer
    }

    func finishWelcome() {
        self.welcomeTimer?.invalidate()
        self.welcomeTimer = nil
        self.welcomeElapsed = WelcomeTiming.duration
    }

    func stop() {
        self.timer?.invalidate(); self.timer = nil
        self.welcomeTimer?.invalidate(); self.welcomeTimer = nil
    }

    // MARK: Private

    private var timer: Timer?
    private var welcomeTimer: Timer?
    private var startedAt = 0.0
}
