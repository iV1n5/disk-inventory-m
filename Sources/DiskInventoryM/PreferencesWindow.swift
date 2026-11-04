import AppKit

/// Settings for new windows.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private static let options: [(title: String, key: String)] = [
        ("Show package contents", Preferences.showPackageContents),
        ("Show physical file size", Preferences.showPhysicalSize),
        ("Show free space (whole volumes)", Preferences.showFreeSpace),
        ("Show other space (whole volumes)", Preferences.showOtherSpace),
        ("Split window horizontally", Preferences.splitHorizontally),
        ("Animate zooming", Preferences.animatedZooming),
    ]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: true
        )
        window.title = "Settings"
        super.init(window: window)

        let caption = NSTextField.label(color: .secondaryLabelColor)
        caption.stringValue = "View settings for new windows:"
        var views: [NSView] = [caption]
        for option in Self.options {
            let box = NSButton(checkboxWithTitle: option.title, target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(option.key)
            box.state = UserDefaults.standard.bool(forKey: option.key) ? .on : .off
            views.append(box)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        ])
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }
}
