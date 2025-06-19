import AppKit
import Combine
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
        self.statusIconAnimator = StatusIconAnimator()
        self.startMouseMonitor()
    }

    @MainActor
    func show() {
        guard let targetWindowPostion, let window else { return }
        window.setFrameTopLeftPoint(targetWindowPostion)
        window.orderFront(nil)
        self.statusIconAnimator?.highlight()
        NSApp.activate()
        self.visibilitySubject.send(true)
    }

    @MainActor
    func hide() {
        self.statusIconAnimator?.unhighlight()
        self.window?.orderOut(nil)
        self.visibilitySubject.send(false)
    }

    // MARK: Private

    private var visibilitySubject = CurrentValueSubject<Bool, Never>(false)
    private var window: AppWindow?
    private var statusIconAnimator: StatusIconAnimator?
    private var mouseMonitor: Any?

    @MainActor
    private var targetWindowPostion: NSPoint? {
        guard
            let button = self.statusIconAnimator?.statusBarButton,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen
        else { return nil }

        // Get button frame in screen coordinates
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)

        let visibleFrame = screen.visibleFrame

        let windowWidth: CGFloat = 300
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

            DispatchQueue.main.async {
                self.hide()
            }
        }
    }
}

public extension NSStatusBarButton {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        @Dependency(\.windowManager) var windowManager

        if windowManager.isVisible {
            windowManager.hide()
        } else {
            windowManager.show()
        }
    }
}
