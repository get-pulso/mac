import Dependencies
import SwiftUI

final class SettingsViewModel: ObservableObject {
    // MARK: Internal

    func terminate() {
        self.router.move(to: .login)
        try? self.tracker.stop()
        NSApp.terminate(self)
    }

    func logout() {
        Task {
            try await self.auth.invalidateTokens()
        }
    }

    func dashboard() {
        self.router.move(to: .dashboard)
    }

    func checkForUpdates() {
        self.updater.checkForUpdates()
    }

    // MARK: Private

    @Dependency(\.auth) private var auth: Auth
    @Dependency(\.appRouter) private var router: AppRouter
    @Dependency(\.tracker) private var tracker: Tracker
    @Dependency(\.updater) private var updater: Updater
}
