import SwiftUI

/// One action and one default shortcut, shared by the real sign-in and safe
/// preview. The same pill as the arrival page's button: Firstlight's violet
/// running top to bottom, a hairline of light on the upper edge, and on
/// macOS 26 the system's glass under it.
struct OnboardingContinueButton: View {
    // MARK: Internal

    var isLoading = false
    var isEnabled = true
    var loadingTitle = "Opening Google…"
    /// The one button of the onboarding keeps its place from Welcome to the
    /// end; later steps only give it another title.
    var title: String?
    var account: WelcomeAccount?
    var avatar: AnyView?
    var action: () -> Void

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Glass tinted with the page's violet: the light of the arrival
                // page, now with the system's material under it.
                Button(action: action) {
                    self.label
                        .glassEffect(.regular.tint(Self.violet.opacity(0.85)).interactive(), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        }
                        .shadow(color: Self.violet.opacity(0.4), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: action) {
                    self.label
                        .background(Self.gradient, in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                        }
                        .shadow(color: Self.violet.opacity(0.45), radius: 10, y: 5)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .focused($focused)
        .overlay {
            if focused {
                Capsule().stroke(.white.opacity(0.8), lineWidth: 2).padding(-4)
            }
        }
        .opacity(isEnabled ? 1 : 0.6)
        .disabled(!isEnabled || isLoading)
        .keyboardShortcut(.defaultAction)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .accessibilityLabel(currentTitle)
        .accessibilityHint(
            title != nil ? "Press Enter to continue." :
                account == nil ? "Press Enter to sign in with Google." :
                "Press Enter to open Firstlight in the menu bar."
        )
        .help("\(restingTitle) (Enter)")
    }

    // MARK: Private

    /// The arrival page's #8262FF → #6644F2, as one tint for the glass. The
    /// same violet every prominent control in the app is tinted with.
    private static let violet = Color.firstlight
    private static let gradient = LinearGradient(
        colors: [Color(red: 0.51, green: 0.38, blue: 1.0), Color(red: 0.40, green: 0.27, blue: 0.95)],
        startPoint: .top, endPoint: .bottom
    )

    @FocusState private var focused: Bool

    private var restingTitle: String { self.title ?? self.account?.buttonTitle ?? "Continue with Google" }
    private var currentTitle: String { self.isLoading ? self.loadingTitle : self.restingTitle }

    private var label: some View {
        HStack(spacing: 10) {
            if isLoading { ProgressView().controlSize(.mini).tint(.white) }
            else if let account {
                Group {
                    if let avatar { avatar }
                    else {
                        AvatarLetter(letter: account.initial, size: 12)
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                .accessibilityHidden(true)
            }
            // The title morphs: shared letters stay, the rest moves.
            OnboardingMorphLabel(currentTitle)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        // An avatar carries its own edge, so it sits closer to the rim than a
        // first letter of text would.
        .padding(.leading, account == nil ? 20 : 8)
        .padding(.trailing, 20)
        .frame(height: 36)
        // No Enter hint and no full width: the pill is only as wide as what it
        // says. Enter still works — it is in the tooltip and in the
        // accessibility hint, and one default button on the page is guessable.
        .fixedSize()
        .contentShape(Capsule())
    }
}
