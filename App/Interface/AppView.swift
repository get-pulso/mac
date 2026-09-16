import SwiftUI
import WindowAnimation

struct AppView: View {
    @StateObject var appRouter: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            UpdateNotificationView()

            switch self.appRouter.destination {
            case .login:
                // Authentication is hosted by the real onboarding NSWindow.
                EmptyView()
            case .signInCompletion:
                SignInCompletionView()
            case .dashboard:
                NativeDashboardView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.opacity)
            case .none:
                EmptyView()
            }
        }
        .frame(width: 350)
        .modifier(
            WindowAnimationModifier(
                speed: WindowMotion.speed,
                alignment: .top,
                animation: .init(
                    angularFrequency: WindowMotion.angularFrequency,
                    dampingRatio: WindowMotion.dampingRatio,
                    threshold: WindowMotion.threshold,
                    stopWhenHitTarget: true
                )
            )
        )
    }
}

private enum WindowMotion {
    // About 200 ms for the largest panel changes. Critical damping keeps the
    // menu-bar edge steady and avoids the one-frame snap at the first crossing.
    static let speed = 4.2
    static let angularFrequency = 9.0
    static let dampingRatio = 1.0
    static let threshold = 0.5
}
