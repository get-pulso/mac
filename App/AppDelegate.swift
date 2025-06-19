import Cocoa
import Combine
import Defaults
import Dependencies
import SwiftUI

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
                Defaults[.currentUserID] = nil
                try? self.storage.cleanFriendsStore()

                await MainActor.run {
                    self.appRouter.move(to: .login)
                }
            }
        }

        self.windowManager.configure()
    }

    // MARK: Private

    @Dependency(\.auth) private var auth
    @Dependency(\.storage) private var storage
    @Dependency(\.tracker) private var tracker
    @Dependency(\.appRouter) private var appRouter
    @Dependency(\.updater) private var updater
    @Dependency(\.windowManager) private var windowManager
}
