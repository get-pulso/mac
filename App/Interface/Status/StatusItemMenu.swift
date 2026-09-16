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
        quit: @escaping () -> Void
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
    }

    // MARK: Internal

    static func opensContextMenu(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || (type == .leftMouseUp && modifiers.contains(.control))
    }

    func attach(to item: NSStatusItem) {
        self.statusItem = item
        item.button?.target = self
        item.button?.action = #selector(self.clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Pulso")
        item.button?.toolTip = "Pulso · Right-click for options"
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Pulso")
        menu.autoenablesItems = false
        menu.addItem(self.item("Open Pulso", action: #selector(self.openPulso)))
        let invitation = self.item("Invite a Friend", action: #selector(self.openInvite))
        invitation.isEnabled = self.canOpenSettings()
        menu.addItem(invitation)
        let preferences = self.item("Settings…", action: #selector(self.openSettings), key: ",")
        preferences.isEnabled = self.canOpenSettings()
        // macOS can decorate a conventional Settings item even when image is
        // nil. A zero-sized image opts out without introducing custom menu UI.
        preferences.image = NSImage(size: .zero)
        menu.addItem(preferences)
        menu.addItem(.separator())
        let replay = self.item("Replay onboarding", action: #selector(self.replayWelcome))
        replay.isEnabled = self.canReplayOnboarding()
        menu.addItem(replay)
        menu.addItem(.separator())
        menu.addItem(self.item("Quit Pulso", action: #selector(self.quitPulso), key: "q"))
        return menu
    }

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

    @objc private func openPulso() { self.open() }
    @objc private func openInvite() { if self.canOpenSettings() { self.invite() } }
    @objc private func openSettings() { if self.canOpenSettings() { self.settings() } }
    @objc private func replayWelcome() { if self.canReplayOnboarding() { self.replayOnboarding() } }
    @objc private func quitPulso() { self.quit() }
}
