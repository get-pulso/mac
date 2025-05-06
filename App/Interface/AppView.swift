import SwiftUI

struct AppView: View {
    @StateObject var appRouter: AppRouter

    var body: some View {
        switch self.appRouter.destination {
        case let .singIn(viewModel):
            SignInView(viewModel: viewModel)
                .transition(.opacity)
        case let .dashboard(viewModel):
            DashboardView(viewModel: viewModel)
                .transition(.opacity)
        default:
            ProgressView()
        }
    }
}
