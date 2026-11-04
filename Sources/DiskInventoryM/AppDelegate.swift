import AppKit
import DiskCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var scanWindows: [ScanWindowController] = []
    private var volumesWindow: VolumesWindowController?
    private var preferencesWindow: PreferencesWindowController?
    private let recentMenu = NSMenu(title: "Open Recent")
    private let zoomOutMenu = NSMenu(title: "Zoom Out To")
    private var openedSomething = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Preferences.register()
        NSApp.mainMenu = makeMainMenu()
        // Get the shader compiled while the user chooses what to scan.
        DispatchQueue.global(qos: .userInitiated).async { _ = Graphics.renderer }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !openedSomething { showVolumesWindow(nil) }
        #if UITEST
        UIDriver.startIfRequested()
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedSomething = true
        for url in urls { open(path: url.path) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showVolumesWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Opening things

    func open(path: String) {
        // A folder that is already open just comes to the front.
        if let existing = scanWindows.first(where: { $0.requestedPath == path }) {
            existing.showWindow(nil)
            return
        }
        noteRecent(path)
        let controller = ScanWindowController(path: path)
        controller.onClose = { [weak self, weak controller] in
            self?.scanWindows.removeAll { $0 === controller }
        }
        // The first window remembers its place. Further ones step down from the one before.
        if let last = scanWindows.last?.window {
            controller.window?.setFrame(last.frame, display: false)
            let corner = NSPoint(x: last.frame.minX, y: last.frame.maxY)
            _ = controller.window?.cascadeTopLeft(from: corner)
        } else {
            controller.windowFrameAutosaveName = "ScanWindow"
        }
        scanWindows.append(controller)
        controller.showWindow(nil)
        controller.startScan()
        volumesWindow?.close()
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to look at."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.open(path: url.path) }
        }
    }

    @objc func showVolumesWindow(_ sender: Any?) {
        if volumesWindow == nil {
            let controller = VolumesWindowController()
            controller.onOpen = { [weak self] path in self?.open(path: path) }
            controller.onChooseFolder = { [weak self] in self?.openFolder(nil) }
            volumesWindow = controller
        }
        volumesWindow?.reload()
        volumesWindow?.showWindow(nil)
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil { preferencesWindow = PreferencesWindowController() }
        preferencesWindow?.showWindow(nil)
    }

    /// Colours apply at once, to every window: they are a matter of taste rather than of what a
    /// particular scan is for.
    @objc func chooseMapColors(_ sender: NSMenuItem) {
        guard let scheme = sender.representedObject as? String else { return }
        UserDefaults.standard.set(scheme, forKey: Preferences.mapColors)
        for window in scanWindows { window.mapColorsChanged() }
    }

    @objc func openFullDiskAccessSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Recent folders

    private func noteRecent(_ path: String) {
        var recent = UserDefaults.standard.stringArray(forKey: Preferences.recentFolders) ?? []
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(10)), forKey: Preferences.recentFolders)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { open(path: path) }
    }

    @objc private func clearRecent(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: Preferences.recentFolders)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === recentMenu {
            let recent = UserDefaults.standard.stringArray(forKey: Preferences.recentFolders) ?? []
            for path in recent {
                let item = menu.addItem(withTitle: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
            }
            if !recent.isEmpty { menu.addItem(.separator()) }
            let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            clear.isEnabled = !recent.isEmpty
        } else if menu === zoomOutMenu {
            let controller = NSApp.mainWindow?.windowController as? ScanWindowController
            (controller ?? scanWindows.last)?.populateZoomOutMenu(menu)
        }
    }

    // MARK: Main menu

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "Disk Inventory M"))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        let window = windowMenu()
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About Disk Inventory M", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showPreferences(_:)), ",", target: self))
        menu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Disk Inventory M", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Disk Inventory M", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        typealias Scan = ScanWindowController
        let menu = NSMenu()
        menu.addItem(item("Open Folder…", #selector(openFolder(_:)), "o", target: self))
        menu.addItem(item("Open Volume…", #selector(showVolumesWindow(_:)), "o", [.command, .shift], target: self))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        recentMenu.delegate = self
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        menu.addItem(item("Open", #selector(Scan.openItem(_:)), downArrow))
        menu.addItem(item("Reveal in Finder", #selector(Scan.revealInFinder(_:)), "F", [.command, .shift]))
        menu.addItem(item("Quick Look", #selector(Scan.toggleQuickLook(_:)), "y"))
        menu.addItem(item("Move to Trash", #selector(Scan.moveToTrash(_:)), "\u{8}"))
        menu.addItem(.separator())
        menu.addItem(item("Refresh All", #selector(Scan.refreshAll(_:)), "r"))
        menu.addItem(item("Refresh Selection", #selector(Scan.refreshSelection(_:)), "r", [.command, .shift]))
        return menu
    }

    private func editMenu() -> NSMenu {
        typealias Scan = ScanWindowController
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "Z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", #selector(Scan.focusSearch(_:)), "f"))
        menu.addItem(item("Select Parent Folder", #selector(Scan.selectParentFolder(_:)), "u"))
        menu.addItem(item("Scroll to Selection", #selector(Scan.scrollToSelection(_:)), "j"))
        return menu
    }

    private func viewMenu() -> NSMenu {
        typealias Scan = ScanWindowController
        let menu = NSMenu()
        menu.addItem(item("Zoom In", #selector(Scan.zoomIn(_:)), "+"))
        // The same without Shift, for keyboards where "+" shares a key with "=".
        let zoomInAlternative = item("Zoom In", #selector(Scan.zoomIn(_:)), "=")
        zoomInAlternative.isHidden = true
        zoomInAlternative.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInAlternative)
        menu.addItem(item("Zoom Out", #selector(Scan.zoomOut(_:)), "-"))
        let zoomOutTo = NSMenuItem(title: "Zoom Out To", action: nil, keyEquivalent: "")
        zoomOutTo.submenu = zoomOutMenu
        zoomOutMenu.delegate = self
        menu.addItem(zoomOutTo)
        menu.addItem(.separator())
        menu.addItem(item("Show Package Contents", #selector(Scan.togglePackageContents(_:))))
        menu.addItem(item("Show Free Space", #selector(Scan.toggleFreeSpace(_:))))
        menu.addItem(item("Show Other Space", #selector(Scan.toggleOtherSpace(_:))))
        menu.addItem(item("Show Physical File Size", #selector(Scan.toggleSizeMode(_:))))
        menu.addItem(mapColorsItem())
        menu.addItem(.separator())
        menu.addItem(item("Split Horizontally", #selector(Scan.toggleSplitDirection(_:))))
        menu.addItem(item("File Kind Statistics", #selector(Scan.toggleKinds(_:)), "k", [.command, .option]))
        menu.addItem(item("Selection List", #selector(Scan.toggleSelectionList(_:)), "l", [.command, .option]))
        menu.addItem(item("Information", #selector(Scan.toggleInformation(_:)), "i"))
        menu.addItem(.separator())
        menu.addItem(item("Show Toolbar", #selector(Scan.toggleToolbar(_:)), "t", [.command, .option]))
        menu.addItem(item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private func mapColorsItem() -> NSMenuItem {
        let choices = NSMenu()
        for (title, scheme) in [("System", MapColors.system), ("Families", MapColors.families)] {
            let choice = item(title, #selector(chooseMapColors(_:)), target: self)
            choice.representedObject = scheme.rawValue
            choices.addItem(choice)
        }
        let parent = NSMenuItem(title: "Map Colors", action: nil, keyEquivalent: "")
        parent.submenu = choices
        return parent
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Grant Full Disk Access…", #selector(openFullDiskAccessSettings(_:)), target: self))
        return menu
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseMapColors(_:)) {
            item.state = item.representedObject as? String == Preferences.currentMapColors.rawValue ? .on : .off
        }
        return true
    }
}
