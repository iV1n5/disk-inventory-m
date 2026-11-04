import AppKit
import DiskCore
import TreemapMetal
import UniformTypeIdentifiers

/// The shared GPU renderer. Compiling the shader takes a moment, so the app starts this off in
/// the background at launch; whoever needs it first simply waits for that to finish.
enum Graphics {
    static let renderer: TreemapRenderer? = try? TreemapRenderer()
}

/// What occupies the place to the right of the map.
enum SidePanel: String {
    case none, kinds, cleanup
}

/// The catalogue of what can usually be cleaned up, which ships with the app.
enum Cleanup {
    static let rules: [CleanupRule] = {
        guard
            let url = Bundle.main.url(forResource: "CleanupRules", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let rules = try? CleanupRule.load(from: data)
        else { return [] }
        return rules
    }()

    #if UITEST
    /// So that tests can stay away from the real home folder.
    @MainActor static var homeForTests: String?
    #endif

    @MainActor static var context: CleanupContext {
        #if UITEST
        if let homeForTests { return CleanupContext(home: homeForTests) }
        #endif
        return CleanupContext()
    }
}

/// Settings that apply to newly opened windows.
enum Preferences {
    static let showPackageContents = "ShowPackageContents"
    static let showPhysicalSize = "ShowPhysicalFileSize"
    static let showFreeSpace = "ShowFreeSpace"
    static let showOtherSpace = "ShowOtherSpace"
    static let sidePanel = "SidePanel"
    static let showToolbar = "ShowToolbar"
    static let mapColors = "MapColors"
    static let animatedZooming = "AnimatedZooming"
    static let splitHorizontally = "SplitWindowHorizontally"
    static let recentFolders = "RecentFolders"
    static let listWidth = "ListWidth"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showPackageContents: false,
            showPhysicalSize: true,
            showFreeSpace: false,
            showOtherSpace: false,
            sidePanel: SidePanel.none.rawValue,
            showToolbar: false,
            mapColors: MapColors.system.rawValue,
            animatedZooming: true,
            splitHorizontally: false,
        ])
    }

    static var currentSidePanel: SidePanel {
        SidePanel(rawValue: UserDefaults.standard.string(forKey: sidePanel) ?? "") ?? .none
    }

    static var currentMapColors: MapColors {
        MapColors(rawValue: UserDefaults.standard.string(forKey: mapColors) ?? "") ?? .system
    }

    /// Free and other space only make sense for whole volumes: next to a whole disk, a folder
    /// would shrink to a speck.
    static func displayOptions(forVolume isVolume: Bool) -> DisplayOptions {
        let defaults = UserDefaults.standard
        var options = DisplayOptions()
        options.showPackageContents = defaults.bool(forKey: showPackageContents)
        options.sizeMode = defaults.bool(forKey: showPhysicalSize) ? .physical : .logical
        options.showFreeSpace = isVolume && defaults.bool(forKey: showFreeSpace)
        options.showOtherSpace = isVolume && defaults.bool(forKey: showOtherSpace)
        return options
    }
}

@MainActor
enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func count(_ value: UInt64) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func items(_ value: UInt64, _ singular: String, _ plural: String) -> String {
        "\(count(value)) \(value == 1 ? singular : plural)"
    }

    static func date(secondsSince1970 seconds: UInt32) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// Finder icons, cached because looking one up is slow compared to drawing a table row.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byExtension: [String: NSImage] = [:]
    private var byPackagePath: [String: NSImage] = [:]
    private lazy var folder = sized(NSWorkspace.shared.icon(for: .folder))
    private lazy var document = sized(NSWorkspace.shared.icon(for: .data))

    private func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    func icon(for id: NodeID, in tree: FileTree) -> NSImage {
        let node = tree.node(id)
        if node.flags.contains(.synthetic) {
            let name = id == tree.freeSpaceNode ? "circle.dashed" : "questionmark.folder"
            return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? document
        }
        if node.flags.contains(.package) {
            // Every application has its own icon, so these go by path.
            let path = tree.path(of: id)
            if let cached = byPackagePath[path] { return cached }
            let image = sized(NSWorkspace.shared.icon(forFile: path))
            byPackagePath[path] = image
            return image
        }
        if node.isDirectory { return folder }

        let name = tree.name(of: id)
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return document }
        if let cached = byExtension[pathExtension] { return cached }
        let image: NSImage
        if let type = UTType(filenameExtension: pathExtension) {
            image = sized(NSWorkspace.shared.icon(for: type))
        } else {
            image = document
        }
        byExtension[pathExtension] = image
        return image
    }
}

/// Keeps all of a table's columns in view by giving one of them whatever room the others leave.
/// NSTableView can do something like this itself, but only if the table starts out exactly as wide
/// as its scroll view.
@MainActor
final class ColumnFitter: NSObject {
    private weak var table: NSTableView?
    private weak var flexible: NSTableColumn?
    private weak var scrollView: NSScrollView?
    private var isFitting = false

    init(table: NSTableView, flexible: NSTableColumn, in scrollView: NSScrollView) {
        self.table = table
        self.flexible = flexible
        self.scrollView = scrollView
        super.init()
        table.columnAutoresizingStyle = .noColumnAutoresizing
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(fit), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(fit), name: NSTableView.columnDidResizeNotification, object: table)
    }

    @objc func fit() {
        guard !isFitting, let table, let flexible, let scrollView else { return }
        isFitting = true
        defer { isFitting = false }
        let others = table.tableColumns.filter { $0 !== flexible && !$0.isHidden }
        let spacing = table.intercellSpacing.width * CGFloat(others.count + 1)
        let taken = others.reduce(CGFloat(0)) { $0 + $1.width } + spacing
        flexible.width = max(flexible.minWidth, scrollView.contentView.bounds.width - taken)
    }
}

extension NSColor {
    convenience init(kindColor color: SIMD4<Float>) {
        self.init(
            srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1
        )
    }
}

extension NSTextField {
    static func label(font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize), color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        // Anything stronger than the window's own wish to keep its size would let a long file
        // name stretch the whole window.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}
