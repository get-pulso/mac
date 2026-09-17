#if DEBUG
import AppKit
import Combine
import OSLog
import Sparkle
import SwiftUI

/// Runs the real Sparkle feed check without starting tracking or authentication.
/// Launch through run-local-signed.sh --update-diagnostics -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO.
@MainActor
enum UpdateDiagnostics {
    // MARK: Internal

    static func showIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--update-diagnostics") else { return false }
        if let window = self.window {
            AppActivation.bringForward(window)
            return true
        }
        self.updater = Updater()
        guard let updater = self.updater else { return true }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = "Firstlight Update Check"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView:
            Form { Section("Updates") { UpdateSettingsView(updater: updater, enabled: true) } }
                .formStyle(.grouped).fontDesign(.rounded)
        )
        window.center()
        self.window = window
        DockPresence.claim(window)
        AppActivation.bringForward(window)
        self.observation = updater.$state.sink { state in
            self.record("Live Sparkle: \(state)")
        }
        Task {
            await self.checkDriverLifecycle()
            await self.checkAuthenticationAnchor()
            updater.checkForUpdates()
        }
        return true
    }

    // MARK: Private

    private static var updater: Updater?
    private static var window: NSWindow?
    private static var observation: AnyCancellable?
    private static let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("firstlight-update-diagnostics.txt")

    private static func record(_ line: String) {
        Logger(subsystem: "sh.firstlight.mac", category: "UpdateDiagnostics").notice("\(line, privacy: .public)")
        let previous = (try? String(contentsOf: self.logURL, encoding: .utf8)) ?? ""
        try? (previous + line + "\n").write(to: self.logURL, atomically: true, encoding: .utf8)
    }

    private static func checkAuthenticationAnchor() async {
        let suite = "sh.firstlight.auth-anchor-diagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: OnboardingWindowController.introSeenKey)
        let controller = OnboardingWindowController(defaults: defaults)
        defer {
            controller.close()
            defaults.removePersistentDomain(forName: suite)
            if let window = self.window { AppActivation.bringForward(window) }
        }
        controller.show(content: AnyView(Text("Authentication window placement check")))
        do {
            try controller.prepareForAuthentication()
            try await Task.sleep(for: .milliseconds(200))
            guard let anchor = NSApp.keyWindow else { assertionFailure("Missing authentication anchor"); return }
            assert(anchor.title == "Welcome to Firstlight" && anchor === NSApp.mainWindow)
            assert(anchor.isVisible && anchor.alphaValue == 1 && anchor.isOnActiveSpace)
            assert(anchor.collectionBehavior.contains(.moveToActiveSpace))
            self
                .record(
                    "PASS: authentication anchor is visible, key and main on the current Space (no OAuth request sent)"
                )
        } catch {
            assertionFailure("Authentication anchor failed: \(error)")
        }
    }

    private static func checkDriverLifecycle() async {
        try? "".write(to: self.logURL, atomically: true, encoding: .utf8)
        let driver = UpdateDriver(checkTimeout: 0.03)
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        driver.cancel()
        driver.cancel()
        assert(cancellations == 1 && driver.state.value == .idle)
        self.record("PASS: cancelling a check is single-use and clears progress")

        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        var acknowledgements = 0
        let current = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [
            SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue,
        ])
        driver.showUpdateNotFoundWithError(current) { acknowledgements += 1 }
        driver.dismissUpdateInstallation()
        assert(acknowledgements == 1 && driver.state.value == .upToDate)
        try? await Task.sleep(for: .milliseconds(60))
        assert(cancellations == 1 && driver.state.value == .upToDate)
        self.record("PASS: no-update result survives Sparkle dismissal; old timeout is cancelled")

        let unsupported = NSError(domain: SUSparkleErrorDomain, code: 1001, userInfo: [
            SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
            NSLocalizedDescriptionKey: "A newer macOS version is required.",
        ])
        driver.showUpdateNotFoundWithError(unsupported) { acknowledgements += 1 }
        driver.dismissUpdateInstallation()
        assert(driver.state.value == .failed("A newer macOS version is required."))
        self.record("PASS: incompatible update is not reported as up to date")

        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        driver.showUpdaterError(URLError(.notConnectedToInternet)) { acknowledgements += 1 }
        driver.dismissUpdateInstallation()
        if case .failed = driver.state.value {} else { assertionFailure("Error disappeared") }
        assert(acknowledgements == 3)
        self.record("PASS: errors acknowledge Sparkle and stay visible after dismissal")

        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        try? await Task.sleep(for: .milliseconds(60))
        driver.dismissUpdateInstallation()
        assert(cancellations == 2)
        if case .failed = driver.state.value {} else { assertionFailure("Timeout disappeared") }
        self.record("PASS: stalled check times out, cancels Sparkle and leaves retryable feedback")

        driver.showDownloadInitiated { cancellations += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 50)
        assert(driver.state.value == .downloading(0.5))
        driver.showDownloadDidStartExtractingUpdate()
        assert(driver.cancellation == nil)
        driver.showExtractionReceivedProgress(0.75)
        assert(driver.state.value == .extracting(0.75))
        var installs = 0
        driver.showReady(toInstallAndRelaunch: { choice in if choice == .install { installs += 1 } })
        driver.install()
        driver.install()
        assert(installs == 1)
        self.record("PASS: download/extraction progress and exactly-once installation callback")
        var quitRetries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { quitRetries += 1 }
        assert(driver.state.value == .waitingToQuit)
        driver.install()
        driver.install()
        assert(quitRetries == 2)
        driver.showInstallingUpdate(withApplicationTerminated: true) { quitRetries += 1 }
        driver.install()
        assert(quitRetries == 2 && driver.state.value == .installing)
        self.record("PASS: cancelled termination can be retried; terminated app cannot be quit again")
        assert(!NSApp.windows.contains { $0.title == "Updating Firstlight" })
        self.record("PASS: no separate Sparkle window was created")
    }
}
#endif
