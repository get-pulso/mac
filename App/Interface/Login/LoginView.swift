import SwiftUI

struct LoginView: View {
    @StateObject var viewModel = LoginViewModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("Pulso")
                .font(.system(.title, weight: .bold))
                .foregroundStyle(.primary)

            Text(
                "Activity tracker for macOS. Monitor time spent with friends and see what they're currently listening to."
            )
            .fixedSize(horizontal: false, vertical: true)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            if self.viewModel.isWaitingForLogin {
                ProgressView("Waiting for web login…")
                    .controlSize(.small)
                    .font(.subheadline)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            } else {
                Button("Sing In", action: self.viewModel.startLogin)
            }
        }
        .padding(12)
    }
}
