import AppKit
import DiskCore

/// A small cushion, matching how a kind looks in the treemap.
final class KindSwatchView: NSView {
    var color = NSColor.gray {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 2)
        let dark = color.blended(withFraction: 0.45, of: .black) ?? color
        let light = color.blended(withFraction: 0.55, of: .white) ?? color
        let gradient = NSGradient(colors: [light, color, dark], atLocations: [0, 0.5, 1], colorSpace: .sRGB)
        gradient?.draw(in: NSBezierPath(rect: rect), relativeCenterPosition: NSPoint(x: -0.1, y: 0.2))
    }
}

@MainActor
protocol KindsPanelDelegate: AnyObject {
    func kindsPanel(didSelect kind: KindID?)
    func kindsPanelShowFiles(of kind: KindID)
}

/// The list of file kinds with their colours, sizes and file counts.
@MainActor
final class KindsPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column {
        static let color = NSUserInterfaceItemIdentifier("color")
        static let kind = NSUserInterfaceItemIdentifier("kind")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let files = NSUserInterfaceItemIdentifier("files")
    }

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    weak var delegate: KindsPanelDelegate?

    private var statistics: [KindStatistic] = []
    private var colors: [SIMD4<Float>] = []
    private var table: KindTable?
    private var columnFitter: ColumnFitter?

    override init() {
        super.init()
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, String?, Bool)] = [
            (Column.color, "Color", 40, nil, true),
            (Column.kind, "Kind", 150, "kind", true),
            (Column.size, "Size", 68, "size", false),
            (Column.files, "Files", 56, "files", false),
        ]
        for (identifier, title, width, key, ascending) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = min(width, 36)
            if let key { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending) }
            if identifier == Column.size || identifier == Column.files {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.allowsEmptySelection = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        if let kind = tableView.tableColumn(withIdentifier: Column.kind) {
            columnFitter = ColumnFitter(table: tableView, flexible: kind, in: scrollView)
        }
    }

    func show(_ statistics: [KindStatistic], colors: [SIMD4<Float>], table: KindTable) {
        self.statistics = statistics
        self.colors = colors
        self.table = table
        sortRows()
        tableView.reloadData()
    }

    private func sortRows() {
        guard let descriptor = tableView.sortDescriptors.first, let table else { return }
        let ascending = descriptor.ascending
        switch descriptor.key {
        case "kind":
            statistics.sort {
                let order = table.kinds[Int($0.kind)].name.localizedStandardCompare(table.kinds[Int($1.kind)].name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        case "files":
            statistics.sort { ascending ? $0.files < $1.files : $0.files > $1.files }
        default:
            statistics.sort { ascending ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
        }
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        delegate?.kindsPanelShowFiles(of: statistics[row].kind)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        statistics.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortRows()
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let table else { return nil }
        let statistic = statistics[row]
        switch tableColumn.identifier {
        case Column.color:
            let swatch = tableView.makeView(withIdentifier: Column.color, owner: nil) as? KindSwatchView ?? {
                let view = KindSwatchView()
                view.identifier = Column.color
                return view
            }()
            swatch.color = NSColor(kindColor: colors[Int(statistic.kind)])
            return swatch
        case Column.kind:
            let cell = textCell(Column.kind, alignment: .left)
            cell.textField?.stringValue = table.kinds[Int(statistic.kind)].name
            return cell
        case Column.size:
            let cell = textCell(Column.size, alignment: .right)
            cell.textField?.stringValue = Format.bytes(statistic.bytes)
            return cell
        case Column.files:
            let cell = textCell(Column.files, alignment: .right)
            cell.textField?.stringValue = Format.count(statistic.files)
            return cell
        default:
            return nil
        }
    }

    private func textCell(_ identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let font: NSFont = identifier == Column.kind
            ? .systemFont(ofSize: NSFont.smallSystemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let text = NSTextField.label(font: font)
        text.lineBreakMode = .byTruncatingTail
        text.alignment = alignment
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        delegate?.kindsPanel(didSelect: row >= 0 ? statistics[row].kind : nil)
    }
}
