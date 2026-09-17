import Foundation

/// Friend events on the wire and in the ledger: what an older or a newer
/// server answers, what one bad event costs, what is said, in what order, and
/// that nothing is said twice.
@main struct FriendEventChecks {
    /// The inbox as the build before friend events decoded it.
    private struct ShippedInbox: Decodable {
        let bumps: [NativeBump]
        let phrases: [NativeBumpPhrase]
    }

    static func main() throws {
        var checks = 0
        func expect(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
        }
        let decoder = JSONDecoder()
        func inbox(_ json: String) throws -> NativeBumpInbox {
            try decoder.decode(NativeBumpInbox.self, from: Data(json.utf8))
        }

        let bump = #"""
        {"id":"b1","kind":"on_fire","message":"says you're on fire 🔥","created_at":"2026-09-16T22:00:00.123Z",
         "from":{"id":"crudy","name":"CrudyLame","avatar_url":null}}
        """#
        let phrases = #"[{"kind":"good_job","label":"Good job","message":"says good job 👏"}]"#
        func event(_ id: String, _ kind: String, from person: String, request: String? = nil) -> String {
            let requestField = request.map { #","request_id":"\#($0)""# } ?? ""
            return #"""
            {"id":"\#(id)","kind":"\#(kind)","message":"words for \#(kind)","created_at":"2026-09-16T22:00:00Z"\#(requestField),
             "from":{"id":"\#(person)","name":"\#(person)","avatar_url":null}}
            """#
        }

        // An older server says nothing about friends.
        let older = try inbox(#"{"bumps":[\#(bump)],"phrases":\#(phrases)}"#)
        expect(older.bumps.count == 1 && older.friendEvents.isEmpty, "older server: bumps, no events")

        // A newer one: three kinds, a kind from the future, and one broken event.
        let events = [
            event("e1", "joined", from: "maya"),
            event("e2", "request", from: "liana", request: "r1"),
            event("e3", "poke", from: "stranger"),
            event("e4", "accepted", from: "alex", request: "r0"),
            #"{"id":"e5","kind":"request","message":"no face","created_at":"2026-09-16T22:00:00Z"}"#,
        ].joined(separator: ",")
        let newer = #"{"bumps":[\#(bump)],"phrases":\#(phrases),"friendEvents":[\#(events)]}"#
        let decoded = try inbox(newer)
        expect(decoded.bumps.map(\.id) == ["b1"], "a broken event costs the bumps nothing")
        expect(decoded.friendEvents.map(\.id) == ["e1", "e2", "e3", "e4"], "a broken event costs only itself")
        expect(decoded.friendEvents[1].knownKind == .request, "request kind")
        expect(decoded.friendEvents[1].request_id == "r1", "request carries its id")
        expect(decoded.friendEvents[0].request_id == nil, "an absent request id is nil")
        expect(decoded.friendEvents[2].knownKind == nil, "a kind from the future is unknown, not an error")
        expect(decoded.friendEvents[1].from.displayName == "liana", "sender")

        let shipped = try decoder.decode(ShippedInbox.self, from: Data(newer.utf8))
        expect(shipped.bumps.count == 1, "the build before friend events reads the new answer")

        let garbled = try inbox(#"{"bumps":[\#(bump)],"phrases":\#(phrases),"friendEvents":"soon"}"#)
        expect(garbled.bumps.count == 1 && garbled.friendEvents.isEmpty, "a garbled list is no events")

        // Said once, requests first, the server's order within each kind.
        let now = Date()
        var ledger = FriendEventLedger()
        let fresh = ledger.ingest(decoded.friendEvents, now: now)
        expect(fresh.map(\.id) == ["e2", "e1", "e4"], "requests first, then new friends, newest first")
        expect(ledger.ingest(decoded.friendEvents, now: now).isEmpty, "nothing is said twice")
        expect(ledger.seen["e3"] == nil, "an unknown kind is not remembered, so a newer build can say it")
        _ = ledger.ingest([], now: now.addingTimeInterval(8 * 86400))
        expect(ledger.seen.isEmpty, "the ledger forgets after a week")

        // Kept per account.
        let suite = "firstlight.friend-event-checks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = FriendEventLedger()
        _ = saved.ingest(decoded.friendEvents, now: now)
        saved.save(account: "account-a", to: defaults)
        var restored = FriendEventLedger.load(account: "account-a", from: defaults)
        expect(restored == saved, "the ledger survives a relaunch")
        expect(restored.ingest(decoded.friendEvents, now: now).isEmpty, "and still says nothing twice")
        expect(FriendEventLedger.load(account: "account-b", from: defaults).seen.isEmpty, "another account starts clean")

        expect(NativeFriendEvent.spoken([]).isEmpty, "an empty batch")
        expect(NativeFriendEvent.islandLimit == 3, "three islands a poll at most")

        print("Friend event checks passed: \(checks)")
    }
}
