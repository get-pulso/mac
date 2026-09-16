import Foundation

@main
struct NativeResourceCacheChecks {
    static func main() async throws {
        let start = Date(timeIntervalSince1970: 100)
        var cache = NativeResourceCache<String, [Int]>()
        precondition(cache.value(for: "people") == nil)
        precondition(!cache.isFresh("people", for: 30, now: start))

        cache.insert([1, 2], for: "people", now: start)
        precondition(cache.value(for: "people") == [1, 2])
        precondition(cache.isFresh("people", for: 30, now: start.addingTimeInterval(29)))
        precondition(!cache.isFresh("people", for: 30, now: start.addingTimeInterval(30)))
        precondition(cache.value(for: "people") == [1, 2]) // Stale is still renderable.

        cache.insert([3], for: "people", now: start.addingTimeInterval(100))
        cache.invalidate("people")
        precondition(cache.value(for: "people") == [3])
        precondition(!cache.isFresh("people", for: 30, now: start.addingTimeInterval(100)))

        cache.insert([3], for: "people", now: start)
        cache.update([3, 4], for: "people", now: start.addingTimeInterval(20))
        precondition(cache.value(for: "people") == [3, 4])
        precondition(!cache.isFresh("people", for: 30, now: start.addingTimeInterval(30))) // Growing keeps the age.
        cache.update([5], for: "missing", now: start)
        precondition(cache.value(for: "missing") == [5] && cache.isFresh("missing", for: 30, now: start))

        cache.removeValue(for: "people")
        precondition(!cache.contains("people"))
        cache.insert([], for: "empty", now: start)
        precondition(cache.contains("empty")) // Loaded-empty differs from never loaded.
        cache.removeAll()
        precondition(!cache.contains("empty"))

        actor Counter {
            var value = 0
            func increment() { self.value += 1 }
        }
        let counter = Counter()
        let coalescer = NativeRequestCoalescer<String, Int>()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try await coalescer.value(for: "same-request") {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(30))
                        return 42
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        precondition(values.count == 20 && values.allSatisfy { $0 == 42 })
        let coalescedCount = await counter.value
        precondition(coalescedCount == 1)

        _ = try await coalescer.value(for: "same-request") {
            await counter.increment()
            return 43
        }
        let completedCount = await counter.value
        precondition(completedCount == 2) // Completed responses are not retained here.

        let epochs = NativeRequestEpochs<String>()
        let initialEpoch = await epochs.value(for: "session")
        precondition(initialEpoch == 0)
        await epochs.advance(for: "session")
        let advancedEpoch = await epochs.value(for: "session")
        precondition(advancedEpoch == 1)
        print("Native resource cache checks passed: stale rendering, invalidation and in-flight request coalescing.")
    }
}
