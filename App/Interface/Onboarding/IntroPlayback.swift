import AppKit
import Combine

/// Shader seconds. The Flow clock runs `tempo` times slower than real time;
/// every constant here and in Waves.metal is authored in shader time.
enum IntroTiming {
    /// The real titled window takes over while the light is still moving.
    static let handoff = 2.05
    /// The whole field has become the original mark; the shader is static afterwards.
    static let logoSettled = 3.60
    /// The clock stops here, once Welcome and the Continue button have arrived.
    static let duration = 4.0
    /// Playback seconds per shader second.
    static let tempo = 1.5
    static let dimmingPeak = 0.62

    static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let x = min(1, max(0, (value - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    /// The desktop darkens under the floating light and is fully restored
    /// before the native window appears at the handoff.
    static func dimming(at time: Double) -> Double {
        self.dimmingPeak * self.smooth(0, 0.9, time) * (1 - self.smooth(1.40, 2.02, time))
    }

    static func realSeconds(_ shaderSeconds: Double) -> Double { shaderSeconds * self.tempo }
}

/// Welcome content in the native window, driven by the same shader clock: the
/// title arrives while the light becomes the mark, the button once it has.
enum WelcomeTiming {
    static let titleStart = 3.26
    static let titleVisibleAt = 3.60
    static let buttonStart = 3.62
    static let interactiveAt = 3.95

    static func titleOpacity(at time: Double) -> Double {
        IntroTiming.smooth(self.titleStart, self.titleVisibleAt, time)
    }

    static func buttonOpacity(at time: Double) -> Double {
        IntroTiming.smooth(self.buttonStart, self.interactiveAt, time)
    }

    static func spring(_ time: Double, after delay: Double) -> Double {
        let t = max(0, time - delay)
        let value = 1 - exp(-8.5 * t) * (cos(10 * t) + 0.85 * sin(10 * t))
        return value + (1 - value) * IntroTiming.smooth(0.65, 0.75, t)
    }
}

/// A single clock synchronizes the transparent Metal surface, the native
/// window's continuation of the same light, the desktop dimmers and Welcome.
final class IntroPlayback: ObservableObject {
    // MARK: Internal

    @Published private(set) var elapsed = 0.0
    /// One seed per presentation, never per frame; both hosts share it.
    @Published private(set) var variant = 2
    @Published private(set) var nativePresented = false
    @Published var panelRect = CGRect(x: 76, y: 76, width: 868, height: 608)
    @Published private(set) var shaderFailure: String?
    var onFrame: ((Double, Bool) -> Void)?

    var finished: Bool { self.elapsed >= IntroTiming.duration }
    var readyForNative: Bool { self.elapsed >= IntroTiming.handoff }

    /// The proxy freezes at the handoff frame once the native window shows the
    /// same light; the native host follows the live clock.
    func renderTime(nativeSurface: Bool) -> Double {
        if nativeSurface { return self.elapsed }
        return self.nativePresented ? IntroTiming.handoff : self.elapsed
    }

    func prepare() {
        self.stop()
        self.elapsed = 0
        self.nativePresented = false
        self.variant = Int.random(in: 3 ... 60000)
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
            let real = ProcessInfo.processInfo.systemUptime - self.startedAt
            self.elapsed = min(IntroTiming.duration, real / IntroTiming.tempo)
            self.onFrame?(self.elapsed, self.finished)
            if self.finished { self.stop() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func didPresentNative() { self.nativePresented = true }

    func fail(_ message: String) {
        self.shaderFailure = message
        NSLog("Onboarding Metal fallback: %@", message)
        self.finish()
    }

    /// Skips to the static original mark with Welcome in place.
    func finish() {
        self.stop()
        self.elapsed = IntroTiming.duration
        self.onFrame?(self.elapsed, true)
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }

    // MARK: Private

    private var timer: Timer?
    private var startedAt = 0.0
}
