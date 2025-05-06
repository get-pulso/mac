import SwiftUI

struct SignInView: View {
    let viewModel: SignInViewModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

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

            Button("Sing In", action: self.viewModel.startLogin)

            Spacer()
        }
        .padding(.init(top: 0, leading: 12, bottom: 0, trailing: 12))
        .frame(width: 290)
    }
}
