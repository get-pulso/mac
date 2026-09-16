#if DEBUG
import Foundation

/// Developer mode for the invite flow: every tray and every state on invented
/// data, without touching the server or the account. It answers the invite
/// endpoints inside `Network.request`, so the store, the trays, the timings
/// and the animations are the real ones — only the replies are made up.
///
/// Off by default, and compiled out of Release entirely. Pinned to the main
/// actor: a refresh fires several requests at once, and they all read the same
/// invented account.
@MainActor
enum InviteMocks {
    // MARK: Internal

    /// A person a mock code belongs to. `isFriend` decides whether the tray
    /// offers to add them or says they are already friends.
    struct Person {
        let id: String
        let code: String
        let name: String
        let isFriend: Bool
        var minutes: Double = 0
        /// What the About tray has to show. A person who left every field
        /// empty is a case of its own.
        var location: String?
        var bio: String?
        var website: String?
        var twitter: String?
    }

    struct Reply {
        let status: Int
        let data: Data
    }

    /// One knob, one thing that can go wrong. Each is listed in the debug bar.
    enum Flake: String, CaseIterable {
        case slowCode = "Your code loads slowly"
        case failCode = "Your code fails to load"
        case slowLookup = "Code owner resolves slowly"
        case failSend = "Sending fails once"

        // MARK: Internal

        var key: String { "firstlight.mocks.flake." + self.rawValue }
    }

    static let ownCode = "U8MUXZ62"

    /// Codes worth typing. The tray's whole friend-code range in five entries.
    static let people: [Person] = [
        Person(
            id: "mock-liana", code: "LIANA001", name: "Liana", isFriend: false, minutes: 252,
            location: "Lisbon", bio: "Designing interfaces that stay out of the way. Mostly type, sometimes motion.",
            website: "https://liana.design", twitter: "liana"
        ),
        Person(
            id: "mock-alex", code: "ALEX0002", name: "Alexander Petrov", isFriend: false, minutes: 194,
            location: "Berlin", bio: "Rust and coffee.", twitter: "apetrov"
        ),
        // Writes nothing about himself: the bare card.
        Person(id: "mock-maya", code: "MAYA0003", name: "Maya", isFriend: false, minutes: 96),
        Person(
            id: "mock-crudy", code: "FRIEND04", name: "CrudyLame", isFriend: true, minutes: 140,
            location: "SF", bio: "Shipping small things daily."
        ),
    ]

