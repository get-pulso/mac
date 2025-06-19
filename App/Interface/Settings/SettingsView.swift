import SwiftUI

struct SettingsView: View {
    // MARK: Internal

    @ObservedObject var viewModel = SettingsViewModel()

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Text("Settings")
                    .font(.headline)

                HStack {
                    Button(action: self.viewModel.dashboard) {
                        Image(systemName: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }

            Divider()

            self.section(
                title: "Check for Updates",
                desc: "Manually check if a new version of Pulso is available.",
                button: "Check",
                action: self.viewModel.checkForUpdates
            )

            self.section(
                title: "Terminate",
                desc: "Stop the app and all activity tracking immediately.",
                button: "Kill App",
                action: self.viewModel.terminate
            )

            self.section(
                title: "Logout",
                desc: "Sign out and stop tracking. Log in again to continue.",
                button: "Log Out",
                action: self.viewModel.logout
            )
        }
        .padding(12)
    }

    // MARK: Private

    private func section(title: String, desc: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                }

                HStack {
                    Text(desc)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            VStack {
                Button(button, action: action)
            }
        }
    }
}
