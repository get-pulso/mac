import Combine
import SwiftUI

final class AppRouter: ObservableObject {
    // MARK: Internal

    enum Destination {
        case singIn(SignInViewModel)
        case dashboard(DashboardViewModel)
    }

    @Published var destination: Destination?

    var visibilityPublisher: AnyPublisher<Bool, Never> {
        self.visibilitySubject.eraseToAnyPublisher()
    }

    func login() {
        if case .singIn = self.destination { return }
        withAnimation {
            self.destination = .singIn(SignInViewModel())
        }
    }

    func dashboard() throws {
        if case .dashboard = self.destination { return }
        try withAnimation {
            self.destination = try .dashboard(DashboardViewModel())
        }
    }

    func hide() {
        self.visibilitySubject.send(false)
    }

    func show() {
        self.visibilitySubject.send(true)
    }

    // MARK: Private

    private let visibilitySubject = PassthroughSubject<Bool, Never>()
}
