import Foundation

struct BumpReceivedMoment: Identifiable, Codable {
    // MARK: Lifecycle

    init(id: String, name: String, avatarURL: String?, effect: BumpEffect, receivedAt: Date) {
        self.id = id; self.name = name; self.avatarURL = avatarURL
        self.effect = effect; self.receivedAt = receivedAt
    }

    init(_ bump: NativeBump) {
        self.id = bump.id; self.name = bump.from.displayName; self.avatarURL = bump.from.avatar_url
        self.effect = .forKind(bump.kind); self.receivedAt = BumpJournal.timestamp(bump.created_at) ?? Date()
        self.kind = bump.kind; self.message = bump.message
    }

    // MARK: Internal

    let id: String
    let name: String
    let avatarURL: String?
    let effect: BumpEffect
    let receivedAt: Date
    var kind: String? = nil
    var message: String? = nil

    var title: String {
        switch self.kind {
        case "hard_worker": "Hard worker"
        case "respect": "Respect"
        case let kind? where BumpEffect(rawValue: kind) == nil: "A bump for you"
        default: self.effect.title
        }
    }
}

struct BumpSentReceipt: Codable {
    let effect: BumpEffect
    let nextAllowedAt: Date
    var daily = false
}

/// Write the account's inbox atomically before acknowledging delivery. Seen IDs
/// outlive played moments, so a repeated GET never replays an old effect.
struct BumpJournal: Codable {
    var recent: [BumpReceivedMoment] = []
    var seen: [String: Date] = [:]
    var unread: Set<String> = []
    var sent: [String: BumpSentReceipt] = [:]

    static func timestamp(_ raw: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    static func file(for account: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Firstlight/Bumps", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Account IDs are UUIDs; encode defensively to keep them inside this folder.
        let key = Data(account.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return root.appendingPathComponent(key + ".json")
    }

    static func load(from file: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    mutating func ingest(_ moments: [BumpReceivedMoment], now: Date = Date()) -> [BumpReceivedMoment] {
        self.seen = self.seen.filter { now.timeIntervalSince($0.value) < 7 * 86400 }
        var fresh: [BumpReceivedMoment] = []
        for moment in moments where self.seen[moment.id] == nil {
            self.seen[moment.id] = now; self.unread.insert(moment.id); fresh.append(moment)
        }
        // Never trim an unplayed bump. Only already-played items are bounded.
        let ordered = (fresh + self.recent).sorted { $0.receivedAt > $1.receivedAt }
        self.recent = ordered.enumerated().filter { $0.offset < 50 || self.unread.contains($0.element.id) }
            .map(\.element)
        self.unread.formIntersection(Set(self.recent.map(\.id)))
        self.sent = self.sent.filter { $0.value.nextAllowedAt > now }
        return fresh
    }

    func save(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
