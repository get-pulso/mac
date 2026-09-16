import AppKit
import SwiftUI

/// Exercise the real sidebar offscreen, without changing app preferences.
@main
struct NativeSettingsChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        var selected: String? = "General"
        var changes = 0
        let items: [NeutralSettingsList.Item] = [
            .init(title: "General", icon: "gearshape"),
            .init(title: "Security", icon: "lock.shield"),
        ]
        let sidebar = NeutralSettingsList(items: items, selection: Binding(
            get: { selected }, set: { selected = $0; changes += 1 }
        ))
        let host = NSHostingView(rootView: sidebar)
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = findTable(child) { return table } }
            return nil
        }
        guard let table = findTable(host) else { preconditionFailure("Sidebar table not constructed") }
        precondition(table.rowSizeStyle == .default)
        precondition(table.rowHeight >= 28 && table.rowHeight <= 36)
        precondition(table.style == .sourceList)
        precondition(table.bounds.width >= 160)
        precondition(table.selectionHighlightStyle == .none)
        precondition(!table.allowsMultipleSelection)
        precondition(table.numberOfRows == 2)
        precondition(table.selectedRow == 0)
        precondition(changes == 0) // Programmatic restoration must not navigate again.
        func expectSelectedFont(_ row: Int, selected: Bool) {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! NeutralSettingsCell
            let font = cell.titleField.font!
            precondition(font == NSFont.systemFont(ofSize: font.pointSize, weight: selected ? .semibold : .regular),
                         "Row \(row) font must match selection immediately")
            let renderedFont = cell.titleField.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            precondition((renderedFont ?? font) == font, "Rendered text must use the same selection weight")
        }
        expectSelectedFont(0, selected: true)
        expectSelectedFont(1, selected: false)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        precondition(selected == "Security" && changes == 1)
        expectSelectedFont(0, selected: false)
        expectSelectedFont(1, selected: true)
        let row = table.delegate!.tableView!(table, rowViewForRow: 1)!
        precondition(row is NeutralSettingsRow)
        row.isSelected = true
        precondition(row.interiorBackgroundStyle == .normal)
        let cell = table.delegate!.tableView!(table, viewFor: table.tableColumns[0], row: 1) as! NeutralSettingsCell
        cell.frame = NSRect(x: 0, y: 0, width: 180, height: table.rowHeight)
        cell.layoutSubtreeIfNeeded()
        precondition(cell.titleField.stringValue == "Security")
        precondition(cell.textField == nil) // AppKit must not separately restyle the visible label.
        let well = cell.subviews.compactMap { $0 as? NeutralSettingsIconWell }.first!
        precondition(well.frame.minX == 0 && well.frame.width == 20)
        precondition(NeutralSettingsIconWell.borderWidth == 0.5)
        precondition(NeutralSettingsIconWell.borderTopAlpha > 0.3)
        precondition(NeutralSettingsIconWell.borderBottomAlpha == 0)
        let image = cell.subviews.compactMap { $0 as? NSImageView }.first!
        precondition(image.contentTintColor == .labelColor)
        precondition(cell.constraints.contains { constraint in
            constraint.firstItem as? NSTextField === cell.titleField &&
                constraint.secondItem as? NeutralSettingsIconWell === well &&
                constraint.firstAttribute == .leading && constraint.secondAttribute == .trailing &&
                constraint.constant == 8
        })

        // Rapid selection updates must not depend on a layout or run-loop pass.
        for selectedRow in [0, 1, 0, 1, 0, 1] {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            expectSelectedFont(0, selected: selectedRow == 0)
            expectSelectedFont(1, selected: selectedRow == 1)
        }
        let selectedCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true) as! NeutralSettingsCell
        let unselectedCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NeutralSettingsCell
        // AppKit's later background and source-list sizing passes must not
        // override the current selection weight.
        selectedCell.backgroundStyle = .emphasized
        unselectedCell.backgroundStyle = .normal
        for size in [NSTableView.RowSizeStyle.small, .medium, .large] {
            table.rowSizeStyle = size
            table.layoutSubtreeIfNeeded()
            expectSelectedFont(0, selected: false)
            expectSelectedFont(1, selected: true)
        }
        expectSelectedFont(0, selected: false)
        expectSelectedFont(1, selected: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        expectSelectedFont(0, selected: false)
        expectSelectedFont(1, selected: true)

        let previousChanges = changes
        selected = nil // Selecting Account clears the section selection.
        host.rootView = NeutralSettingsList(items: items, selection: .constant(nil))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(table.selectedRow == -1 && changes == previousChanges)
        expectSelectedFont(0, selected: false)
        expectSelectedFont(1, selected: false)
        print("Native settings checks passed: sidebar geometry, immediate selection fonts, delayed restyling and Account deselection.")
    }
}
