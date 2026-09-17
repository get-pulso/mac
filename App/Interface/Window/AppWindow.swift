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

    // MARK: Private

    private let hostingView: NSView

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
