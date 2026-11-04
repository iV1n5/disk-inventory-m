import CoreGraphics
import Foundation
import Testing
@testable import DiskCore
import TreemapMetal

@Suite struct LayoutTests {
    /// Two folders of files, sized to make hand-checking easy.
    private func sampleTree() -> FileTree {
        let builder = SyntheticTree()
        let folders = builder.add(to: 0, [("left", nil), ("right", nil), ("loose", 1000)])
        builder.add(to: folders[0], [("a", 4000), ("b", 2000), ("c", 1000)])
        builder.add(to: folders[1], [("d", 1500), ("e", 500)])
        return builder.finish()
    }

    private func counts(_ layout: TreemapLayout) -> [Int] {
        var coverage = [Int](repeating: 0, count: layout.width * layout.height)
        for tile in layout.tiles {
            for y in Int(tile.rect.y)..<Int(tile.rect.w) {
                for x in Int(tile.rect.x)..<Int(tile.rect.z) {
                    coverage[y * layout.width + x] += 1
                }
            }
        }
        return coverage
    }

    @Test func tilesCoverEveryPixelExactlyOnce() {
        let layout = TreemapLayout(tree: sampleTree(), root: 0, options: DisplayOptions(), width: 301, height: 197)
        #expect(counts(layout).allSatisfy { $0 == 1 })
    }

