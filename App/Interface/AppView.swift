import SwiftUI

struct AppView: View {
    @StateObject var appRouter: AppRouter

    var body: some View {
        VStack(spacing: 0) {
            UpdateNotificationView()

            switch self.appRouter.destination {
            case let .login(viewModel):
                LoginView(viewModel: viewModel)
                    .transition(.opacity)
            case let .dashboard(viewModel):
                DashboardView(viewModel: viewModel)
                    .transition(.opacity.combined(with: .blur))
            default:
                EmptyView()
            }
        }
    }
}
