import AppKit
import SwiftUI

/// Offscreen construction tests: no windows shown, screenshots captured,
/// accounts accessed, or network requests. Exercises actual AppKit sizing.
@main
struct NativeLayoutChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let sidebar = NSHostingController(rootView: List { Text("Account"); Text("General") }.listStyle(.sidebar))
        let detail = NSHostingController(rootView: Form { Section("Appearance") { Text("System") } }.formStyle(.grouped))
        sidebar.sizingOptions = []; detail.sizingOptions = []
        let split = NSSplitViewController()
        let left = NSSplitViewItem(sidebarWithViewController: sidebar)
        left.minimumThickness = 170; left.maximumThickness = 210; left.canCollapse = false
        let right = NSSplitViewItem(viewController: detail)
        right.minimumThickness = 430
        split.addSplitViewItem(left); split.addSplitViewItem(right)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = split
        window.toolbarStyle = NativeLayout.settingsToolbarStyle
        window.toolbar = NSToolbar(identifier: "LayoutCheck")
        NativeLayout.sizeSettingsWindow(window)
        precondition(window.contentView!.bounds.width >= NativeLayout.settingsMinimumSize.width)
        precondition(window.contentView!.bounds.height >= NativeLayout.settingsMinimumSize.height)
        precondition(window.contentView!.bounds.width >= 680)
        precondition(split.splitViewItems.count == 2)
        precondition(NativeLayout.popoverHeaderHeight == 50)
        precondition(NativeLayout.peopleListHeight == 310)
        precondition(NativeLayout.peopleFooterHeight == 45)
        precondition(NativeLayout.selectionListHeight == 410)
        // Full-size content includes the titlebar. Its safe-area inset changes
        // with toolbar style and OS version; do not assume a compact 50 pt bar.
        let toolbarInset = window.contentView!.bounds.height - window.contentLayoutRect.height
        precondition(toolbarInset >= 0 && toolbarInset < 100)
        for size in [NativeLayout.settingsMinimumSize, NativeLayout.settingsSize, NSSize(width: 900, height: 700)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(window.contentLayoutRect.width >= size.width)
            precondition(window.contentLayoutRect.height >= size.height - toolbarInset - 1)
        }
        print("Native layout checks passed: 15; window construction and three sizes, without displaying UI.")
        print("Settings content: \(Int(window.contentView!.bounds.width)) × \(Int(window.contentView!.bounds.height)) pt")
    }
}
