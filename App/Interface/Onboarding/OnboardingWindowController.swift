import AppKit
import SwiftUI

private final class OnboardingWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { self.onEscape?() }
}

private final class ClearOnboardingHost: NSHostingView<OnboardingView> {
    override var isOpaque: Bool { false }
}

/// Owns only the signed-out experience. The menu-bar popover remains independent.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: Internal

    static let shared = OnboardingWindowController()
    /// Kept from the first shipped intro so existing installs do not replay it.
    static let introSeenKey = "firstlight.onboarding.opal.introSeen"

    private(set) var isPresented = false
    private(set) var hasPresentedThisLaunch = false
    var onClose: (() -> Void)?

    func show(content: AnyView, forceAnimation: Bool = false) {
        if self.isPresented {
            if let nativeWindow, nativeWindow.alphaValue == 1 {
                if nativeWindow.isMiniaturized { nativeWindow.deminiaturize(nil) }
                AppActivation.bringForward(nativeWindow)
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        self.isPresented = true
        self.hasPresentedThisLaunch = true
        self.generation = UUID()
        self.playback.prepare()
        let area = screen.visibleFrame
        let size = NSSize(width: min(1020, area.width - 24), height: min(760, area.height - 24))
        let canvas = NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let carrier = OnboardingWindow(contentRect: canvas, styleMask: [.borderless], backing: .buffered, defer: false)
        carrier.title = "Firstlight Intro"
        carrier.backgroundColor = .clear
        carrier.isOpaque = false
        carrier.hasShadow = false
        carrier.alphaValue = 0
        carrier.isReleasedWhenClosed = false
        carrier.ignoresMouseEvents = true
        carrier.collectionBehavior = [.fullScreenAuxiliary]
        carrier.contentView = self.makeHost(content: content, native: false)
        carrier.onEscape = { [weak self] in self?.finishAnimation() }
        self.carrier = carrier

        // AppKit exclusively supplies the traffic lights, frame corners and shadow.
        let native = OnboardingWindow(
            contentRect: canvas.insetBy(dx: self.inset, dy: self.inset),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        native.title = "Welcome to Firstlight"
        native.titleVisibility = .hidden
        native.titlebarAppearsTransparent = true
        native.titlebarSeparatorStyle = .none
        native.backgroundColor = .clear
        native.isOpaque = false
        native.hasShadow = true
        native.isReleasedWhenClosed = false
        native.isMovableByWindowBackground = true
        native.contentMinSize = NSSize(width: 620, height: 420)
        native.collectionBehavior = [.fullScreenPrimary]
        native.delegate = self
        native.onEscape = { [weak self] in self?.nativeWindow?.performClose(nil) }
        native.contentView = self.makeHost(content: content, native: true)
        native.setFrame(canvas.insetBy(dx: self.inset, dy: self.inset), display: false)
        self.nativeWindow = native
        self.playback.panelRect = CGRect(
            x: self.inset,
            y: self.inset,
            width: native.frame.width,
            height: native.frame.height
        )
        self.playback.onFrame = { [weak self] time, finished in self?.updateDesktop(time: time, finished: finished) }
        self.observeInterruptions()

        // Prewarm the final drawable without exposing any underlying window chrome.
        native.alphaValue = 0
        native.orderBack(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        // The intro plays in the carrier, so it is the one to bring forward;
        // the real window takes over from it at the hand-off below, by which
        // time the app is active and can simply take the keyboard.
        AppActivation.bringForward(carrier)
        let animated = forceAnimation || !self.defaults.bool(forKey: Self.introSeenKey)
        let ticket = self.generation
        // Activation and the first Metal drawable settle before the clock starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0.2 : 0)) { [weak self] in
            guard let self, self.isPresented, self.generation == ticket, !self.handingOff else { return }
            self.playback.start(animated: animated)
        }
    }

    func finishAnimation() {
        guard self.isPresented, !self.playback.finished else { return }
        self.playback.finish()
    }

    /// Used by successful authentication and app termination, never signs out.
    func close() { self.tearDown(closeNative: true) }

    func windowWillClose(_ notification: Notification) {
        self.tearDown(closeNative: false)
        self.onClose?()
    }

    // MARK: Private

    private let defaults: UserDefaults
    private let inset: CGFloat = 76
    private let playback = IntroPlayback()
    private var carrier: OnboardingWindow?
    private var nativeWindow: OnboardingWindow?
    private var dimmers: [NSWindow] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = UUID()
    private var handingOff = false

    private func makeHost(content: AnyView, native: Bool) -> NSView {
        let host =
            ClearOnboardingHost(rootView: OnboardingView(playback: playback, nativeSurface: native, content: content))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        return host
    }

    private func updateDesktop(time: Double, finished: Bool) {
        guard self.isPresented, let carrier, let native = nativeWindow else { return }
        // The real window takes over while the light is still moving; the same
        // clock keeps running inside it until the light has become the mark.
        let presentNative = self.playback.readyForNative || finished
        if !presentNative, self.dimmers.isEmpty {
            native.orderOut(nil)
            for screen in NSScreen.screens {
                let dimmer = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                dimmer.title = "Firstlight Desktop Dimmer"
                dimmer.backgroundColor = .black
                dimmer.isOpaque = false
                dimmer.hasShadow = false
                dimmer.alphaValue = 0
                dimmer.ignoresMouseEvents = true
                dimmer.isReleasedWhenClosed = false
                dimmer.level = .statusBar
                dimmer.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                dimmer.orderFrontRegardless()
                self.dimmers.append(dimmer)
            }
            carrier.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            carrier.makeKeyAndOrderFront(nil)
            let ticket = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.generation == ticket, !self.handingOff else { return }
                carrier.alphaValue = 1
            }
        }
        self.dimmers.forEach { $0.alphaValue = IntroTiming.dimming(atReal: self.playback.realElapsed) }
        guard presentNative, !self.handingOff, !self.playback.nativePresented else { return }
        self.removeDimmers()
        self.handingOff = true
        let ticket = self.generation
        native.alphaValue = 0
        native.orderBack(nil)
        native.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.generation == ticket, self.isPresented else { return }
            native.alphaValue = 1
            if NSApp.isActive { native.makeKeyAndOrderFront(nil) }
            else { native.orderBack(nil) }
            native.invalidateShadow()
            carrier.orderOut(nil)
            carrier.contentView = nil // Release the proxy's Metal resources.
            self.playback.didPresentNative()
            self.defaults.set(true, forKey: Self.introSeenKey)
        }
    }

    private func removeDimmers() {
        self.dimmers.forEach { $0.close() }
        self.dimmers.removeAll()
    }

    private func observeInterruptions() {
        for name in [
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
            NSApplication.didHideNotification,
        ] {
            let center = NotificationCenter.default
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishAnimation() }
            }
            self.observers.append((center, token))
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, NSWorkspace.willSleepNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if notification.name == NSWorkspace.willSleepNotification || NSWorkspace.shared
                        .accessibilityDisplayShouldReduceMotion
                    {
                        self?.finishAnimation()
                    }
                }
            }
            self.observers.append((center, token))
        }
    }

    private func tearDown(closeNative: Bool) {
        self.isPresented = false
        self.generation = UUID() // Invalidate queued prewarm/handoff callbacks.
        self.playback.stop()
        self.playback.onFrame = nil
        self.removeDimmers()
        for (center, token) in self.observers { center.removeObserver(token) }
        self.observers.removeAll()
        self.nativeWindow?.delegate = nil
        if closeNative { self.nativeWindow?.close() }
        self.carrier?.close()
        self.nativeWindow = nil
        self.carrier = nil
        self.handingOff = false
    }
}
