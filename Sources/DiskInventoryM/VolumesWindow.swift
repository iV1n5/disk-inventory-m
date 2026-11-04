import AppKit
import DiskCore

/// The window shown at launch, for picking a volume or folder to look at.
@MainActor
final class VolumesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private var volumes: [VolumeInfo] = []
    var onOpen: ((String) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let openButton = NSButton(title: "Open Volume", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Disk Inventory M"
        window.minSize = NSSize(width: 420, height: 220)
        window.center()
        super.init(window: window)
        // This has to be set on the controller: it overrules whatever the window was told.
        windowFrameAutosaveName = "VolumesWindow"

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("volume"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .inset
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let folderButton = NSButton(title: "Open Folder…", target: self, action: #selector(chooseFolder))
        openButton.target = self
        openButton.action = #selector(openSelected)
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false
        let buttons = NSStackView(views: [folderButton, openButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func reload() {
        volumes = VolumeInfo.mountedVolumes()
        tableView.reloadData()
        if !volumes.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func openSelected() {
        let row = tableView.selectedRow
        guard volumes.indices.contains(row) else { return }
        onOpen?(volumes[row].mountPath)
    }

    @objc private func chooseFolder() {
        onChooseFolder?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        volumes.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let volume = volumes[row]
        let identifier = NSUserInterfaceItemIdentifier("volumeRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? VolumeRowView ?? {
            let view = VolumeRowView()
            view.identifier = identifier
            return view
        }()
        cell.show(volume)
        return cell
    }
}

private final class VolumeRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium))
    private let detail = NSTextField.label(color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        for view in [icon, title, detail, bar] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func show(_ volume: VolumeInfo) {
        icon.image = NSWorkspace.shared.icon(forFile: volume.mountPath)
        title.stringValue = volume.name
        detail.stringValue = "\(Format.bytes(volume.availableBytes)) free of \(Format.bytes(volume.totalBytes))"
        bar.doubleValue = volume.totalBytes > 0 ? Double(volume.usedBytes) / Double(volume.totalBytes) : 0
    }
}
