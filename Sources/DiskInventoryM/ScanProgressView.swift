import AppKit
import DiskCore

/// Covers the window while a scan runs.
final class ScanProgressView: NSView {
    private let title = NSTextField.label(font: .systemFont(ofSize: 15, weight: .semibold))
    private let counts = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
    private let path = NSTextField.label(color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1

        let stack = NSStackView(views: [title, counts, bar, path, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: path)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.6),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    func begin(path: String) {
        title.stringValue = "Scanning \((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)"
        counts.stringValue = " "
        self.path.stringValue = path
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    /// `expectedBytes` is known only for whole volumes, where it gives a real progress bar.
    func update(_ progress: DiskScanner.Progress, expectedBytes: UInt64?) {
        counts.stringValue = "\(Format.items(progress.files, "file", "files")) · \(Format.bytes(progress.bytes))"
        if !progress.currentPath.isEmpty { path.stringValue = progress.currentPath }
        if let expectedBytes, expectedBytes > 0 {
            bar.isIndeterminate = false
            bar.doubleValue = min(Double(progress.bytes) / Double(expectedBytes), 0.99)
        }
    }

    func end() {
        bar.stopAnimation(nil)
    }

    // Keep clicks from reaching whatever is underneath.
    override func mouseDown(with event: NSEvent) {}
}
