import Foundation

/// Pure merge rules for the paged people list. No network or UI involved.
@main
struct NativePeoplePagingChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func person(_ id: String, rank: Int? = nil) -> NativePerson {
            NativePerson(
                user_id: id, name: id, avatar_url: nil, rank: rank, active_minutes: nil, last_active_at: nil,
                bio: nil, location: nil, website: nil, twitter: nil, telegram: nil, active_app: nil
            )
        }
        func page(_ ids: [String], total: Int, next: Int?, me: NativePerson? = nil) -> NativeLeaderboardPage {
            NativeLeaderboardPage(items: ids.map { person($0) }, total: total, next_offset: next, me: me)
        }

        // An empty list asks for one page; a scrolled list asks for what it holds, up to the server cap.
        expect(NativePeopleList.empty.refreshLimit == NativePeopleList.pageSize, "Initial refresh is one page")
        let short = NativePeopleList.empty.refreshed(with: page(["a", "b"], total: 2, next: nil))
        expect(short.items.map(\.id) == ["a", "b"] && !short.hasMore, "Short ranking has no next page")
        expect(short.refreshLimit == NativePeopleList.pageSize, "Refresh never asks for less than a page")
        let deep = NativePeopleList(items: (0 ..< 700).map { person("\($0)") }, total: 1000, nextOffset: 700, me: nil)
        expect(deep.refreshLimit == NativePeopleList.maxRefreshLimit, "Refresh respects the server cap")

        // Appending skips rows that shifted into the next page and continues from what is held.
        var list = NativePeopleList.empty.refreshed(with: page(["a", "b", "c"], total: 6, next: 3))
        expect(list.nextOffset == 3, "First page reports the next offset")
        list = list.appending(page(["c", "d", "e"], total: 6, next: 6))
        expect(list.items.map(\.id) == ["a", "b", "c", "d", "e"], "Duplicate row is kept once")
        expect(list.nextOffset == 6, "Next offset is the server's position after the fetched page")
        list = list.appending(page(["e", "f"], total: 6, next: nil))
        expect(list.items.map(\.id) == ["a", "b", "c", "d", "e", "f"] && !list.hasMore, "Last page closes the list")

        // A refresh replaces the positions it covers and keeps rows beyond them. Row c held a
        // refreshed position and lost it, so it is dropped now and recovered by the next page.
        let scrolled = NativePeopleList(items: ["a", "b", "c", "d"].map { person($0) }, total: 10, nextOffset: 4, me: nil)
        let refreshed = scrolled.refreshed(with: page(["b", "a", "x"], total: 10, next: 3))
        expect(refreshed.items.map(\.id) == ["b", "a", "x", "d"], "Fresh prefix, stale tail without duplicates")
        expect(refreshed.nextOffset == 3 && refreshed.total == 10, "Next page starts right after the fresh prefix")
        let recovered = refreshed.appending(page(["c", "d", "e"], total: 10, next: 6))
        expect(recovered.items.map(\.id) == ["b", "a", "x", "d", "c", "e"], "Displaced row comes back once")
        let refreshedWhole = scrolled.refreshed(with: page(["d", "c", "b", "a"], total: 10, next: 4))
        expect(refreshedWhole.items.map(\.id) == ["d", "c", "b", "a"], "A refresh covering every held row reorders freely")
        let shrunk = scrolled.refreshed(with: page(["a", "b"], total: 2, next: nil))
        expect(shrunk.items.map(\.id) == ["a", "b"] && !shrunk.hasMore, "Tail goes when the ranking ends inside the prefix")

        // The caller's row is pinned only while it is not among the loaded rows.
        let me = person("me", rank: 77)
        var ranked = NativePeopleList.empty.refreshed(with: page(["a", "b"], total: 100, next: 2, me: me))
        expect(ranked.pinnedMe?.id == "me" && ranked.pinnedMe?.rank == 77, "Own row pinned while off the loaded list")
        ranked = ranked.appending(page(["me", "c"], total: 100, next: 4, me: me))
        expect(ranked.pinnedMe == nil, "Own row unpinned once loaded")
        ranked = NativePeopleList.empty.refreshed(with: page(["a"], total: 3, next: 1, me: me))
            .appending(page(["b"], total: 3, next: 2, me: nil))
        expect(ranked.pinnedMe?.id == "me", "Appending keeps the last known own row")
        expect(NativePeopleList.empty.refreshed(with: page([], total: 0, next: nil)).pinnedMe == nil, "Nothing to pin")

        print("Native people paging checks passed: \(checks); refresh limits, duplicate rows, stale tails and the pinned own row. No network or UI involved.")
    }
}
