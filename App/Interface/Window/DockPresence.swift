import AppKit

/// Pulso runs as a menu bar agent (`LSUIElement`), so by default it owns no Dock tile
/// and no menu bar. A real window needs both: somewhere to switch back to, and Quit
/// plus the text editing shortcuts. Ownership is counted per window, so the app drops
/// back to the menu bar as soon as the last one closes.
///
/// The status item popover deliberately does not claim it: it dismisses on an outside
/// click and belongs to the menu bar, not to the Dock.
@MainActor
enum DockPresence {
    // MARK: Internal

    /// Gives the app a Dock tile and a menu bar for as long as `window` stays open.
    static func claim(_ window: NSWindow) {
        guard self.owners.insert(ObjectIdentifier(window)).inserted, self.owners.count == 1 else { return }
        MainMenu.install()
        NSApp.setActivationPolicy(.regular)
    }

    /// Call from `windowWillClose(_:)`; the app returns to the menu bar with the last window.
    static func release(_ window: NSWindow) {
        guard self.owners.remove(ObjectIdentifier(window)) != nil, self.owners.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: Private

    private static var owners: Set<ObjectIdentifier> = []
}
