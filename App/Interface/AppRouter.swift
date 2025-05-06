import SwiftUI

final class AppRouter: ObservableObject {
    enum Destination {
        case singIn(SignInViewModel)
        case dashboard(DashboardViewModel)
    }

    @Published var destination: Destination?

    func login() {
        self.destination = .singIn(SignInViewModel())
    }

    func dashboard() throws {
        self.destination = try .dashboard(DashboardViewModel())
    }
}
