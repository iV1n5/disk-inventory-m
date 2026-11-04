import AppKit
import DiskCore

/// A small floating window with the details of the selected item.
@MainActor
final class InfoPanelController: NSWindowController {
    private let icon = NSImageView()
    private let name = NSTextField.label(font: .systemFont(ofSize: 13, weight: .semibold))
    private var values: [String: NSTextField] = [:]
    private static let rows = ["Kind", "Where", "Size on disk", "Content size", "Files", "Modified"]

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 230),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered, defer: true
        )
        panel.title = "Information"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        windowFrameAutosaveName = "InfoPanel"

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingMiddle

        let header = NSStackView(views: [icon, name])
        header.spacing = 8
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        for title in Self.rows {
            let label = NSTextField.label(color: .secondaryLabelColor)
            label.stringValue = title
            label.alignment = .right
            let value = NSTextField.label()
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            values[title] = value
            grid.addRow(with: [label, value])
        }
        grid.column(at: 0).xPlacement = .trailing

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        let content = panel.contentView!
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ id: NodeID?, in tree: FileTree?) {
        guard let id, let tree else {
            name.stringValue = "No selection"
            icon.image = nil
            values.values.forEach { $0.stringValue = "" }
            return
        }
        let node = tree.node(id)
        name.stringValue = tree.name(of: id)
        let image = IconCache.shared.icon(for: id, in: tree).copy() as? NSImage
        image?.size = NSSize(width: 32, height: 32)
        icon.image = image
        values["Kind"]?.stringValue = tree.kindTable.kinds[Int(tree.kind(of: id))].name
        values["Where"]?.stringValue = node.flags.contains(.synthetic) ? "" : tree.path(of: id)
        values["Size on disk"]?.stringValue = Format.bytes(node.physicalSize)
        values["Content size"]?.stringValue = Format.bytes(node.logicalSize)
        values["Files"]?.stringValue = node.isDirectory ? Format.count(UInt64(node.fileCount)) : ""
        values["Modified"]?.stringValue = node.modificationTime > 0 ? Format.date(secondsSince1970: node.modificationTime) : ""
    }
}
