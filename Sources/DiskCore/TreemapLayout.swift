/// One rectangle to draw. The layout matches the `Tile` struct in the Metal shader.
public struct TreemapTile: Sendable {
    /// Left, top, right and bottom edges, in whole pixels.
    public var rect: SIMD4<Float>
    /// The cushion surface over this rectangle, as `s1x, s2x, s1y, s2y` in the terms of van Wijk
    /// and van de Wetering, relative to the top left corner so that float precision suffices.
    public var cushion: SIMD4<Float>
    public var kind: UInt32
    var padding: UInt32 = 0
}

/// How pronounced the cushions look. See "Cushion Treemaps" (van Wijk, van de Wetering, 1999).
public struct CushionParameters: Sendable {
    /// The ridge height of the outermost level.
    public var height = 0.34
    /// How much lower each deeper level's ridge is.
    public var falloff = 0.90

    public init() {}
}

/// A position in the laid-out hierarchy. Unlike tiles these exist for folders too, which is what
/// hit testing and selection outlines work with.
struct TreemapEntry {
    var x0: Int32
    var y0: Int32
    var x1: Int32
    var y1: Int32
    var node: NodeID
    var firstChild: Int32 = -1
    var childCount: Int32 = 0
    /// True for an entry standing in for a folder's many children too small to draw.
    var isRemainder = false
}

/// A pixel rectangle with its origin at the top left.
public struct PixelRect: Sendable, Equatable {
    public let x0: Int
    public let y0: Int
    public let x1: Int
    public let y1: Int

    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }

    public init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

/// A squarified treemap (Bruls, Huizing, van Wijk, 2000) of part of a `FileTree`.
///
/// Items below about a pixel are merged into one remainder per folder, so the cost depends on
/// what can actually be seen, not on how many files there are.
public final class TreemapLayout: @unchecked Sendable {
    public let tree: FileTree
    public let root: NodeID
    public let options: DisplayOptions
    public let width: Int
    public let height: Int
    public let tiles: [TreemapTile]
    let entries: [TreemapEntry]

    public init(
        tree: FileTree,
        root: NodeID,
        options: DisplayOptions,
        width: Int,
        height: Int,
        cushion: CushionParameters = CushionParameters()
    ) {
        self.tree = tree
        self.root = root
        self.options = options
        self.width = width
        self.height = height

        var builder = Builder(tree: tree, options: options, root: root, cushion: cushion)
        builder.run(width: width, height: height)
        tiles = builder.tiles
        entries = builder.entries
    }

    /// The most specific node drawn at a pixel, or nil outside the map.
    public func node(atX x: Int, y: Int) -> NodeID? {
        hit(x: x, y: y)?.node
    }

    /// The most specific thing drawn at a pixel, along with where exactly it is drawn.
    public func hit(x: Int, y: Int) -> (node: NodeID, rect: PixelRect)? {
        guard !entries.isEmpty, x >= 0, y >= 0, x < width, y < height else { return nil }
        var index = 0
        while true {
            let entry = entries[index]
            let first = Int(entry.firstChild)
            let next = entry.childCount == 0 ? nil : (first..<(first + Int(entry.childCount))).first { child in
                let e = entries[child]
                return x >= e.x0 && x < e.x1 && y >= e.y0 && y < e.y1
            }
            guard let next else {
                let rect = PixelRect(x0: Int(entry.x0), y0: Int(entry.y0), x1: Int(entry.x1), y1: Int(entry.y1))
                return (entry.node, rect)
            }
            index = next
        }
    }

    /// Where a node is drawn. A node too small to appear yields its nearest visible ancestor.
    public func rect(of node: NodeID) -> (node: NodeID, rect: PixelRect)? {
        var current = node
        while current != FileTree.noNode {
            if let entry = entries.first(where: { $0.node == current }) {
                let rect = PixelRect(
                    x0: Int(entry.x0), y0: Int(entry.y0), x1: Int(entry.x1), y1: Int(entry.y1)
                )
                return (current, rect)
            }
            if current == root { return nil }
            current = tree.node(current).parent
        }
        return nil
    }
}

