@main
enum NativeAppRankingContextChecks {
    static func main() {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }

        var contexts = NativeAppRankingContexts()
        contexts.setScope("group-a", for: nil)
        contexts.open("spotify", scope: "group-a", sourceID: nil, returning: false)
        contexts.setScope("friends", for: "spotify")
        expect(contexts.context(for: nil).scope == "group-a")
        expect(contexts.context(for: "spotify").scope == "friends")

        // A second app reached through a person must not change the ranking
        // underneath it. The person's context belongs only to the new app.
        contexts.open("cursor", scope: "everyone", sourceID: "person-b", returning: false)
        expect(contexts.context(for: "spotify").scope == "friends")
        expect(contexts.context(for: "spotify").sourceID == nil)
        expect(contexts.context(for: "cursor").sourceID == "person-b")
        expect(contexts.context(for: nil).scope == "group-a")

        // Re-entering an app already in the navigation stack is Back, so its
        // audience and source must keep the same cached page and scroll state.
        contexts.open("spotify", scope: "everyone", sourceID: "person-c", returning: true)
        expect(contexts.context(for: "spotify").scope == "friends")
        expect(contexts.context(for: "spotify").sourceID == nil)
        contexts.open("cursor", scope: "friends", sourceID: "person-c", returning: true)
        expect(contexts.context(for: "cursor").scope == "everyone")
        expect(contexts.context(for: "cursor").sourceID == "person-b")

        // A new visit after leaving the route inherits its new entry point.
        contexts.open("spotify", scope: "group-b", sourceID: "person-c", returning: false)
        expect(contexts.context(for: "spotify").scope == "group-b")
        expect(contexts.context(for: "spotify").sourceID == "person-c")
        expect(contexts.context(for: nil).sourceID == nil)
        print("Native app ranking context checks passed: \(checks)")
    }
}
