import Darwin
import Foundation
import Testing
@testable import DiskCore

@Suite struct ScannerTests {
    @Test func addsUpSizesThroughTheHierarchy() throws {
        let folder = try TemporaryFolder()
        try folder.write("a/one.bin", bytes: 1000)
        try folder.write("a/b/two.bin", bytes: 2000)
        try folder.write("three.bin", bytes: 4000)

        let tree = try DiskScanner(path: folder.path).run()

        #expect(tree.node(tree.root).logicalSize == 7000)
        #expect(tree.node(tree.root).fileCount == 3)
        #expect(tree.directoryCount == 3)
        let a = try tree.id("a")
        #expect(tree.node(a).logicalSize == 3000)
        #expect(tree.node(a).fileCount == 2)
        #expect(tree.path(of: try tree.id("a/b/two.bin")) == folder.path + "/a/b/two.bin")
    }

    @Test func listsChildrenLargestFirst() throws {
        let folder = try TemporaryFolder()
        for (index, size) in [50_000, 900_000, 10_000, 300_000].enumerated() {
            try folder.write("file\(index).bin", bytes: size)
        }
        let tree = try DiskScanner(path: folder.path).run()
        let sizes = tree.children(of: tree.root).map { tree.size(of: $0, .physical) }
        #expect(sizes == sizes.sorted(by: >))
        #expect(sizes.count == 4)
    }

    @Test func countsHardLinksOnce() throws {
        let folder = try TemporaryFolder()
        let original = try folder.write("original.bin", bytes: 100_000)
        try folder.makeDirectory("elsewhere")
        try FileManager.default.linkItem(at: original, to: folder.url("elsewhere/link.bin"))

        let tree = try DiskScanner(path: folder.path).run()

        #expect(tree.node(tree.root).logicalSize == 100_000)
        let copies = ["original.bin", "elsewhere/link.bin"].compactMap { tree.find($0) }
        #expect(copies.count == 2)
        #expect(copies.filter { tree.node($0).flags.contains(.hardLinkDuplicate) }.count == 1)
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let folder = try TemporaryFolder()
        try folder.write("real/big.bin", bytes: 500_000)
        try FileManager.default.createSymbolicLink(atPath: folder.url("loop").path, withDestinationPath: folder.path)

        let tree = try DiskScanner(path: folder.path).run()

        let link = try tree.id("loop")
        #expect(tree.node(link).flags.contains(.symlink))
        #expect(tree.node(link).childCount == 0)
        #expect(tree.node(tree.root).fileCount == 2)
    }

    @Test func sortsKindsIntoFamilies() throws {
        let folder = try TemporaryFolder()
        let expected: [(String, KindFamily)] = [
            ("clip.mov", .video), ("clip.mp4", .video),
            ("photo.jpg", .image), ("shot.png", .image), ("raw.dng", .image),
            ("song.mp3", .audio), ("take.wav", .audio), ("album.flac", .audio),
            ("backup.zip", .archive), ("logs.gz", .archive), ("disk.dmg", .archive), ("setup.pkg", .archive),
            ("paper.pdf", .document), ("letter.docx", .document), ("notes.txt", .document), ("book.epub", .document),
            ("main.swift", .data), ("config.json", .data), ("table.csv", .data), ("blob.unknownthing", .data),
        ]
        for (name, _) in expected { try folder.write(name, bytes: 10) }
        try folder.write("Example.app/Contents/MacOS/Example", bytes: 10)

        let tree = try DiskScanner(path: folder.path).run()
        for (name, family) in expected {
            let kind = tree.kindTable.kinds[Int(tree.kind(of: try tree.id(name)))]
            #expect(kind.family == family, "\(name) is \(kind.name), in \(kind.family)")
        }
        let app = tree.kindTable.kinds[Int(tree.kind(of: try tree.id("Example.app")))]
        #expect(app.family == .application)
    }

    @Test func recognisesPackagesAndKinds() throws {
        let folder = try TemporaryFolder()
        try folder.write("Example.app/Contents/MacOS/Example", bytes: 10)
        try folder.write("picture.PNG", bytes: 10)
        try folder.write("notes.txt", bytes: 10)
        try folder.makeDirectory("plain.folder")

        let tree = try DiskScanner(path: folder.path).run()
        let table = tree.kindTable

        let app = try tree.id("Example.app")
        #expect(tree.node(app).flags.contains(.package))
        #expect(table.kinds[Int(tree.kind(of: app))].name.localizedCaseInsensitiveContains("application"))
        let picture = try tree.id("picture.PNG")
        #expect(table.kinds[Int(tree.kind(of: picture))].name.contains("PNG"))
        let plain = try tree.id("plain.folder")
        #expect(!tree.node(plain).flags.contains(.package))
        #expect(tree.kind(of: plain) == table.folder)
    }

