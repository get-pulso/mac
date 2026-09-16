import AppKit
import Combine
import Dependencies
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    // MARK: Internal

    static let shared = SettingsWindowController()

    func show(section: NativeSettingsModel.Section? = nil, page: String = "", groupsPage: NativeGroupsPage = .list) {
        @Dependency(\.windowManager) var popover
        popover.hide()
        let wasVisible = self.window?.isVisible == true
        let previousRoute = self.model?.route
        if self.window == nil { self.makeWindow() }
        self.model?.navigate(section ?? .general, page: page, groupsPage: groupsPage)
        if !wasVisible, previousRoute == self.model?.route { self.model?.refreshCurrentRoute() }
        self.updateNavigation()
        if let window, let bounds = window.contentView?.bounds,
           bounds.width < NativeLayout.settingsMinimumSize.width || bounds.height < NativeLayout.settingsMinimumSize
           .height
        {
            NativeLayout.sizeSettingsWindow(window)
        }
        if let window {
            DockPresence.claim(window)
            AppActivation.bringForward(window)
        }
    }

    func close() {
        self.window?.close()
        self.window = nil; self.model = nil; self.split = nil
        self.navigation = nil; self.newGroupItem = nil; self.observation = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        self.model?.confirmLeavingProfile() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DockPresence.release(window)
    }

    func confirmTermination() -> Bool { self.model?.confirmLeavingProfile() ?? true }

    func invalidateGroups() {
        self.model?.groupSettings.invalidateList()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [self.separatorID, self.navigationID, .flexibleSpace, self.statusID, self.newGroupID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        self.toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if id == self.separatorID, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
        if id == self.statusID, let model {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Status"
            item.paletteLabel = "Status"
            let host = NSHostingView(rootView: NativeSettingsStatusView(model: model))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            item.autovalidates = false
            return item
        }
        if id == self.newGroupID {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "New Group"
            item.paletteLabel = "New Group"
            item.toolTip = "Create a new group"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Group")
            item.target = self
            item.action = #selector(self.createGroup)
            item.isBordered = true
            item.autovalidates = false
            item.isHidden = true
            self.newGroupItem = item
            return item
        }
        guard id == self.navigationID else { return nil }
        let item = NSToolbarItemGroup(
            itemIdentifier: id,
            images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
                NSImage(
                    systemSymbolName: "chevron.right",
                    accessibilityDescription: "Forward"
                )!,
            ],
            selectionMode: .momentary,
            labels: ["Back", "Forward"],
            target: self,
            action: #selector(self.navigate(_:))
        )
        item.isNavigational = true
        item.controlRepresentation = .expanded
        item.autovalidates = false
        self.navigation = item
        return item
    }

    // MARK: Private

    private var window: NSWindow?
    private var model: NativeSettingsModel?
    private var split: NSSplitViewController?
    private var navigation: NSToolbarItemGroup?
    private var newGroupItem: NSToolbarItem?
    private var observation: AnyCancellable?
    private let navigationID = NSToolbarItem.Identifier("FirstlightSettingsNavigation")
    private let newGroupID = NSToolbarItem.Identifier("FirstlightSettingsNewGroup")
    private let statusID = NSToolbarItem.Identifier("FirstlightSettingsStatus")
    private let separatorID = NSToolbarItem.Identifier("FirstlightSettingsSeparator")

    private func makeWindow() {
        let model = NativeSettingsModel()
        self.model = model
        let sidebar = NSHostingController(rootView: NativeSettingsSidebar(model: model))
        let detail = NSHostingController(rootView: NativeSettingsView(model: model))
        sidebar.sizingOptions = []; detail.sizingOptions = []
        let split = NSSplitViewController()
        split.view.frame = NSRect(x: 0, y: 0, width: 680, height: 500)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 210
        sidebarItem.canCollapse = false
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 430
        split.addSplitViewItem(detailItem)
        self.split = split

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.title = model.title
        // The sidebar selection names the screen; the title stays only for the
        // Window menu and accessibility, like Raycast's settings.
        window.titleVisibility = .hidden
        window.toolbarStyle = NativeLayout.settingsToolbarStyle
        window.contentMinSize = NativeLayout.settingsMinimumSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        let toolbar = NSToolbar(identifier: "FirstlightSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // Assigning a contentViewController replaces the content view with its
        // initial frame. Apply the desired size after controller + toolbar.
        NativeLayout.sizeSettingsWindow(window)
        window.center()
        split.splitView.setPosition(180, ofDividerAt: 0)
        self.window = window
        self.observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateNavigation() }
        }
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        self.model?.travel(sender.selectedIndex == 0 ? -1 : 1)
    }

    @objc private func createGroup() {
        self.model?.navigateGroups(.create)
    }

    private func updateNavigation() {
        guard let model else { return }
        self.window?.title = model.title
        self.window?.isDocumentEdited = model.route.section == .groups ? model.groupSettings.hasChanges :
            model.route.page == "edit" && model.hasProfileChanges
        let canNavigate = !(model.route.page == "edit" && model.busy && model.hasProfileChanges) &&
            !(model.route.section == .groups && model.groupSettings.busy)
        self.navigation?.subitems.first?.isEnabled = model.canGoBack && canNavigate
        self.navigation?.subitems.last?.isEnabled = model.canGoForward && canNavigate
        let showsNewGroup = model.route.section == .groups && model.route.groupsPage == .list
        self.newGroupItem?.isHidden = !showsNewGroup
        self.newGroupItem?.isEnabled = showsNewGroup && !model.groupSettings.busy
    }
}