    @Test func coverageHoldsForAnAwkwardTree() {
        // Many sizes spanning orders of magnitude, in nested folders, at an odd resolution.
        let builder = SyntheticTree()
        let folders = builder.add(to: 0, (0..<40).map { ("folder\($0)", nil) })
        var seed: UInt64 = 42
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed >> 33
        }
        for folder in folders {
            builder.add(to: folder, (0..<30).map { ("f\($0)", next() % 100_000_000 + 1) })
        }
        let layout = TreemapLayout(tree: builder.finish(), root: 0, options: DisplayOptions(), width: 523, height: 311)
        #expect(counts(layout).allSatisfy { $0 == 1 })
    }

    @Test func areasAreProportionalToSizes() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 1000, height: 800)
        let total = Double(1000 * 800)
        for name in ["left/a", "left/b", "left/c", "right/d", "right/e", "loose"] {
            let id = try tree.id(name)
            let rect = try #require(layout.rect(of: id)).rect
            let expected = Double(tree.size(of: id, .physical)) / 10_000 * total
            #expect(abs(Double(rect.area) - expected) / expected < 0.01, "\(name)")
        }
    }

    @Test func keepsRectanglesCloseToSquare() {
        let builder = SyntheticTree()
        builder.add(to: 0, (0..<64).map { ("f\($0)", 1000) })
        let layout = TreemapLayout(tree: builder.finish(), root: 0, options: DisplayOptions(), width: 800, height: 800)
        #expect(layout.tiles.count == 64)
        for tile in layout.tiles {
            let width = tile.rect.z - tile.rect.x
            let height = tile.rect.w - tile.rect.y
            #expect(max(width / height, height / width) < 1.6)
        }
    }

    @Test func putsTheLargestItemTopLeft() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 1000, height: 800)
        #expect(layout.node(atX: 1, y: 1) == (try tree.id("left/a")))
    }

    @Test func hitTestingFindsTheFileUnderThePointer() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 640, height: 480)
        for name in ["left/a", "left/c", "right/e", "loose"] {
            let id = try tree.id(name)
            let rect = try #require(layout.rect(of: id)).rect
            #expect(layout.node(atX: (rect.x0 + rect.x1) / 2, y: (rect.y0 + rect.y1) / 2) == id, "\(name)")
        }
        #expect(layout.node(atX: -1, y: 10) == nil)
        #expect(layout.node(atX: 640, y: 10) == nil)
    }

    @Test func foldersEncloseTheirContents() throws {
        let tree = sampleTree()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 640, height: 480)
        let folder = try #require(layout.rect(of: try tree.id("left"))).rect
        for name in ["left/a", "left/b", "left/c"] {
            let rect = try #require(layout.rect(of: try tree.id(name))).rect
            #expect(rect.x0 >= folder.x0 && rect.x1 <= folder.x1)
            #expect(rect.y0 >= folder.y0 && rect.y1 <= folder.y1)
        }
    }

    @Test func zoomingFillsTheViewWithOneFolder() throws {
        let tree = sampleTree()
        let right = try tree.id("right")
        let layout = TreemapLayout(tree: tree, root: right, options: DisplayOptions(), width: 400, height: 300)
        #expect(layout.tiles.count == 2)
        #expect(counts(layout).allSatisfy { $0 == 1 })
        #expect(layout.rect(of: try tree.id("left/a")) == nil)
    }

    @Test func costDependsOnPixelsNotOnFileCount() {
        // A million files, far more than the 10,000 pixels available.
        let builder = SyntheticTree()
        builder.add(to: 0, (0..<1_000_000).map { ("f\($0)", 100) })
        let layout = TreemapLayout(tree: builder.finish(), root: 0, options: DisplayOptions(), width: 100, height: 100)
        #expect(layout.tiles.count <= 100 * 100)
        #expect(counts(layout).allSatisfy { $0 == 1 })
    }

    @Test func aSmallFileResolvesToItsVisibleFolder() throws {
        let builder = SyntheticTree()
        let folders = builder.add(to: 0, [("huge", 1_000_000_000_000), ("folder", nil)])
        let files = builder.add(to: folders[1], [("big", 100_000_000), ("speck", 1)])
        let tree = builder.finish()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 400, height: 300)
        let visible = try #require(layout.rect(of: files[1]))
        #expect(visible.node != files[1])
    }

    @Test func somethingTooSmallIsNotTheWholeOfItsFolder() throws {
        let builder = SyntheticTree()
        let folders = builder.add(to: 0, [("folder", nil), ("other", 1_000_000)])
        // Too small for a rectangle each, but enough for one between them.
        let specks = (0..<2000).map { ("speck\($0)", UInt64?(100)) }
        let files = builder.add(to: folders[0], [("big", 1_000_000)] + specks)
        let tree = builder.finish()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 100, height: 100)

        let folder = try #require(layout.rect(of: folders[0])).rect
        let speck = try #require(layout.location(of: files[5]))
        #expect(!speck.isExact)
        #expect(speck.rect.width * speck.rect.height < folder.width * folder.height / 2)
        #expect(speck.rect.x0 >= folder.x0 && speck.rect.x1 <= folder.x1)
        #expect(speck.rect.y0 >= folder.y0 && speck.rect.y1 <= folder.y1)
        #expect(layout.location(of: files[0])?.isExact == true)
        #expect(layout.location(of: folders[0])?.isExact == true)
    }

    @Test func somethingWithNoRoomLeftGoesToTheEndOfItsFolder() throws {
        let builder = SyntheticTree()
        let folders = builder.add(to: 0, [("huge", 1_000_000_000), ("folder", nil)])
        let files = builder.add(to: folders[1], [("big", 500_000_000), ("empty", 0)])
        let tree = builder.finish()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 400, height: 300)

        let folder = try #require(layout.rect(of: folders[1])).rect
        let empty = try #require(layout.location(of: files[1]))
        #expect(!empty.isExact)
        #expect(empty.rect.width == 1 && empty.rect.height == 1)
        #expect(empty.rect.x1 == folder.x1 && empty.rect.y1 == folder.y1)
    }

    @Test func emptyTreesProduceNothing() throws {
        let folder = try TemporaryFolder()
        let tree = try DiskScanner(path: folder.path).run()
        let layout = TreemapLayout(tree: tree, root: tree.root, options: DisplayOptions(), width: 100, height: 100)
        #expect(layout.tiles.isEmpty)
        #expect(layout.node(atX: 5, y: 5) == nil)
    }

    @Test func freeAndOtherSpaceTakeTheirShare() throws {
        let folder = try TemporaryFolder()
        try folder.write("file.bin", bytes: 1_000_000)
        let tree = try DiskScanner(path: folder.path).run()
        var options = DisplayOptions()
        options.showFreeSpace = true
        options.showOtherSpace = true

        let layout = TreemapLayout(tree: tree, root: tree.root, options: options, width: 500, height: 500)

        let volume = try #require(tree.volume)
        let free = tree.freeSpaceNode
        #expect(tree.isSynthetic(free))
        // The node reflects a reading taken moments ago, so compare loosely.
        let share = Double(tree.size(of: free, .physical)) / Double(volume.totalBytes)
        let rect = try #require(layout.rect(of: free)).rect
        #expect(abs(Double(rect.area) / 250_000 - share) < 0.02)
        #expect(counts(layout).allSatisfy { $0 == 1 })
        #expect(tree.displayChildren(of: tree.root, options).contains(free))
        #expect(!tree.displayChildren(of: tree.root, DisplayOptions()).contains(free))
    }

    @Test func packagesAreSolidUnlessShownAsFolders() throws {
        let folder = try TemporaryFolder()
        try folder.write("Example.app/Contents/a.dat", bytes: 500_000)
        try folder.write("Example.app/Contents/b.dat", bytes: 300_000)
        let tree = try DiskScanner(path: folder.path).run()
        var options = DisplayOptions()
        let solid = TreemapLayout(tree: tree, root: tree.root, options: options, width: 300, height: 200)
        #expect(solid.tiles.count == 1)
        options.showPackageContents = true
        let opened = TreemapLayout(tree: tree, root: tree.root, options: options, width: 300, height: 200)
        #expect(opened.tiles.count == 2)
    }
}