    @Test func treatsPackagesAsFilesUnlessAskedNotTo() throws {
        let folder = try TemporaryFolder()
        try folder.write("Example.app/Contents/Resources/a.dat", bytes: 500)
        try folder.write("Example.app/Contents/Resources/b.dat", bytes: 700)

        let tree = try DiskScanner(path: folder.path).run()
        let app = try tree.id("Example.app")

        var options = DisplayOptions()
        options.sizeMode = .logical
        #expect(!tree.isContainer(app, options))
        #expect(tree.kindStatistics(options).map(\.files) == [1])

        options.showPackageContents = true
        #expect(tree.isContainer(app, options))
        #expect(tree.kindStatistics(options).map(\.files) == [2])
    }

    @Test func reportsDirectoriesItCannotRead() throws {
        let folder = try TemporaryFolder()
        try folder.write("open/fine.bin", bytes: 100)
        try folder.write("locked/secret.bin", bytes: 100)
        chmod(folder.url("locked").path, 0o000)

        let tree = try DiskScanner(path: folder.path).run()

        let locked = try tree.id("locked")
        #expect(tree.node(locked).flags.contains(.unreadable))
        #expect(tree.unreadableCount == 1)
        #expect(tree.issues.first?.code == EACCES)
        #expect(tree.node(tree.root).logicalSize == 100)
    }

    @Test func skipsExcludedPaths() throws {
        let folder = try TemporaryFolder()
        try folder.write("keep/a.bin", bytes: 100)
        try folder.write("skip/b.bin", bytes: 100)
        var options = DiskScanner.Options()
        options.excludedPaths = [folder.url("skip").path]

        let tree = try DiskScanner(path: folder.path, options: options).run()

        #expect(tree.node(tree.root).logicalSize == 100)
        #expect(tree.find("skip/b.bin") == nil)
    }

    @Test func scansPathsLongerThanTheSystemLimit() throws {
        let folder = try TemporaryFolder()
        // Build the chain relative to each level, as a single path would be rejected.
        var descriptor = open(folder.path, O_RDONLY)
        #expect(descriptor >= 0)
        let level = String(repeating: "x", count: 200)
        for _ in 0..<8 {
            #expect(mkdirat(descriptor, level, 0o755) == 0)
            let next = openat(descriptor, level, O_RDONLY)
            close(descriptor)
            descriptor = next
            #expect(descriptor >= 0)
        }
        let file = openat(descriptor, "deep.bin", O_WRONLY | O_CREAT, 0o644)
        #expect(file >= 0)
        _ = [UInt8](repeating: 1, count: 4096).withUnsafeBytes { Darwin.write(file, $0.baseAddress, 4096) }
        close(file)
        close(descriptor)

        let tree = try DiskScanner(path: folder.path).run()

        #expect(tree.unreadableCount == 0)
        #expect(tree.node(tree.root).logicalSize == 4096)
        #expect(tree.node(tree.root).fileCount == 1)

        // Plain removal can't manage paths this long either, so unwind it level by level.
        removeChain(root: folder.path, level: level, depth: 8)
    }

    private func removeChain(root: String, level: String, depth: Int) {
        var descriptors = [open(root, O_RDONLY)]
        for _ in 0..<depth {
            descriptors.append(openat(descriptors.last!, level, O_RDONLY))
        }
        unlinkat(descriptors.last!, "deep.bin", 0)
        while descriptors.count > 1 {
            close(descriptors.removeLast())
            unlinkat(descriptors.last!, level, AT_REMOVEDIR)
        }
        close(descriptors[0])
    }

    @Test func canBeCancelled() throws {
        let folder = try TemporaryFolder()
        for index in 0..<50 { try folder.write("d\(index)/file.bin", bytes: 10) }
        let scanner = try DiskScanner(path: folder.path)
        scanner.cancel()
        #expect(throws: ScanError.self) { try scanner.run() }
    }

    @Test func rejectsWhatIsNotAFolder() throws {
        let folder = try TemporaryFolder()
        let file = try folder.write("file.bin", bytes: 10)
        #expect(throws: ScanError.self) { try DiskScanner(path: file.path) }
        #expect(throws: ScanError.self) { try DiskScanner(path: folder.path + "/missing") }
    }

    @Test func handlesManyFilesInOneDirectory() throws {
        // More entries than fit one attribute buffer, so several bulk reads are needed.
        let folder = try TemporaryFolder()
        for index in 0..<6000 {
            FileManager.default.createFile(atPath: folder.url("file-\(index).dat").path, contents: Data(count: 1))
        }
        let tree = try DiskScanner(path: folder.path).run()
        #expect(tree.node(tree.root).fileCount == 6000)
        #expect(tree.node(tree.root).logicalSize == 6000)
    }
}

