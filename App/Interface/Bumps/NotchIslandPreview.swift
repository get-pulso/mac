#if DEBUG
import AppKit

/// The notch island on made-up arrivals, beside the running app and without
/// an account: `--preview-notch-island request`, or `accepted`, `joined`,
/// `bump`, `all`. `--preview-accept-after <seconds>` presses Accept on its own,
/// so a whole request can be watched without a hand on the trackpad. Accept
/// only waits here; nothing reaches the network. The process quits once
/// everything has been said, so a preview never lingers in the notch.
enum NotchIslandPreview {
    // MARK: Internal

    @MainActor static func showIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--preview-notch-island") else { return false }
        func value(_ flag: String) -> String? {
            guard let position = args.firstIndex(of: flag), args.indices.contains(position + 1) else { return nil }
            return args[position + 1]
        }
        let which = args.indices.contains(index + 1) && !args[index + 1].hasPrefix("--") ? args[index + 1] : "all"

        let island = BumpNotchIsland.shared
        island.acceptRequest = { _, _ in try await Task.sleep(for: .milliseconds(700)) }
        island.me = { BumpNotchIsland.Face(name: "Serafim", avatarURL: nil) }
        let events = self.events.filter { which == "all" || $0.kind == which }
        let bumps = which == "all" || which == "bump" ? self.bumps : []
        island.show(bumps, friendEvents: NativeFriendEvent.spoken(events))

        if let raw = value("--preview-accept-after"), let delay = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { island.pressAccept() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard island.isIdle else { return }
                timer.invalidate()
                NSApp.terminate(nil)
            }
        }
        return true
    }

    // MARK: Private

    /// The invite mocks' people, so the preview and the invite trays agree.
    private static let events: [NativeFriendEvent] = decode("""
    [
      {"id": "preview-request", "kind": "request", "message": "wants to be friends",
       "created_at": "2026-09-16T21:40:00Z", "request_id": "preview-request",
       "from": {"id": "mock-liana", "name": "Liana", "avatar_url": null}},
      {"id": "preview-accepted", "kind": "accepted", "message": "accepted your friend request",
       "created_at": "2026-09-16T21:39:00Z", "request_id": null,
       "from": {"id": "mock-alex", "name": "Alexander Petrov", "avatar_url": null}},
      {"id": "preview-joined", "kind": "joined", "message": "joined with your link",
       "created_at": "2026-09-16T21:38:00Z", "request_id": null,
       "from": {"id": "mock-maya", "name": "Maya", "avatar_url": null}}
    ]
    """)

    private static let bumps: [NativeBump] = decode("""
    [
      {"id": "preview-bump", "kind": "on_fire", "message": "says you're on fire 🔥",
       "created_at": "2026-09-16T21:37:00Z",
       "from": {"id": "mock-crudy", "name": "CrudyLame", "avatar_url": null}}
    ]
    """)

    private static func decode<T: Decodable>(_ json: String) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            preconditionFailure("Notch island preview fixture: \(error)")
        }
    }
}
#endif
