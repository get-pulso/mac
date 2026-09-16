import Foundation

/// Small in-memory cache for screen models. Views may render stale values while
/// a refresh runs, but only a missing entry is allowed to produce a skeleton.
struct NativeResourceCache<Key: Hashable, Value> {
    // MARK: Internal

    struct Entry {
        let value: Value
        let storedAt: Date
    }

    func value(for key: Key) -> Value? { self.entries[key]?.value }
    func contains(_ key: Key) -> Bool { self.entries[key] != nil }

    func isFresh(_ key: Key, for maxAge: TimeInterval, now: Date = .now) -> Bool {
        guard let entry = entries[key] else { return false }
        return now.timeIntervalSince(entry.storedAt) < maxAge
    }

    mutating func insert(_ value: Value, for key: Key, now: Date = .now) {
        self.entries[key] = Entry(value: value, storedAt: now)
    }

    /// Keeps the last renderable value but makes the next access revalidate it.
    mutating func invalidate(_ key: Key) {
        guard let entry = self.entries[key] else { return }
        self.entries[key] = Entry(value: entry.value, storedAt: .distantPast)
    }

    mutating func invalidateAll() {
        for (key, entry) in self.entries {
            self.entries[key] = Entry(value: entry.value, storedAt: .distantPast)
        }
    }

    mutating func removeValue(for key: Key) { self.entries[key] = nil }
    mutating func removeAll() { self.entries.removeAll() }

    // MARK: Private

    private var entries: [Key: Entry] = [:]
}

/// Coalesces identical requests that overlap in time. It does not retain a
/// completed response; screen caches remain the single source of stale data.
actor NativeRequestCoalescer<Key: Hashable & Sendable, Value: Sendable> {
    // MARK: Internal

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task = self.tasks[key] {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }
        let task = Task { try await operation() }
        self.tasks[key] = task
        defer { self.tasks[key] = nil }
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    // MARK: Private

    private var tasks: [Key: Task<Value, Error>] = [:]
}

/// A successful mutation advances the session epoch. GETs started afterwards
/// cannot join a response that began before that mutation completed.
actor NativeRequestEpochs<Key: Hashable & Sendable> {
    // MARK: Internal

    func value(for key: Key) -> UInt64 { self.values[key, default: 0] }

    func advance(for key: Key) {
        self.values[key, default: 0] &+= 1
    }

    // MARK: Private

    private var values: [Key: UInt64] = [:]
}
