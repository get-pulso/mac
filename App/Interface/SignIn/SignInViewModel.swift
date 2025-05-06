import Dependencies
import SwiftUI

final class SignInViewModel: ObservableObject {
    // MARK: Internal

    func startLogin() {
        withAnimation {
            try? self.appRouter.dashboard()
        }
    }

    // MARK: Private

    @Dependency(\.appRouter) private var appRouter: AppRouter
}
