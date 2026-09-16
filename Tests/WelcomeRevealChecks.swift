import AppKit

@main
enum WelcomeRevealChecks {
    static func main() {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool) {
            precondition(result())
            checks += 1
        }

        // One shader clock: window handoff, settled mark, name, rise, header, title, button.
        expect(IntroTiming.handoff < IntroTiming.logoSettled)
        expect(RayLogoTiming.pigmentEnd <= WelcomeTiming.markImageStart) // only the finished mark is handed over
        expect(WelcomeTiming.markImageStart < WelcomeTiming.markImageVisibleAt)
        expect(WelcomeTiming.markImageVisibleAt <= WelcomeTiming.nameStart)
        expect(WelcomeTiming.markImageProgress(at: RayLogoTiming.pigmentEnd) == 0)
        expect(WelcomeTiming.markImageProgress(at: WelcomeTiming.nameStart) == 1)
        expect(IntroTiming.logoSettled < WelcomeTiming.nameStart)
        expect(WelcomeTiming.nameStart < WelcomeTiming.nameVisibleAt)
        expect(WelcomeTiming.nameVisibleAt <= WelcomeTiming.riseStart)
        expect(WelcomeTiming.riseStart < WelcomeTiming.riseEnd)
        expect(WelcomeTiming.riseEnd <= WelcomeTiming.titleStart)
        expect(WelcomeTiming.titleStart < WelcomeTiming.titleVisibleAt)
        expect(WelcomeTiming.titleVisibleAt <= WelcomeTiming.subtitleStart)
        expect(WelcomeTiming.subtitleStart < WelcomeTiming.subtitleVisibleAt)
        expect(WelcomeTiming.subtitleVisibleAt <= WelcomeTiming.buttonStart)
        expect(WelcomeTiming.subtitleOpacity(at: WelcomeTiming.titleVisibleAt) == 0)
        expect(WelcomeTiming.subtitleOpacity(at: WelcomeTiming.buttonStart) == 1)
        expect(WelcomeTiming.buttonStart < WelcomeTiming.interactiveAt)
        expect(WelcomeTiming.interactiveAt <= IntroTiming.duration)
        expect(WelcomeTiming.titleOpacity(at: IntroTiming.logoSettled) == 0)
        expect(WelcomeTiming.titleOpacity(at: IntroTiming.duration) == 1)
        expect(WelcomeTiming.buttonOpacity(at: IntroTiming.logoSettled) == 0)
        expect(WelcomeTiming.buttonOpacity(at: IntroTiming.duration) == 1)
        for frame in 0 ... Int(IntroTiming.duration * 60) {
            let time = Double(frame) / 60
            expect(WelcomeTiming.nameProgress(at: time) >= WelcomeTiming.riseProgress(at: time))
            expect(WelcomeTiming.titleOpacity(at: time) >= WelcomeTiming.subtitleOpacity(at: time))
            expect(WelcomeTiming.subtitleOpacity(at: time) >= WelcomeTiming.buttonOpacity(at: time))
            // The title only arrives once the pair has fully risen.
            expect(WelcomeTiming.titleOpacity(at: time) == 0 || WelcomeTiming.riseProgress(at: time) == 1)
            let value = WelcomeTiming.spring(time, after: WelcomeTiming.buttonStart)
            expect(value >= 0 && value < 1.1)
        }
        expect(WelcomeTiming.spring(WelcomeTiming.buttonStart, after: WelcomeTiming.buttonStart) == 0)
        expect(WelcomeTiming.spring(IntroTiming.duration + 1, after: WelcomeTiming.buttonStart) == 1)

