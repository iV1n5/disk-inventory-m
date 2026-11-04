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

/// The ways of colouring kinds.
public enum MapColors: String, Sendable, CaseIterable {
    /// The system's colours, from the largest kind down.
    case system
    /// By what files are: video is blue on every disk.
    case families
}

/// The colours kinds are drawn in.
public enum KindPalette {
    /// One hue per family, in steps of lightness, so that the kinds of a family stay apart without
    /// leaving it. They come from OKLCH, which keeps the steps even to the eye.
    private static let familyShades: [KindFamily: [UInt32]] = [
        .video: [0x2A80E2, 0x4C9FFF, 0x69BDFF, 0x0267C7, 0x7CD0FF],
        .image: [0x00A062, 0x48CD8C, 0x008145, 0x67E8A5, 0x2EBA7A],
        .audio: [0x9E66D7, 0xC48CFF, 0xE1A9FF, 0x864EBC, 0xB179EB],
        .archive: [0xDD7B2B, 0xF99549, 0xC26300, 0xFFAE64, 0xAE5000],
        .application: [0xEC5482, 0xCF386B, 0xFF6E9B],
        .document: [0xE5C95E, 0xF2D76C, 0xD1B64A, 0xD8BD51, 0xC5A93B, 0xF9DD73],
        .data: [0x5B798B, 0x7897AA, 0x446274, 0x90B0C4, 0x6C8B9E, 0x4F6D7F, 0x84A4B7, 0x607F91],
    ]
    /// macOS's own colours, for the largest kinds.
    private static let systemColors: [UInt32] = [
        0x0A84FF, 0xFF9F0A, 0x30D158, 0x5E5CE6, 0xFFD60A, 0xFF375F,
        0x40C8E0, 0xBF5AF2, 0x66D4CF, 0xFF453A, 0xAC8E68, 0x64D2FF,
    ]
    private static let remaining: UInt32 = 0x77777D
    private static let freeSpace: UInt32 = 0xB3B3AD
    private static let otherSpace: UInt32 = 0x525257

    private static func color(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255, 1)
    }

    /// A colour for every kind of the table, given the kinds sorted by importance.
    public static func colors(
        for statistics: [KindStatistic],
        table: KindTable,
        scheme: MapColors = .system
    ) -> [SIMD4<Float>] {
        let shown = statistics.filter { $0.kind != table.freeSpace && $0.kind != table.otherSpace }
        var colors: [SIMD4<Float>]
        switch scheme {
        case .families:
            colors = table.kinds.map { color(familyShades[$0.family]?.first ?? remaining) }
            // Within a family, the largest kind gets the first shade.
            var used: [KindFamily: Int] = [:]
            for statistic in shown {
                let family = table.kinds[Int(statistic.kind)].family
                guard let shades = familyShades[family] else { continue }
                let step = used[family, default: 0]
                colors[Int(statistic.kind)] = color(shades[step % shades.count])
                used[family] = step + 1
            }
        case .system:
            colors = [SIMD4<Float>](repeating: color(remaining), count: table.kinds.count)
            for (statistic, hex) in zip(shown, systemColors) {
                colors[Int(statistic.kind)] = color(hex)
            }
        }
        colors[Int(table.freeSpace)] = color(freeSpace)
        colors[Int(table.otherSpace)] = color(otherSpace)
        return colors
    }
}
