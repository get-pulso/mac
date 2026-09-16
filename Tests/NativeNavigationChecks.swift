@main
enum NativeNavigationChecks {
    // MARK: Internal

    static func main() {
        var checks = 0
        func expect(_ condition: Bool) { precondition(condition); checks += 1 }

        var history = NativeNavigationHistory<Route>()
        history.record(.friends, before: .connect)
        expect(history.previous == .friends)
        history.record(.connect, before: .history)
        expect(history.previous == .connect)
        expect(history.pop() == .connect)
        expect(history.pop() == .friends)
        expect(history.pop() == nil)

        history.record(.group, before: .group)
        expect(history.previous == nil)
        history.record(.group, before: .connect)
        history.removeAll()
        expect(history.previous == nil)

        print("Native navigation checks passed: \(checks)")
    }

    // MARK: Private

    private enum Route: Equatable { case friends, connect, history, group }
}
