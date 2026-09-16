import Foundation

@main struct BumpDeliveryChecks {
    static func main() throws {
        var checks = 0
        func expect(_ value: Bool) { precondition(value); checks += 1 }
        let now = Date()
        let moment = BumpReceivedMoment(id: "one", name: "Test", avatarURL: nil, effect: .keepGoing, receivedAt: now)
        var journal = BumpJournal()
        expect(journal.ingest([moment], now: now).count == 1)
        expect(journal.unread == ["one"])
        expect(journal.ingest([moment], now: now).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("account.json")
        journal.sent["friend"] = .init(effect: .onFire, nextAllowedAt: now.addingTimeInterval(1800))
        try journal.save(to: file)
        var restored = try BumpJournal.load(from: file)
        expect(restored.recent.first?.id == "one")
        expect(restored.sent["friend"]?.nextAllowedAt == journal.sent["friend"]?.nextAllowedAt)
        expect(restored.ingest([moment], now: now).isEmpty)
        expect(restored.unread.count == 1)
        expect(try BumpJournal.load(from: root.appendingPathComponent("other-account.json")).recent.isEmpty)
        for i in 0..<70 {
            _ = restored.ingest([.init(id: "extra-\(i)", name: "Friend", avatarURL: nil,
                                      effect: .goodJob, receivedAt: now.addingTimeInterval(Double(i + 1)))], now: now)
        }
        expect(restored.recent.count == 71)
        expect(restored.unread.count == 71)
        restored.unread.removeAll()
        _ = restored.ingest([], now: now)
        expect(restored.recent.count == 50)
        expect(restored.ingest([moment], now: now).isEmpty) // trimmed history still deduplicates
        _ = restored.ingest([], now: now.addingTimeInterval(1801))
        expect(restored.sent.isEmpty)
        expect(BumpJournal.timestamp("2026-09-16T22:00:00.123Z") != nil)
        expect(BumpJournal.timestamp("2026-09-16T22:00:00Z") != nil)
        let incoming = try JSONDecoder().decode(NativeBump.self, from: Data("""
        {"id":"legacy", "kind":"respect", "message":"respects the grind", "created_at":"2026-09-16T22:00:00.123Z",
         "from":{"id":"friend", "name":"Sam", "avatar_url":null}}
        """.utf8))
        expect(BumpReceivedMoment(incoming).title == "Respect")
        expect(BumpReceivedMoment(incoming).effect == .goodJob)
        let state = try JSONDecoder().decode(NativeBumpState.self, from: Data("{\"can_send\":false}".utf8))
        expect(!state.can_send)
        print("Bump delivery contracts passed: \(checks)")
    }
}
