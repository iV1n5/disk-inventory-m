import Foundation
import Testing
@testable import DiskCore

/// A temporary folder that disappears with the test.
final class TemporaryFolder {
    let path: String

    init() throws {
        // Scans report real paths, and on macOS the temporary folder is behind a symlink.
        let base = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(base) }
        path = (String(cString: base) as NSString).appendingPathComponent("dim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        // Undo any permission changes a test made, or removal would fail.
        if let items = FileManager.default.enumerator(atPath: path) {
            for case let item as String in items {
                chmod((path as NSString).appendingPathComponent(item), 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func url(_ relative: String) -> URL {
        URL(fileURLWithPath: (path as NSString).appendingPathComponent(relative))
    }

    @discardableResult
    func write(_ relative: String, bytes: Int) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }
}

extension FileTree {
    /// Finds a node by its path below the root.
    func find(_ relative: String) -> NodeID? {
        var current = root
        for component in relative.split(separator: "/") {
            guard let next = children(of: current).first(where: { name(of: $0) == component }) else {
                return nil
            }
            current = next
        }
        return current
    }
}

extension FileTree {
    /// Like `find`, but failing the test when there is no such node.
    func id(_ relative: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> NodeID {
        try #require(find(relative), sourceLocation: sourceLocation)
    }
}

/// Builds trees directly, to test the layout on exact sizes without touching the disk.
final class SyntheticTree {
    let tree: FileTree

    init() {
        tree = FileTree(rootPath: "/synthetic")!
        let reference = tree.storeName("root")!
        _ = tree.makeDetachedNode(Node(
            logicalSize: 0, physicalSize: 0, nameRef: reference, parent: FileTree.noNode, firstChild: 0,
            childCount: 0, fileCount: 0, modificationTime: 0, extensionID: ReservedExtension.folder,
            flags: [.directory]
        ))
    }

    /// Adds files of the given sizes, and folders where the size is nil, returning their ids.
    @discardableResult
    func add(to parent: NodeID, _ items: [(String, UInt64?)]) -> [NodeID] {
        let ids = items.map { name, size -> NodeID in
            tree.makeDetachedNode(Node(
                logicalSize: size ?? 0, physicalSize: size ?? 0, nameRef: tree.storeName(name)!,
                parent: parent, firstChild: 0, childCount: 0, fileCount: size == nil ? 0 : 1,
                modificationTime: 0, extensionID: ReservedExtension.none,
                flags: size == nil ? [.directory] : []
            ))!
        }
        tree.nodes[Int(parent)].firstChild = ids[0]
        tree.nodes[Int(parent)].childCount = UInt32(ids.count)
        return ids
    }

    func finish() -> FileTree {
        tree.finishScan(from: 0, hardLinks: [])
        return tree
    }
}

extension PixelRect {
    var area: Int { width * height }
}
