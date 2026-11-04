import CoreGraphics
import DiskCore
import Foundation
import ImageIO
import TreemapMetal
import UniformTypeIdentifiers

/// Headless companion to the app: `dim scan <path>`.
func formatBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
}

func runScan(_ arguments: [String]) throws {
    var path: String?
    var options = DiskScanner.Options()
    var top = 8
    var dump = false
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--exclude": if let value = iterator.next() { options.excludedPaths.append(value) }
        case "--threads": if let value = iterator.next(), let n = Int(value) { options.threadCount = n }
        case "--top": if let value = iterator.next(), let n = Int(value) { top = n }
        case "--dump": dump = true
        default: path = argument
        }
    }
    guard let path else { throw ScanError.cannotOpen(path: "(none)", code: EINVAL) }

    let start = Date()
    let tree = try DiskScanner(path: path, options: options).run()
    let elapsed = Date().timeIntervalSince(start)
    if dump {
        var pending = [tree.root]
        while let id = pending.popLast() {
            print(tree.path(of: id))
            pending.append(contentsOf: tree.children(of: id))
        }
        return
    }
    let rootNode = tree.node(tree.root)
    print("path        \(tree.rootPath)")
    print("nodes       \(tree.nodeCount)  files \(rootNode.fileCount)  directories \(tree.directoryCount)")
    print("physical    \(rootNode.physicalSize) bytes (\(formatBytes(rootNode.physicalSize)))")
    print("logical     \(rootNode.logicalSize) bytes (\(formatBytes(rootNode.logicalSize)))")
    print("unreadable  \(tree.unreadableCount)")
    print(String(format: "time        %.3f s  (%.0f entries/s)", elapsed, Double(tree.nodeCount) / elapsed))
    print("kinds       \(tree.kindTable.kinds.count)")
    for child in tree.children(of: tree.root).prefix(top) {
        print("  \(formatBytes(tree.size(of: child, .physical)).padding(toLength: 10, withPad: " ", startingAt: 0)) \(tree.name(of: child))")
    }
}

/// `dim render <path> <out.png>`: renders the treemap, timing each stage.
func runRender(_ arguments: [String]) throws {
    var positional: [String] = []
    var width = 1600, height = 1000
    var showPackages = false, showSpace = false, logical = false
    var scanOptions = DiskScanner.Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--exclude": if let value = iterator.next() { scanOptions.excludedPaths.append(value) }
        case "--width": if let value = iterator.next(), let n = Int(value) { width = n }
        case "--height": if let value = iterator.next(), let n = Int(value) { height = n }
        case "--packages": showPackages = true
        case "--space": showSpace = true
        case "--logical": logical = true
        default: positional.append(argument)
        }
    }
    guard positional.count == 2 else { throw ScanError.cannotOpen(path: "(need <path> <out.png>)", code: EINVAL) }

    var options = DisplayOptions()
    options.showPackageContents = showPackages
    options.showFreeSpace = showSpace
    options.showOtherSpace = showSpace
    options.sizeMode = logical ? .logical : .physical

    let clock = ContinuousClock()
    var tree: FileTree!
    let scan = try clock.measure { tree = try DiskScanner(path: positional[0], options: scanOptions).run() }
    tree.sortChildren(by: options.sizeMode)
    var statistics: [KindStatistic] = []
    let stats = clock.measure { statistics = tree.kindStatistics(options) }
    var cushion = CushionParameters()
    let renderer = try TreemapRenderer()
    // For tuning the look: DIM_SHADE="height falloff ambient diffuse gain spill".
    if let tuning = ProcessInfo.processInfo.environment["DIM_SHADE"] {
        let values = tuning.split(separator: " ").compactMap { Double($0) }
        if values.count == 6 {
            cushion.height = values[0]
            cushion.falloff = values[1]
            renderer.shading.ambient = Float(values[2])
            renderer.shading.diffuse = Float(values[3])
            renderer.shading.gain = Float(values[4])
            renderer.shading.spill = Float(values[5])
        }
    }
    var layout: TreemapLayout!
    let lay = clock.measure {
        layout = TreemapLayout(tree: tree, root: tree.root, options: options, width: width, height: height, cushion: cushion)
    }
    let colors = KindPalette.colors(for: statistics, table: tree.kindTable)
    var image: CGImage!
    _ = try renderer.makeImage(layout, colors: colors)  // Warm up, so the next one measures drawing.
    let draw = try clock.measure { image = try renderer.makeImage(layout, colors: colors) }

    let url = URL(fileURLWithPath: positional[1]) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw ScanError.cannotOpen(path: positional[1], code: EIO)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("scan \(scan)  statistics \(stats)  layout \(lay)  draw+readback \(draw)")
    print("nodes \(tree.nodeCount)  tiles \(layout.tiles.count)  kinds \(statistics.count)")
    for statistic in statistics.prefix(13) {
        print("  \(formatBytes(statistic.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(statistic.files) \(tree.kindTable.kinds[Int(statistic.kind)].name)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "scan": try runScan(Array(arguments.dropFirst()))
    case "render": try runRender(Array(arguments.dropFirst()))
    case "icon": try runIcon(Array(arguments.dropFirst()))
    default:
        print("usage: dim scan <path> [--exclude <path>] [--threads <n>] [--top <n>] [--dump]")
        print("       dim icon <out.iconset>")
        print("       dim render <path> <out.png> [--exclude <path>] [--width <n>] [--height <n>] [--packages] [--space] [--logical]")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
