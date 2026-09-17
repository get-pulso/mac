import Foundation

/// Which friend events this account has been told about already.
///
/// The server forgets an event once the Mac acknowledges it; this covers the
/// read whose acknowledgement failed, so the next poll brings the same event
/// back without the notch saying it twice. Kept a week, far longer than the
/// server holds anything unacknowledged.
struct FriendEventLedger: Codable, Equatable {
    // MARK: Internal

    var seen: [String: Date] = [:]

    static func load(account: String, from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: self.key(account)),
              let ledger = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return ledger
    }

    /// The events not said before, in the order they should be said. Kinds
    /// this build does not know are left out and not remembered, so a newer
    /// build can still say them.
    mutating func ingest(_ events: [NativeFriendEvent], now: Date = Date()) -> [NativeFriendEvent] {
        self.seen = self.seen.filter { now.timeIntervalSince($0.value) < 7 * 86400 }
        var fresh: [NativeFriendEvent] = []
        for event in events where event.knownKind != nil && self.seen[event.id] == nil {
            self.seen[event.id] = now
            fresh.append(event)
        }
        return NativeFriendEvent.spoken(fresh)
    }

    func save(account: String, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(account))
    }

    // MARK: Private

    private static func key(_ account: String) -> String { "firstlight.friendEvents.seen.\(account)" }
}

extension NativeFriendEvent {
    /// How many friend events one poll may put in the notch. The rest are
    /// still acknowledged, and waiting in the popover.
    static let islandLimit = 3

    /// The order a batch is said in: requests first, since they wait on an
    /// answer, then new friends. Within each, the server's order, newest first.
    static func spoken(_ events: [NativeFriendEvent]) -> [NativeFriendEvent] {
        events.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.knownKind?.waitsOnAnswer == true ? 0 : 1
                let right = rhs.element.knownKind?.waitsOnAnswer == true ? 0 : 1
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}
