struct NativeNavigationHistory<Route: Equatable> {
    private(set) var routes: [Route] = []

    var previous: Route? { self.routes.last }

    mutating func record(_ current: Route, before next: Route) {
        guard current != next else { return }
        self.routes.append(current)
    }

    mutating func pop() -> Route? { self.routes.popLast() }

    mutating func removeAll() { self.routes.removeAll() }

    /// A repeated destination is a return to that screen, not another copy.
    mutating func returnTo(_ route: Route) -> Bool {
        guard let index = self.routes.lastIndex(of: route) else { return false }
        self.routes.removeSubrange(index...)
        return true
    }
}
