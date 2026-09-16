import Foundation

@main
enum StatusPresenceChecks {
    static func main() {
        var checks = 0
        func expect(
            _ value: @autoclosure () -> Bool,
            _ message: String,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            checks += 1
            precondition(value(), "Status presence check \(checks) failed: \(message)", file: file, line: line)
        }

        let now = ISO8601DateFormatter().date(from: "2026-09-16T08:00:00Z")!
        func candidate(_ id: String, secondsAgo: TimeInterval, avatar: String? = nil) -> StatusPresenceCandidate {
            StatusPresenceCandidate(
                id: id,
                avatarURL: avatar ?? "https://example.com/\(id).png",
                lastActiveAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
            )!
        }

        let selected = StatusPresenceSelection.avatarURLs(
            from: [
                candidate("old", secondsAgo: 121),
                candidate("third", secondsAgo: 90),
                candidate("self", secondsAgo: 0),
                candidate("first", secondsAgo: 10),
                candidate("fourth", secondsAgo: 100),
                candidate("second", secondsAgo: 30),
            ],
            excluding: "self",
            now: now
        )
        expect(
            selected.map(\.lastPathComponent) == ["first.png", "second.png", "third.png"],
            "online friends are recent-first, capped at three, and exclude the current user"
        )
        expect(
            StatusPresenceSelection.avatarURLs(
                from: [candidate("edge", secondsAgo: 120)], excluding: nil, now: now
            ).count == 1,
            "the two-minute boundary is online"
        )
        expect(
            StatusPresenceSelection.avatarURLs(
                from: [candidate("future", secondsAgo: -31)], excluding: nil, now: now
            ).isEmpty,
            "timestamps too far in the future are rejected"
        )
        expect(
            StatusPresenceCandidate(id: "bad", avatarURL: nil, lastActiveAt: "not-a-date") == nil,
            "invalid or missing avatar presence is ignored"
        )

        print("Status presence checks passed: \(checks)")
    }
}
