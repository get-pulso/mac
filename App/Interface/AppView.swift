import SwiftUI
import WindowAnimation

struct AppView: View {
    @StateObject var appRouter: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            UpdateNotificationView()

            switch self.appRouter.destination {
            case .login:
                LoginView()
                    .transition(.opacity)
            case .dashboard:
                DashboardView()
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.opacity)
            case .none:
                EmptyView()
            }
        }
        .frame(width: 300)
        .modifier(
            WindowAnimationModifier(
                speed: 10,
                animation: .forInterfaceAnimation
            )
        )
    }
}
