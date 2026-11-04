/// Index of a node inside a `FileTree`. Stable for the lifetime of the tree.
public typealias NodeID = UInt32

/// Index of a kind inside a `KindTable`.
public typealias KindID = UInt16

/// Which of the two sizes of a file drives the display.
public enum SizeMode: Int, Sendable, CaseIterable {
    /// Space actually allocated on disk: what deleting the file gives back.
    case physical
    /// The length of the file's contents.
    case logical
}

public struct NodeFlags: OptionSet, Sendable, BitwiseCopyable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let directory = NodeFlags(rawValue: 1 << 0)
    /// A directory the Finder presents as a single file, such as an `.app`.
    public static let package = NodeFlags(rawValue: 1 << 1)
    public static let symlink = NodeFlags(rawValue: 1 << 2)
    /// A further name for a file already counted elsewhere in the tree. Its sizes are zero so
    /// that totals count the data once, as `du` does.
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 3)
    /// Another volume is mounted here. It is not descended into.
    public static let mountPoint = NodeFlags(rawValue: 1 << 4)
    /// The directory could not be read, so its contents are missing from the tree.
    public static let unreadable = NodeFlags(rawValue: 1 << 5)
    /// Content lives in the cloud and is not stored locally.
    public static let dataless = NodeFlags(rawValue: 1 << 6)
    /// Not a file: free space or other space on the volume.
    public static let synthetic = NodeFlags(rawValue: 1 << 7)
    /// The file is stored compressed by the file system.
    public static let compressed = NodeFlags(rawValue: 1 << 8)
}

/// One file or directory. 48 bytes, so a scan of ten million files needs about half a gigabyte.
public struct Node: Sendable, BitwiseCopyable {
    /// For directories these are totals over the subtree.
    public var logicalSize: UInt64
    public var physicalSize: UInt64
    /// Offset into the name arena, shifted left by `nameLengthBits`, plus the length in bytes.
    var nameRef: UInt64
    public var parent: NodeID
    /// Where this directory's slice of the child arena starts.
    var firstChild: UInt32
    public var childCount: UInt32
    /// Number of files in the subtree; 1 for a file.
    public var fileCount: UInt32
    /// Seconds since 1970.
    public var modificationTime: UInt32
    var extensionID: UInt16
    public var flags: NodeFlags

    static let nameLengthBits: UInt64 = 12

    @inline(__always)
    public func size(_ mode: SizeMode) -> UInt64 {
        mode == .physical ? physicalSize : logicalSize
    }

    public var isDirectory: Bool { flags.contains(.directory) }
}