        // The mark and the name share one geometry. Until the name starts,
        // the mark is the shader's own centred slot; once revealed the pair is
        // centred; once risen the pair sits on the header line, smaller, and stays.
        let panel = CGSize(width: 868, height: 608)
        let settled = WelcomeLayout.frame(at: IntroTiming.logoSettled, in: panel)
        expect(settled.markRect == RayLogoTiming.rect(in: panel))
        expect(settled.nameReveal == 0)
        // At the start the whole name is behind the mark; it slides out to the
        // right through the soft edge at the mark's side, and only ever forward.
        let hidden = WelcomeLayout.frame(at: WelcomeTiming.nameStart, in: panel)
        expect(hidden.nameReveal == 0 && hidden.nameSlide < 0)
        let hiddenWidth = (hidden.nameCenter.x - hidden.markRect.maxX - WelcomeLayout.gap) * 2
        expect(hidden.nameCenter.x + hidden.nameSlide + hiddenWidth / 2 <= hidden.nameWindowLeft + 0.001)
        var previousSlide = hidden.nameSlide
        var previousReveal = hidden.nameReveal
        var previousFront = hidden.nameFront
        for frame in Int(WelcomeTiming.nameStart * 60) ... Int(WelcomeTiming.nameVisibleAt * 60) {
            let now = WelcomeLayout.frame(at: Double(frame) / 60, in: panel)
            expect(now.nameSlide >= previousSlide - 0.001 && now.nameReveal >= previousReveal)
            expect(abs(now.nameWindowLeft - now.markRect.maxX) < 0.001 && now.nameFront > 0)
            expect(now.nameFront <= previousFront + 0.001) // the soft edge only ever closes
            previousFront = now.nameFront
            previousSlide = now.nameSlide
            previousReveal = now.nameReveal
        }
        let paired = WelcomeLayout.frame(at: WelcomeTiming.nameVisibleAt, in: panel)
        expect(paired.nameReveal == 1 && paired.nameSlide == 0)
        expect(paired.nameWindowLeft + paired.nameFront <= paired.markRect.maxX + WelcomeLayout.gap + 0.001)
        expect(abs(paired.markRect.midY - panel.height / 2) < 0.5)
        expect(paired.markRect.maxX < paired.nameCenter.x)
        let nameWidth = (paired.nameCenter.x - paired.markRect.maxX - WelcomeLayout.gap) * 2
        expect(abs(paired.markRect.minX + (paired.markRect.width + WelcomeLayout.gap + nameWidth) / 2 - panel.width / 2) < 1)
        let header = WelcomeLayout.frame(at: IntroTiming.duration, in: panel)
        expect(abs(header.markRect.midY - WelcomeLayout.headerCenterY) < 0.5)
        expect(abs(header.markRect.width - WelcomeLayout.headerMarkSide) < 0.5)
        expect(header.markRect.maxX < header.nameCenter.x && header.nameOpacity == 1)
        expect(abs(header.nameCenter.y - WelcomeLayout.headerCenterY) < 0.5)

        // The desktop is dark only under the floating light, never behind the window.
        expect(IntroTiming.dimming(atReal: 0) == 0)
        expect(abs(IntroTiming.dimming(atReal: 2.0) - IntroTiming.dimmingPeak) < 0.001)
        for frame in Int(IntroTiming.realHandoff * 60) ... Int(IntroTiming.realDuration * 60) {
            expect(IntroTiming.dimming(atReal: Double(frame) / 60) == 0)
        }
        // The pacing map never runs backwards and ends exactly on the clock's end.
        var previous = 0.0
        for frame in 0 ... Int(IntroTiming.realDuration * 60) {
            let shader = IntroTiming.shaderTime(atReal: Double(frame) / 60)
            expect(shader >= previous)
            previous = shader
        }
        expect(IntroTiming.shaderTime(atReal: IntroTiming.realDuration) == IntroTiming.duration)
        expect(abs(IntroTiming.shaderTime(atReal: IntroTiming.realHandoff) - IntroTiming.handoff) < 0.01)

        let playback = IntroPlayback()
        playback.prepare()
        expect(playback.elapsed == 0 && !playback.readyForNative && !playback.nativePresented)
        playback.finish()
        expect(playback.finished && playback.readyForNative)
        // Skipping lands on the header with Welcome fully in place.
        expect(WelcomeTiming.buttonOpacity(at: playback.elapsed) == 1)
        // The proxy follows the clock until the native window shows the same light,
        // then freezes at the handoff frame; the native host follows the clock.
        expect(playback.renderTime(nativeSurface: false) == playback.elapsed)
        playback.didPresentNative()
        expect(playback.renderTime(nativeSurface: false) == IntroTiming.handoff)
        expect(playback.renderTime(nativeSurface: true) == playback.elapsed)
        playback.prepare()
        expect(!playback.nativePresented && playback.elapsed == 0)
        // The clock follows the pacing map, not the wall clock directly.
        playback.start(animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.45))
        let running = playback.elapsed
        expect(running > 0 && running <= IntroTiming.shaderTime(atReal: 0.7))
        playback.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expect(playback.elapsed == running) // Closing cannot keep the clock running.
        print(
            "PASS: \(checks) welcome timing checks; handoff → mark → name → header → title → enabled CTA on one clock, geometry, dimming only before the window, tempo, freeze on handoff, cancellation"
        )
    }
}