private struct Surface {
    var s1x = 0.0
    var s2x = 0.0
    var s1y = 0.0
    var s2y = 0.0
}

private struct Builder {
    let tree: FileTree
    let nodes: UnsafeMutablePointer<Node>
    let options: DisplayOptions
    let mode: SizeMode
    let root: NodeID
    let cushion: CushionParameters
    var tiles: [TreemapTile] = []
    var entries: [TreemapEntry] = []

    /// Below this area in pixels, an item is not worth a rectangle of its own.
    static let smallestArea = 1.0

    init(tree: FileTree, options: DisplayOptions, root: NodeID, cushion: CushionParameters) {
        self.tree = tree
        self.nodes = tree.nodes
        self.options = options
        self.mode = options.sizeMode
        self.root = root
        self.cushion = cushion
    }

    mutating func run(width: Int, height: Int) {
        guard width > 0, height > 0, tree.displaySize(of: root, options) > 0 else { return }
        entries.append(
            TreemapEntry(x0: 0, y0: 0, x1: Int32(width), y1: Int32(height), node: root)
        )
        layOut(entry: 0, surface: Surface(), ridge: cushion.height, isTop: true)
    }

    private mutating func layOut(entry index: Int, surface: Surface, ridge: Double, isTop: Bool) {
        let entry = entries[index]
        var surface = surface
        Self.addRidge(&surface.s1x, &surface.s2x, Double(entry.x0), Double(entry.x1), ridge)
        Self.addRidge(&surface.s1y, &surface.s2y, Double(entry.y0), Double(entry.y1), ridge)

        let area = Double(entry.x1 - entry.x0) * Double(entry.y1 - entry.y0)
        let hasExtras = isTop && root == tree.root && !tree.extras(options).isEmpty
        let isContainer = (tree.isContainer(entry.node, options) || hasExtras) && !entry.isRemainder
        guard isContainer, area >= 2 else {
            addTile(for: entry, surface: surface)
            return
        }

        let first = entries.count
        if isTop, root == tree.root {
            let children = tree.displayChildren(of: root, options)
            let total = Double(tree.displaySize(of: root, options))
            children.withUnsafeBufferPointer {
                squarify($0, total: total, parent: entry)
            }
        } else {
            squarify(tree.children(of: entry.node), total: Double(tree.size(of: entry.node, mode)), parent: entry)
        }
        let last = entries.count
        guard last > first else {
            addTile(for: entry, surface: surface)
            return
        }
        entries[index].firstChild = Int32(first)
        entries[index].childCount = Int32(last - first)

        let childRidge = ridge * cushion.falloff
        for child in first..<last {
            layOut(entry: child, surface: surface, ridge: childRidge, isTop: false)
        }
    }

