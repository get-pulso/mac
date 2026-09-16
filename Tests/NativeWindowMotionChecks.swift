import Foundation

@main
enum NativeWindowMotionChecks {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }

        func read(_ path: String) throws -> String {
            try String(contentsOfFile: path, encoding: .utf8)
        }

        let app = try read("App/Interface/AppView.swift")
        expect(app.contains("alignment: .top"), "Popover resize must remain anchored to the menu bar")
        expect(app.contains("static let dampingRatio = 1.0"), "Window resize must be critically damped")
        expect(app.contains("static let speed = 4.2"), "Window resize must keep the tuned native pace")
        expect(app.contains("static let threshold = 0.5"), "Window resize must settle without a visible final jump")

        let controls = try read("App/Interface/NativeControls.swift")
        expect(
            controls.contains("@State private var measuredHeight = NativeLayout.peopleBodyHeight"),
            "A detail screen must begin at the current list body height"
        )
        expect(!controls.contains("@State private var measuredHeight: CGFloat = 120"),
               "A detail screen must not animate through an arbitrary placeholder height")

        let layout = try read("App/Helpers/NativeLayout.swift")
        expect(layout.contains("peopleBodyHeight = peopleListHeight + peopleFooterHeight"),
               "The initial detail height must track the actual list layout")

        print("Native window motion checks passed: \(checks)")
    }
}
