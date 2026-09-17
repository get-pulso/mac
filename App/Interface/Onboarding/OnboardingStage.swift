import SwiftUI

/// Where the onboarding window is in the path from Welcome to the menu bar.
/// The header — the mark and the name — is the one thing that never moves.
/// Welcome holds one thing in the centre; after it come the chapters, which
/// share one frame: words on the left, the thing itself on the right, and a
/// footer whose one button keeps its place while only its label changes.
@MainActor
final class OnboardingStage: ObservableObject {
    enum Step: Int, Equatable, Comparable, CaseIterable {
        /// The intro and the one sign-in button: the state the window opens in.
        case welcome
        /// Shown, not asked: the profile, and the agents behind its card.
        case day
        /// Shown, not asked: the list, the boards, a bump.
        case friends
        /// Asked: the row friends will see. Photo, name, a line, a city.
        case profile
        /// Asked: how much of the day friends see, as one of three answers.
        case privacy
        /// Asked, and skippable: a link to send, or a friend's code.
        case invite
        /// The mark leaves the header for the menu bar; the window goes.
        case handoff

        // MARK: Internal

        /// The chapters, in order: what the dashes in the footer count.
        static let chapters: [Step] = [.day, .friends, .profile, .privacy, .invite]

        var isChapter: Bool { Self.chapters.contains(self) }

        /// A chapter that shows has rows to step through; one that asks has none.
        var rows: Int {
            switch self {
            case .day: 2
            case .friends: 3
            default: 0
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let shared = OnboardingStage()

    /// Forward, the current content rises out with a little blur and the next
    /// arrives from below; back is the same motion the other way. The numbers
    /// are the welcome's own arrival vocabulary.
    static let forward: AnyTransition = .asymmetric(
        insertion: .offset(y: 24).combined(with: .opacity).combined(with: .blur),
        removal: .offset(y: -24).combined(with: .opacity).combined(with: .blur)
    )
    static let backward: AnyTransition = .asymmetric(
        insertion: .offset(y: -24).combined(with: .opacity).combined(with: .blur),
        removal: .offset(y: 24).combined(with: .opacity).combined(with: .blur)
    )
    /// How far a page turns. Well clear of the 16 pt the popover pushes its
    /// own screens by, so the window changing chapter is never read as the
    /// popover moving between screens inside one.
    static let pageTurn: CGFloat = 64
    /// The frame changing chapter: the page turns sideways, forward the way
    /// Continue reads and back the other way. Only what leaves takes this —
    /// what stays between two chapters, the popover and the row friends will
    /// see, keeps its place and changes where it stands. Reduce Motion takes
    /// the travel away and leaves the change itself.
    static let turningForward: AnyTransition = .asymmetric(
        insertion: .offset(x: pageTurn).combined(with: .opacity).combined(with: .blur),
        removal: .offset(x: -pageTurn).combined(with: .opacity).combined(with: .blur)
    )
    static let turningBackward: AnyTransition = .asymmetric(
        insertion: .offset(x: -pageTurn).combined(with: .opacity).combined(with: .blur),
        removal: .offset(x: pageTurn).combined(with: .opacity).combined(with: .blur)
    )
    /// The chapters as a whole: they arrive the way one chapter gives way to
    /// the next, and at the end they simply go. What happens next — the mark
    /// leaving for the menu bar — is the event, and a second flourish under
    /// it only competes with it.
    static func chapters(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : turningForward,
            removal: .opacity.animation(.easeOut(duration: 0.18))
        )
    }
    static let stepDuration = 0.34
    static let stepAnimation: Animation = .spring(duration: stepDuration, bounce: 0)

    @Published var step: Step = .welcome
    /// Which row of a showing chapter is open. Continue walks the rows before
    /// it leaves the chapter, so nobody has to find them to see them.
    @Published private(set) var row = 0
    /// Which way the last move went, for the transition of what it brought in.
    @Published private(set) var movingForward = true
    /// The header mark has left for the menu bar: the window draws neither
    /// it nor the name, since the flying copy is the only one there is.
    @Published var markInFlight = false
    /// Who the invitation that brought this person here was from, once Welcome
    /// has looked it up: the last chapter greets them with that face.
    @Published var inviter: WelcomeInvite.Inviter?

    var isWelcome: Bool { self.step == .welcome }

    /// What changes inside a chapter's own frame, which rises and falls.
    var transition: AnyTransition { self.movingForward ? Self.forward : Self.backward }

    /// The frame itself changing chapter, which turns sideways — or, where
    /// the system asks for less motion, gives way without travelling at all.
    func turn(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return self.movingForward ? Self.turningForward : Self.turningBackward
    }

    /// A step that has just come in has arrived once its spring is done.
    static func arrival() async { try? await Task.sleep(for: .seconds(self.stepDuration)) }

    func advance(to step: Step, row: Int = 0) {
        guard self.step != step else { return }
        // Set apart from the step, and first: a transition is read when the
        // view is inserted, so the direction has to be there already.
        self.movingForward = step > self.step
        withAnimation(Self.stepAnimation) {
            self.step = step
            self.row = min(max(row, 0), max(step.rows - 1, 0))
        }
    }

    func open(row: Int) {
        guard row != self.row, row >= 0, row < self.step.rows else { return }
        withAnimation(Self.stepAnimation) { self.row = row }
    }

    func reset() {
        self.step = .welcome
        self.row = 0
        self.movingForward = true
        self.markInFlight = false
        self.inviter = nil
    }
}
