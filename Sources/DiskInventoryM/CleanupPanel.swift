import AppKit
import DiskCore

@MainActor
protocol CleanupPanelDelegate: AnyObject {
    func cleanupPanel(didSelect suggestion: CleanupSuggestion)
    func cleanupPanelMoveToTrash(_ suggestion: CleanupSuggestion)
    func cleanupPanelReveal(_ suggestion: CleanupSuggestion)
    func cleanupPanelShowInList(_ suggestion: CleanupSuggestion)
}

/// What could go, and what it takes to get rid of it. Nothing happens here without a click: files
/// only ever go to the Trash, and commands are for the person to run.
@MainActor
final class CleanupPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case suggestion(CleanupSuggestion)
    }

    private enum Column {
        static let title = NSUserInterfaceItemIdentifier("title")
        static let size = NSUserInterfaceItemIdentifier("size")
    }

    let view = NSView()
    weak var delegate: CleanupPanelDelegate?

    private let summary = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium))
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyNote = NSTextField(wrappingLabelWithString: "")
    private let amount = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium))
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let listButton = NSButton(title: "Show in List", target: nil, action: nil)
    private var commandHeight = NSLayoutConstraint()

    private var rows: [Row] = []
    private var isUpdatingSelection = false
    private var columnFitter: ColumnFitter?
    private(set) var selected: CleanupSuggestion?

    override init() {
        super.init()

        for (identifier, width) in [(Column.title, CGFloat(220)), (Column.size, CGFloat(76))] {
            let column = NSTableColumn(identifier: identifier)
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .fullWidth
        tableView.floatsGroupRows = false
        tableView.allowsEmptySelection = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        if let title = tableView.tableColumn(withIdentifier: Column.title) {
            columnFitter = ColumnFitter(table: tableView, flexible: title, in: scrollView)
        }

        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyNote.font = small
        emptyNote.textColor = .secondaryLabelColor
        emptyNote.alignment = .center
        emptyNote.stringValue = "Nothing to clean up here.\n\nSuggestions come from your home folder and a few system folders, so they appear when a scan includes those."
        explanation.font = small
        explanation.textColor = .secondaryLabelColor
        command.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        command.isSelectable = true
        for field in [emptyNote, explanation, command] {
            field.translatesAutoresizingMaskIntoConstraints = false
            // Anything stronger would let a long text stretch the whole window.
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for button in [actionButton, listButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.controlSize = .small
            button.bezelStyle = .push
            button.target = self
            button.font = small
        }
        actionButton.action = #selector(actionClicked)
        listButton.action = #selector(listClicked)

        let details = NSView()
        details.translatesAutoresizingMaskIntoConstraints = false
        for subview in [amount, explanation, command, actionButton, listButton] as [NSView] {
            details.addSubview(subview)
        }
        for subview in [summary, scrollView, emptyNote, details] as [NSView] {
            view.addSubview(subview)
        }
        commandHeight = command.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: details.topAnchor),

            emptyNote.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyNote.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyNote.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            details.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            details.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            details.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            amount.topAnchor.constraint(equalTo: details.topAnchor, constant: 8),
            amount.leadingAnchor.constraint(equalTo: details.leadingAnchor, constant: 10),
            amount.trailingAnchor.constraint(equalTo: details.trailingAnchor, constant: -10),
            explanation.topAnchor.constraint(equalTo: amount.bottomAnchor, constant: 3),
            explanation.leadingAnchor.constraint(equalTo: amount.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: amount.trailingAnchor),
            command.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 6),
            command.leadingAnchor.constraint(equalTo: amount.leadingAnchor),
            command.trailingAnchor.constraint(equalTo: amount.trailingAnchor),
            actionButton.topAnchor.constraint(equalTo: command.bottomAnchor, constant: 7),
            actionButton.leadingAnchor.constraint(equalTo: amount.leadingAnchor),
            actionButton.bottomAnchor.constraint(equalTo: details.bottomAnchor, constant: -9),
            listButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            listButton.leadingAnchor.constraint(equalTo: actionButton.trailingAnchor, constant: 6),
        ])
        showDetails(of: nil)
    }

    func show(_ suggestions: [CleanupSuggestion]) {
        let previous = selected?.rule.id
        let safe = suggestions.filter { $0.rule.safety == .safe }
        let review = suggestions.filter { $0.rule.safety == .review }
        rows = []
        if !safe.isEmpty { rows += [.header("Safe to remove")] + safe.map(Row.suggestion) }
        if !review.isEmpty { rows += [.header("Worth a look")] + review.map(Row.suggestion) }

        isUpdatingSelection = true
        tableView.reloadData()
        var kept: CleanupSuggestion?
        for (index, row) in rows.enumerated() {
            if case .suggestion(let suggestion) = row, suggestion.rule.id == previous {
                kept = suggestion
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        isUpdatingSelection = false
        showDetails(of: kept)

        let total = safe.reduce(UInt64(0)) { $0 + $1.bytes }
        summary.stringValue = safe.isEmpty ? "" : "Up to \(Format.bytes(total)) safe to remove"
        emptyNote.isHidden = !suggestions.isEmpty
        scrollView.isHidden = suggestions.isEmpty
    }

    private func showDetails(of suggestion: CleanupSuggestion?) {
        selected = suggestion
        actionButton.isHidden = suggestion == nil
        listButton.isHidden = (suggestion?.nodes.count ?? 0) < 2
        guard let suggestion else {
            amount.stringValue = ""
            explanation.stringValue = rows.isEmpty ? "" : "Choose something to see what it takes to remove it."
            command.stringValue = ""
            command.isHidden = true
            commandHeight.isActive = true
            return
        }
        let size = Format.bytes(suggestion.bytes)
        let items = suggestion.nodes.count > 1 ? Format.items(UInt64(suggestion.nodes.count), "item", "items") + ", " : ""
        amount.stringValue = suggestion.rule.action == .command ? "Up to \(size)" : items + size
        explanation.stringValue = suggestion.rule.why
        command.stringValue = suggestion.rule.command ?? ""
        command.isHidden = suggestion.rule.command == nil
        commandHeight.isActive = suggestion.rule.command == nil
        actionButton.title = actionTitle(of: suggestion)
    }

    private func actionTitle(of suggestion: CleanupSuggestion) -> String {
        switch suggestion.rule.action {
        case .trash: "Move to Trash…"
        case .command: "Copy Command"
        case .reveal: "Reveal in Finder"
        }
    }

    @objc private func actionClicked() {
        guard let selected else { return }
        switch selected.rule.action {
        case .trash:
            delegate?.cleanupPanelMoveToTrash(selected)
        case .reveal:
            delegate?.cleanupPanelReveal(selected)
        case .command:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected.rule.command ?? "", forType: .string)
            actionButton.title = "Copied"
            let id = selected.rule.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let current = self.selected, current.rule.id == id else { return }
                self.actionButton.title = self.actionTitle(of: current)
            }
        }
    }

    @objc private func listClicked() {
        if let selected { delegate?.cleanupPanelShowInList(selected) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .suggestion = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = cell("header", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold))
            cell.textField?.stringValue = title
            return cell
        case .suggestion(let suggestion):
            if tableColumn?.identifier == Column.size {
                let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                let cell = cell("size", font: font)
                cell.textField?.alignment = .right
                cell.textField?.stringValue = Format.bytes(suggestion.bytes)
                return cell
            }
            let cell = cell("title", font: .systemFont(ofSize: NSFont.smallSystemFontSize))
            cell.textField?.stringValue = suggestion.rule.title
            return cell
        }
    }

    private func cell(_ name: String, font: NSFont) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(name)
        if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return cell }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField.label(font: font)
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isUpdatingSelection else { return }
        let index = tableView.selectedRow
        guard index >= 0, case .suggestion(let suggestion) = rows[index] else {
            showDetails(of: nil)
            return
        }
        showDetails(of: suggestion)
        delegate?.cleanupPanel(didSelect: suggestion)
    }

    #if UITEST
    var uiRowCount: Int {
        rows.filter { if case .suggestion = $0 { true } else { false } }.count
    }
    var uiActionTitle: String { selected == nil ? "none" : actionButton.title }

    /// Chooses the nth suggestion, leaving out the headers.
    func uiSelect(_ position: Int) {
        var remaining = position
        for (index, row) in rows.enumerated() {
            guard case .suggestion = row else { continue }
            if remaining == 0 {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                return
            }
            remaining -= 1
        }
    }
    #endif
}
