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
        expect(
            controls.contains("var maximumHeight = NativeLayout.peopleBodyHeight"),
            "Detail screens must use the same maximum body height as the people list"
        )
        expect(
            !controls.contains("@State private var measuredHeight: CGFloat = 120"),
            "A detail screen must not animate through an arbitrary placeholder height"
        )
        expect(
            controls.contains("var reservesMaximumHeight = false"),
            "A loading profile must be able to reserve the finished detail height"
        )
        expect(
            controls.contains("reservesMaximumHeight ? maximumHeight"),
            "Reserved profile loading must use the maximum detail height"
        )

        let dashboard = try read("App/Interface/Dashboard/NativeDashboardView.swift")
        expect(
            dashboard.contains("PopoverContent(reservesMaximumHeight: self.isLoadingProfileActivity)"),
            "A profile with known activity must not resize again while its breakdown loads"
        )
        expect(
            dashboard.contains("NativeTrackedAppsSkeleton()"),
            "The delayed activity breakdown must stand in as app rows, not a spinner"
        )
        expect(
            controls.contains("NativeDelayedSkeleton(delay: .zero)"),
            "A skeleton filling reserved height must appear immediately, without the flash threshold"
        )

        let layout = try read("App/Helpers/NativeLayout.swift")
        expect(
            layout.contains("peopleBodyHeight = peopleListHeight + peopleFooterHeight"),
            "The initial detail height must track the actual list layout"
        )

        print("Native window motion checks passed: \(checks)")
    }
}
