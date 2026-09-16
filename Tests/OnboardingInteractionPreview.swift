import AppKit

/// Links only the production onboarding views, not Clerk, networking or account storage.
/// A distinct test bundle ID keeps UI automation separate from the user's running Firstlight.
@main
enum OnboardingInteractionPreview {
    static func main() {
        let app = NSApplication.shared
        let delegate = WelcomePreviewDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class WelcomePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard OnboardingPreview.showIfRequested() else { NSApp.terminate(nil); return }
    }
}
