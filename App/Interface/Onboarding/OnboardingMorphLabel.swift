import SwiftUI

/// The onboarding pill's label. It changes the way every morphing text in the
/// app does — shared letters hold or glide sideways, the rest fade where they
/// stand — so `Continue with Google` becomes `Connecting…` on its `Con`, and
/// nothing travels up or down. See `NativeMorphText`.
struct OnboardingMorphLabel: View {
    // MARK: Lifecycle

    init(_ text: String) { self.text = text }

    // MARK: Internal

    let text: String

    var body: some View { NativeMorphText(self.text) }
}
