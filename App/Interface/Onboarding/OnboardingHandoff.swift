import AppKit
import QuartzCore

/// The mark is the one thing that exists both in the onboarding window's
/// header and in the menu bar. When the profile is saved it leaves the
/// header and flies to the status item, which takes it in: the window is
/// gone, and the place the app now lives has just been pointed at. In every
/// frame the mark is in exactly one place.
@MainActor
enum OnboardingHandoff {
    // MARK: Internal

    static let flightDuration = 0.55

    /// Flies `image` from `start` (screen coordinates) to the centre of the
    /// status item's button, shrinking to the icon's size, then calls
    /// `arrival`. With Reduce Motion, or when the two are on different
    /// screens, there is no flight: `arrival` is called at once.
    static func fly(
        image: NSImage,
        from start: CGRect,
        to button: NSStatusBarButton,
        iconSide: CGFloat,
        reduceMotion: Bool,
        arrival: @escaping () -> Void
    ) {
        guard !reduceMotion,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen,
              screen.frame.intersects(start)
        else {
            arrival()
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let end = CGRect(
            x: buttonRect.midX - iconSide / 2, y: buttonRect.midY - iconSide / 2,
            width: iconSide, height: iconSide
        )
        let cover = start.union(end).insetBy(dx: -40, dy: -40)

        let window = NSWindow(contentRect: cover, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Firstlight Handoff"
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSView(frame: NSRect(origin: .zero, size: cover.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = host

        let mark = CALayer()
        mark.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        mark.contentsGravity = .resizeAspect
        mark.contentsScale = screen.backingScaleFactor
        mark.frame = start.offsetBy(dx: -cover.minX, dy: -cover.minY)
        host.layer?.addSublayer(mark)
        window.orderFrontRegardless()
        self.inFlight = window

        let target = end.offsetBy(dx: -cover.minX, dy: -cover.minY)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                window.orderOut(nil)
                window.close()
                if self.inFlight === window { self.inFlight = nil }
                arrival()
            }
        }
        // The same quintic ease the pair rose to the header with.
        let group = CAAnimationGroup()
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: CGPoint(x: mark.frame.midX, y: mark.frame.midY))
        position.toValue = NSValue(point: CGPoint(x: target.midX, y: target.midY))
        let bounds = CABasicAnimation(keyPath: "bounds.size")
        bounds.fromValue = NSValue(size: mark.bounds.size)
        bounds.toValue = NSValue(size: target.size)
        group.animations = [position, bounds]
        group.duration = self.flightDuration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.83, 0, 0.17, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        mark.add(group, forKey: "flight")
        CATransaction.commit()
    }

    // MARK: Private

    private static var inFlight: NSWindow?
}
