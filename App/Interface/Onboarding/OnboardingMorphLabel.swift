import SwiftUI

/// A one-line label whose text changes by morphing rather than by swapping:
/// the letters the old and new text share stay where they are, only the part
/// that differs leaves upward and arrives from below. `Continue with Google`
/// becomes `Connecting…` by keeping its `Con`; `Skip for now` becomes
/// `Continue` by keeping nothing and still moving as one piece, so the eye
/// sees a change of state rather than a new button.
struct OnboardingMorphLabel: View {
    // MARK: Lifecycle

    init(_ text: String) {
        self.text = text
        _shown = State(initialValue: text)
        _split = State(initialValue: text.count)
    }

    // MARK: Internal

    let text: String

    var body: some View {
        let prefix = String(self.shown.prefix(self.split))
        let suffix = String(self.shown.dropFirst(self.split))
        HStack(spacing: 0) {
            if !prefix.isEmpty { Text(prefix) }
            ZStack(alignment: .leading) {
                Text(suffix)
                    .id(self.shown)
                    .transition(.asymmetric(
                        insertion: .offset(y: 7).combined(with: .opacity),
                        removal: .offset(y: -7).combined(with: .opacity)
                    ))
            }
        }
        .lineLimit(1)
        .fixedSize()
        .onChange(of: self.text) { old, new in
            self.split = self.reduceMotion ? 0 : Self.sharedPrefixLength(old, new)
            withAnimation(self.reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2)) {
                self.shown = new
            }
        }
        .accessibilityLabel(self.text)
    }

    // MARK: Private

    @State private var shown: String
    @State private var split: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fewer than three shared letters read as a coincidence, not a link.
    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count >= 3 ? count : 0
    }
}
