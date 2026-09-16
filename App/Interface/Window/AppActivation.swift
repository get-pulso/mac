import AppKit

/// Bringing a real window forward when the user asked for it from the menu bar.
///
/// Firstlight runs as an accessory, so a click on the status item or one of its
/// menu items does not bring the app forward by itself. `NSApp.activate()` is
/// only a request: since macOS 14 the system decides, and for an app in this
/// position it decides no — the window opens behind whatever the pointer came
/// from and needs a second click before it takes any typing. The older call is
/// not cooperative and is the one that works; it is deprecated, not removed,
/// and this is the case it exists for.
///
/// The menu bar popover does not come through here. It is a non-activating
/// panel and takes the keyboard without the app becoming frontmost at all.
@MainActor
enum AppActivation {
    /// Activates the app and gives `window` the keyboard, in that order: a
    /// window made key while another app is still active is key only within
    /// this app, and the typing goes elsewhere.
    static func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard !window.isKeyWindow else { return }
        // Activation can land a beat later. Ask once more, and only while the
        // window is still on screen.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
}
