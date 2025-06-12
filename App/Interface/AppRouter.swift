import Combine
import SwiftUI

final class AppRouter: ObservableObject {
    // MARK: Internal

    enum Destination: Equatable {
        case login
        case dashboard
        case settings
    }

    @Published var destination: Destination?

    var visibilityPublisher: AnyPublisher<Bool, Never> {
        self.visibilitySubject.eraseToAnyPublisher()
    }

    func move(to destination: Destination) {
        guard self.destination != destination else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            self.destination = destination
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
