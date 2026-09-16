import SwiftUI

/// One action and one default shortcut, shared by the real sign-in and safe
/// preview. The same pill as the arrival page's button: Firstlight's violet
/// running top to bottom, a hairline of light on the upper edge, and on
/// macOS 26 the system's glass under it.
struct OnboardingContinueButton: View {
    // MARK: Internal

    var isLoading = false
    var isEnabled = true
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
        .accessibilityLabel(isLoading ? "Opening Google sign-in" : account?.buttonTitle ?? "Continue with Google")
        .accessibilityHint(
            account == nil ? "Press Enter to sign in with Google." :
                "Press Enter to open Firstlight in the menu bar."
        )
        .help("\(account?.buttonTitle ?? "Continue with Google") (Enter)")
    }

    // MARK: Private

    /// The arrival page's #8262FF → #6644F2, as one tint for the glass.
    private static let violet = Color(red: 0.45, green: 0.33, blue: 0.97)
    private static let gradient = LinearGradient(
        colors: [Color(red: 0.51, green: 0.38, blue: 1.0), Color(red: 0.40, green: 0.27, blue: 0.95)],
        startPoint: .top, endPoint: .bottom
    )

    @FocusState private var focused: Bool

    private var label: some View {
        HStack(spacing: 10) {
            if isLoading { ProgressView().controlSize(.mini).tint(.white) }
            else if let account {
                Group {
                    if let avatar { avatar }
                    else {
                        Text(account.initial).font(.system(size: 12, weight: .medium))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.18), in: Circle())
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
                .accessibilityHidden(true)
            }
            Text(isLoading ? "Opening Google…" : account?.buttonTitle ?? "Continue with Google")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            HStack(spacing: 5) {
                Text("Enter").font(.system(size: 11, weight: .medium))
                Image(systemName: "return").font(.system(size: 11, weight: .medium))
            }
            .fixedSize()
            .foregroundStyle(.white.opacity(0.55))
            .opacity(isLoading ? 0 : 1)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .contentShape(Capsule())
    }
}
