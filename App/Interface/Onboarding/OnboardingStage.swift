import SwiftUI

/// Where the onboarding window is in the path from Welcome to the menu bar.
/// The header — the mark and the name — is the one thing that never moves;
/// the centre of the window holds exactly one thing per step and the single
/// button at the bottom keeps its place, only its label changes.
@MainActor
final class OnboardingStage: ObservableObject {
    enum Step: Equatable {
        /// The intro and the one sign-in button: the state the window opens in.
        case welcome
        /// Google gave no first name: one field, one continue.
        case name
        /// The profile: what are you working on, a location, links.
        case about
        /// The mark leaves the header for the menu bar; the window goes.
        case handoff
    }

    static let shared = OnboardingStage()

    /// Steps only move forward, and the motion says so: the current content
    /// rises out with a little blur, the next arrives from below. The numbers
    /// are the welcome's own arrival vocabulary.
    static let forward: AnyTransition = .asymmetric(
        insertion: .offset(y: 24).combined(with: .opacity).combined(with: .blur),
        removal: .offset(y: -24).combined(with: .opacity).combined(with: .blur)
    )
    static let backward: AnyTransition = .asymmetric(
        insertion: .offset(y: -24).combined(with: .opacity).combined(with: .blur),
        removal: .offset(y: 24).combined(with: .opacity).combined(with: .blur)
    )
    static let stepDuration = 0.34
    static let stepAnimation: Animation = .spring(duration: stepDuration, bounce: 0)

    @Published var step: Step = .welcome
    /// The header mark has left for the menu bar: the window draws neither
    /// it nor the name, since the flying copy is the only one there is.
    @Published var markInFlight = false

    var isWelcome: Bool { self.step == .welcome }

    /// A step that has just come in has arrived once its spring is done.
    static func arrival() async { try? await Task.sleep(for: .seconds(self.stepDuration)) }

    func advance(to step: Step) {
        guard self.step != step else { return }
        withAnimation(Self.stepAnimation) { self.step = step }
    }

    func reset() {
        self.step = .welcome
        self.markInFlight = false
    }
}
