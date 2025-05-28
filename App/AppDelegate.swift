import Cocoa
import Dependencies

class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.tracker) var tracker: Tracker
    @Dependency(\.appRouter) var appRouter: AppRouter
    @Dependency(\.updater) var updater: Updater

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.tracker.activate()
        try? self.appRouter.dashboard()
        self.updater.start()
    }
}
