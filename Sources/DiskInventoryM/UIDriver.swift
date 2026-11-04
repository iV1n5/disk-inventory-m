#if UITEST
import AppKit
import DiskCore

/// Runs the real app from a script, so that the interface can be tested end to end without
/// needing Accessibility or Screen Recording permissions. Only compiled into test builds; see
/// `scripts/ui-test.sh`.
///
/// Mouse input goes through `NSWindow.sendEvent` and menu commands through the menu itself, which
/// means hit testing, validation and the responder chain all take part as they would for a user.
@MainActor
final class UIDriver {
    private let commands: [[String]]
    private let logPath: String
    private var failures = 0
    private var remembered: [String: String] = [:]

    static func startIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard
            let scriptPath = environment["DIM_UI_SCRIPT"],
            let script = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        else { return }
        let driver = UIDriver(script: script, logPath: environment["DIM_UI_LOG"] ?? "/dev/stdout")
        Task { @MainActor in await driver.run() }
    }

    private init(script: String, logPath: String) {
        commands = script.split(separator: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        }.filter { !$0.isEmpty && !$0[0].hasPrefix("#") }
        self.logPath = logPath
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }

    private func log(_ message: String) {
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((message + "\n").utf8))
        try? handle.close()
    }

    private var controller: ScanWindowController? {
        NSApp.windows.compactMap { $0.windowController as? ScanWindowController }.first
    }

    private func run() async {
        // A test that hangs mustn't leave a stray window behind. This runs off the main thread,
        // so it fires even if the hang is there.
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { exit(3) }

        for command in commands {
            log("> " + command.joined(separator: " "))
            await perform(command)
            // Let queued layouts and redraws catch up before the next step.
            try? await Task.sleep(for: .milliseconds(120))
        }
        log("finished, \(failures) failed")
        NSApp.terminate(nil)
    }

    private func check(_ condition: Bool, _ description: String) {
        if !condition { failures += 1 }
        log((condition ? "  ok: " : "  FAILED: ") + description)
    }

    private func perform(_ command: [String]) async {
        let arguments = Array(command.dropFirst())
        let rest = arguments.joined(separator: " ")
        switch command[0] {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(rest) ?? 1))
        case "wait-scan":
            await waitUntil { self.controller?.uiState["ready"] == "yes" }
        case "wait-for":
            let parts = rest.split(separator: "=", maxSplits: 1).map(String.init)
            await waitUntil(timeout: 10) { self.controller?.uiState[parts[0]] == parts[1] }
        case "open":
            (NSApp.delegate as? AppDelegate)?.open(path: rest)
        case "resize":
            if let window = controller?.window, arguments.count == 2,
                let width = Double(arguments[0]), let height = Double(arguments[1]) {
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
            }
        case "menu":
            performMenu(path: rest.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) })
        case "click", "doubleclick", "hover":
            if arguments.count == 2, let x = Double(arguments[0]), let y = Double(arguments[1]) {
                mouse(command[0], x: x, y: y)
            }
        case "expect-quicklook-wiring":
            for (description, result) in controller?.uiQuickLookWiring(expecting: rest) ?? [] {
                check(result, description)
            }
        case "expect-if-active":
            // For what macOS only does in the frontmost app, which a test can't insist on being.
            guard NSApp.isActive else {
                log("  skipped: the app is not in front")
                return
            }
            let parts = rest.split(separator: "=", maxSplits: 1).map(String.init)
            let actual = controller?.uiState[parts[0]] ?? "(none)"
            check(parts.count == 2 && actual == parts[1], "\(parts[0]) is \(actual)")
        case "context-menu":
            // Asks for the menu a right click would show, without showing it.
            if arguments.count == 2, let x = Double(arguments[0]), let y = Double(arguments[1]) { contextMenu(x: x, y: y) }
        case "click-path":
            if let x = Double(rest) { clickPathBar(x: x) }
        case "select":
            controller?.uiSelect(relativePath: rest)
        case "sort":
            if arguments.count == 2 { controller?.uiSortOutline(key: arguments[0], ascending: arguments[1] == "ascending") }
        case "row":
            if let row = Int(rest) { controller?.uiSelectOutlineRow(row) }
        case "kind":
            if let row = Int(rest) { controller?.uiSelectKindRow(row) }
        case "find":
            controller?.uiSearch(rest)
        case "state":
            log("  " + (controller?.uiState.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " | ") ?? "no window"))
        case "expect":
            // expect key=value
            let parts = rest.split(separator: "=", maxSplits: 1).map(String.init)
            let actual = controller?.uiState[parts[0]] ?? "(none)"
            check(parts.count == 2 && actual == parts[1], "\(parts[0]) is \(actual)")
        case "expect-not":
            let parts = rest.split(separator: "=", maxSplits: 1).map(String.init)
            let actual = controller?.uiState[parts[0]] ?? "(none)"
            check(parts.count == 2 && actual != parts[1], "\(parts[0]) is \(actual), not \(parts[1])")
        case "expect-enabled", "expect-disabled":
            let path = rest.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            let wanted = command[0] == "expect-enabled"
            check(isEnabled(path) == wanted, "\(rest) is \(wanted ? "enabled" : "disabled")")
        case "expect-layout-matches":
            let state = controller?.uiState
            check(state?["layoutSize"] == state?["pixels"], "layout \(state?["layoutSize"] ?? "?") fills the view \(state?["pixels"] ?? "?")")
        case "remember":
            remembered[rest] = controller?.uiState[rest]
        case "expect-changed":
            let actual = controller?.uiState[rest]
            check(actual != nil && actual != remembered[rest], "\(rest) went from \(remembered[rest] ?? "?") to \(actual ?? "?")")
        case "expect-same":
            let actual = controller?.uiState[rest]
            check(actual != nil && actual == remembered[rest], "\(rest) stayed \(actual ?? "?")")
        case "run":
            // A change made behind the app's back, for testing refreshes.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", rest]
            try? process.run()
            process.waitUntilExit()
        case "snapshot":
            snapshot(to: rest)
        default:
            log("  unknown command")
            failures += 1
        }
    }

    private func waitUntil(timeout: Double = 60, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(condition(), "condition reached in time")
    }

    // MARK: Input

    private func findItem(_ path: [String]) -> (menu: NSMenu, index: Int)? {
        var menu = NSApp.mainMenu
        for (depth, title) in path.enumerated() {
            guard let current = menu, let item = current.items.first(where: { $0.title == title }) else { return nil }
            if depth == path.count - 1 { return (current, current.index(of: item)) }
            menu = item.submenu
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        }
        return nil
    }

    // Tests run without activating the app, so as not to steal the keyboard from whoever is
    // working on this Mac. An inactive app has no key window, and hence no responder chain to
    // send commands up, so commands are handed to the window controller it would end at.

    private func isEnabled(_ path: [String]) -> Bool {
        guard let found = findItem(path) else { return false }
        let item = found.menu.items[found.index]
        if item.target == nil, let controller { return controller.validateMenuItem(item) }
        return item.isEnabled
    }

    private func performMenu(path: [String]) {
        guard let found = findItem(path) else {
            check(false, "menu item \(path) exists")
            return
        }
        let item = found.menu.items[found.index]
        guard let action = item.action else { return }
        if item.target == nil, let controller {
            check(controller.validateMenuItem(item), "\(item.title) is enabled")
            NSApp.sendAction(action, to: controller, from: item)
        } else {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// x and y are fractions of the treemap's size, from its top left corner.
    private func mouse(_ kind: String, x: Double, y: Double) {
        guard let controller, let window = controller.window, let view = controller.uiTreemap else { return }
        let local = NSPoint(x: view.bounds.width * x, y: view.bounds.height * y)
        let location = view.convert(local, to: nil)
        func send(_ type: NSEvent.EventType, clicks: Int) {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
            )
            if let event { window.sendEvent(event) }
        }
        switch kind {
        case "hover":
            // Tracking areas only fire for real pointer movement, so call the handler directly.
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )
            if let event { view.mouseMoved(with: event) }
        case "doubleclick":
            send(.leftMouseDown, clicks: 1)
            send(.leftMouseUp, clicks: 1)
            send(.leftMouseDown, clicks: 2)
            send(.leftMouseUp, clicks: 2)
        default:
            send(.leftMouseDown, clicks: 1)
            send(.leftMouseUp, clicks: 1)
        }
    }

    private func contextMenu(x: Double, y: Double) {
        guard let controller, let window = controller.window, let view = controller.uiTreemap else { return }
        let location = view.convert(NSPoint(x: view.bounds.width * x, y: view.bounds.height * y), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
        guard let event, let menu = view.menu(for: event) else {
            check(false, "a context menu appears")
            return
        }
        let items = menu.items.filter { !$0.isSeparatorItem }.map { item in
            "\(item.title)[\(controller.validateMenuItem(item) ? "on" : "off")]"
        }
        log("  " + items.joined(separator: " "))
        check(items.count == 8, "the context menu has all its items")
    }

    /// Clicks the path bar at `x` points from its left edge. Path bars track the mouse in a loop
    /// of their own until the button goes up, so the release has to be queued before the press.
    private func clickPathBar(x: Double) {
        guard let controller, let window = controller.window, let bar = controller.uiPathControl else { return }
        let location = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { window.sendEvent(down) }
    }

    // MARK: Pictures

    /// Takes a picture of the window as composited on screen, Metal output included. An app may
    /// always capture its own windows, but this function has left the SDK, hence the lookup.
    private func snapshot(to path: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else {
            check(false, "a window to capture")
            return
        }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            check(false, "capture function available")
            return
        }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        guard let image = capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue() else {
            check(false, "window captured")
            return
        }
        let representation = NSBitmapImageRep(cgImage: image)
        let data = representation.representation(using: .png, properties: [:])
        check(((try? data?.write(to: URL(fileURLWithPath: path))) != nil), "snapshot \(image.width)x\(image.height)")
    }
}
#endif
