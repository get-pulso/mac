import Cocoa
import Combine
import Defaults
import Dependencies

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Internal

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.tracker.activate()
        self.updater.start()
        Defaults[.sessionCounter] += 1
        Task {
            if await self.auth.hasToken {
                // cleaning auth from previos installations
                if Defaults[.sessionCounter] == 1 {
                    try? await self.auth.invalidateTokens()
                    self.appRouter.move(to: .login)
                } else {
                    self.appRouter.move(to: .dashboard)
                }
            } else {
                self.appRouter.move(to: .login)
            }

            // observing logout
            for await _ in await self.auth.invalidationPublisher.values {
                await MainActor.run {
                    self.appRouter.move(to: .login)
                }
            }
        }
    }

    // MARK: Private

    @Dependency(\.auth) private var auth: Auth
    @Dependency(\.tracker) private var tracker: Tracker
    @Dependency(\.appRouter) private var appRouter: AppRouter
    @Dependency(\.updater) private var updater: Updater
}
