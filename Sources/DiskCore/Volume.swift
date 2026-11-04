import Foundation

/// A mounted volume and how full it is.
public struct VolumeInfo: Sendable, Hashable {
    public let mountPath: String
    public let name: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    private static let keys: Set<URLResourceKey> = [
        .volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    /// The volume holding `path`.
    public init?(containing path: String) {
        let url = URL(fileURLWithPath: path)
        guard
            let values = try? url.resourceValues(forKeys: Self.keys),
            let mount = values.volume,
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity
        else { return nil }
        mountPath = mount.path
        name = values.volumeLocalizedName ?? mount.lastPathComponent
        totalBytes = UInt64(max(total, 0))
        availableBytes = UInt64(max(available, 0))
    }

    /// The volumes a person would recognise, boot volume first.
    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { VolumeInfo(containing: $0.path) }
    }
}
