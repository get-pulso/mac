import AppKit
import Combine

/// Every constant here, in WelcomeTiming, WelcomeLayout and Waves.metal is
/// authored in shader seconds. The clock plays that timeline through `pacing`,
/// a non-linear map from real seconds: the desktop darkens first, the light is
/// born slowly, then the window and the mark arrive quickly and settle softly.
enum IntroTiming {
    struct Key {
        /// Real seconds, shader seconds and shader seconds per real second.
        let real: Double, shader: Double, speed: Double
    }

    /// The real titled window takes over while the light is still moving.
    static let handoff = 2.05
    /// The whole field has become the original mark; the shader is static afterwards.
    static let logoSettled = 3.60
    /// The clock stops here, once the mark and the name have become the header,
    /// Welcome has arrived and the Continue button is live.
    static let duration = 6.15
    static let dimmingPeak = 0.72

    /// Monotone cubic Hermite keys (every speed is within three times the
    /// neighbouring secants, so the map never runs backwards). Speeds shape
    /// the eases: a quick departure into a long, soft settle, like a sheet.
    /// Everything after the settled mark plays at an even 0.85 shader
    /// seconds per real second, whatever the welcome choreography's length.
    static let pacing: [Key] = [
        Key(real: 0.00, shader: 0.00, speed: 0.00), // only the desktop darkens
        Key(real: 1.00, shader: 0.06, speed: 0.15), // the light is born slowly
        Key(real: 4.00, shader: 1.75, speed: 0.75), // it has filled the pane
        Key(real: 4.25, shader: 2.05, speed: 1.30), // the real window appears quickly
        Key(real: 5.60, shader: 3.15, speed: 0.55), // the light settles into the mark
        Key(real: 5.95, shader: 3.60, speed: 1.10), // original pigment, without lingering
        Key(real: 5.95 + (duration - 3.60) / 0.85, shader: duration, speed: 0.60),
    ]

    static var realDuration: Double { self.pacing.last!.real }
    static var realHandoff: Double { self.pacing.first { $0.shader >= self.handoff }!.real }

    static func smooth(_ a: Double, _ b: Double, _ value: Double) -> Double {
        let x = min(1, max(0, (value - a) / (b - a)))
        return x * x * (3 - 2 * x)
    }

    static func unit(_ a: Double, _ b: Double, _ value: Double) -> Double {
        min(1, max(0, (value - a) / (b - a)))
    }

    /// Quick departure, long soft settle: how a sheet or a sliding word arrives.
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3.2) }

    /// Symmetric, with no visible start or stop: how a group moves to a new place.
    static func easeInOut(_ x: Double) -> Double { x * x * x * (x * (x * 6 - 15) + 10) }

    static func shaderTime(atReal real: Double) -> Double {
        let keys = self.pacing
        guard real > 0 else { return 0 }
        guard real < keys.last!.real else { return keys.last!.shader }
        let index = keys.lastIndex { $0.real <= real }!
        let a = keys[index], b = keys[index + 1]
        let h = b.real - a.real, t = (real - a.real) / h
        let t2 = t * t, t3 = t2 * t
        let value = (2 * t3 - 3 * t2 + 1) * a.shader + (t3 - 2 * t2 + t) * h * a.speed
            + (-2 * t3 + 3 * t2) * b.shader + (t3 - t2) * h * b.speed
        return min(b.shader, max(a.shader, value))
    }

    /// Real seconds: the desktop darkens before any light and is fully
    /// restored while the light still fills the pane, before the window appears.
    static func dimming(atReal real: Double) -> Double {
        self.dimmingPeak * self.smooth(0, 1.1, real) * (1 - self.smooth(3.30, 4.05, real))
    }
}

/// Welcome content in the native window, driven by the same shader clock.
/// Once the light has become the mark in the centre, the name is revealed
/// beside it, the pair rises to the top edge and shrinks into the header and
/// stays there; only then do the title and the button arrive below.
enum WelcomeTiming {
    /// The static mark is handed from the shader to a plain image of the same
    /// asset (crisp, and in the same layer as the name); a short cross-fade.
    static let markImageStart = 3.40
    static let markImageVisibleAt = 3.55
    /// The name is revealed to the right of the settled mark; the pair stays centred.
    static let nameStart = 3.70
    static let nameVisibleAt = 4.25
    /// The pair rises to the header line and shrinks; it never leaves.
    static let riseStart = 4.35
    static let riseEnd = 4.95
    /// Title, then its subtitle, then the button: one after another.
    static let titleStart = 5.00
    static let titleVisibleAt = 5.30
    static let subtitleStart = 5.38
    static let subtitleVisibleAt = 5.68
    static let buttonStart = 5.78
    static let interactiveAt = 6.15

