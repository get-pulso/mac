import Foundation

/// Pure rules for the place a leaderboard row shows. No network or UI involved.
@main
struct NativeLeaderboardPlaceChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        // The server's number wins wherever it exists, ties included: two rows
        // on the same total both read as second, and neither takes third.
        expect(LeaderboardPlace.place(rank: 2, loadedIndex: 1) == 2, "Server place is used as sent")
        expect(LeaderboardPlace.place(rank: 2, loadedIndex: 2) == 2, "A tie keeps its shared place")
        expect(LeaderboardPlace.place(rank: 812, loadedIndex: nil) == 812, "A pinned row needs no position")

        // An older server sends no number. A loaded row is still somewhere in
        // the list, so its position answers for it, counting from one.
        expect(LeaderboardPlace.place(rank: nil, loadedIndex: 0) == 1, "First loaded row is first place")
        expect(LeaderboardPlace.place(rank: nil, loadedIndex: 41) == 42, "Position counts from one")
        expect(LeaderboardPlace.place(rank: nil, loadedIndex: nil) == nil, "Nothing to show without either")
        expect(LeaderboardPlace.place(rank: 0, loadedIndex: 3) == 4, "A zero place is not a place")
        expect(LeaderboardPlace.place(rank: -1, loadedIndex: nil) == nil, "A negative place is not a place")
        expect(LeaderboardPlace.place(rank: nil, loadedIndex: -1) == nil, "A negative position is not a place")

        // Only the first three places are marked.
        expect(LeaderboardPlace.medal(for: 1) == .gold, "First place")
        expect(LeaderboardPlace.medal(for: 2) == .silver, "Second place")
        expect(LeaderboardPlace.medal(for: 3) == .bronze, "Third place")
        expect(LeaderboardPlace.medal(for: 4) == nil, "Fourth place is a plain position")
        expect(LeaderboardPlace.medal(for: nil) == nil, "No place, no medal")

        // The profile line names the whole board, not the loaded part of it.
        expect(LeaderboardPlace.summary(place: 3, total: 26) == "#3 of 26", "Place within the board")
        expect(LeaderboardPlace.summary(place: nil, total: 26) == nil, "No place, no line")
        expect(LeaderboardPlace.summary(place: 4, total: 0) == "#4", "An unknown total is left out")
        expect(LeaderboardPlace.summary(place: 9, total: 4) == "#9", "A total behind the place is left out")
        expect(LeaderboardPlace.summary(place: 1, total: 1) == "#1 of 1", "A board of one still reads")

        print("Leaderboard place checks passed: \(checks); no network or UI involved.")
    }
}
