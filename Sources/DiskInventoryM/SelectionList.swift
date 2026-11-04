import AppKit
import DiskCore

@MainActor
protocol SelectionListDelegate: AnyObject {
    func selectionList(didSelect node: NodeID)
    func selectionList(didChooseKind kind: KindID?)
    func selectionList(didSearchFor query: String)
    func selectionListMenu() -> NSMenu?
}

final class SelectionTableView: NSTableView {
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

/// A flat list of files, largest first: all files of a kind, or the results of a search.
@MainActor
final class SelectionListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let folder = NSUserInterfaceItemIdentifier("folder")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    let view = NSView()
    let searchField = NSSearchField()
    weak var delegate: SelectionListDelegate?

    private let tableView = SelectionTableView()
    private let scrollView = NSScrollView()
    private let kindPopup = NSPopUpButton()
    private let countLabel = NSTextField.label(color: .secondaryLabelColor)

    private var tree: FileTree?
    private var options = DisplayOptions()
    private var rows: [NodeID] = []
    private var kindsInMenu: [KindID?] = []
    private var isUpdatingSelection = false
    private var columnFitter: ColumnFitter?

    override init() {
        super.init()

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.name, "Name", 240),
            (Column.folder, "Folder", 340),
            (Column.size, "Size", 76),
            (Column.kind, "Kind", 150),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = 50
            if identifier == Column.size { column.headerCell.alignment = .right }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.contextMenu = { [weak self] in self?.delegate?.selectionListMenu() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        if let folder = tableView.tableColumn(withIdentifier: Column.folder) {
            columnFitter = ColumnFitter(table: tableView, flexible: folder, in: scrollView)
        }

        let caption = NSTextField.label()
        caption.stringValue = "Show all files of kind:"
        kindPopup.translatesAutoresizingMaskIntoConstraints = false
        kindPopup.controlSize = .small
        kindPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        kindPopup.target = self
        kindPopup.action = #selector(kindChosen)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.placeholderString = "Find by Name"
        searchField.sendsWholeSearchString = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        for subview in [caption, kindPopup, countLabel, searchField, scrollView] as [NSView] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            caption.centerYAnchor.constraint(equalTo: kindPopup.centerYAnchor),
            kindPopup.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            kindPopup.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            kindPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: kindPopup.trailingAnchor, constant: 10),
            countLabel.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: kindPopup.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchField.centerYAnchor.constraint(equalTo: kindPopup.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 200),
            scrollView.topAnchor.constraint(equalTo: kindPopup.bottomAnchor, constant: 5),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func searchChanged() {
        delegate?.selectionList(didSearchFor: searchField.stringValue)
    }

    @objc private func kindChosen() {
        let index = kindPopup.indexOfSelectedItem
        guard kindsInMenu.indices.contains(index) else { return }
        delegate?.selectionList(didChooseKind: kindsInMenu[index])
    }

    func setKinds(_ statistics: [KindStatistic], table: KindTable, selected: KindID?) {
        let sorted = statistics.sorted {
            table.kinds[Int($0.kind)].name.localizedStandardCompare(table.kinds[Int($1.kind)].name) == .orderedAscending
        }
        kindsInMenu = [nil] + sorted.map { Optional($0.kind) }
        kindPopup.removeAllItems()
        kindPopup.addItem(withTitle: "(all kinds)")
        kindPopup.menu?.addItem(.separator())
        // The separator takes up an index in the menu, so mirror it.
        kindsInMenu.insert(nil, at: 1)
        for statistic in sorted {
            kindPopup.addItem(withTitle: table.kinds[Int(statistic.kind)].name)
        }
        if let selected, let index = kindsInMenu.firstIndex(of: selected) {
            kindPopup.selectItem(at: index)
        }
    }

    func show(rows: [NodeID], total: String, tree: FileTree, options: DisplayOptions) {
        self.rows = rows
        self.tree = tree
        self.options = options
        countLabel.stringValue = total
        tableView.reloadData()
    }

    func select(_ node: NodeID?) {
        isUpdatingSelection = true
        defer { isUpdatingSelection = false }
        guard let node, let row = rows.firstIndex(of: node) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func removeRow(_ node: NodeID) {
        guard let row = rows.firstIndex(of: node) else { return }
        rows.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row))
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    #if UITEST
    var uiRowCount: Int { rows.count }
    #endif

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tree, let tableColumn else { return nil }
        let id = rows[row]
        let cell = self.cell(tableColumn.identifier)
        switch tableColumn.identifier {
        case Column.name:
            cell.textField?.stringValue = tree.name(of: id)
            cell.imageView?.image = IconCache.shared.icon(for: id, in: tree)
        case Column.folder:
            cell.textField?.stringValue = (tree.path(of: id) as NSString).deletingLastPathComponent
        case Column.size:
            cell.textField?.stringValue = Format.bytes(tree.size(of: id, options.sizeMode))
        case Column.kind:
            cell.textField?.stringValue = tree.kindTable.kinds[Int(tree.kind(of: id))].name
        default:
            break
        }
        return cell
    }

    private func cell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let font: NSFont = identifier == Column.size
            ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSTextField.label(font: font)
        if identifier == Column.size { text.alignment = .right }
        cell.addSubview(text)
        cell.textField = text

        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if identifier == Column.name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            leading = text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection, tableView.selectedRow >= 0 else { return }
        delegate?.selectionList(didSelect: rows[tableView.selectedRow])
    }
}
