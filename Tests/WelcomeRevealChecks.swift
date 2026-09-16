import AppKit

@main
enum WelcomeRevealChecks {
    static func main() {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool) {
            precondition(result())
            checks += 1
        }

        // One shader clock: window handoff, mark settled, title, button, interaction.
        expect(IntroTiming.handoff < WelcomeTiming.titleStart)
        expect(WelcomeTiming.titleStart < WelcomeTiming.titleVisibleAt)
        expect(WelcomeTiming.titleVisibleAt <= IntroTiming.logoSettled)
        expect(IntroTiming.logoSettled < WelcomeTiming.buttonStart)
        expect(WelcomeTiming.buttonStart < WelcomeTiming.interactiveAt)
        expect(WelcomeTiming.interactiveAt <= IntroTiming.duration)
        expect(WelcomeTiming.titleOpacity(at: IntroTiming.handoff) == 0)
        expect(WelcomeTiming.titleOpacity(at: IntroTiming.logoSettled) == 1)
        expect(WelcomeTiming.buttonOpacity(at: IntroTiming.logoSettled) == 0)
        expect(WelcomeTiming.buttonOpacity(at: IntroTiming.duration) == 1)
        for frame in 0 ... Int(IntroTiming.duration * 60) {
            let time = Double(frame) / 60
            expect(WelcomeTiming.titleOpacity(at: time) >= WelcomeTiming.buttonOpacity(at: time))
            let value = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
            expect(value >= 0 && value < 1.1)
        }
        expect(WelcomeTiming.spring(WelcomeTiming.buttonStart, after: WelcomeTiming.buttonStart) == 0)
        expect(WelcomeTiming.spring(IntroTiming.duration + 1, after: WelcomeTiming.buttonStart) == 1)

        // The desktop is dark only under the floating light, never behind the window.
        expect(IntroTiming.dimming(at: 0) == 0)
        expect(abs(IntroTiming.dimming(at: 1.0) - IntroTiming.dimmingPeak) < 0.001)
        for frame in Int(IntroTiming.handoff * 60) ... Int(IntroTiming.duration * 60) {
            expect(IntroTiming.dimming(at: Double(frame) / 60) == 0)
        }
        expect(IntroTiming.realSeconds(IntroTiming.duration) == IntroTiming.duration * IntroTiming.tempo)

        let playback = IntroPlayback()
        playback.prepare()
        expect(playback.elapsed == 0 && !playback.readyForNative && !playback.nativePresented)
        playback.finish()
        expect(playback.finished && playback.readyForNative)
        // Skipping lands on the static original mark with Welcome fully in place.
        expect(WelcomeTiming.buttonOpacity(at: playback.elapsed) == 1)
        // The proxy follows the clock until the native window shows the same light,
        // then freezes at the handoff frame; the native host follows the clock.
        expect(playback.renderTime(nativeSurface: false) == playback.elapsed)
        playback.didPresentNative()
        expect(playback.renderTime(nativeSurface: false) == IntroTiming.handoff)
        expect(playback.renderTime(nativeSurface: true) == playback.elapsed)
        playback.prepare()
        expect(!playback.nativePresented && playback.elapsed == 0)
        // Flow runs slower than real time by the authored tempo.
        playback.start(animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let running = playback.elapsed
        expect(running > 0.45 / IntroTiming.tempo * 0.5 && running < 0.45 / IntroTiming.tempo * 1.6)
        playback.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(playback.elapsed == running) // Closing cannot keep the clock running.
        print(
            "PASS: \(checks) welcome timing checks; handoff → mark → title → enabled CTA on one clock, dimming only before the window, tempo, freeze on handoff, cancellation"
        )
    }
}
