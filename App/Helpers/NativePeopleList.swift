import Foundation

/// One tab and period of the ranking, as far as the popover has scrolled it.
/// The server pages by offset; this keeps the loaded prefix consistent across
/// appends and periodic refreshes without ever moving rows out from under
/// the cursor.
struct NativePeopleList {
    static let pageSize = 50
    /// The server caps one page here, so a refresh cannot re-request more.
    static let maxRefreshLimit = 500
    static let empty = NativePeopleList(items: [], total: 0, nextOffset: nil, me: nil)

    var items: [NativePerson]
    var total: Int
    var nextOffset: Int?
    var me: NativePerson?

    var hasMore: Bool { self.nextOffset != nil }

    /// The caller's own row, shown under the list while it is not among the
    /// loaded rows, so a low rank is visible without scrolling to it.
    var pinnedMe: NativePerson? {
        guard let me, !self.items.contains(where: { $0.id == me.id }) else { return nil }
        return me
    }

    /// A refresh re-requests what is on screen so every loaded row is current.
    var refreshLimit: Int { min(max(self.items.count, Self.pageSize), Self.maxRefreshLimit) }

    /// The fresh prefix replaces the positions it covers. Rows loaded beyond
    /// the refresh cap keep their last values rather than disappearing
    /// mid-scroll; they go only when the ranking now ends inside the prefix.
    /// The next offset is the server's, so a row that slipped below the
    /// prefix is picked up by the next page instead of being skipped.
    func refreshed(with page: NativeLeaderboardPage) -> NativePeopleList {
        var merged = page.items
        if page.next_offset != nil {
            let fresh = Set(page.items.map(\.id))
            merged += self.items.dropFirst(page.items.count).filter { !fresh.contains($0.id) }
        }
        return NativePeopleList(items: merged, total: page.total, nextOffset: page.next_offset, me: page.me)
    }

    /// Ranks shift between requests, so a row can arrive twice; it is kept
    /// once. Offsets stay the server's: re-fetching a known row is harmless,
    /// skipping an unknown one is not.
    func appending(_ page: NativeLeaderboardPage) -> NativePeopleList {
        let known = Set(self.items.map(\.id))
        return NativePeopleList(
            items: self.items + page.items.filter { !known.contains($0.id) },
            total: page.total,
            nextOffset: page.next_offset,
            me: page.me ?? self.me
        )
    }
}
