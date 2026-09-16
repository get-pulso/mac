import AppKit

enum NativeLayout {
    static let popoverWidth: CGFloat = 350
    static let popoverHeaderHeight: CGFloat = 50
    /// The margin a detail screen keeps inside the popover.
    static let popoverContentPadding: CGFloat = 14
    static let peopleListHeight: CGFloat = 310
    static let peopleFooterHeight: CGFloat = 45
    static let peopleBodyHeight = peopleListHeight + peopleFooterHeight
    static let selectionListHeight: CGFloat = 410
    static let settingsSize = NSSize(width: 680, height: 500)
    static let settingsMinimumSize = NSSize(width: 640, height: 440)
    static let settingsToolbarStyle: NSWindow.ToolbarStyle = .unified
    /// Detail screens measure their own title against the scrolling viewport,
    /// so the header can take the title over once it scrolls away.
    static let popoverScrollSpace = "popoverScroll"

    @MainActor static func sizeSettingsWindow(_ window: NSWindow) {
        window.contentMinSize = self.settingsMinimumSize
        window.setContentSize(self.settingsSize)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