    /// Links, in the shape the app's own parser accepts.
    static let groupLink = "https://firstlight.sh/invite?token=runway"
    static let expiredLink = "https://firstlight.sh/invite?token=expired"
    static let personalLink = "https://firstlight.sh/join/LIANA001"
    static let unknownCode = "GHOST005"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: self.enabledKey)
            if !newValue { self.reset() }
        }
    }

    /// How many people are waiting on an answer. Drives the Invite badge and
    /// the row into the incoming tray.
    static var incomingCount: Int {
        get { UserDefaults.standard.object(forKey: "firstlight.mocks.incoming") as? Int ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: "firstlight.mocks.incoming") }
    }

    static var outgoingCount: Int {
        get { UserDefaults.standard.object(forKey: "firstlight.mocks.outgoing") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "firstlight.mocks.outgoing") }
    }

    static func flake(_ flake: Flake) -> Bool { UserDefaults.standard.bool(forKey: flake.key) }

    static func setFlake(_ flake: Flake, _ on: Bool) { UserDefaults.standard.set(on, forKey: flake.key) }

    /// Back to a fresh account: nobody answered, nobody added, no group.
    static func reset() {
        self.answered.removeAll()
        self.cancelled.removeAll()
        self.added.removeAll()
        self.sent.removeAll()
        self.joinedGroup = false
        self.sendFailArmed = true
    }

    /// The reply for a path this mode owns, or nil to let the request go out
    /// to the server as usual.
    static func response(
        path: String,
        method: String,
        query: [String: String?]?,
        body: Encodable?
    ) async throws -> Reply? {
        guard self.isEnabled else { return nil }
        guard let reply = try await route(path: path, method: method, query: query, body: body) else { return nil }
        return reply
    }

    // MARK: Private

    private static let enabledKey = "firstlight.mocks.enabled"

    /// Requests answered in this run, so the incoming list shrinks as you go.
    private static var answered = Set<String>()
    private static var cancelled = Set<String>()
    /// People added in this run: they join the list, the way a new friend does.
    private static var added: [Person] = []
    /// Requests sent in this run, so the Sent pill counts up.
    private static var sent: [Person] = []
    private static var joinedGroup = false
    private static var sendFailArmed = true

    private static var incoming: [Person] {
        Array(self.people.prefix(self.incomingCount)).filter { !self.answered.contains($0.id) }
    }

    private static var outgoing: [Person] {
        let standing = Array(self.people.suffix(self.outgoingCount))
            .filter { !self.cancelled.contains($0.id) }
        return standing + self.sent.filter { !self.cancelled.contains($0.id) }
    }

    private static func route(
        path: String,
        method: String,
        query: [String: String?]?,
        body: Encodable?
    ) async throws -> Reply? {
        switch (method, path) {
        case ("GET", "/api/user/invite-link"):
            if self.flake(.slowCode) { try await Task.sleep(for: .milliseconds(2200)) }
            else { try await self.hop() }
            if self.flake(.failCode) { return self.fail(500, "Your friend code isn't available right now.") }
            return self.json("""
            {"personalInviteCode":"\(self.ownCode)","personalInviteLink":"https://firstlight.sh/join/\(
                self.ownCode
            )","tokensAvailable":5}
            """)

        case ("GET", "/api/friends/requests"):
            try await self.hop()
            let incoming = self.incoming.map {
                """
                {"id":"in-\($0.id)","requester":{"id":"\($0.id)","name":"\($0.name)"},"target_user":null}
                """
            }
            let outgoing = self.outgoing.map {
                """
                {"id":"out-\($0.id)","requester":null,"target_user":{"id":"\($0.id)","name":"\($0.name)"}}
                """
            }
            return self
                .json(
                    "{\"incoming\":[\(incoming.joined(separator: ","))],\"outgoing\":[\(outgoing.joined(separator: ","))]}"
                )

        case ("GET", "/api/user/direct-friends"):
            try await self.hop()
            let ids = (self.people.filter(\.isFriend) + self.added).map { "\"\($0.id)\"" }
            return self.json("{\"directFriendIds\":[\(ids.joined(separator: ","))],\"groupFriends\":{}}")

        case ("GET", "/api/groups"):
            try await self.hop()
            var groups = ["{\"id\":\"mock-design\",\"name\":\"Design\",\"is_creator\":false}"]
            if self.joinedGroup {
                groups.append("{\"id\":\"mock-runway\",\"name\":\"Runway\",\"is_creator\":false}")
            }
            return self.json("[\(groups.joined(separator: ","))]")

        case ("GET", "/api/friends/leaderboard"):
            try await self.hop()
            return self.leaderboard()

        case ("GET", "/api/invite/info"):
            let token = query?["token"] ?? nil
            try await Task.sleep(for: .milliseconds(900))
            if token == "expired" { return self.fail(410, "This invitation has expired or was used up.") }
            return self.json("""
            {"invite":{"groupName":"Runway","inviterName":"Anna K.","inviterAvatarUrl":null,
            "memberCount":6,"isUniversal":false}}
            """)

        case ("POST", "/api/invite/accept"):
            try await Task.sleep(for: .milliseconds(900))
            self.joinedGroup = true
            return self.json("{}")

        case ("POST", "/api/friends/request"):
            try await Task.sleep(for: .milliseconds(900))
            if self.flake(.failSend), self.sendFailArmed {
                self.sendFailArmed = false
                return self.fail(500, "Couldn't reach Firstlight. Try again.")
            }
            self.sendFailArmed = true
            let payload = (body as? [String: String]) ?? [:]
            let code = (payload["inviteCode"] ?? "").uppercased()
            let fromLink = payload["source"] == "link"
            guard let person = people.first(where: { $0.code == code }) else {
                return self.fail(404, "No one is using that friend code.")
            }
            if person.isFriend || self.added.contains(where: { $0.id == person.id }) {
                return self.fail(409, "You are already friends with this user.")
            }
            // A link is the owner's own consent: it makes friends at once.
            // A bare code only asks, and waits in Sent.
            if fromLink { self.added.append(person) } else { self.sent.append(person) }
            let target = "{\"id\":\"\(person.id)\",\"name\":\"\(person.name)\"}"
            return self.json("{\"success\":true,\"connected\":\(fromLink),\"targetUser\":\(target)}")

        default:
            break
        }

        if method == "GET", path.hasPrefix("/api/join/") {
            let code = String(path.dropFirst("/api/join/".count)).uppercased()
            if self.flake(.slowLookup) { try await Task.sleep(for: .milliseconds(1600)) }
            else { try await Task.sleep(for: .milliseconds(450)) }
            guard let person = people.first(where: { $0.code == code }) else {
                return self.fail(404, "Invalid invite code")
            }
            return self.json("""
            {"invite":{"code":"\(code)","inviterId":"\(person.id)","inviterName":"\(
                person.name
            )","inviterAvatarUrl":null}}
            """)
        }
        if method == "GET", path.hasPrefix("/api/users/"), path.hasSuffix("/card") {
            try await self.hop()
            let id = String(path.dropFirst("/api/users/".count).dropLast("/card".count))
            guard let person = (people + self.added).first(where: { $0.id == id }) else {
                return self.fail(404, "Unknown person")
            }
            let field: (String?) -> String = { $0.map { "\"\($0)\"" } ?? "null" }
            return self.json("""
            {"id":"\(person.id)","name":"\(person.name)","avatar_url":null,
            "bio":\(field(person.bio)),"location":\(field(person.location)),
            "website":\(field(person.website)),"twitter":\(field(person.twitter)),"telegram":null}
            """)
        }
        if path.hasPrefix("/api/friends/requests/") {
            try await Task.sleep(for: .milliseconds(700))
            let id = String(path.dropFirst("/api/friends/requests/".count))
            if id.hasPrefix("in-") {
                let personID = String(id.dropFirst(3))
                self.answered.insert(personID)
                if let person = people.first(where: { $0.id == personID }),
                   (body as? [String: String])?["action"] == "accept"
                {
                    self.added.append(person)
                }
            }
            if id.hasPrefix("out-") { self.cancelled.insert(String(id.dropFirst(4))) }
            return self.json("{}")
        }
        return nil
    }

    /// Long enough to see a skeleton, short enough not to wait on it.
    private static func hop() async throws { try await Task.sleep(for: .milliseconds(320)) }

    private static func json(_ raw: String) -> Reply {
        Reply(status: 200, data: Data(raw.utf8))
    }

    private static func fail(_ status: Int, _ message: String) -> Reply {
        Reply(status: status, data: Data("{\"error\":\"\(message)\"}".utf8))
    }

    private static func leaderboard() -> Reply {
        let now = ISO8601DateFormatter().string(from: Date())
        var roster: [Person] = [
            Person(id: "mock-me", code: "", name: "You", isFriend: true, minutes: 354),
            Person(id: "mock-anna", code: "", name: "Anna K.", isFriend: true, minutes: 252),
            Person(id: "mock-lena", code: "", name: "Lena P.", isFriend: true, minutes: 65),
        ]
        roster.append(contentsOf: self.added)
        let items = roster.enumerated().map { index, person in
            """
            {"user_id":"\(person.id)","name":"\(person.name)","rank":\(index + 1),
            "active_minutes":\(person.minutes),"last_active_at":"\(now)",
            "location":\(index == 0 ? "\"SF\"" : "null")}
            """
        }
        return self.json("""
        {"items":[\(items.joined(separator: ","))],"total":\(roster.count),"next_offset":null,"me":null}
        """)
    }
}
#endif
