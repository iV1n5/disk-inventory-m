// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskInventoryM",
    platforms: [.macOS(.v15)],
    targets: [
        // Scanning, the in-memory file tree and the treemap layout. No UI.
        .target(name: "DiskCore"),
        // GPU rendering of a laid-out treemap.
        .target(name: "TreemapMetal", dependencies: ["DiskCore"]),
        // The macOS application.
        .executableTarget(name: "DiskInventoryM", dependencies: ["DiskCore", "TreemapMetal"]),
        // Headless companion tool: benchmarks, accuracy checks, PNG rendering.
        .executableTarget(name: "dim", dependencies: ["DiskCore", "TreemapMetal"]),
        .testTarget(name: "DiskCoreTests", dependencies: ["DiskCore", "TreemapMetal"]),
    ]
)
