import AppKit
import SwiftUI

final class AppWindow: NSWindow {
    // MARK: Lifecycle

    init(appView: AppView) {
        self.appView = appView
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.setupAppearance()
        self.setupLayout()
    }

    // MARK: Private

    private let appView: AppView
    private lazy var hostingView = NSHostingView(rootView: self.appView)

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
