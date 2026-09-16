import Foundation

/// Where a row stands in the ranking, as the list prints it.
///
/// The server numbers every row it sends, people with no activity included,
/// and tied rows share a number. A row that arrives without one came from an
/// older server; it is still part of the loaded prefix, so its position there
/// is its place.
enum LeaderboardPlace {
    /// The first three places are worth recognising; the rest read as plain
    /// positions.
    enum Medal { case gold, silver, bronze }

    static func place(rank: Int?, loadedIndex: Int?) -> Int? {
        if let rank, rank > 0 { return rank }
        guard let loadedIndex, loadedIndex >= 0 else { return nil }
        return loadedIndex + 1
    }

    static func medal(for place: Int?) -> Medal? {
        switch place {
        case 1: .gold
        case 2: .silver
        case 3: .bronze
        default: nil
        }
    }

    /// The caller's standing in the ranking they are looking at. The total is
    /// the whole board, not the part that has been scrolled into memory, and
    /// is left out when the client does not know it yet.
    static func summary(place: Int?, total: Int) -> String? {
        guard let place else { return nil }
        guard total >= place else { return "#\(place)" }
        return "#\(place) of \(total)"
    }
}