@Suite struct RenderingTests {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let data = image.dataProvider!.data! as Data
        let offset = y * image.bytesPerRow + x * 4
        return (Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset]))
    }

    @Test func compilesTheShaderAndDrawsCushions() throws {
        let builder = SyntheticTree()
        builder.add(to: 0, [("only", 1000)])
        let tree = builder.finish()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 200, height: 200)
        let renderer = try TreemapRenderer()
        var colors = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: tree.kindTable.kinds.count)
        colors[Int(tree.kind(of: tree.find("only")!))] = SIMD4(0, 0, 1, 1)

        let image = try renderer.makeImage(layout, colors: colors)

        let center = pixel(image, x: 100, y: 100)
        let corner = pixel(image, x: 188, y: 188)
        #expect(center.b > corner.b, "a cushion is brightest around its middle")
        #expect(center.b > 200)
        #expect(center.r > corner.r, "the highlight washes out towards white, most of all in the middle")
        #expect(center.r < 64, "gently: the colour stays recognisable")
        #expect(pixel(image, x: 0, y: 100).b < pixel(image, x: 2, y: 100).b, "a large tile stands apart from what is next to it")
    }

    @Test func smallTilesGoWithoutGapsAndRounding() throws {
        let builder = SyntheticTree()
        builder.add(to: 0, [("only", 1000)])
        let tree = builder.finish()
        let layout = TreemapLayout(tree: tree, root: 0, options: DisplayOptions(), width: 8, height: 8)
        var colors = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: tree.kindTable.kinds.count)
        colors[Int(tree.kind(of: tree.find("only")!))] = SIMD4(0, 0, 1, 1)

        let image = try TreemapRenderer().makeImage(layout, colors: colors)

        #expect(pixel(image, x: 0, y: 0).b > 100, "or a folder of many small files would turn into dots")
    }

    @Test func eachTileUsesTheColorOfItsKind() throws {
        let folder = try TemporaryFolder()
        try folder.write("one.txt", bytes: 1_000_000)
        try folder.write("two.png", bytes: 1_000_000)
        let tree = try DiskScanner(path: folder.path).run()
        let layout = TreemapLayout(tree: tree, root: tree.root, options: DisplayOptions(), width: 200, height: 200)
        var colors = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: tree.kindTable.kinds.count)
        let text = try tree.id("one.txt")
        let picture = try tree.id("two.png")
        colors[Int(tree.kind(of: text))] = SIMD4(1, 0, 0, 1)
        colors[Int(tree.kind(of: picture))] = SIMD4(0, 1, 0, 1)

        let image = try TreemapRenderer().makeImage(layout, colors: colors)

        let textRect = try #require(layout.rect(of: text)).rect
        let pictureRect = try #require(layout.rect(of: picture)).rect
        let textPixel = pixel(image, x: textRect.x0 + 3, y: textRect.y1 - 3)
        let picturePixel = pixel(image, x: pictureRect.x0 + 3, y: pictureRect.y1 - 3)
        #expect(textPixel.r > textPixel.g)
        #expect(picturePixel.g > picturePixel.r)
    }

    @Test func tileStrideMatchesTheShader() {
        #expect(MemoryLayout<TreemapTile>.stride == 48)
    }
}

@Suite struct PaletteTests {
    @Test(arguments: [MapColors.system, .gems])
    func colorsByRankGoToTheLargestKindsAndTheRestShareOne(scheme: MapColors) throws {
        let folder = try TemporaryFolder()
        for index in 0..<16 {
            try folder.write("file.ext\(Character(UnicodeScalar(UInt8(97 + index))))", bytes: (index + 1) * 10_000)
        }
        let tree = try DiskScanner(path: folder.path).run()
        let statistics = tree.kindStatistics(DisplayOptions())
        let colors = KindPalette.colors(for: statistics, table: tree.kindTable, scheme: scheme)

        #expect(statistics.count == 16)
        let shades = statistics.map { colors[Int($0.kind)] }
        #expect(Set(shades.prefix(12).map { "\($0)" }).count == 12)
        #expect(Set(shades.suffix(4).map { "\($0)" }).count == 1)
    }

    /// The point of families: what a kind looks like doesn't depend on what else is on the disk.
    @Test func aFamilyKeepsItsColourWhateverElseIsOnTheDisk() throws {
        func colorOfMovie(besides others: [(String, Int)]) throws -> SIMD4<Float> {
            let folder = try TemporaryFolder()
            try folder.write("clip.mov", bytes: 50_000)
            for (name, size) in others { try folder.write(name, bytes: size) }
            let tree = try DiskScanner(path: folder.path).run()
            let colors = KindPalette.colors(for: tree.kindStatistics(DisplayOptions()), table: tree.kindTable, scheme: .families)
            return colors[Int(tree.kind(of: try tree.id("clip.mov")))]
        }
        let alone = try colorOfMovie(besides: [])
        let withLargerFiles = try colorOfMovie(besides: [("photo.jpg", 900_000), ("backup.zip", 700_000)])
        #expect(alone == withLargerFiles)
    }

    @Test func kindsOfAFamilyDifferInShade() throws {
        let folder = try TemporaryFolder()
        try folder.write("clip.mov", bytes: 90_000)
        try folder.write("clip.mp4", bytes: 50_000)
        let tree = try DiskScanner(path: folder.path).run()
        let colors = KindPalette.colors(for: tree.kindStatistics(DisplayOptions()), table: tree.kindTable, scheme: .families)
        let first = colors[Int(tree.kind(of: try tree.id("clip.mov")))]
        let second = colors[Int(tree.kind(of: try tree.id("clip.mp4")))]
        #expect(first != second)
    }
}
