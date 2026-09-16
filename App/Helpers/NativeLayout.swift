import AppKit

enum NativeLayout {
    static let popoverHeaderHeight: CGFloat = 50
    static let peopleListHeight: CGFloat = 310
    static let peopleFooterHeight: CGFloat = 38
    static let peopleBodyHeight = peopleListHeight + peopleFooterHeight
    static let selectionListHeight: CGFloat = 410
    static let settingsSize = NSSize(width: 680, height: 500)
    static let settingsMinimumSize = NSSize(width: 640, height: 440)
    static let settingsToolbarStyle: NSWindow.ToolbarStyle = .unified

    @MainActor static func sizeSettingsWindow(_ window: NSWindow) {
        window.contentMinSize = self.settingsMinimumSize
        window.setContentSize(self.settingsSize)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
