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
        var opened = 0, invited = 0, settings = 0, quit = 0
        var signedIn = false
        let controller = StatusItemMenu(
            toggle: {}, open: { opened += 1 }, invite: { invited += 1 }, beforeMenu: {},
            settings: { settings += 1 }, canOpenSettings: { signedIn },
            replayOnboarding: {}, canReplayOnboarding: { true }, quit: { quit += 1 }
        )
        expect(!StatusItemMenu.opensContextMenu(type: .leftMouseUp, modifiers: []))
        expect(StatusItemMenu.opensContextMenu(type: .rightMouseUp, modifiers: []))
        expect(StatusItemMenu.opensContextMenu(type: .leftMouseUp, modifiers: .control))
        expect(!StatusItemMenu.opensContextMenu(type: nil, modifiers: []))
        // A 1080 pt screen with a 30 pt menu bar, and the item's button inside it.
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let belowBar = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let button = NSRect(x: 1468, y: 1053, width: 22, height: 22)
        func onItem(_ x: CGFloat, _ y: CGFloat, visibleFrame: NSRect = belowBar) -> Bool {
            StatusItemMenu.isOnItem(NSPoint(x: x, y: y), button: button, screen: screen, visibleFrame: visibleFrame)
        }
        expect(onItem(1479, 1064))
        expect(onItem(1479, 1080)) // The pointer thrown against the top edge.
        expect(onItem(1468, 1051) && onItem(1490, 1050)) // The bar's margin under the button.
        expect(!onItem(1479, 1049)) // Under the bar: another app's window.
        expect(!onItem(1467, 1064) && !onItem(1491, 1064)) // The neighbouring items.
        expect(!onItem(1479, 1300)) // A display arranged above this one.
        expect(onItem(1479, 1053, visibleFrame: screen) && !onItem(1479, 1052, visibleFrame: screen)) // A hidden bar.
        let menu = controller.makeMenu()
        // Built without DEBUG, as Release is: replaying onboarding, invite mocks
        // and the performance HUD are developer tools and must not be here.
        expect(menu.items.map(\.title) == ["Open Firstlight", "Invite a Friend", "Settings…", "", "Quit Firstlight"])
        expect(!menu.items[1].isEnabled && !menu.items[2].isEnabled)
        expect(menu.items[3].isSeparatorItem)
        expect(menu.items[2].keyEquivalent == "," && menu.items[4].keyEquivalent == "q")
        expect(menu.items[2].image == nil) // No automatic gear or leading image column.
        expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil })
        menu.performActionForItem(at: 0)
        expect(opened == 1)
        menu.performActionForItem(at: 4)
        expect(quit == 1)
        signedIn = true
        let authenticatedMenu = controller.makeMenu()
        expect(authenticatedMenu.items.map(\.title) == menu.items.map(\.title))
        expect(authenticatedMenu.items[1].isEnabled && authenticatedMenu.items[2].isEnabled)
        authenticatedMenu.performActionForItem(at: 1)
        expect(invited == 1)
        authenticatedMenu.performActionForItem(at: 2)
        expect(settings == 1)
        signedIn = false
        authenticatedMenu.performActionForItem(at: 1)
        authenticatedMenu.performActionForItem(at: 2)
        expect(invited == 1)
        expect(settings == 1) // Account may have expired while the menu was open.
        expect(controller.makeMenu().items[0].isEnabled && controller.makeMenu().items[4].isEnabled)
        print("Native status menu checks passed: \(checks)")
    }
}
