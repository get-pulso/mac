#if DEBUG
import AppKit
import Defaults
import os

/// Opt-in native smoke run; guarded by the same local-only mode as the simulated sends.
@MainActor enum BumpLocalTestSmoke {
    // MARK: Internal

    static func runIfRequested() async {
        // Shows the notch island with a made-up bump, without polling or sending.
        if CommandLine.arguments.contains("--bump-island-demo") {
            try? await Task.sleep(for: .seconds(2))
            BumpNotchIsland.shared.show([
                NativeBump(
                    id: "island-demo",
                    kind: "on_fire",
                    message: "says you're on fire 🔥",
                    created_at: ISO8601DateFormatter().string(from: Date()),
                    from: .init(id: "island-demo", name: "Alexey", avatar_url: nil)
                ),
            ])
            return
        }
        guard CommandLine.arguments.contains("--bump-test-smoke"), BumpLocalTestMode.isEnabled else { return }
        let log = OSLog(subsystem: "sh.firstlight.mac", category: "bump-e2e")
        do {
            let store = SocialStore.shared
            let effects = BumpEffects.shared
            WindowManager.liveValue.show()
            for _ in 0 ..< 30 where store.people.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
            guard let person = store.people
                .first(where: { $0.id != Defaults[.currentUserID] && $0.public_apps_only != true })
            else {
                throw Failure.failed("No person available in the loaded list")
            }
            store.openPerson(person)
            await effects.loadState(for: person.id)
            for _ in 0 ..< 50 {
                if !effects.stateLoading.contains(person.id) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try self.check(effects.canSend(to: person), "Loaded person is eligible")
            let before = effects.recent.filter { $0.id.hasPrefix("local-test-") }.count
            effects.send(
                .keepGoing,
                to: person,
                systemReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            try self.check(
                effects.run?.effect == .keepGoing && !effects.sending,
                "Effect starts synchronously without a network loader"
            )
            guard let deadline = effects.sent[person.id]?.nextAllowedAt
            else { throw Failure.failed("Missing cooldown") }
            try self.check((19 ... 20).contains(deadline.timeIntervalSinceNow), "20-second cooldown begins on click")
            let firstRun = effects.run?.id
            effects.send(.onFire, to: person, systemReduced: false)
            try self.check(effects.run?.id == firstRun, "Immediate repeat is blocked")
            try await Task.sleep(for: .seconds(2))
            WindowManager.liveValue.hide()
            try await Task.sleep(for: .seconds(9))
            try self.check(
                effects.recent.filter { $0.id.hasPrefix("local-test-") }.count == before + 1,
                "One echo arrives after 10 seconds while hidden"
            )
            try self.check(effects.unreadCount > 0 && effects.incoming == nil, "Hidden echo waits for presentation")
            store.showList()
            WindowManager.liveValue.show()
            try await Task.sleep(for: .seconds(1))
            try self.check(
                effects.incoming?.name == person.displayName && effects.incoming?.effect == .keepGoing,
                "Reopening presents the sender and original effect"
            )
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.25))
            store.openPerson(person)
            effects.send(.onFire, to: person, systemReduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            try self.check(
                effects.run?.effect == .onFire && effects.run?.id != firstRun,
                "Same person accepts another bump after 20 seconds"
            )
            try await Task.sleep(for: .seconds(10.5))
            try self.check(
                effects.recent.filter { $0.id.hasPrefix("local-test-") }.count == before + 2,
                "Second send receives exactly one echo"
            )
            os_log(
                "LOCAL BUMP SMOKE PASSED: immediate effect, duplicate prevention, hidden echo, sender identity, 20s resend, second echo",
                log: log,
                type: .default
            )
        } catch {
            os_log("LOCAL BUMP SMOKE FAILED: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    // MARK: Private

    private enum Failure: Error { case failed(String) }

    private static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure.failed(label) }
        os_log(
            "local smoke: %{public}@",
            log: OSLog(subsystem: "sh.firstlight.mac", category: "bump-e2e"),
            type: .default,
            label
        )
    }
}
#endif
