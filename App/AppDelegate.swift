import Cocoa
import Dependencies

class AppDelegate: NSObject, NSApplicationDelegate {
    @Dependency(\.tracker) var tracker: Tracker
    @Dependency(\.appRouter) var appRouter: AppRouter

    func applicationDidFinishLaunching(_ notification: Notification) {
        let eventManager = NSAppleEventManager.shared()
        eventManager.setEventHandler(
            self,
            andSelector: #selector(self.handleAppleEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )

        self.tracker.activate()
        self.appRouter.login()
    }

    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "pulso"
        else { return }
    }
}
