struct NativeNavigationHistory<Route: Equatable> {
    private(set) var routes: [Route] = []

    var previous: Route? { self.routes.last }

    mutating func record(_ current: Route, before next: Route) {
        guard current != next else { return }
        self.routes.append(current)
    }

    mutating func pop() -> Route? { self.routes.popLast() }

    mutating func removeAll() { self.routes.removeAll() }
}
