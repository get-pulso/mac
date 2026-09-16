import Dependencies
import SwiftUI

/// Only appears in the menu-bar panel, never over the colorful welcome window.
struct SignInCompletionView: View {
    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Firstlight").font(.system(size: 14, weight: .semibold))
            if let error = model.error ?? session.error, !session.isCompletingSignIn, !model.busy {
                NativeInlineError(message: error)
                HStack {
                    Button("Sign out") { model.run { try await session.signOut() } }
                    Spacer()
                    Button("Retry") { model.run { try await session.finishSignIn() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.firstlight)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                NativeAuthSkeleton()
            }
        }
        .padding(16)
        .font(.system(size: 13))
        .controlSize(.regular)
        .onExitCommand { windowManager.hide() }
    }

    // MARK: Private

    @ObservedObject private var session = NativeSession.shared
    @ObservedObject private var model = LoginViewModel.shared
    @Dependency(\.windowManager) private var windowManager
}
