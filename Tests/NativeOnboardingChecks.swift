import AppKit
import SwiftUI

/// Runs the production controller and shader with an inert form and isolated
/// preferences. No Clerk, account storage, tracking or network requests.
@main
enum NativeOnboardingChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        if !CommandLine.arguments.contains("--window-only") {
            do { try OnboardingShaderChecks.run() }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = OnboardingChecksDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class OnboardingChecksDelegate: NSObject, NSApplicationDelegate {
    let suite = "com.get-pulso.onboarding.checks.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var controller = OnboardingWindowController(defaults: defaults)
    let content = AnyView(Text("Authentication test fixture"))
    var closed = 0
    var assertions = 0

    var native: NSWindow? { NSApp.windows.first { $0.title == "Welcome to Pulso" && $0.isVisible } }
    var carrier: NSWindow? { NSApp.windows.first { $0.title == "Pulso Intro" && $0.isVisible } }
    var dimmers: [NSWindow] { NSApp.windows.filter { $0.title == "Pulso Desktop Dimmer" && $0.isVisible } }

    var nativeWindowsAreGone: Bool { self.native == nil && self.carrier == nil && self.dimmers.isEmpty }

    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.assertions += 1
        guard condition() else {
            self.controller.close()
            self.defaults.removePersistentDomain(forName: self.suite)
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    func later(_ delay: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.controller.onClose = { [weak self] in self?.closed += 1 }
        self.controller.show(content: self.content)
        self.later(1.9) { [self] in
            print(
                "Window checkpoint: active=\(NSApp.isActive), reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)"
            )
            for window in NSApp.windows {
                print(
                    "  \(window.title): visible=\(window.isVisible), alpha=\(window.alphaValue), opaque=\(window.isOpaque), shadow=\(window.hasShadow)"
                )
            }
            expect(controller.isPresented, "signed-out presentation is active")
            expect(
                carrier != nil && carrier?.isOpaque == false && carrier?.hasShadow == false,
                "transparent cloud, no background panel or shadow"
            )
            expect(native == nil || native?.alphaValue == 0, "no real window before the spring finishes")
            expect(dimmers.count == NSScreen.screens.count, "every display is dimmed")
            expect(
                dimmers.allSatisfy { $0.alphaValue > 0.7 && $0.ignoresMouseEvents },
                "full-strength click-through dimming"
            )
            print("PASS: Cloud intro, hidden login window, \(dimmers.count) displays")
        }
        self.later(6.5) { [self] in checkNativeHandoff() }
    }

    func checkNativeHandoff() {
        guard let native else { self.expect(false, "native login window is missing"); return }
        self.expect(self.dimmers.isEmpty && self.carrier == nil, "intro windows removed after handoff")
        self.expect(native.alphaValue == 1 && native.level == .normal, "native window at normal level")
        self.expect(
            native.styleMask.contains([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]),
            "native frame style"
        )
        self.expect(native.hasShadow, "system window shadow")
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = native.standardWindowButton(kind)
            else { self.expect(false, "system button missing"); return }
            self.expect(button.window === native && !button.isHidden && button.isEnabled, "real active traffic light")
            self.expect(button.frame.width <= 16 && button.frame.height <= 16, "system-size traffic lights")
            print("PASS: system button \(kind), \(button.frame.size), \(String(describing: button.action))")
        }
        for size in [
            NSSize(width: 620, height: 420),
            NSSize(width: 868, height: 608),
            NSSize(width: 1100, height: 800),
        ] {
            native.setContentSize(size)
            native.contentView?.layoutSubtreeIfNeeded()
            self.expect(native.contentView!.bounds.width >= size.width, "resizable native layout")
        }
        self.expect(self.defaults.bool(forKey: OnboardingWindowController.introSeenKey), "intro completion persisted")
        native.performClose(nil)
        self.expect(self.closed == 1 && !self.controller.isPresented, "closing login does not quit the menu-bar app")
        self.controller.show(content: self.content)
        self.expect(self.dimmers.isEmpty, "reopening sign-in does not replay dimming")
        self.later(0.2) { [self] in
            expect(self.native?.alphaValue == 1, "reopened form is immediately usable")
            controller.close() // Same operation used by successful authentication.
            expect(!controller.isPresented && self.native == nil, "authenticated handoff closes login")
            controller.show(content: content, forceAnimation: true)
            controller.close() // Authentication/termination can race with prewarm.
            later(0.2) { [self] in
                expect(nativeWindowsAreGone, "cancelled prewarm cannot resurrect a window")
                checkInterruption(index: 0)
            }
        }
    }

    func checkInterruption(index: Int) {
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didResignActiveNotification),
            (.default, NSApplication.didChangeScreenParametersNotification),
            (.default, NSApplication.didHideNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
        ]
        guard index < notifications.count else { self.checkPlaybackFallback(); return }
        self.controller.show(content: self.content, forceAnimation: true)
        let (center, name) = notifications[index]
        center.post(name: name, object: nil)
        self.expect(self.dimmers.isEmpty, "interruption immediately restores the desktop: \(name.rawValue)")
        self.later(0.12) { [self] in
            expect(native?.alphaValue == 1 && carrier == nil, "interruption finishes into usable login")
            controller.close()
            expect(nativeWindowsAreGone, "cleanup after interruption")
            checkInterruption(index: index + 1)
        }
    }

    func checkPlaybackFallback() {
        let playback = IntroPlayback()
        var completed = false
        playback.onFrame = { _, finished in completed = finished }
        playback.start(animated: false)
        self.expect(completed && playback.finished, "unanimated / Reduce Motion path finishes immediately")
        playback.start(animated: true)
        playback.fail("Intentional verification failure")
        self.expect(
            completed && playback.finished && playback.shaderFailure != nil,
            "Metal failure never blocks sign-in"
        )
        self.expect(IntroTiming.dimming(at: playback.elapsed) == 0, "fallback restores desktop")
        self.controller.close()
        self.defaults.removePersistentDomain(forName: self.suite)
        print("PASS: \(self.assertions) onboarding lifecycle assertions; no account or network access")
        NSApp.terminate(nil)
    }
}
