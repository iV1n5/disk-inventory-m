import AppKit
import DiskCore

/// NSOutlineView tells rows apart by object identity, so each node shown needs one lasting object.
final class NodeItem: NSObject {
    let id: NodeID

    init(_ id: NodeID) {
        self.id = id
    }
}

final class FilesOutlineView: NSOutlineView {
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return contextMenu?()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            NSApp.sendAction(#selector(ScanWindowController.toggleQuickLook(_:)), to: nil, from: self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A little bar showing a share of the parent folder.
final class ShareBarView: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 2, dy: (bounds.height - 6) / 2)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        var filled = track
        filled.size.width = max(fraction > 0 ? 2 : 0, track.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}

@MainActor
protocol FilesOutlineDelegate: AnyObject {
    func filesOutline(didSelect node: NodeID?)
    func filesOutlineMenu() -> NSMenu?
    func filesOutlineDoubleClicked(_ node: NodeID)
}

/// The Finder-like list: folders and files with their sizes, largest first.
@MainActor
final class FilesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let share = NSUserInterfaceItemIdentifier("share")
        static let files = NSUserInterfaceItemIdentifier("files")
    }

    let scrollView = NSScrollView()
    let outlineView = FilesOutlineView()
    weak var delegate: FilesOutlineDelegate?

    private var tree: FileTree?
    private var root: NodeID = 0
    private var options = DisplayOptions()
    private var items: [NodeID: NodeItem] = [:]
    /// Children in display order, for the folders where that's not simply the tree's order.
    private var customOrder: [NodeID: [NodeID]] = [:]
    private var isUpdatingSelection = false
    private var columnFitter: ColumnFitter?

    override init() {
        super.init()

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String?, Bool)] = [
            (Column.name, "Name", 240, 80, "name", true),
            (Column.size, "Size", 76, 50, "size", false),
            (Column.share, "%", 56, 30, nil, false),
            (Column.files, "Files", 64, 40, "files", false),
        ]
        for (identifier, title, width, minimum, key, ascending) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minimum
            if let key { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending) }
            if identifier == Column.size || identifier == Column.files {
                column.headerCell.alignment = .right
            }
            outlineView.addTableColumn(column)
            if identifier == Column.name { outlineView.outlineTableColumn = column }
        }
        outlineView.tableColumn(withIdentifier: Column.files)?.isHidden = true

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsColumnReordering = false
        // Otherwise opening deep folders widens the name column, pushing the sizes out of view.
        outlineView.autoresizesOutlineColumn = false
        outlineView.autosaveName = "FilesOutline"
        outlineView.autosaveTableColumns = true
        outlineView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.contextMenu = { [weak self] in self?.delegate?.filesOutlineMenu() }
        outlineView.headerView?.menu = makeHeaderMenu()

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        if let name = outlineView.tableColumn(withIdentifier: Column.name) {
            columnFitter = ColumnFitter(table: outlineView, flexible: name, in: scrollView)
        }
    }

    private func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        for column in outlineView.tableColumns where column.identifier != Column.name {
            let item = menu.addItem(withTitle: column.title == "%" ? "Share of Folder" : column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column
            item.state = column.isHidden ? .off : .on
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
        columnFitter?.fit()
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? NodeItem else { return }
        delegate?.filesOutlineDoubleClicked(item.id)
    }

    // MARK: Showing content

    func show(tree: FileTree, root: NodeID, options: DisplayOptions) {
        let isNewTree = self.tree !== tree
        self.tree = tree
        self.root = root
        self.options = options
        if isNewTree { items.removeAll() }
        customOrder.removeAll()
        outlineView.reloadData()
    }

    /// Selects a node, opening the folders around it as needed.
    func select(_ id: NodeID?) {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }

        guard let id, let tree else {
            outlineView.deselectAll(nil)
            return
        }
        let ancestry = tree.ancestry(of: id)
        guard let position = ancestry.firstIndex(of: root), id != root else {
            outlineView.deselectAll(nil)
            return
        }
        for ancestor in ancestry[(position + 1)...].dropLast() {
            outlineView.expandItem(item(for: ancestor))
        }
        let row = outlineView.row(forItem: item(for: id))
        guard row >= 0 else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    func scrollToSelection() {
        let row = outlineView.selectedRow
        if row >= 0 { outlineView.scrollRowToVisible(row) }
    }

    private func item(for id: NodeID) -> NodeItem {
        if let item = items[id] { return item }
        let item = NodeItem(id)
        items[id] = item
        return item
    }

    // MARK: Children

    private var isDefaultOrder: Bool {
        let descriptor = outlineView.sortDescriptors.first
        return descriptor?.key == "size" && descriptor?.ascending == false
    }

    private func orderedChildren(of id: NodeID) -> [NodeID]? {
        guard let tree else { return nil }
        if let cached = customOrder[id] { return cached }

        let needsExtras = id == tree.root && (options.showFreeSpace || options.showOtherSpace)
        guard !isDefaultOrder || needsExtras else { return nil }

        var children = tree.displayChildren(of: id, options)
        if let descriptor = outlineView.sortDescriptors.first, !isDefaultOrder {
            let mode = options.sizeMode
            let ascending = descriptor.ascending
            switch descriptor.key {
            case "name":
                let names = Dictionary(uniqueKeysWithValues: children.map { ($0, tree.name(of: $0)) })
                children.sort {
                    let order = names[$0]!.localizedStandardCompare(names[$1]!)
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
            case "files":
                children.sort {
                    let (a, b) = (tree.node($0).fileCount, tree.node($1).fileCount)
                    return ascending ? a < b : a > b
                }
            default:
                children.sort {
                    let (a, b) = (tree.size(of: $0, mode), tree.size(of: $1, mode))
                    return ascending ? a < b : a > b
                }
            }
        }
        customOrder[id] = children
        return children
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree else { return 0 }
        let id = (item as? NodeItem)?.id ?? root
        if item != nil, !tree.isContainer(id, options) { return 0 }
        return orderedChildren(of: id)?.count ?? Int(tree.node(id).childCount)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let id = (item as? NodeItem)?.id ?? root
        if let ordered = orderedChildren(of: id) { return self.item(for: ordered[index]) }
        return self.item(for: tree!.children(of: id)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tree, let item = item as? NodeItem else { return false }
        return tree.isContainer(item.id, options)
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        customOrder.removeAll()
        outlineView.reloadData()
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tree, let tableColumn, let id = (item as? NodeItem)?.id else { return nil }
        let node = tree.node(id)
        switch tableColumn.identifier {
        case Column.name:
            let cell = nameCell()
            cell.textField?.stringValue = tree.name(of: id)
            cell.textField?.textColor = node.flags.contains(.unreadable) ? .secondaryLabelColor : .labelColor
            cell.imageView?.image = IconCache.shared.icon(for: id, in: tree)
            cell.toolTip = tooltip(for: node)
            return cell
        case Column.size:
            let cell = textCell(Column.size, alignment: .right)
            cell.textField?.stringValue = Format.bytes(node.size(options.sizeMode))
            return cell
        case Column.files:
            let cell = textCell(Column.files, alignment: .right)
            cell.textField?.stringValue = node.isDirectory ? Format.count(UInt64(node.fileCount)) : ""
            return cell
        case Column.share:
            let bar = outlineView.makeView(withIdentifier: Column.share, owner: nil) as? ShareBarView ?? {
                let view = ShareBarView()
                view.identifier = Column.share
                return view
            }()
            let parent = node.parent == FileTree.noNode ? id : node.parent
            let total = tree.displaySize(of: parent, options)
            bar.fraction = total > 0 ? CGFloat(Double(node.size(options.sizeMode)) / Double(total)) : 0
            return bar
        default:
            return nil
        }
    }

    private func tooltip(for node: Node) -> String? {
        if node.flags.contains(.unreadable) { return "This folder could not be read." }
        if node.flags.contains(.mountPoint) { return "Another volume is mounted here. It is not included." }
        if node.flags.contains(.dataless) { return "Stored in the cloud, not on this Mac." }
        if node.flags.contains(.hardLinkDuplicate) { return "A further name for a file counted elsewhere." }
        return nil
    }

    private func nameCell() -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: Column.name, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = Column.name
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize))
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func textCell(_ identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
        text.alignment = alignment
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let row = outlineView.selectedRow
        let item = row >= 0 ? outlineView.item(atRow: row) as? NodeItem : nil
        delegate?.filesOutline(didSelect: item?.id)
    }
}
