import AppKit
import DiskCore
import Quartz

/// One window showing one scanned folder or volume.
@MainActor
final class ScanWindowController: NSWindowController, NSWindowDelegate {
    private enum Origin {
        case treemap, outline, list, program
    }

    let requestedPath: String
    var onClose: (() -> Void)?

    // The tree may only change on this queue, which is also where layouts are computed, and only
    // while the main thread waits for it: that way nothing ever reads a tree mid-change.
    private let work = DispatchQueue(label: "DiskInventoryM.tree", qos: .userInitiated)

    private var tree: FileTree?
    private var options = DisplayOptions()
    private var zoomRoot: NodeID = 0
    private var zoomHistory: [NodeID] = []
    private var selection: NodeID?
    private var hovered: NodeID?
    private var statistics: [KindStatistic] = []
    private var listKind: KindID?
    private var listQuery = ""

    private var scanner: DiskScanner?
    private var progressTimer: Timer?
    private var isRefreshingSelection = false
    private var scanDuration: TimeInterval = 0

    private let outline = FilesOutlineController()
    private let kinds = KindsPanelController()
    private let selectionList = SelectionListController()
    private let treemap: TreemapView
    private let pathControl = NSPathControl()
    private let progressView = ScanProgressView()
    private let statusTitle = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium))
    private let statusDetail = NSTextField.label(color: .secondaryLabelColor)
    private let statusTotals = NSTextField.label(color: .secondaryLabelColor)
    private let banner = NSView()
    private let bannerText = NSTextField.label()
    private var bannerHeight = NSLayoutConstraint()
    private let contentSplit = NSSplitView()
    private let sideSplit = NSSplitView()
    private let bottomSplit = NSSplitView()
    private var searchItem: NSSearchToolbarItem?
    private var infoPanel: InfoPanelController?

    init(path: String) {
        requestedPath = path
        treemap = TreemapView(queue: work)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 720, height: 420)
        window.title = (path as NSString).lastPathComponent
        window.isRestorable = false
        window.toolbarStyle = .unified
        window.center()
        super.init(window: window)
        window.delegate = self

        treemap.delegate = self
        treemap.animatesZooming = UserDefaults.standard.bool(forKey: Preferences.animatedZooming)
        outline.delegate = self
        kinds.delegate = self
        selectionList.delegate = self

        buildInterface(in: window)
        buildToolbar(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    // MARK: Interface

    private func buildInterface(in window: NSWindow) {
        let treemapPane = NSView()
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.focusRingType = .none
        treemap.translatesAutoresizingMaskIntoConstraints = false
        treemapPane.addSubview(pathControl)
        treemapPane.addSubview(treemap)
        NSLayoutConstraint.activate([
            pathControl.topAnchor.constraint(equalTo: treemapPane.topAnchor, constant: 2),
            pathControl.leadingAnchor.constraint(equalTo: treemapPane.leadingAnchor, constant: 6),
            pathControl.trailingAnchor.constraint(equalTo: treemapPane.trailingAnchor, constant: -6),
            pathControl.heightAnchor.constraint(equalToConstant: 20),
            treemap.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 2),
            treemap.leadingAnchor.constraint(equalTo: treemapPane.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: treemapPane.trailingAnchor),
            treemap.bottomAnchor.constraint(equalTo: treemapPane.bottomAnchor),
        ])

        configure(contentSplit, vertical: !UserDefaults.standard.bool(forKey: Preferences.splitHorizontally), name: "ContentSplit")
        contentSplit.addArrangedSubview(outline.scrollView)
        contentSplit.addArrangedSubview(treemapPane)
        contentSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        contentSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)

        configure(sideSplit, vertical: true, name: "SideSplit")
        sideSplit.addArrangedSubview(contentSplit)
        sideSplit.addArrangedSubview(kinds.scrollView)
        sideSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        sideSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)

        configure(bottomSplit, vertical: false, name: "BottomSplit")
        bottomSplit.addArrangedSubview(sideSplit)
        bottomSplit.addArrangedSubview(selectionList.view)
        bottomSplit.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        bottomSplit.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        selectionList.view.isHidden = true

        for pane in [outline.scrollView, kinds.scrollView, treemapPane] as [NSView] {
            let width = pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
            width.priority = .defaultHigh
            let height = pane.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
            height.priority = .defaultHigh
            NSLayoutConstraint.activate([width, height])
        }
        selectionList.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        buildBanner()

        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        statusTotals.alignment = .right
        statusTotals.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusTotals.lineBreakMode = .byClipping
        for field in [statusTitle, statusDetail, statusTotals] { status.addSubview(field) }
        statusTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            status.heightAnchor.constraint(equalToConstant: 40),
            statusTitle.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 10),
            statusTitle.topAnchor.constraint(equalTo: status.topAnchor, constant: 5),
            statusTitle.trailingAnchor.constraint(lessThanOrEqualTo: statusTotals.leadingAnchor, constant: -12),
            statusDetail.leadingAnchor.constraint(equalTo: statusTitle.leadingAnchor),
            statusDetail.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 2),
            statusDetail.trailingAnchor.constraint(lessThanOrEqualTo: statusTotals.leadingAnchor, constant: -12),
            statusTotals.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -10),
            statusTotals.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])

        banner.isHidden = true

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.cancelButton.target = self
        progressView.cancelButton.action = #selector(cancelScan)
        progressView.isHidden = true

        let content = window.contentView!
        for view in [banner, bottomSplit, status, progressView] as [NSView] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSplit.topAnchor.constraint(equalTo: banner.bottomAnchor),
            bottomSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSplit.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            progressView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            progressView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func configure(_ split: NSSplitView, vertical: Bool, name: String) {
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.autosaveName = name
        split.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildBanner() {
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
        banner.translatesAutoresizingMaskIntoConstraints = false
        let button = NSButton(title: "Open Privacy Settings…", target: NSApp.delegate, action: #selector(AppDelegate.openFullDiskAccessSettings(_:)))
        button.controlSize = .small
        button.bezelStyle = .push
        button.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")!, target: self, action: #selector(dismissBanner))
        close.isBordered = false
        close.translatesAutoresizingMaskIntoConstraints = false
        for view in [bannerText, button, close] as [NSView] { banner.addSubview(view) }
        bannerHeight = banner.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bannerHeight,
            bannerText.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 10),
            bannerText.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            bannerText.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
            button.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
        ])
    }

    private func setBannerVisible(_ visible: Bool) {
        banner.isHidden = !visible
        bannerHeight.constant = visible ? 32 : 0
    }

    @objc private func dismissBanner() {
        setBannerVisible(false)
    }

    /// Gives the panes sensible sizes the first time around. From then on the split views restore
    /// whatever arrangement the user left them in. (Checking for their saved state doesn't work:
    /// they save it the moment they first lay out.)
    private func applyInitialPaneSizes() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Preferences.panesArranged) else { return }
        defaults.set(true, forKey: Preferences.panesArranged)
        window?.contentView?.layoutSubtreeIfNeeded()
        sideSplit.setPosition(sideSplit.bounds.width - 330, ofDividerAt: 0)
        contentSplit.setPosition(contentSplit.isVertical ? 400 : 260, ofDividerAt: 0)
    }

    // MARK: Scanning

    func startScan() {
        applyInitialPaneSizes()
        let newScanner: DiskScanner
        do {
            newScanner = try DiskScanner(path: requestedPath)
        } catch {
            fail(error)
            return
        }
        scanner = newScanner
        progressView.begin(path: newScanner.tree.rootPath)
        progressView.isHidden = false

        let volume = VolumeInfo(containing: newScanner.tree.rootPath)
        let expected = volume?.mountPath == newScanner.tree.rootPath ? volume?.usedBytes : nil
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scanner = self.scanner else { return }
                self.progressView.update(scanner.progress, expectedBytes: expected)
            }
        }

        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try newScanner.run() }
            Task { @MainActor [weak self] in
                self?.scanFinished(result, duration: Date().timeIntervalSince(started))
            }
        }
    }

    @objc private func cancelScan() {
        scanner?.cancel()
    }

    private func scanFinished(_ result: Result<FileTree, any Error>, duration: TimeInterval) {
        progressTimer?.invalidate()
        progressTimer = nil
        progressView.end()
        scanner = nil

        switch result {
        case .success(let newTree):
            scanDuration = duration
            progressView.isHidden = true
            let isFirstScan = tree == nil
            install(newTree, isFirstScan: isFirstScan)
        case .failure(ScanError.cancelled):
            progressView.isHidden = true
            if tree == nil { close() }
        case .failure(let error):
            progressView.isHidden = true
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "“\((requestedPath as NSString).lastPathComponent)” could not be scanned."
        if case ScanError.cannotOpen(_, let code) = error {
            alert.informativeText = String(cString: strerror(code))
        } else {
            alert.informativeText = "\(error)"
        }
        alert.alertStyle = .warning
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.tree == nil { self?.close() }
            }
        }
    }

    private func install(_ newTree: FileTree, isFirstScan: Bool) {
        if isFirstScan {
            options = Preferences.displayOptions(forVolume: newTree.isVolumeRoot)
        }
        work.sync { newTree.sortChildren(by: options.sizeMode) }

        tree = newTree
        zoomRoot = newTree.root
        zoomHistory = []
        selection = nil
        hovered = nil
        treemap.selectedNode = nil
        treemap.highlightedKind = nil
        window?.representedURL = URL(fileURLWithPath: newTree.rootPath)

        showContent(transition: .none)
        refreshStatistics()
        updateBanner()
        window?.makeFirstResponder(outline.outlineView)
    }

    private func showContent(transition: TreemapView.Transition) {
        guard let tree else { return }
        outline.show(tree: tree, root: zoomRoot, options: options)
        treemap.show(tree: tree, root: zoomRoot, options: options, transition: transition)
        updatePathBar()
        updateTitle()
        updateStatus()
    }

    /// Recomputes what is derived from the whole tree: kinds, their colours, the selection list.
    private func refreshStatistics() {
        guard let tree else { return }
        let options = self.options
        work.async { [weak self] in
            let statistics = tree.kindStatistics(options)
            let colors = KindPalette.colors(for: statistics, table: tree.kindTable)
            Task { @MainActor [weak self] in
                guard let self, self.tree === tree else { return }
                self.statistics = statistics
                self.kinds.show(statistics, colors: colors, table: tree.kindTable)
                self.treemap.setColors(colors)
                self.selectionList.setKinds(statistics, table: tree.kindTable, selected: self.listKind)
                self.reloadSelectionList()
                self.updateTotals()
            }
        }
    }

    private func updateBanner() {
        guard let tree else { return }
        let restricted = tree.issues.filter(\.isPrivacyRestriction).count
        setBannerVisible(restricted > 0)
        if restricted > 0 {
            let folders = Format.items(UInt64(restricted), "folder", "folders")
            bannerText.stringValue = "\(folders) could not be read because macOS restricts access. Give Disk Inventory M Full Disk Access to include everything."
        }
    }

    private func updateTitle() {
        guard let tree else { return }
        let size = Format.bytes(tree.size(of: tree.root, options.sizeMode))
        window?.title = "\(tree.name(of: tree.root)) (\(size))"
    }

    private func updateTotals() {
        guard let tree else { return }
        let files = Format.items(UInt64(tree.node(tree.root).fileCount), "file", "files")
        let folders = Format.items(tree.directoryCount, "folder", "folders")
        statusTotals.stringValue = "\(files), \(folders) · scanned in \(String(format: "%.1f", scanDuration)) s"
    }

    private func updatePathBar() {
        guard let tree else { return }
        pathControl.pathItems = tree.ancestry(of: zoomRoot).map { id in
            let item = NSPathControlItem()
            item.title = tree.name(of: id)
            item.image = IconCache.shared.icon(for: id, in: tree)
            return item
        }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard
            let tree, let clicked = sender.clickedPathItem,
            let index = sender.pathItems.firstIndex(where: { $0 === clicked })
        else { return }
        let target = tree.ancestry(of: zoomRoot)[index]
        if target != zoomRoot { zoomOut(to: target) }
    }

    /// The status line follows the pointer, and falls back to the selection.
    private func updateStatus() {
        guard let tree else {
            statusTitle.stringValue = ""
            statusDetail.stringValue = ""
            return
        }
        let id = hovered ?? selection ?? zoomRoot
        let node = tree.node(id)
        if node.flags.contains(.synthetic) {
            statusTitle.stringValue = tree.name(of: id)
            statusDetail.stringValue = Format.bytes(node.size(options.sizeMode))
            return
        }
        let path = tree.path(of: id)
        let folder = (path as NSString).deletingLastPathComponent
        statusTitle.stringValue = "\(tree.name(of: id)) (\(folder))"
        let kind = tree.kindTable.kinds[Int(tree.kind(of: id))].name
        var details = [kind, Format.bytes(node.size(options.sizeMode))]
        if node.isDirectory, !node.flags.contains(.package) || options.showPackageContents {
            details.append(Format.items(UInt64(node.fileCount), "file", "files"))
        }
        statusDetail.stringValue = details.joined(separator: ", ")
    }

    // MARK: Selection

    private func select(_ node: NodeID?, from origin: Origin) {
        selection = node
        treemap.selectedNode = node
        if origin != .outline { outline.select(node) }
        if origin != .list { selectionList.select(node) }
        updateStatus()
        infoPanel?.show(node, in: tree)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    private var selectedPath: String? {
        guard let tree, let selection, !tree.isSynthetic(selection) else { return nil }
        return tree.path(of: selection)
    }

    /// The folder to zoom into for the current selection, if any.
    private var zoomTarget: NodeID? {
        guard let tree, let selection, !tree.isSynthetic(selection) else { return nil }
        let target = tree.isContainer(selection, options) ? selection : tree.node(selection).parent
        return target == zoomRoot || target == FileTree.noNode ? nil : target
    }

    // MARK: Zooming

    private func zoomIn(to target: NodeID) {
        zoomHistory.append(zoomRoot)
        zoomRoot = target
        showContent(transition: .zoomIn)
        outline.select(selection)
    }

    private func zoomOut(to target: NodeID) {
        zoomRoot = target
        pruneZoomHistory()
        showContent(transition: .zoomOut)
        outline.select(selection)
    }

    /// Going back must always lead somewhere higher up than the current view.
    private func pruneZoomHistory() {
        guard let tree else { return }
        let ancestors = Set(tree.ancestry(of: zoomRoot).dropLast())
        zoomHistory.removeAll { !ancestors.contains($0) }
    }

    func populateZoomOutMenu(_ menu: NSMenu) {
        guard let tree else { return }
        for id in tree.ancestry(of: zoomRoot).dropLast().reversed() {
            let item = menu.addItem(withTitle: tree.name(of: id), action: #selector(zoomOutToItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.image = IconCache.shared.icon(for: id, in: tree)
        }
    }

    @objc private func zoomOutToItem(_ sender: NSMenuItem) {
        zoomOut(to: NodeID(sender.tag))
    }

    @objc func zoomIn(_ sender: Any?) {
        if let zoomTarget { zoomIn(to: zoomTarget) }
    }

    @objc func zoomOut(_ sender: Any?) {
        if let previous = zoomHistory.last { zoomOut(to: previous) }
    }

    // MARK: Actions on the selection

    @objc func openItem(_ sender: Any?) {
        guard let selectedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: selectedPath))
    }

    @objc func revealInFinder(_ sender: Any?) {
        guard let selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: selectedPath)])
    }

    @objc func selectParentFolder(_ sender: Any?) {
        guard let tree, let selection, selection != zoomRoot else { return }
        let parent = tree.node(selection).parent
        if parent != FileTree.noNode { select(parent, from: .program) }
    }

    @objc func scrollToSelection(_ sender: Any?) {
        outline.select(selection)
    }

    @objc func copy(_ sender: Any?) {
        guard let selectedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedPath, forType: .string)
    }

    @objc func moveToTrash(_ sender: Any?) {
        guard let tree, let node = selection, canTrashSelection, let path = selectedPath else { return }
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            Task { @MainActor [weak self] in
                guard let self, self.tree === tree else { return }
                switch result {
                case .success:
                    self.removeFromDisplay(node)
                case .failure(let error):
                    self.showTrashFailure(error, name: url.lastPathComponent)
                }
            }
        }
    }

    private func removeFromDisplay(_ node: NodeID) {
        guard let tree else { return }
        let parent = tree.node(node).parent
        work.sync {
            tree.remove(node)
            tree.updateVolumeSpace()
        }
        // A search can select a folder that the current view is inside of.
        if tree.ancestry(of: zoomRoot).contains(node) {
            zoomRoot = parent
            pruneZoomHistory()
        }
        selectionList.removeRow(node)
        hovered = nil
        selection = nil
        showContent(transition: .none)
        treemap.invalidateLayout()
        select(parent == zoomRoot ? nil : parent, from: .program)
        refreshStatistics()
    }

    private func showTrashFailure(_ error: any Error, name: String) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” could not be moved to the Trash."
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) }
    }

    @objc func refreshAll(_ sender: Any?) {
        guard scanner == nil else { return }
        startScan()
    }

    @objc func refreshSelection(_ sender: Any?) {
        guard let tree, let target = refreshTarget else { return }
        let refresher: DiskScanner
        do {
            refresher = try DiskScanner(refreshing: target, in: tree)
        } catch {
            fail(error)
            return
        }
        isRefreshingSelection = true
        statusTotals.stringValue = "Refreshing…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try refresher.run() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshingSelection = false
                if case .failure(let error) = result {
                    self.fail(error)
                    return
                }
                self.work.sync { refresher.commit(replacing: target) }
                self.showContent(transition: .none)
                self.treemap.invalidateLayout()
                self.select(target == self.zoomRoot ? nil : target, from: .program)
                self.refreshStatistics()
            }
        }
    }

    /// The toolbar's single button: the selection if there is one, and otherwise everything.
    @objc func refresh(_ sender: Any?) {
        if refreshTarget != nil {
            refreshSelection(sender)
        } else {
            refreshAll(sender)
        }
    }

    private var refreshTarget: NodeID? {
        guard let tree, let selection, !tree.isSynthetic(selection) else { return nil }
        return tree.node(selection).isDirectory ? selection : tree.node(selection).parent
    }

    private var canTrashSelection: Bool {
        guard let tree, let selection, !isBusy else { return false }
        return selection != tree.root && selection != zoomRoot && !tree.isSynthetic(selection)
    }

    private var isBusy: Bool {
        scanner != nil || isRefreshingSelection
    }

    // MARK: View settings

    private func optionsChanged() {
        guard let tree else { return }
        let mode = options.sizeMode
        work.sync { tree.sortChildren(by: mode) }
        if !options.showPackageContents { leavePackages(in: tree) }
        showContent(transition: .none)
        refreshStatistics()
    }

    /// With packages shown as files, nothing inside of one has a place on screen any more.
    private func leavePackages(in tree: FileTree) {
        func outermostPackage(above id: NodeID) -> NodeID? {
            tree.ancestry(of: id).first { tree.node($0).flags.contains(.package) }
        }
        if let package = outermostPackage(above: zoomRoot) {
            zoomRoot = tree.node(package).parent
            pruneZoomHistory()
        }
        if let current = selection, let package = outermostPackage(above: current), package != current {
            select(nil, from: .program)
        }
    }

    @objc func togglePackageContents(_ sender: Any?) {
        options.showPackageContents.toggle()
        optionsChanged()
    }

    @objc func toggleFreeSpace(_ sender: Any?) {
        options.showFreeSpace.toggle()
        optionsChanged()
    }

    @objc func toggleOtherSpace(_ sender: Any?) {
        options.showOtherSpace.toggle()
        optionsChanged()
    }

    @objc func toggleSizeMode(_ sender: Any?) {
        options.sizeMode = options.sizeMode == .physical ? .logical : .physical
        optionsChanged()
    }

    @objc func toggleSplitDirection(_ sender: Any?) {
        contentSplit.isVertical.toggle()
        contentSplit.adjustSubviews()
        let size = contentSplit.isVertical ? contentSplit.bounds.width : contentSplit.bounds.height
        contentSplit.setPosition(size * 0.4, ofDividerAt: 0)
    }

    @objc func toggleKinds(_ sender: Any?) {
        kinds.scrollView.isHidden.toggle()
        sideSplit.adjustSubviews()
    }

    @objc func toggleSelectionList(_ sender: Any?) {
        selectionList.view.isHidden.toggle()
        bottomSplit.adjustSubviews()
        if !selectionList.view.isHidden {
            window?.contentView?.layoutSubtreeIfNeeded()
            if selectionList.view.frame.height < 150 {
                bottomSplit.setPosition(bottomSplit.bounds.height - 240, ofDividerAt: 0)
            }
            reloadSelectionList()
        }
    }

    @objc func toggleInformation(_ sender: Any?) {
        if let panel = infoPanel?.window, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        if infoPanel == nil { infoPanel = InfoPanelController() }
        infoPanel?.show(selection, in: tree)
        infoPanel?.showWindow(nil)
    }

    // MARK: Selection list and searching

    private func reloadSelectionList() {
        guard let tree, !selectionList.view.isHidden else { return }
        let options = self.options
        let kind = listKind
        let query = listQuery
        let limit = 5000
        work.async { [weak self] in
            let rows = query.isEmpty
                ? tree.files(ofKind: kind, limit: limit, options)
                : tree.search(query, limit: limit, options)
            Task { @MainActor [weak self] in
                guard let self, self.tree === tree else { return }
                var total = Format.items(UInt64(rows.count), "item", "items")
                if rows.count == limit { total = "Largest \(total)" }
                if !query.isEmpty { total += " matching “\(query)”" }
                self.selectionList.show(rows: rows, total: total, tree: tree, options: options)
                self.selectionList.select(self.selection)
            }
        }
    }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        listQuery = sender.stringValue
        if !listQuery.isEmpty, selectionList.view.isHidden { toggleSelectionList(nil) }
        reloadSelectionList()
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            ("Open", #selector(openItem(_:))),
            ("Reveal in Finder", #selector(revealInFinder(_:))),
            ("Quick Look", #selector(toggleQuickLook(_:))),
            ("Copy Path", #selector(copy(_:))),
        ]
        for (title, action) in entries {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(refreshSelection(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(moveToTrash(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        scanner?.cancel()
        progressTimer?.invalidate()
        progressTimer = nil
        infoPanel?.close()
        onClose?()
    }
}

// MARK: - Validating menus and toolbar items

extension ScanWindowController: NSMenuItemValidation, NSToolbarItemValidation {
    private func isEnabled(_ action: Selector?) -> Bool {
        guard let action, tree != nil else { return false }
        switch action {
        case #selector(zoomIn(_:)): return zoomTarget != nil
        case #selector(zoomOut(_:)): return !zoomHistory.isEmpty
        case #selector(openItem(_:)), #selector(revealInFinder(_:)), #selector(toggleQuickLook(_:)), #selector(copy(_:)):
            return selectedPath != nil
        case #selector(moveToTrash(_:)): return canTrashSelection
        case #selector(refreshAll(_:)), #selector(refresh(_:)): return !isBusy
        case #selector(refreshSelection(_:)): return !isBusy && refreshTarget != nil
        case #selector(selectParentFolder(_:)): return selection != nil && selection != zoomRoot
        case #selector(scrollToSelection(_:)): return selection != nil
        case #selector(togglePackageContents(_:)), #selector(toggleFreeSpace(_:)),
            #selector(toggleOtherSpace(_:)), #selector(toggleSizeMode(_:)):
            return !isBusy
        default: return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePackageContents(_:)): item.state = options.showPackageContents ? .on : .off
        case #selector(toggleFreeSpace(_:)): item.state = options.showFreeSpace ? .on : .off
        case #selector(toggleOtherSpace(_:)): item.state = options.showOtherSpace ? .on : .off
        case #selector(toggleSizeMode(_:)): item.state = options.sizeMode == .physical ? .on : .off
        case #selector(toggleSplitDirection(_:)): item.state = contentSplit.isVertical ? .off : .on
        case #selector(toggleKinds(_:)): item.state = kinds.scrollView.isHidden ? .off : .on
        case #selector(toggleSelectionList(_:)): item.state = selectionList.view.isHidden ? .off : .on
        case #selector(toggleInformation(_:)): item.state = infoPanel?.window?.isVisible == true ? .on : .off
        default: break
        }
        return isEnabled(item.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isEnabled(item.action)
    }
}

// MARK: - Toolbar

extension ScanWindowController: NSToolbarDelegate {
    private enum Item {
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let reveal = NSToolbarItem.Identifier("reveal")
        static let quickLook = NSToolbarItem.Identifier("quickLook")
        static let trash = NSToolbarItem.Identifier("trash")
        static let refresh = NSToolbarItem.Identifier("refresh")
        static let kinds = NSToolbarItem.Identifier("kinds")
        static let list = NSToolbarItem.Identifier("list")
        static let info = NSToolbarItem.Identifier("info")
        static let search = NSToolbarItem.Identifier("search")
    }

    fileprivate func buildToolbar(in window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ScanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.zoomOut, Item.zoomIn, .space, Item.reveal, Item.quickLook, Item.trash, Item.refresh,
            .flexibleSpace, Item.list, Item.kinds, Item.info, Item.search,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ label: String, _ symbol: String, _ action: Selector, _ tip: String) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = tip
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.action = action
            item.isBordered = true
            return item
        }
        switch identifier {
        case Item.zoomOut: return button("Zoom Out", "minus.magnifyingglass", #selector(zoomOut(_:)), "Zoom out to the previous folder")
        case Item.zoomIn: return button("Zoom In", "plus.magnifyingglass", #selector(zoomIn(_:)), "Zoom in on the selected folder")
        case Item.reveal: return button("Reveal", "folder", #selector(revealInFinder(_:)), "Reveal the selected item in the Finder")
        case Item.quickLook: return button("Quick Look", "eye", #selector(toggleQuickLook(_:)), "Preview the selected item")
        case Item.trash: return button("Trash", "trash", #selector(moveToTrash(_:)), "Move the selected item to the Trash")
        case Item.refresh: return button("Refresh", "arrow.clockwise", #selector(refresh(_:)), "Scan the selected folder again, or everything if nothing is selected")
        case Item.list: return button("Selection List", "list.bullet.rectangle", #selector(toggleSelectionList(_:)), "Show or hide the list of files")
        case Item.kinds: return button("Kinds", "chart.pie", #selector(toggleKinds(_:)), "Show or hide the file kind statistics")
        case Item.info: return button("Information", "info.circle", #selector(toggleInformation(_:)), "Show or hide details of the selected item")
        case Item.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Find by Name"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsWholeSearchString = true
            searchItem = item
            return item
        default: return nil
        }
    }
}

// MARK: - Coordinating the views

extension ScanWindowController: TreemapViewDelegate {
    func treemapView(_ view: TreemapView, didHover node: NodeID?) {
        hovered = node
        updateStatus()
    }

    func treemapView(_ view: TreemapView, didSelect node: NodeID?) {
        select(node, from: .treemap)
    }

    /// Goes one level deeper, towards what was clicked.
    func treemapView(_ view: TreemapView, didDoubleClick node: NodeID) {
        guard let tree else { return }
        let ancestry = tree.ancestry(of: node)
        guard let position = ancestry.firstIndex(of: zoomRoot), position + 1 < ancestry.count else { return }
        let next = ancestry[position + 1]
        if tree.isContainer(next, options) { zoomIn(to: next) }
    }

    func treemapViewMenu(_ view: TreemapView) -> NSMenu? {
        makeContextMenu()
    }
}

extension ScanWindowController: FilesOutlineDelegate {
    func filesOutline(didSelect node: NodeID?) {
        select(node, from: .outline)
    }

    func filesOutlineMenu() -> NSMenu? {
        makeContextMenu()
    }

    func filesOutlineDoubleClicked(_ node: NodeID) {
        guard let tree else { return }
        if tree.isContainer(node, options) {
            zoomIn(to: node)
        } else if !tree.isSynthetic(node) {
            openItem(nil)
        }
    }
}

extension ScanWindowController: KindsPanelDelegate {
    func kindsPanel(didSelect kind: KindID?) {
        treemap.highlightedKind = kind
    }

    func kindsPanelShowFiles(of kind: KindID) {
        listKind = kind
        listQuery = ""
        searchItem?.searchField.stringValue = ""
        if let tree { selectionList.setKinds(statistics, table: tree.kindTable, selected: kind) }
        if selectionList.view.isHidden {
            toggleSelectionList(nil)
        } else {
            reloadSelectionList()
        }
    }
}

extension ScanWindowController: SelectionListDelegate {
    func selectionList(didSelect node: NodeID) {
        select(node, from: .list)
    }

    func selectionList(didChooseKind kind: KindID?) {
        listKind = kind
        listQuery = ""
        searchItem?.searchField.stringValue = ""
        reloadSelectionList()
    }

    func selectionListMenu() -> NSMenu? {
        makeContextMenu()
    }
}

// MARK: - Quick Look

extension ScanWindowController: QLPreviewPanelDataSource {
    @objc func toggleQuickLook(_ sender: Any?) {
        guard selectedPath != nil else { return }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let path = MainActor.assumeIsolated { selectedPath }
        return path.map { URL(fileURLWithPath: $0) as NSURL }
    }
}

#if UITEST
// MARK: - Hooks for the interface tests

extension ScanWindowController {
    var uiTreemap: TreemapView? { treemap }
    var uiPathControl: NSPathControl? { pathControl }

    /// What the tests can observe.
    var uiState: [String: String] {
        var state: [String: String] = ["ready": tree != nil && scanner == nil ? "yes" : "no"]
        state["title"] = (window?.title ?? "").replacingOccurrences(of: " ", with: "_")
        guard let tree else { return state }
        state["zoomRoot"] = tree.name(of: zoomRoot).replacingOccurrences(of: " ", with: "_")
        state["selection"] = selection.map { tree.name(of: $0).replacingOccurrences(of: " ", with: "_") } ?? "none"
        state["outlineRows"] = "\(outline.outlineView.numberOfRows)"
        state["outlineSelected"] = "\(outline.outlineView.selectedRow)"
        state["kinds"] = "\(statistics.count)"
        state["tiles"] = "\(treemap.treemapLayout?.tiles.count ?? 0)"
        state["layoutRoot"] = treemap.treemapLayout.map { tree.name(of: $0.root).replacingOccurrences(of: " ", with: "_") } ?? "none"
        state["statusTitle"] = statusTitle.stringValue.replacingOccurrences(of: " ", with: "_")
        state["statusDetail"] = statusDetail.stringValue.replacingOccurrences(of: " ", with: "_")
        state["totals"] = statusTotals.stringValue.replacingOccurrences(of: " ", with: "_")
        state["highlightedKind"] = treemap.highlightedKind.map { "\($0)" } ?? "none"
        state["listHidden"] = selectionList.view.isHidden ? "yes" : "no"
        state["kindsHidden"] = kinds.scrollView.isHidden ? "yes" : "no"
        state["physical"] = options.sizeMode == .physical ? "yes" : "no"
        state["packages"] = options.showPackageContents ? "yes" : "no"
        state["rootSize"] = "\(tree.size(of: tree.root, options.sizeMode))"
        state["layoutSize"] = treemap.treemapLayout.map { "\($0.width)x\($0.height)" } ?? "none"
        state["pixels"] = "\(Int(treemap.bounds.width * 2))x\(Int(treemap.bounds.height * 2))"
        state["zoomOutAvailable"] = zoomHistory.isEmpty ? "no" : "yes"
        state["free"] = options.showFreeSpace ? "yes" : "no"
        state["other"] = options.showOtherSpace ? "yes" : "no"
        state["listRows"] = "\(selectionList.uiRowCount)"
        state["banner"] = banner.isHidden ? "hidden" : "shown"
        state["infoVisible"] = infoPanel?.window?.isVisible == true ? "yes" : "no"
        state["firstRow"] = uiFirstOutlineRow
        state["quickLook"] = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible ? "shown" : "hidden"
        state["active"] = NSApp.isActive ? "yes" : "no"
        state["windowSize"] = window.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none"
        if QLPreviewPanel.sharedPreviewPanelExists() {
            state["quickLookController"] = (QLPreviewPanel.shared().currentController as AnyObject?) === self ? "this-window" : "none"
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), let item = QLPreviewPanel.shared().currentPreviewItem {
            state["quickLookItem"] = item.previewItemURL?.lastPathComponent ?? "none"
        }
        state["splitVertical"] = contentSplit.isVertical ? "yes" : "no"
        return state
    }

    /// Every link Quick Look depends on, short of the panel's own search for its controller, which
    /// only happens in an active app.
    func uiQuickLookWiring(expecting name: String) -> [(String, Bool)] {
        let panel = QLPreviewPanel.shared()!
        var responder: NSResponder? = window?.firstResponder
        var reachesController = false
        while let current = responder, !reachesController {
            reachesController = current === self
            responder = current.nextResponder
        }
        let item = previewPanel(panel, previewItemAt: 0)
        return [
            ("the responder chain reaches this controller", reachesController),
            ("it accepts control of the panel", acceptsPreviewPanelControl(panel)),
            ("it offers one item", numberOfPreviewItems(in: panel) == 1),
            ("that item is the selection", item?.previewItemURL?.lastPathComponent == name),
        ]
    }

    func uiSelect(relativePath: String) {
        guard let tree else { return }
        var current = tree.root
        for component in relativePath.split(separator: "/") {
            guard let next = tree.children(of: current).first(where: { tree.name(of: $0) == component }) else { return }
            current = next
        }
        select(current, from: .program)
    }

    func uiSortOutline(key: String, ascending: Bool) {
        outline.outlineView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
    }

    var uiFirstOutlineRow: String {
        guard let tree, let item = outline.outlineView.item(atRow: 0) as? NodeItem else { return "none" }
        return tree.name(of: item.id).replacingOccurrences(of: " ", with: "_")
    }

    func uiSelectOutlineRow(_ row: Int) {
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func uiSelectKindRow(_ row: Int) {
        if row < 0 {
            kinds.tableView.deselectAll(nil)
        } else {
            kinds.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    func uiSearch(_ text: String) {
        guard let field = searchItem?.searchField else { return }
        field.stringValue = text
        searchChanged(field)
    }
}
#endif
