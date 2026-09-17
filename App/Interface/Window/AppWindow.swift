import AppKit
import SwiftUI

/// The menu bar popover's window. A panel, and a non-activating one: the app
/// is an accessory, and `NSApp.activate()` is a request the system is free to
/// refuse, so a window that could only take the keyboard by activating the
/// whole app would open unfocused and need a second click. A non-activating
/// panel becomes key on its own, the way the system's own menu bar popovers
/// and Spotlight do, whether or not the app is frontmost.
final class AppWindow: NSPanel {
    // MARK: Lifecycle

    convenience init(appView: AppView) { self.init(content: appView) }

    /// Hosts the view as it is: no type erasure between the window and the
    /// content, so the popover's own tree is exactly what it always was.
    init(content: some View) {
        self.hostingView = NSHostingView(rootView: content)
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.setupAppearance()
        self.setupLayout()
    }

    // MARK: Internal

    /// A borderless panel answers no by default, and a window that cannot be
    /// key takes no typing. Main stays as a panel has it, false: a panel that
    /// became main would be claiming the app is active, which it need not be.
    override var canBecomeKey: Bool { true }

    /// The panel comes out of the status item: it grows the last few points
    /// from the spot under the icon while it fades in, and goes back the same
    /// way, faster. The motion lives on the presentation layer only, so
    /// AppKit's own geometry for the view is never touched.
    ///
    /// `anchorX` is the icon's centre in screen coordinates.
    func present(fromScreenX anchorX: CGFloat) {
        // Already open and staying: asked again, it only takes the keyboard.
        if self.isVisible, !self.leaving {
            self.makeKeyAndOrderFront(nil)
            return
        }
        self.generation += 1
        self.leaving = false
        let layer = self.contentView?.layer
        layer?.removeAnimation(forKey: Self.growKey)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer else {
            self.alphaValue = 1
            self.makeKeyAndOrderFront(nil)
            return
        }
        if !self.isVisible { self.alphaValue = 0 }
        self.makeKeyAndOrderFront(nil)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = self.transform(scale: 0.94, anchorX: anchorX, in: layer)
        grow.toValue = CATransform3DIdentity
        grow.duration = 0.24
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        layer.add(grow, forKey: Self.growKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func dismiss(towardScreenX anchorX: CGFloat?) {
        guard self.isVisible, !self.leaving else { return }
        self.generation += 1
        let generation = self.generation
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = self.contentView?.layer, let anchorX
        else {
            self.orderOut(nil)
            return
        }
        self.leaving = true
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = layer.presentation()?.transform ?? CATransform3DIdentity
        shrink.toValue = self.transform(scale: 0.96, anchorX: anchorX, in: layer)
        shrink.duration = 0.12
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: Self.growKey)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Opened again before it had finished leaving: it stays.
            guard let self, self.generation == generation else { return }
            self.leaving = false
            self.orderOut(nil)
            layer.removeAnimation(forKey: Self.growKey)
            self.alphaValue = 1
        }
    }

    // MARK: Private

    private static let growKey = "panel-grow"

    private let hostingView: NSView
    private var generation = 0
    private var leaving = false

    private let blurView: NSVisualEffectView = {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }()

    private let borderView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.layer?.cornerRadius = 16
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.layer?.masksToBounds = true
        return view
    }()

    /// A scale about the point under the icon on the panel's top edge. The
    /// view's layer is anchored at its origin, bottom left.
    private func transform(scale: CGFloat, anchorX: CGFloat, in layer: CALayer) -> CATransform3D {
        let x = min(max(anchorX - self.frame.minX, 0), layer.bounds.width)
        let y = layer.bounds.height
        var transform = CATransform3DMakeTranslation(x * (1 - scale), y * (1 - scale), 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }

    private func setupAppearance() {
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .mainMenu
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hasShadow = true
        // A panel hides itself when its app deactivates. This one is dismissed
        // by its own rules — a click outside, Escape, the status item again —
        // and the app may never have been active to begin with.
        self.hidesOnDeactivate = false
        // Clicking anywhere in the panel gives it the keyboard, not only the
        // text fields: a code can be pasted the moment it opens.
        self.becomesKeyOnlyIfNeeded = false
    }

    private func setupLayout() {
        self.blurView.addSubviewEdgePinning(self.hostingView)
        self.borderView.addSubviewEdgePinning(self.blurView)
        self.contentView = self.borderView
    }
}

private extension NSView {
    func addSubviewEdgePinning(_ view: NSView) {
        self.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.bottomAnchor),
        ])
    }
}
