import Dependencies
import SwiftUI

@main
struct Pulso: App {
    // MARK: Lifecycle

    init() {
        self.tracker.bootstrap()
    }

    // MARK: Internal

    @Dependency(\.tracker) var tracker: Tracker

    var body: some Scene {
        MenuBarExtra("Pulso", systemImage: "star.leadinghalf.filled") {
            RootView()
        }
        .menuBarExtraStyle(.window)
    }
}
