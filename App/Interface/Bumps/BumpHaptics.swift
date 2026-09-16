import AppKit
import os

/// Uses the same AppKit performer as the welcome scene. No artificial intensity setting.
@MainActor final class BumpHaptics {
    // MARK: Internal

    func stop() { self.task?.cancel(); self.task = nil }

    func play(_ run: BumpEffectRun) {
        self.stop()
        guard run.frozenTime == nil else { return }
        let cues = BumpHapticScore.cues(effect: run.effect, reduced: run.reduced, incoming: run.incoming)
        self.task = Task { @MainActor in
            var previous = 0.0
            for cue in cues {
                let target = cue.time * (run.slow ? 3 : 1)
                do { try await Task.sleep(for: .seconds(max(0, target - previous))) }
                catch { return }
                previous = target
                // Never dump overdue pulses into the trackpad after a stalled frame.
                guard !Task.isCancelled, Date().timeIntervalSince(run.started) - target < 0.18,
                      NSApp.windows.contains(where: \.isVisible) else { continue }
                NSHapticFeedbackManager.defaultPerformer.perform(
                    cue.impact ? .generic : .alignment, performanceTime: .drawCompleted
                )
                #if DEBUG
                if CommandLine.arguments.contains("--bump-diagnostics") {
                    os_log(
                        "haptic kind=%{public}@ direction=%{public}@",
                        log: OSLog(subsystem: "sh.firstlight.mac", category: "bump-e2e"),
                        type: .default,
                        run.effect.rawValue,
                        run.incoming ? "incoming" : "outgoing"
                    )
                    NSLog("FirstlightBumpHaptic %@ %@", run.effect.rawValue, run.incoming ? "incoming" : "outgoing")
                }
                #endif
            }
        }
    }

    // MARK: Private

    private var task: Task<Void, Never>?
}