    /// The name slides out from behind the mark: fast first, then settling.
    static func markImageProgress(at time: Double) -> Double {
        IntroTiming.smooth(self.markImageStart, self.markImageVisibleAt, time)
    }

    static func nameProgress(at time: Double) -> Double {
        IntroTiming.easeOut(IntroTiming.unit(self.nameStart, self.nameVisibleAt, time))
    }

    /// The pair moves to the header as one piece, without a visible start or stop.
    static func riseProgress(at time: Double) -> Double {
        IntroTiming.easeInOut(IntroTiming.unit(self.riseStart, self.riseEnd, time))
    }

    static func titleOpacity(at time: Double) -> Double {
        IntroTiming.smooth(self.titleStart, self.titleVisibleAt, time)
    }

    static func subtitleOpacity(at time: Double) -> Double {
        IntroTiming.smooth(self.subtitleStart, self.subtitleVisibleAt, time)
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

    /// Shader seconds, mapped through `IntroTiming.pacing`.
    @Published private(set) var elapsed = 0.0
    /// Real seconds since the clock started; the desktop dimmers follow these.
    @Published private(set) var realElapsed = 0.0
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
        self.realElapsed = 0
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
        self.realElapsed = 0
        self.nextRayHapticAt = 0
        self.onFrame?(self.elapsed, false)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let previousRealElapsed = self.realElapsed
            let previousElapsed = self.elapsed
            self.realElapsed = min(IntroTiming.realDuration, ProcessInfo.processInfo.systemUptime - self.startedAt)
            self.elapsed = IntroTiming.shaderTime(atReal: self.realElapsed)
            self.playHaptics(afterReal: previousRealElapsed, shader: previousElapsed)
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
        self.realElapsed = IntroTiming.realDuration
        self.onFrame?(self.elapsed, true)
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
    }

    // MARK: Private

    /// The first broad rays appear at 0.08 shader seconds. The swell reaches
    /// full speed half a second before the native window handoff, where its
    /// final accent lands. AppKit taps have fixed strength, so cadence carries it.
    private static let rayHapticStart = 0.08
    private static let climaxAtReal = IntroTiming.realHandoff - 0.5
    private static let rayHapticFull = IntroTiming.shaderTime(atReal: IntroPlayback.climaxAtReal)
    private static let rayHapticSlowInterval = 0.34
    private static let rayHapticFastInterval = 0.09

    private var timer: Timer?
    private var startedAt = 0.0
    private var nextRayHapticAt = 0.0

    private func playHaptics(afterReal previousRealElapsed: Double, shader previousElapsed: Double) {
        // A stalled frame must never dump delayed taps into the trackpad.
        guard self.realElapsed - previousRealElapsed < 0.25 else {
            self.nextRayHapticAt = self.realElapsed + Self.rayHapticSlowInterval
            return
        }

        // Leave room for a distinct final beat instead of firing two taps together.
        if self.elapsed >= Self.rayHapticStart,
           self.realElapsed < Self.climaxAtReal - Self.rayHapticFastInterval,
           self.realElapsed >= self.nextRayHapticAt
        {
            let rayDensity = IntroTiming.easeInOut(
                IntroTiming.unit(Self.rayHapticStart, Self.rayHapticFull, self.elapsed)
            )
            // Perceived energy rises sooner than a linear cadence while the
            // ray field keeps gaining detail all the way to the handoff.
            let swell = pow(rayDensity, 0.4)
            let interval = Self.rayHapticSlowInterval
                + (Self.rayHapticFastInterval - Self.rayHapticSlowInterval) * swell
            NativeHaptics.introPulse()
            self.nextRayHapticAt = self.realElapsed + interval
        }

        if previousRealElapsed < Self.climaxAtReal, self.realElapsed >= Self.climaxAtReal {
            NativeHaptics.introClimax()
        }

        if previousElapsed < WelcomeTiming.riseStart, self.elapsed >= WelcomeTiming.riseStart {
            NativeHaptics.introRiseStarted()
        }
        if previousElapsed < WelcomeTiming.riseEnd, self.elapsed >= WelcomeTiming.riseEnd {
            NativeHaptics.introRiseEnded()
        }
    }
}
