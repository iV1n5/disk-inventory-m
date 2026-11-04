import Foundation

/// How a tree is being looked at. These settings change what is shown, never what was scanned.
public struct DisplayOptions: Sendable, Equatable {
    public var sizeMode: SizeMode = .physical
    /// Treat packages such as `.app` bundles as folders rather than as single files.
    public var showPackageContents = false
    public var showFreeSpace = false
    public var showOtherSpace = false

    public init() {}
}

/// A problem met during a scan.
public struct ScanIssue: Sendable {
    public let path: String
    public let code: Int32

    /// macOS refused access, as opposed to ordinary Unix permissions saying no. Full Disk Access
    /// fixes this kind.
    public var isPrivacyRestriction: Bool { code == EPERM }
}

/// Everything known about a scanned folder.
///
/// Nodes live in flat arenas and refer to each other by index. That keeps a scan of millions of
/// files compact and free of reference counting, and it keeps `NodeID`s valid forever, which the
/// outline and the treemap both rely on. Each directory owns a slice of the child arena, sorted
/// largest first, so removing or re-sorting children never moves a node.
///
/// Threading: a finished tree may be read from any thread. Changes (`remove`, `commitRefresh`,
/// `sortChildren`) need the caller to keep readers out, which the app does by running them on the
/// same serial queue that computes treemap layouts.
public final class FileTree: @unchecked Sendable {
    public static let noNode = NodeID.max

    private static let maximumNodes = 1 << 30
    private static let maximumNameBytes = 1 << 36

    public let rootPath: String
    public let root: NodeID = 0

    let nodeArena: Arena<Node>
    let childArena: Arena<NodeID>
    let nameArena: Arena<UInt8>
    let extensions = ExtensionRegistry()

    @inline(__always) var nodes: UnsafeMutablePointer<Node> { nodeArena.base }
    @inline(__always) var childSlots: UnsafeMutablePointer<NodeID> { childArena.base }

    public private(set) var kindTable = KindTable()
    public private(set) var sortMode = SizeMode.physical
    public private(set) var volume: VolumeInfo?
    public private(set) var freeSpaceNode = noNode
    public private(set) var otherSpaceNode = noNode

    public internal(set) var directoryCount: UInt64 = 0
    public internal(set) var unreadableCount = 0
    /// A sample of what went wrong, limited in length.
    public internal(set) var issues: [ScanIssue] = []

    /// Whether the scan covered a whole volume rather than a folder on it.
    public var isVolumeRoot: Bool { volume?.mountPath == rootPath }

    init?(rootPath: String) {
        guard
            let nodeArena = Arena<Node>(capacity: Self.maximumNodes),
            let childArena = Arena<NodeID>(capacity: Self.maximumNodes),
            let nameArena = Arena<UInt8>(capacity: Self.maximumNameBytes)
        else { return nil }
        self.rootPath = rootPath
        self.nodeArena = nodeArena
        self.childArena = childArena
        self.nameArena = nameArena
    }

    // MARK: Reading

    public var nodeCount: Int { nodeArena.count }

    @inline(__always)
    public func node(_ id: NodeID) -> Node {
        nodes[Int(id)]
    }

    @inline(__always)
    public func size(of id: NodeID, _ mode: SizeMode) -> UInt64 {
        nodes[Int(id)].size(mode)
    }

    @inline(__always)
    public func children(of id: NodeID) -> UnsafeBufferPointer<NodeID> {
        let node = nodes[Int(id)]
        return UnsafeBufferPointer(start: childSlots + Int(node.firstChild), count: Int(node.childCount))
    }

    public func name(of id: NodeID) -> String {
        String(decoding: nameBytes(of: id), as: UTF8.self)
    }

    @inline(__always)
    func nameBytes(of id: NodeID) -> UnsafeBufferPointer<UInt8> {
        let reference = nodes[Int(id)].nameRef
        let offset = Int(reference >> Node.nameLengthBits)
        let length = Int(reference & ((1 << Node.nameLengthBits) - 1))
        return UnsafeBufferPointer(start: nameArena.base + offset, count: length)
    }