@Suite struct TreeChangeTests {
    @Test func removingANodeUpdatesEverythingAboveIt() throws {
        let folder = try TemporaryFolder()
        try folder.write("a/b/gone.bin", bytes: 1000)
        try folder.write("a/b/stays.bin", bytes: 300)
        try folder.write("other.bin", bytes: 500)
        let tree = try DiskScanner(path: folder.path).run()
        tree.sortChildren(by: .logical)

        tree.remove(try tree.id("a/b/gone.bin"))

        #expect(tree.find("a/b/gone.bin") == nil)
        #expect(tree.node(tree.root).logicalSize == 800)
        #expect(tree.node(tree.root).fileCount == 2)
        #expect(tree.node(try tree.id("a/b")).logicalSize == 300)
        // "other.bin" has become larger than "a", so the root must have been re-sorted.
        #expect(tree.name(of: tree.children(of: tree.root)[0]) == "other.bin")
    }

    @Test func refreshingPicksUpChangesInOneFolderOnly() throws {
        let folder = try TemporaryFolder()
        try folder.write("a/old.bin", bytes: 1000)
        try folder.write("b/kept.bin", bytes: 500)
        let tree = try DiskScanner(path: folder.path).run()
        tree.sortChildren(by: .logical)
        let a = try tree.id("a")

        try FileManager.default.removeItem(at: folder.url("a/old.bin"))
        try folder.write("a/new/fresh.bin", bytes: 3000)
        try folder.write("b/unseen.bin", bytes: 9000)

        let scanner = try DiskScanner(refreshing: a, in: tree)
        try scanner.run()
        // Until the commit, the old state must still be intact.
        #expect(tree.find("a/old.bin") != nil)
        scanner.commit(replacing: a)

        #expect(tree.find("a/old.bin") == nil)
        let fresh = try tree.id("a/new/fresh.bin")
        #expect(tree.path(of: fresh) == folder.path + "/a/new/fresh.bin")
        #expect(tree.ancestry(of: fresh).first == tree.root)
        #expect(tree.node(a).logicalSize == 3000)
        #expect(tree.node(tree.root).logicalSize == 3500)
        #expect(tree.find("b/unseen.bin") == nil)
    }

    @Test func switchingSizeModeReordersChildren() throws {
        let tree = SyntheticTree()
        let ids = tree.add(to: 0, [("a", 100), ("b", 200)])
        // "a" takes more room on disk despite having less content.
        tree.tree.nodes[Int(ids[0])].physicalSize = 4096
        tree.tree.nodes[Int(ids[1])].physicalSize = 1024
        let result = tree.finish()

        #expect(result.name(of: result.children(of: 0)[0]) == "a")
        result.sortChildren(by: .logical)
        #expect(result.name(of: result.children(of: 0)[0]) == "b")
    }

    @Test func searchMatchesPartsOfNamesIgnoringCase() throws {
        let folder = try TemporaryFolder()
        try folder.write("Holiday Photos/IMG_001.JPG", bytes: 2000)
        try folder.write("Holiday Photos/img_002.jpg", bytes: 3000)
        try folder.write("notes.txt", bytes: 10)
        let tree = try DiskScanner(path: folder.path).run()
        tree.sortChildren(by: .logical)
        var options = DisplayOptions()
        options.sizeMode = .logical

        let found = tree.search("img_", limit: 10, options)

        #expect(found.map { tree.name(of: $0) } == ["img_002.jpg", "IMG_001.JPG"])
        #expect(tree.search("HOLIDAY", limit: 10, options).count == 1)
        #expect(tree.search("nothing", limit: 10, options).isEmpty)
    }
}

@Suite struct ExtensionTests {
    private func parse(_ name: String) -> String? {
        Array(name.utf8).withUnsafeBufferPointer { bytes in
            guard let found = fileExtension(of: bytes.baseAddress!, length: bytes.count) else { return nil }
            return String(decoding: bytes[found.start..<(found.start + found.length)], as: UTF8.self)
        }
    }

    @Test func findsOrdinaryExtensions() {
        #expect(parse("photo.jpeg") == "jpeg")
        #expect(parse("archive.tar.gz") == "gz")
        #expect(parse("a.b") == "b")
        #expect(parse("Code.c++") == "c++")
    }

    @Test func ignoresWhatIsNotAnExtension() {
        #expect(parse("README") == nil)
        #expect(parse(".gitignore") == nil)
        #expect(parse("trailing.") == nil)
        #expect(parse("server.log.1") == nil)
        #expect(parse("file.with space") == nil)
        #expect(parse("name.averyveryverylongextensionindeed") == nil)
    }

    @Test func hashIgnoresCase() {
        func hash(_ name: String) -> UInt64? {
            Array(name.utf8).withUnsafeBufferPointer { fileExtension(of: $0.baseAddress!, length: $0.count)?.hash }
        }
        #expect(hash("A.JPG") == hash("b.jpg"))
        #expect(hash("A.JPG") != hash("A.PNG"))
    }
}