    /// Divides the parent's rectangle among `children`, which are sorted largest first.
    private mutating func squarify(_ children: UnsafeBufferPointer<NodeID>, total: Double, parent: TreemapEntry) {
        var left = Double(parent.x0)
        var top = Double(parent.y0)
        let right = Double(parent.x1)
        let bottom = Double(parent.y1)
        var remaining = total
        var index = 0
        let count = children.count

        while index < count, remaining > 0 {
            let width = right - left
            let height = bottom - top
            guard width >= 1, height >= 1 else { break }

            let scale = width * height / remaining
            let largest = Double(displaySize(children[index])) * scale
            guard largest > 0 else { break }
            guard largest >= Self.smallestArea else { break }

            // Grow the row for as long as that improves its worst aspect ratio.
            let side = min(width, height)
            let sideSquared = side * side
            var rowArea = 0.0
            var worst = Double.infinity
            var end = index
            while end < count {
                let area = Double(displaySize(children[end])) * scale
                guard area > 0 else { break }
                let grown = rowArea + area
                let grownSquared = grown * grown
                let ratio = max(sideSquared * largest / grownSquared, grownSquared / (sideSquared * area))
                if ratio > worst { break }
                worst = ratio
                rowArea = grown
                end += 1
            }

            let isLastRow = end == count || displaySize(children[end]) == 0
            let thickness = rowArea / side
            if width >= height {
                // A column down the left side.
                let columnRight = isLastRow ? right : min(right, left + thickness)
                var y = top
                for position in index..<end {
                    let length = Double(displaySize(children[position])) * scale / thickness
                    let yEnd = position == end - 1 ? bottom : min(bottom, y + length)
                    addEntry(children[position], left: left, top: y, right: columnRight, bottom: yEnd)
                    y = yEnd
                }
                left = columnRight
            } else {
                // A row along the top.
                let rowBottom = isLastRow ? bottom : min(bottom, top + thickness)
                var x = left
                for position in index..<end {
                    let length = Double(displaySize(children[position])) * scale / thickness
                    let xEnd = position == end - 1 ? right : min(right, x + length)
                    addEntry(children[position], left: x, top: top, right: xEnd, bottom: rowBottom)
                    x = xEnd
                }
                top = rowBottom
            }
            remaining -= rowArea / scale
            index = end
        }
        // Whatever is left, if any of it survives rounding to whole pixels, is drawn as one piece.
        addRemainder(left: left, top: top, right: right, bottom: bottom, of: parent.node)
    }

    @inline(__always)
    private func displaySize(_ id: NodeID) -> UInt64 {
        nodes[Int(id)].size(mode)
    }

    private mutating func addEntry(_ node: NodeID, left: Double, top: Double, right: Double, bottom: Double) {
        let x0 = Int32(left.rounded())
        let y0 = Int32(top.rounded())
        let x1 = Int32(right.rounded())
        let y1 = Int32(bottom.rounded())
        guard x1 > x0, y1 > y0 else { return }
        entries.append(TreemapEntry(x0: x0, y0: y0, x1: x1, y1: y1, node: node))
    }

    private mutating func addRemainder(left: Double, top: Double, right: Double, bottom: Double, of node: NodeID) {
        let x0 = Int32(left.rounded())
        let y0 = Int32(top.rounded())
        let x1 = Int32(right.rounded())
        let y1 = Int32(bottom.rounded())
        guard x1 > x0, y1 > y0 else { return }
        var entry = TreemapEntry(x0: x0, y0: y0, x1: x1, y1: y1, node: node)
        entry.isRemainder = true
        entries.append(entry)
    }

    private mutating func addTile(for entry: TreemapEntry, surface: Surface) {
        let x0 = Double(entry.x0)
        let y0 = Double(entry.y0)
        let rect = SIMD4<Float>(Float(entry.x0), Float(entry.y0), Float(entry.x1), Float(entry.y1))
        // Move the polynomial's origin to the tile's corner: s(x + x0) has the same second-order
        // term, and a first-order term of s1 + 2 * s2 * x0.
        let local = SIMD4<Float>(
            Float(surface.s1x + 2 * surface.s2x * x0),
            Float(surface.s2x),
            Float(surface.s1y + 2 * surface.s2y * y0),
            Float(surface.s2y)
        )
        tiles.append(TreemapTile(rect: rect, cushion: local, kind: UInt32(dominantKind(of: entry.node))))
    }

    /// The colour of a folder too small to show its contents: that of its largest file.
    private func dominantKind(of id: NodeID) -> KindID {
        var current = id
        while tree.isContainer(current, options) {
            let children = tree.children(of: current)
            guard let first = children.first, nodes[Int(first)].size(mode) > 0 else { break }
            current = first
        }
        return tree.kind(of: current)
    }

    /// Adds a parabolic ridge over `lo...hi` to the surface. The slope at the edges depends only
    /// on `height`, so that all rectangles look alike whatever their size.
    @inline(__always)
    private static func addRidge(_ s1: inout Double, _ s2: inout Double, _ lo: Double, _ hi: Double, _ height: Double) {
        let factor = 4 * height / (hi - lo)
        s1 += factor * (hi + lo)
        s2 -= factor
    }
}
