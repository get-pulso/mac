import AppKit

/// Target/action belongs to this item, never to every NSStatusBarButton.
@MainActor
final class StatusItemMenu: NSObject {
    // MARK: Lifecycle

    init(
        toggle: @escaping () -> Void,
        open: @escaping () -> Void,
        invite: @escaping () -> Void,
        beforeMenu: @escaping () -> Void,
        settings: @escaping () -> Void,
        canOpenSettings: @escaping () -> Bool,
        replayOnboarding: @escaping () -> Void,
        canReplayOnboarding: @escaping () -> Bool,
        quit: @escaping () -> Void,
        prefetch: @escaping () -> Void = {},
        rehearseOnboarding: @escaping () -> Void = {}
    ) {
        self.toggle = toggle
        self.open = open
        self.invite = invite
        self.beforeMenu = beforeMenu
        self.settings = settings
        self.canOpenSettings = canOpenSettings
        self.replayOnboarding = replayOnboarding
        self.canReplayOnboarding = canReplayOnboarding
        self.quit = quit
        self.prefetch = prefetch
        self.rehearseOnboarding = rehearseOnboarding
    }

    // MARK: Internal

    static func opensContextMenu(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || (type == .leftMouseUp && modifiers.contains(.control))
    }

    /// Whether a mouse down at `point` fell on the item whose button is at
    /// `button`, all in screen coordinates. The item owns the bar's full height
    /// in its button's column: from the bar's lower edge, where the visible
    /// frame stops, up to the top of the screen, where a pointer thrown at the
    /// bar comes to rest.
    static func isOnItem(_ point: NSPoint, button: NSRect, screen: NSRect, visibleFrame: NSRect) -> Bool {
        point.x >= button.minX && point.x <= button.maxX
            && point.y >= min(button.minY, visibleFrame.maxY) && point.y <= screen.maxY
    }

    func attach(to item: NSStatusItem) {
        self.statusItem = item
        item.button?.target = self
        item.button?.action = #selector(self.clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Firstlight")
        item.button?.toolTip = "Firstlight · Right-click for options"
        self.trackHover(on: item.button)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Firstlight")
        menu.autoenablesItems = false
        menu.addItem(self.item("Open Firstlight", action: #selector(self.openFirstlight)))
        let invitation = self.item("Invite a Friend", action: #selector(self.openInvite))
        invitation.isEnabled = self.canOpenSettings()
        menu.addItem(invitation)
        // `openSettings` is a private AppKit convention that injects a gear
        // image and reserves a leading menu column. Use a neutral selector so
        // this item aligns with the other text-only status-menu actions.
        let preferences = self.item("Settings…", action: #selector(self.showSettings), key: ",")
        preferences.isEnabled = self.canOpenSettings()
        menu.addItem(preferences)
        // Developer tools only: compiled out of Release, which the status
        // menu checks are built as.
        #if DEBUG
        menu.addItem(.separator())
        let replay = self.item("Replay onboarding", action: #selector(self.replayWelcome))
        replay.isEnabled = self.canReplayOnboarding()
        menu.addItem(replay)
        // The whole path again, profile steps included, with nothing saved.
        let rehearse = self.item("Replay onboarding with profile", action: #selector(self.rehearseWelcome))
        rehearse.isEnabled = self.canReplayOnboarding()
        menu.addItem(rehearse)
        menu.addItem(.separator())
        menu.addItem(self.item(
            InviteMocks.isEnabled ? "Turn off invite mocks" : "Invite mocks…",
            action: #selector(self.toggleInviteMocks)
        ))
        menu.addItem(self.item(
            PerformanceHUD.isEnabled ? "Hide performance HUD" : "Show performance HUD",
            action: #selector(self.togglePerformanceHUD)
        ))
        #endif
        menu.addItem(.separator())
        menu.addItem(self.item("Quit Firstlight", action: #selector(self.quitFirstlight), key: "q"))
        return menu
    }

    /// The pointer arriving over the icon, whether or not it is clicked.
    @objc(mouseEntered:) func mouseEntered(with _: NSEvent) { self.prefetch() }

    // MARK: Private

    private weak var statusItem: NSStatusItem?
    private let toggle: () -> Void
    private let open: () -> Void
    private let invite: () -> Void
    private let beforeMenu: () -> Void
    private let settings: () -> Void
    private let canOpenSettings: () -> Bool
    private let replayOnboarding: () -> Void
    private let canReplayOnboarding: () -> Bool
    private let quit: () -> Void
    private let rehearseOnboarding: () -> Void
    /// Asks for what the popover will need. The pointer reaches the menu bar
    /// before the click does, and that head start is roughly what one request
    /// costs, so the list is often already in hand by the time it opens.
    private let prefetch: () -> Void
    private var hoverArea: NSTrackingArea?

    @objc private func clicked() {
        let event = NSApp.currentEvent
        guard Self.opensContextMenu(type: event?.type, modifiers: event?.modifierFlags ?? []) else {
            self.toggle()
            return
        }
        guard let statusItem, let button = statusItem.button else { return }
        self.beforeMenu()
        // With a menu attached AppKit handles the click, rather than invoking
        // this action. Remove it afterwards so a normal click still toggles UI.
        statusItem.menu = self.makeMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func trackHover(on button: NSStatusBarButton?) {
        guard let button else { return }
        if let hoverArea { button.removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        button.addTrackingArea(area)
        self.hoverArea = area
    }

    @objc private func openFirstlight() { self.open() }
    @objc private func openInvite() { if self.canOpenSettings() { self.invite() } }
    @objc private func showSettings() { if self.canOpenSettings() { self.settings() } }
    @objc private func replayWelcome() { if self.canReplayOnboarding() { self.replayOnboarding() } }
    @objc private func rehearseWelcome() { if self.canReplayOnboarding() { self.rehearseOnboarding() } }
    @objc private func quitFirstlight() { self.quit() }

    #if DEBUG
    @objc private func toggleInviteMocks() {
        InviteMocks.isEnabled.toggle()
        InviteMocks.reset()
        SocialStore.shared.reloadForMocks()
        self.open()
    }

    @objc private func togglePerformanceHUD() { PerformanceHUD.isEnabled.toggle() }
    #endif
}
