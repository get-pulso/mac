import AppKit

/// Builds and exercises real NSMenu actions without creating a status item,
/// showing UI, terminating Firstlight, or accessing a signed-in account.
@main
enum NativeStatusMenuChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var checks = 0
        func expect(
            _ value: @autoclosure () -> Bool,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            checks += 1
            precondition(value(), "Status menu check \(checks) failed", file: file, line: line)
        }
        var opened = 0, invited = 0, settings = 0, replayed = 0, quit = 0
        var signedIn = false
        var canReplay = true
        let controller = StatusItemMenu(
            toggle: {}, open: { opened += 1 }, invite: { invited += 1 }, beforeMenu: {},
            settings: { settings += 1 }, canOpenSettings: { signedIn },
            replayOnboarding: { replayed += 1 }, canReplayOnboarding: { canReplay }, quit: { quit += 1 }
        )
        expect(!StatusItemMenu.opensContextMenu(type: .leftMouseUp, modifiers: []))
        expect(StatusItemMenu.opensContextMenu(type: .rightMouseUp, modifiers: []))
        expect(StatusItemMenu.opensContextMenu(type: .leftMouseUp, modifiers: .control))
        expect(!StatusItemMenu.opensContextMenu(type: nil, modifiers: []))
        let menu = controller.makeMenu()
        expect(menu.items.map(\.title) == ["Open Firstlight", "Invite a Friend", "Settings…", "", "Replay onboarding", "", "Quit Firstlight"])
        expect(!menu.items[1].isEnabled && !menu.items[2].isEnabled)
        expect(menu.items[3].isSeparatorItem)
        expect(menu.items[2].keyEquivalent == "," && menu.items[6].keyEquivalent == "q")
        expect(menu.items[2].image == nil) // No automatic gear or leading image column.
        expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil })
        menu.performActionForItem(at: 0)
        expect(opened == 1)
        menu.performActionForItem(at: 4)
        expect(replayed == 1 && !signedIn) // Replay is available before signing in too.
        menu.performActionForItem(at: 6)
        expect(quit == 1)
        signedIn = true
        let authenticatedMenu = controller.makeMenu()
        expect(authenticatedMenu.items[1].isEnabled && authenticatedMenu.items[2].isEnabled)
        authenticatedMenu.performActionForItem(at: 1)
        expect(invited == 1)
        authenticatedMenu.performActionForItem(at: 2)
        expect(settings == 1)
        authenticatedMenu.performActionForItem(at: 4)
        expect(replayed == 2 && signedIn) // Replay never changes the account.
        canReplay = false
        expect(!controller.makeMenu().items[4].isEnabled)
        authenticatedMenu.performActionForItem(at: 4)
        expect(replayed == 2) // OAuth may have started while this menu was open.
        canReplay = true
        expect(controller.makeMenu().items[4].isEnabled)
        signedIn = false
        authenticatedMenu.performActionForItem(at: 1)
        authenticatedMenu.performActionForItem(at: 2)
        expect(invited == 1)
        expect(settings == 1) // Account may have expired while the menu was open.
        expect(controller.makeMenu().items[0].isEnabled && controller.makeMenu().items[6].isEnabled)
        print("Native status menu checks passed: \(checks)")
    }
}
