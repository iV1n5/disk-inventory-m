/// How much of a tree is made up of one kind of file.
public struct KindStatistic: Sendable {
    public let kind: KindID
    public var bytes: UInt64
    public var files: UInt64
}

extension FileTree {
    /// Totals per kind, largest first. Honours the display options: with package contents hidden,
    /// an application counts as one file of kind "Application".
    public func kindStatistics(_ options: DisplayOptions) -> [KindStatistic] {
        let kindCount = kindTable.kinds.count
        var bytes = [UInt64](repeating: 0, count: kindCount)
        var files = [UInt64](repeating: 0, count: kindCount)
        let mode = options.sizeMode

        var pending = [root]
        while let directory = pending.popLast() {
            for child in children(of: directory) {
                if isContainer(child, options) {
                    pending.append(child)
                    continue
                }
                let node = nodes[Int(child)]
                if node.flags.contains(.directory), !node.flags.contains(.package) { continue }
                let kind = Int(self.kind(of: child))
                bytes[kind] &+= node.size(mode)
                files[kind] &+= 1
            }
        }

        var result: [KindStatistic] = []
        for kind in 0..<kindCount where files[kind] > 0 {
            result.append(KindStatistic(kind: KindID(kind), bytes: bytes[kind], files: files[kind]))
        }
        result.sort { $0.bytes > $1.bytes }
        return result
    }

    /// Every file of one kind, largest first.
    public func files(ofKind kind: KindID?, limit: Int, _ options: DisplayOptions) -> [NodeID] {
        var result: [NodeID] = []
        var pending = [root]
        while let directory = pending.popLast() {
            for child in children(of: directory) {
                if isContainer(child, options) {
                    pending.append(child)
                    continue
                }
                let node = nodes[Int(child)]
                if node.flags.contains(.directory), !node.flags.contains(.package) { continue }
                if let kind, self.kind(of: child) != kind { continue }
                result.append(child)
            }
        }
        let mode = options.sizeMode
        result.sort { size(of: $0, mode) > size(of: $1, mode) }
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    /// Every file or folder whose name contains `query`, ignoring case, largest first.
    public func search(_ query: String, limit: Int, _ options: DisplayOptions) -> [NodeID] {
        let needle = Array(query.utf8).map(lowercased)
        guard !needle.isEmpty else { return [] }
        var result: [NodeID] = []
        var pending = [root]
        while let directory = pending.popLast() {
            for child in children(of: directory) {
                if nameContains(child, needle) { result.append(child) }
                if isContainer(child, options) { pending.append(child) }
            }
        }
        let mode = options.sizeMode
        result.sort { size(of: $0, mode) > size(of: $1, mode) }
        if result.count > limit { result.removeLast(result.count - limit) }
        return result
    }

    private func nameContains(_ id: NodeID, _ needle: [UInt8]) -> Bool {
        let name = nameBytes(of: id)
        guard name.count >= needle.count else { return false }
        let first = needle[0]
        for start in 0...(name.count - needle.count) where lowercased(name[start]) == first {
            var matched = 1
            while matched < needle.count, lowercased(name[start + matched]) == needle[matched] {
                matched += 1
            }
            if matched == needle.count { return true }
        }
        return false
    }
}

/// The colours kinds are drawn in.
public enum KindPalette {
    /// Six strong colours, then six softer versions, for the largest kinds.
    private static let distinct: [SIMD3<Float>] = [
        SIMD3(0.17, 0.27, 0.95),  // blue
        SIMD3(0.92, 0.13, 0.15),  // red
        SIMD3(0.10, 0.78, 0.20),  // green
        SIMD3(0.00, 0.80, 0.85),  // cyan
        SIMD3(0.85, 0.10, 0.85),  // magenta
        SIMD3(0.93, 0.85, 0.08),  // yellow
        SIMD3(0.42, 0.45, 0.80),
        SIMD3(0.80, 0.42, 0.42),
        SIMD3(0.42, 0.72, 0.45),
        SIMD3(0.38, 0.70, 0.72),
        SIMD3(0.72, 0.42, 0.72),
        SIMD3(0.75, 0.72, 0.40),
    ]
    private static let remaining = SIMD3<Float>(0.60, 0.60, 0.60)
    private static let freeSpace = SIMD3<Float>(0.70, 0.70, 0.68)
    private static let otherSpace = SIMD3<Float>(0.32, 0.32, 0.34)

    /// A colour for every kind of the table, given the kinds sorted by importance.
    public static func colors(for statistics: [KindStatistic], table: KindTable) -> [SIMD4<Float>] {
        var colors = [SIMD4<Float>](
            repeating: SIMD4(remaining, 1),
            count: table.kinds.count
        )
        var next = 0
        for statistic in statistics where next < distinct.count {
            if statistic.kind == table.freeSpace || statistic.kind == table.otherSpace { continue }
            colors[Int(statistic.kind)] = SIMD4(distinct[next], 1)
            next += 1
        }
        colors[Int(table.freeSpace)] = SIMD4(freeSpace, 1)
        colors[Int(table.otherSpace)] = SIMD4(otherSpace, 1)
        return colors
    }
}
