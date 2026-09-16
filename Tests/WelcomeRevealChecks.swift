import AppKit

@main
enum WelcomeRevealChecks {
    static func main() {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool) {
            precondition(result())
            checks += 1
        }

        expect(WelcomeTiming.logoStart > 0)
        expect(WelcomeTiming.logoStart < WelcomeTiming.titleStart)
        expect(WelcomeTiming.titleStart < WelcomeTiming.buttonStart)
        expect(WelcomeTiming.buttonStart < WelcomeTiming.interactiveAt)
        expect(WelcomeTiming.interactiveAt < WelcomeTiming.duration)
        expect(WelcomeTiming.logoGoneAt < WelcomeTiming.titleStart)
        expect(WelcomeTiming.titleVisibleAt < WelcomeTiming.buttonStart)
        expect(WelcomeTiming.logoOpacity(at: 1.2) == 1)
        expect(WelcomeTiming.logoExitStart - WelcomeTiming.logoVisibleAt >= 1.2)
        expect(WelcomeTiming.buttonStart - WelcomeTiming.titleVisibleAt >= 0.8)
        expect(WelcomeTiming.logoOpacity(at: WelcomeTiming.duration) == 0)
        expect(WelcomeTiming.titleOpacity(at: WelcomeTiming.duration) == 1)
        for frame in 0 ... Int(WelcomeTiming.duration * 60) {
            let time = Double(frame) / 60
            expect(WelcomeTiming.logoOpacity(at: time) == 0 || WelcomeTiming.titleOpacity(at: time) == 0)
        }
        for start in [WelcomeTiming.logoStart, WelcomeTiming.titleStart, WelcomeTiming.buttonStart] {
            expect(WelcomeTiming.spring(0, after: start) == 0)
            expect(WelcomeTiming.spring(start, after: start) == 0)
            expect(WelcomeTiming.spring(WelcomeTiming.duration, after: start) == 1)
            for frame in 0 ... Int(WelcomeTiming.duration * 60) {
                let value = WelcomeTiming.spring(Double(frame) / 60, after: start)
                expect(value >= 0 && value < 1.1)
            }
        }

        let playback = IntroPlayback()
        playback.prepare()
        playback.finish()
        expect(playback.finished)
        expect(playback.welcomeElapsed == 0) // Ending the cloud cannot reveal prewarmed content.
        playback.beginWelcome(animated: false)
        expect(playback.welcomeElapsed == WelcomeTiming.duration)
        playback.prepare()
        expect(playback.welcomeElapsed == 0)
        playback.beginWelcome()
        playback.finishWelcome()
        expect(playback.welcomeElapsed == WelcomeTiming.duration)
        playback.prepare()
        playback.beginWelcome()
        playback.stop()
        let stopped = playback.welcomeElapsed
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(playback.welcomeElapsed == stopped) // Closing cannot keep a reveal timer running.
        print(
            "PASS: \(checks) welcome timing checks; logo → title → enabled CTA, handoff gating, cancellation, Reduce Motion path"
        )
    }
}
