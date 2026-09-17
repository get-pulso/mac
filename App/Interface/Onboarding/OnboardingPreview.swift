#if DEBUG
import AppKit
import SwiftUI

/// Visual inspection in the real bundle, without touching Clerk, storage or tracking.
enum OnboardingPreview {
    // MARK: Internal

    @MainActor static func showIfRequested() -> Bool {
        if OnboardingFlowPreview.showIfRequested() { return true }
        guard CommandLine.arguments.contains("--preview-onboarding") else { return false }
        self.controller.onClose = { NSApp.terminate(nil) }
        let account: WelcomeAccount? = CommandLine.arguments.contains("--preview-signed-in")
            ? WelcomeAccount(id: "preview-only", firstName: "Sam", fullName: nil, username: nil, avatarURL: nil)
            : nil
        self.controller.show(content: AnyView(OnboardingPreviewAction(account: account)), forceAnimation: true)
        return true
    }

    // MARK: Private

    @MainActor private static let controller = OnboardingWindowController(
        defaults: UserDefaults(suiteName: "sh.firstlight.onboarding.preview")!
    )
}

private struct OnboardingPreviewAction: View {
    // MARK: Internal

    var account: WelcomeAccount?

    var body: some View {
        VStack(spacing: 12) {
            OnboardingContinueButton(account: account) { requests += 1 }
            Text(
                requests == 0 ? "Preview only. Your account is unchanged." :
                    "Preview: continue requested (\(requests))."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    // MARK: Private

    @State private var requests = 0
}
#endif
