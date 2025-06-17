import Combine
import SwiftUI

final class AppRouter: ObservableObject {
    enum Destination: Equatable {
        case login
        case dashboard
        case settings
    }

    @Published var destination: Destination?

    func move(to destination: Destination) {
        guard self.destination != destination else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            self.destination = destination
        }
    }
}
