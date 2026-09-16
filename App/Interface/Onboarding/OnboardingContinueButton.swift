import SwiftUI

/// One action and one default shortcut, shared by the real sign-in and safe preview.
struct OnboardingContinueButton: View {
    // MARK: Internal

    var isLoading = false
    var isEnabled = true
    var account: WelcomeAccount?
    var avatar: AnyView?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading { ProgressView().controlSize(.mini).tint(.black) }
                else if let account {
                    Group {
                        if let avatar { avatar }
                        else {
                            Text(account.initial).font(.system(size: 12, weight: .medium))
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.08), in: Circle())
                        }
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.black.opacity(0.08), lineWidth: 1))
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
                .foregroundStyle(.black.opacity(0.45))
                .opacity(isLoading ? 0 : 1)
                .accessibilityHidden(true)
            }
            .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.30))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.8), lineWidth: 2).padding(-4)
                }
            }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .focused($focused)
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

    @FocusState private var focused: Bool
}
