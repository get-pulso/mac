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
        self.statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.prerenderIcon()
        self.startIconAnimationTimer()
        self.startMouseMonitor()
        self.statusBarItem?.button?.image = self.iconFrames.first
    }

    func show() {
        guard let targetWindowPostion, let window else { return }
        window.setFrameTopLeftPoint(targetWindowPostion)
        window.orderFront(nil)
        self.statusBarItem?.button?.highlight(true)
        NSApp.activate()
        self.visibilitySubject.send(true)
    }

    func hide() {
        self.statusBarItem?.button?.highlight(false)
        self.window?.orderOut(nil)
        self.visibilitySubject.send(false)
    }

    // MARK: Private

    private enum Constants {
        static let totalIconFrames = 40
        static let iconFrameLength = 0.1
    }

    private var statusBarItem: NSStatusItem?
    private var visibilitySubject = CurrentValueSubject<Bool, Never>(false)
    private var window: AppWindow?
    private var iconFrames: [NSImage] = []
    private var iconFrameIndex: Int = 0
    private var iconTimer: Timer?
    private var mouseMonitor: Any?

    private var targetWindowPostion: NSPoint? {
        guard
            let button = self.statusBarItem?.button,
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

    @MainActor
    private func prerenderIcon() {
        self.iconFrames = (0 ..< Constants.totalIconFrames).map { frameIndex in
            let phase = Double(frameIndex) / Double(Constants.totalIconFrames)
            let view = StatusIcon(phase: phase)
                .frame(width: 20, height: 20)

            let frameRenderer = ImageRenderer(content: view)
            frameRenderer.scale = NSScreen.main?.backingScaleFactor ?? 2

            return frameRenderer.nsImage ?? NSImage()
        }
    }

    private func prepareWindow() {
        @Dependency(\.appRouter) var router: AppRouter
        let contentView = AppView(appRouter: router)
        self.window = AppWindow(appView: contentView)
    }

    private func startIconAnimationTimer() {
        let timer = Timer(
            timeInterval: Constants.iconFrameLength,
            repeats: true
        ) { [weak self] _ in
            guard let self, !self.iconFrames.isEmpty else { return }
            self.iconFrameIndex = (self.iconFrameIndex + 1) % Constants.totalIconFrames
            DispatchQueue.main.async {
                self.statusBarItem?.button?.image = self.iconFrames[self.iconFrameIndex]
            }
        }
        self.iconTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startMouseMonitor() {
        self.mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.window?.isVisible == true else { return }

            if let eventWindow = event.window, eventWindow === self.window {
                return
            }

            self.hide()
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
