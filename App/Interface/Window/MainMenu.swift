import AppKit
import Defaults

/// The menu bar shown while `DockPresence` keeps the app in `.regular`, and installed at
/// launch even as a menu bar agent: the bar is not visible then, but Undo and
/// Cut/Copy/Paste reach the popover's text fields only through the menu's key equivalents.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    // MARK: Internal

    static func install() {
        guard NSApp.mainMenu == nil else { return }
        NSApp.mainMenu = self.shared.makeMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(self.openSettings) else { return true }
        return Defaults[.currentUserID] != nil
    }

    // MARK: Private

    private static let shared = MainMenu()

    /// Responder-chain actions are addressed by name: they are implemented by whatever
    /// view is first responder (`NSTextView` and friends), not by a type known here.
    private static func responderItem(
        _ title: String,
        _ action: String,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector((action)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func makeMenu() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Firstlight"
        let bar = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About \(name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        bar.addItem(self.submenu(appMenu, titled: name))

        let edit = NSMenu(title: "Edit")
        edit.addItem(Self.responderItem("Undo", "undo:", "z"))
        edit.addItem(Self.responderItem("Redo", "redo:", "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(Self.responderItem("Cut", "cut:", "x"))
        edit.addItem(Self.responderItem("Copy", "copy:", "c"))
        edit.addItem(Self.responderItem("Paste", "paste:", "v"))
        edit.addItem(Self.responderItem("Select All", "selectAll:", "a"))
        bar.addItem(self.submenu(edit, titled: "Edit"))

        let windows = NSMenu(title: "Window")
        windows.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        bar.addItem(self.submenu(windows, titled: "Window"))
        NSApp.windowsMenu = windows

        return bar
    }

    private func submenu(_ menu: NSMenu, titled title: String) -> NSMenuItem {
        let item = NSMenuItem()
        menu.title = title
        item.submenu = menu
        return item
    }
}
