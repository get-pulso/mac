import AppKit
import Combine
import Defaults
import Dependencies
import SwiftUI

final class WindowManager {
    // MARK: Internal

    var isVisiblePublisher: AnyPublisher<Bool, Never> {
        self.visibilitySubject.eraseToAnyPublisher()
    }

    var isVisible: Bool {
        self.visibilitySubject.value
    }

    @MainActor
    func configure() {
        self.prepareWindow()
        self.statusIconAnimator = StatusIconAnimator(menu: StatusItemMenu(
            toggle: { [weak self] in
                guard let self else { return }
                if self.isVisible { self.hide() } else { self.show() }
            },
            open: { [weak self] in self?.show() },
            invite: { [weak self] in
                // Opened together with the popover, so the tray has no button
                // to grow out of and simply arrives with it.
                SocialStore.shared.openTray(.home, from: .none)
                self?.show()
            },
            beforeMenu: { [weak self] in self?.hide() },
            settings: { SettingsWindowController.shared.show() },
            canOpenSettings: { Defaults[.currentUserID] != nil },
            replayOnboarding: { [weak self] in self?.replayOnboarding() },
            canReplayOnboarding: { Self.canReplayOnboarding },
            quit: { NSApp.terminate(nil) },
            prefetch: { SocialStore.shared.warm() },
            rehearseOnboarding: { [weak self] in self?.rehearseOnboarding() }
        ))
        self.startMouseMonitor()
    }

    @MainActor
    func showWelcome() {
        self.hide()
        OnboardingStage.shared.reset()
        OnboardingFlow.shared.reset()
        OnboardingWindowController.shared.show(content: AnyView(LoginView(onboarding: true)))
    }

    /// The profile is saved: the step rises out, the name goes, the mark flies
    /// from the window's header into the status item, the window fades, and
    /// the panel opens where the mark landed. The mark is in one place at a time.
    @MainActor
    func handoffFromOnboarding() {
        let controller = OnboardingWindowController.shared
        let stage = OnboardingStage.shared
        guard controller.isPresented else {
            self.show()
            return
        }
        stage.advance(to: .handoff)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard let start = controller.headerMarkScreenRect(),
                  let icon = self.statusIconAnimator, let button = icon.statusBarButton,
                  let image = RayLogoImage.cropped
            else {
                controller.close()
                stage.reset()
                OnboardingFlow.shared.reset()
                self.show()
                return
            }
            stage.markInFlight = true
            icon.dim()
            OnboardingHandoff.fly(
                image: image, from: start, to: button, iconSide: icon.iconSide, reduceMotion: reduceMotion
            ) { [weak self] in
                icon.arrive()
                stage.reset()
                OnboardingFlow.shared.reset()
                self?.show()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                controller.fadeOut(duration: reduceMotion ? 0.12 : 0.35) {}
            }
        }
    }

    @MainActor
    func replayOnboarding() {
        guard Self.canReplayOnboarding else { return }
        self.hide()
        OnboardingStage.shared.reset()
        OnboardingFlow.shared.reset()
        OnboardingWindowController.shared.close()
        OnboardingWindowController.shared.show(content: AnyView(LoginView(onboarding: true)), forceAnimation: true)
    }

    /// The replay, and then the profile steps as a new account sees them: the
    /// name and About fields empty, whatever is typed thrown away at the end.
    @MainActor
    func rehearseOnboarding() {
        self.replayOnboarding()
        OnboardingFlow.shared.rehearsal = true
    }

    @MainActor
    func show() {
        @Dependency(\.appRouter) var router
        // An active Clerk session can still be resolving its Firstlight profile.
        // That work belongs here, without granting dashboard access early.
        guard Defaults[.currentUserID] != nil || router.destination == .signInCompletion else {
            self.showWelcome()
            return
        }
        OnboardingWindowController.shared.close()
        guard let targetWindowPostion, let window else { return }
        window.setFrameTopLeftPoint(targetWindowPostion)
        // The panel takes the keyboard by itself, without waiting on the app
        // becoming frontmost, which the system is free to refuse. Activation
        // is still asked for, so the app comes forward when it is allowed.
        window.present(fromScreenX: self.statusItemPlacement?.frame.midX ?? window.frame.midX)
        NSApp.activate()
        self.statusIconAnimator?.highlight()
        self.visibilitySubject.send(true)
    }

    @MainActor
    func hide() {
        self.statusIconAnimator?.unhighlight()
        self.window?.dismiss(towardScreenX: self.statusItemPlacement?.frame.midX)
        self.visibilitySubject.send(false)
    }

    // MARK: Private

    @MainActor
    private static var canReplayOnboarding: Bool {
        !LoginViewModel.shared.busy && !NativeSession.shared.loading && !NativeSession.shared.isCompletingSignIn
    }

    private var visibilitySubject = CurrentValueSubject<Bool, Never>(false)
    private var window: AppWindow?
    private var statusIconAnimator: StatusIconAnimator?
    private var mouseMonitor: Any?

    /// The status item's button in screen coordinates, and the screen it is on.
    @MainActor
    private var statusItemPlacement: (frame: NSRect, screen: NSScreen)? {
        guard
            let button = statusIconAnimator?.statusBarButton,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen
        else { return nil }
        return (buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), screen)
    }

    @MainActor
    private var targetWindowPostion: NSPoint? {
        guard let placement = self.statusItemPlacement else { return nil }

        let buttonFrameOnScreen = placement.frame
        let visibleFrame = placement.screen.visibleFrame

        let windowWidth: CGFloat = 350
        let cornerRadius: CGFloat = 16

        // Calculate Y: align top of window to bottom of status item
        let y = buttonFrameOnScreen.minY - 5 // 5pt offset for shadow

        // Try leading alignment
        let leadingX = buttonFrameOnScreen.minX - cornerRadius
        let trailingX = buttonFrameOnScreen.maxX - windowWidth + cornerRadius

        // Check if window fits with leading alignment
        let fitsLeading = leadingX + windowWidth <= visibleFrame.maxX
        let fitsTrailing = trailingX >= visibleFrame.minX

        let x: CGFloat = if fitsLeading {
            leadingX
        } else if fitsTrailing {
            trailingX
        } else {
            max(visibleFrame.minX + cornerRadius, min(leadingX, visibleFrame.maxX - windowWidth - cornerRadius))
        }

        return NSPoint(x: x, y: y)
    }

    private func prepareWindow() {
        @Dependency(\.appRouter) var router: AppRouter
        let contentView = AppView(appRouter: router)
        self.window = AppWindow(appView: contentView)
    }

    private func startMouseMonitor() {
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return }

            if let eventWindow = event.window, eventWindow === self.window {
                return
            }

            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                // Since macOS 27 the menu bar belongs to MenuBarAgent, which
                // forwards clicks to the status item, so a click on the item
                // reaches this monitor as a click in another app, ahead of the
                // item's own action. Hiding here would leave that action to
                // find the panel hidden and open it straight back; the item
                // toggles the panel itself.
                if let placement = self.statusItemPlacement, StatusItemMenu.isOnItem(
                    location,
                    button: placement.frame,
                    screen: placement.screen.frame,
                    visibleFrame: placement.screen.visibleFrame
                ) { return }
                self.hide()
            }
        }
    }
}