    public func path(of id: NodeID) -> String {
        if id == root { return rootPath }
        var components: [NodeID] = []
        var current = id
        while current != root, current != Self.noNode {
            components.append(current)
            current = nodes[Int(current)].parent
        }
        var bytes = Array(rootPath.utf8)
        if bytes.last != UInt8(ascii: "/") { bytes.append(UInt8(ascii: "/")) }
        for (index, component) in components.reversed().enumerated() {
            if index > 0 { bytes.append(UInt8(ascii: "/")) }
            bytes.append(contentsOf: nameBytes(of: component))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The nodes from the root down to `id`, inclusive.
    public func ancestry(of id: NodeID) -> [NodeID] {
        var chain: [NodeID] = []
        var current = id
        while current != Self.noNode {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        return chain.reversed()
    }

    public func kind(of id: NodeID) -> KindID {
        let node = nodes[Int(id)]
        if node.flags.contains(.directory), !node.flags.contains(.package) { return kindTable.folder }
        return kindTable.kindOfExtension[Int(node.extensionID)]
    }

    /// Whether the display treats this node as something with visible contents.
    @inline(__always)
    public func isContainer(_ id: NodeID, _ options: DisplayOptions) -> Bool {
        let node = nodes[Int(id)]
        guard node.flags.contains(.directory), node.childCount > 0 else { return false }
        return options.showPackageContents || !node.flags.contains(.package)
    }

    public func isSynthetic(_ id: NodeID) -> Bool {
        nodes[Int(id)].flags.contains(.synthetic)
    }

    /// The children to display, largest first. At the root this includes free and other space
    /// when those are turned on.
    public func displayChildren(of id: NodeID, _ options: DisplayOptions) -> [NodeID] {
        var result = Array(children(of: id))
        if id == root {
            let mode = options.sizeMode
            for extra in extras(options) {
                let size = self.size(of: extra, mode)
                let position = result.firstIndex { self.size(of: $0, mode) < size } ?? result.count
                result.insert(extra, at: position)
            }
        }
        return result
    }

    /// Free and other space, if turned on and not empty.
    func extras(_ options: DisplayOptions) -> [NodeID] {
        var result: [NodeID] = []
        if options.showOtherSpace, otherSpaceNode != Self.noNode, node(otherSpaceNode).physicalSize > 0 {
            result.append(otherSpaceNode)
        }
        if options.showFreeSpace, freeSpaceNode != Self.noNode, node(freeSpaceNode).physicalSize > 0 {
            result.append(freeSpaceNode)
        }
        return result
    }

    /// The total the display adds up to: the node itself, plus free and other space at the root.
    public func displaySize(of id: NodeID, _ options: DisplayOptions) -> UInt64 {
        var total = size(of: id, options.sizeMode)
        if id == root {
            for extra in extras(options) { total += size(of: extra, options.sizeMode) }
        }
        return total
    }

    // MARK: Building

    func storeName(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard let offset = nameArena.allocate(bytes.count) else { return nil }
        if let source = bytes.baseAddress {
            (nameArena.base + offset).update(from: source, count: bytes.count)
        }
        return Self.nameReference(offset: offset, length: bytes.count)
    }

    func storeName(_ name: String) -> UInt64? {
        var name = name
        return name.withUTF8 { storeName($0) }
    }

    @inline(__always)
    static func nameReference(offset: Int, length: Int) -> UInt64 {
        UInt64(offset) << Node.nameLengthBits | UInt64(length)
    }

    /// Claims room for a node that nothing else points to yet.
    func makeDetachedNode(_ node: Node) -> NodeID? {
        guard let index = nodeArena.allocate(1), childArena.allocate(1) != nil else { return nil }
        nodes[index] = node
        childSlots[index] = NodeID(index)
        return NodeID(index)
    }

    /// Turns raw scan results for the nodes from `firstNode` on into a usable tree.
    func finishScan(from firstNode: Int, hardLinks: [HardLink]) {
        kindTable.resolve(extensions: extensions.names)
        removeDuplicateLinks(hardLinks)

        let count = nodeCount
        let isPackage = kindTable.extensionIsPackage
        // Parents are always created before their children, so one backwards pass adds every
        // subtree up.
        var index = count - 1
        while index >= firstNode {
            var node = nodes[index]
            if node.flags.contains(.directory) {
                if isPackage[Int(node.extensionID)] {
                    node.flags.insert(.package)
                    nodes[index].flags = node.flags
                }
            }
            if index > firstNode {
                let parent = Int(node.parent)
                nodes[parent].logicalSize &+= node.logicalSize
                nodes[parent].physicalSize &+= node.physicalSize
                nodes[parent].fileCount &+= node.fileCount
            }
            index -= 1
        }
        sortChildren(from: firstNode, to: count, mode: sortMode)
    }

    private func removeDuplicateLinks(_ links: [HardLink]) {
        guard links.count > 1 else { return }
        let sorted = links.sorted {
            ($0.device, $0.fileID, $0.node) < ($1.device, $1.fileID, $1.node)
        }
        for index in 1..<sorted.count {
            let link = sorted[index]
            let previous = sorted[index - 1]
            guard link.device == previous.device, link.fileID == previous.fileID else { continue }
            let slot = Int(link.node)
            nodes[slot].logicalSize = 0
            nodes[slot].physicalSize = 0
            nodes[slot].flags.insert(.hardLinkDuplicate)
        }
    }

    /// Re-sorts every directory's children by `mode`, largest first.
    public func sortChildren(by mode: SizeMode) {
        guard mode != sortMode else { return }
        sortMode = mode
        sortChildren(from: 0, to: nodeCount, mode: mode)
    }

    private func sortChildren(from first: Int, to last: Int, mode: SizeMode) {
        let chunk = 8192
        let chunks = (last - first + chunk - 1) / chunk
        DispatchQueue.concurrentPerform(iterations: chunks) { chunkIndex in
            let start = first + chunkIndex * chunk
            let end = min(start + chunk, last)
            for index in start..<end where nodes[index].childCount > 1 {
                sortSlice(of: index, mode: mode)
            }
        }
    }

    private func sortSlice(of index: Int, mode: SizeMode) {
        let node = nodes[index]
        var slice = UnsafeMutableBufferPointer(start: childSlots + Int(node.firstChild), count: Int(node.childCount))
        let nodes = self.nodes
        switch mode {
        case .physical:
            slice.sort { nodes[Int($0)].physicalSize > nodes[Int($1)].physicalSize }
        case .logical:
            slice.sort { nodes[Int($0)].logicalSize > nodes[Int($1)].logicalSize }
        }
    }

    // MARK: Volume space

    /// Re-reads how full the volume is and updates the free and other space nodes.
    public func updateVolumeSpace() {
        guard let info = VolumeInfo(containing: rootPath) else { return }
        volume = info
        if freeSpaceNode == Self.noNode {
            freeSpaceNode = makeSpaceNode(name: "Free Space", extensionID: ReservedExtension.freeSpace)
            otherSpaceNode = makeSpaceNode(name: "Other Space", extensionID: ReservedExtension.otherSpace)
        }
        guard freeSpaceNode != Self.noNode, otherSpaceNode != Self.noNode else { return }
        let scanned = nodes[Int(root)].physicalSize
        let other = info.usedBytes > scanned ? info.usedBytes - scanned : 0
        nodes[Int(freeSpaceNode)].physicalSize = info.availableBytes
        nodes[Int(freeSpaceNode)].logicalSize = info.availableBytes
        nodes[Int(otherSpaceNode)].physicalSize = other
        nodes[Int(otherSpaceNode)].logicalSize = other
    }

    private func makeSpaceNode(name: String, extensionID: UInt16) -> NodeID {
        guard let reference = storeName(name) else { return Self.noNode }
        let node = Node(
            logicalSize: 0, physicalSize: 0, nameRef: reference, parent: root, firstChild: 0,
            childCount: 0, fileCount: 0, modificationTime: 0, extensionID: extensionID,
            flags: [.synthetic]
        )
        return makeDetachedNode(node) ?? Self.noNode
    }

    // MARK: Changing

    /// Takes a node out of the tree, for example after it was moved to the Trash.
    public func remove(_ id: NodeID) {
        let removed = nodes[Int(id)]
        let parent = Int(removed.parent)
        guard removed.parent != Self.noNode else { return }

        let first = Int(nodes[parent].firstChild)
        let count = Int(nodes[parent].childCount)
        let slice = UnsafeMutableBufferPointer(start: childSlots + first, count: count)
        guard let position = slice.firstIndex(of: id) else { return }
        if position < count - 1 {
            (childSlots + first + position).update(from: childSlots + first + position + 1, count: count - position - 1)
        }
        nodes[parent].childCount -= 1
        adjustAncestors(of: id, logical: -Int64(removed.logicalSize), physical: -Int64(removed.physicalSize), files: -Int64(removed.fileCount))
    }

    /// Replaces the contents of `id` with those collected under `staging` by a refresh.
    func commitRefresh(of id: NodeID, staging: NodeID) {
        let old = nodes[Int(id)]
        let new = nodes[Int(staging)]
        nodes[Int(id)].firstChild = new.firstChild
        nodes[Int(id)].childCount = new.childCount
        nodes[Int(id)].logicalSize = new.logicalSize
        nodes[Int(id)].physicalSize = new.physicalSize
        nodes[Int(id)].fileCount = new.fileCount
        nodes[Int(id)].flags = new.flags
        for child in children(of: id) {
            nodes[Int(child)].parent = id
        }
        adjustAncestors(
            of: id,
            logical: Int64(new.logicalSize) - Int64(old.logicalSize),
            physical: Int64(new.physicalSize) - Int64(old.physicalSize),
            files: Int64(new.fileCount) - Int64(old.fileCount)
        )
    }

    /// Applies a change in size to everything above `id`, keeping each directory's children in
    /// order.
    private func adjustAncestors(of id: NodeID, logical: Int64, physical: Int64, files: Int64) {
        var current = nodes[Int(id)].parent
        while current != Self.noNode {
            let index = Int(current)
            nodes[index].logicalSize = UInt64(max(0, Int64(nodes[index].logicalSize) + logical))
            nodes[index].physicalSize = UInt64(max(0, Int64(nodes[index].physicalSize) + physical))
            nodes[index].fileCount = UInt32(max(0, Int64(nodes[index].fileCount) + files))
            sortSlice(of: index, mode: sortMode)
            current = nodes[index].parent
        }
    }
}

/// A file with more than one name, noted during a scan so it can be counted once.
struct HardLink {
    let device: Int32
    let fileID: UInt64
    let node: NodeID
}
