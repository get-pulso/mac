import AppKit
import SwiftUI

enum NativeSettingsBorderStyle {
    static let width: CGFloat = 0.5
    static let topOpacity: CGFloat = 0.12
    static let bottomOpacity: CGFloat = 0.025
    static let surfaceOpacity: CGFloat = 0.04
}

struct NativeSettingsAvatarBorder: View {
    var body: some View {
        Circle().stroke(
            LinearGradient(
                colors: [
                    Color.primary.opacity(NativeSettingsBorderStyle.topOpacity),
                    Color.primary.opacity(NativeSettingsBorderStyle.bottomOpacity),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: NativeSettingsBorderStyle.width
        )
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// AppKit keeps keyboard selection and accessibility; only its accent-colored
/// selection painting is replaced. No system-wide accent preference is changed.
struct NeutralSettingsList: NSViewRepresentable {
    struct Item: Equatable { let title: String; let icon: String }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        // MARK: Lifecycle

        init(_ parent: NeutralSettingsList) { self.parent = parent }

        // MARK: Internal

        var parent: NeutralSettingsList
        var updating = false

        func numberOfRows(in tableView: NSTableView) -> Int { self.parent.items.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NeutralSettingsRow() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = self.parent.items[row]
            let cell = NeutralSettingsCell()
            let well = NeutralSettingsIconWell()
            let image = NSImageView()
            image
                .image = NSImage(named: item.icon) ??
                NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            image.contentTintColor = .labelColor
            image.setAccessibilityElement(false)
            let label = cell.titleField
            label.stringValue = item.title
            cell.setSelected(self.parent.selection == item.title)
            label.lineBreakMode = .byTruncatingTail
            for view in [well, image, label] {
                view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                // .sourceList already contributes the native horizontal inset.
                well.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                well.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                well.widthAnchor.constraint(equalToConstant: 20), well.heightAnchor.constraint(equalToConstant: 20),
                image.centerXAnchor.constraint(equalTo: well.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: well.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            self.updateSelection(in: table)
            guard !self.updating,
                  self.parent.items.indices.contains(table.selectedRow) else { return }
            self.parent.selection = self.parent.items[table.selectedRow].title
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            (rowView.view(atColumn: 0) as? NeutralSettingsCell)?.setSelected(tableView.isRowSelected(row))
        }

        func updateSelection(in table: NSTableView) {
            for row in 0 ..< table.numberOfRows {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NeutralSettingsCell)?
                    .setSelected(table.isRowSelected(row))
            }
        }
    }

    let items: [Item]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("setting")))
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        // Source lists derive row, label and glyph sizing from the user's
        // System Settings sidebar icon-size preference.
        table.rowSizeStyle = .default
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityLabel("Settings sections")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let table = scroll.documentView as? NSTableView else { return }
        let changed = coordinator.parent.items != self.items
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.parent = self
        if changed || table.numberOfRows != self.items.count { table.reloadData() }
        let row = self.items.firstIndex { $0.title == selection }
        if let row,
           table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else if row == nil, table.selectedRow != -1 { table.deselectAll(nil) }
        coordinator.updateSelection(in: table)
    }
}

final class NeutralSettingsCell: NSTableCellView {
    // Deliberately not the NSTableCellView.textField outlet: source-list styling
    // rewrites that outlet's attributed text independently of our selection.
    let titleField = NSTextField(labelWithString: "")

    func setSelected(_ selected: Bool) {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: selected ? .semibold : .regular)
        self.titleField.font = font.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
    }
}

final class NeutralSettingsIconWell: NSView {
    static let borderWidth = NativeSettingsBorderStyle.width
    static let borderTopOpacity = NativeSettingsBorderStyle.topOpacity
    static let borderBottomOpacity = NativeSettingsBorderStyle.bottomOpacity

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = Self.borderWidth / 2
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: 5 - inset,
            yRadius: 5 - inset
        )
        NSColor.labelColor.withAlphaComponent(NativeSettingsBorderStyle.surfaceOpacity).setFill()
        path.fill()

        let outer = NSBezierPath(
            roundedRect: self.bounds,
            xRadius: 5,
            yRadius: 5
        )
        let inner = NSBezierPath(
            roundedRect: self.bounds.insetBy(dx: Self.borderWidth, dy: Self.borderWidth),
            xRadius: 5 - Self.borderWidth,
            yRadius: 5 - Self.borderWidth
        )
        let border = NSBezierPath()
        border.append(outer)
        border.append(inner)
        border.windingRule = .evenOdd

        NSGraphicsContext.saveGraphicsState()
        border.addClip()
        NSGradient(
            starting: NSColor.labelColor.withAlphaComponent(Self.borderTopOpacity),
            ending: NSColor.labelColor.withAlphaComponent(Self.borderBottomOpacity)
        )?.draw(
            from: NSPoint(x: self.bounds.midX, y: self.bounds.maxY),
            to: NSPoint(x: self.bounds.midX, y: self.bounds.minY),
            options: []
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class NeutralSettingsRow: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            for column in 0 ..< self.numberOfColumns {
                (self.view(atColumn: column) as? NeutralSettingsCell)?.setSelected(self.isSelected)
            }
            self.needsDisplay = true
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        guard self.isSelected else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}
