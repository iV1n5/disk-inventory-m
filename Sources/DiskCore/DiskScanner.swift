import Darwin
import Foundation
import Synchronization

public enum ScanError: Error, Sendable {
    case cannotOpen(path: String, code: Int32)
    case outOfMemory
    case cancelled
}

/// Walks a folder and builds a `FileTree`, using all cores.
///
/// `getattrlistbulk(2)` returns the names and attributes of a whole batch of directory entries
/// per system call, which is far cheaper than `readdir` plus a `stat` per file. Directories are
/// handed out to worker threads through a shared stack. Nothing here reads file contents.
public final class DiskScanner: @unchecked Sendable {
    public struct Options: Sendable {
        public var threadCount = max(4, ProcessInfo.processInfo.activeProcessorCount)
        /// Absolute paths to skip entirely.
        public var excludedPaths: [String] = []

        public init() {}
    }

    public struct Progress: Sendable {
        public var files: UInt64
        public var directories: UInt64
        public var bytes: UInt64
        public var currentPath: String
    }

    public let tree: FileTree
    private let options: Options
    private let excludedPaths: [[UInt8]]
    private let queue = WorkQueue()

    /// What the scan starts from: the root, or a staging node when refreshing a subtree.
    private let startNode: NodeID
    private let startPath: String
    private let firstNode: Int

    private let cancelled = Atomic<Bool>(false)
    private let outOfMemory = Atomic<Bool>(false)
    private let filesSeen = Atomic<UInt64>(0)
    private let directoriesSeen = Atomic<UInt64>(0)
    private let bytesSeen = Atomic<UInt64>(0)
    private let unreadable = Atomic<Int>(0)

    private struct SharedResults {
        var currentPath = ""
        var issues: [ScanIssue] = []
        var hardLinks: [HardLink] = []
    }
    private let shared = Mutex(SharedResults())

    private static let maximumIssues = 500

    // MARK: Starting

    /// Prepares a scan of the folder or volume at `path`.
    public init(path: String, options: Options = Options()) throws {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else {
            throw ScanError.cannotOpen(path: path, code: errno)
        }
        let rootPath = resolved.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            throw ScanError.cannotOpen(path: rootPath, code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw ScanError.cannotOpen(path: rootPath, code: ENOTDIR)
        }
        guard let tree = FileTree(rootPath: rootPath) else { throw ScanError.outOfMemory }

        let volume = VolumeInfo(containing: rootPath)
        let name = rootPath == volume?.mountPath ? volume?.name : nil
        let displayName = name ?? URL(fileURLWithPath: rootPath).lastPathComponent
        guard
            let reference = tree.storeName(displayName),
            tree.makeDetachedNode(
                Node(
                    logicalSize: 0, physicalSize: 0, nameRef: reference, parent: FileTree.noNode,
                    firstChild: 0, childCount: 0, fileCount: 0,
                    modificationTime: UInt32(clamping: info.st_mtimespec.tv_sec),
                    extensionID: ReservedExtension.folder, flags: [.directory]
                )
            ) != nil
        else { throw ScanError.outOfMemory }

        self.tree = tree
        self.options = options
        self.excludedPaths = Self.resolve(options.excludedPaths)
        self.startNode = tree.root
        self.startPath = rootPath
        self.firstNode = 0
    }

    /// Prepares a new look at one directory of an existing tree.
    ///
    /// The results are collected to the side, and only `commit()` swaps them in, so the tree stays
    /// usable by the interface while this runs.
    public init(refreshing id: NodeID, in tree: FileTree, options: Options = Options()) throws {
        var staging = tree.node(id)
        staging.logicalSize = 0
        staging.physicalSize = 0
        staging.fileCount = 0
        staging.childCount = 0
        staging.flags.remove(.unreadable)
        let first = tree.nodeCount
        guard let stagingNode = tree.makeDetachedNode(staging) else { throw ScanError.outOfMemory }

        self.tree = tree
        self.options = options
        self.excludedPaths = Self.resolve(options.excludedPaths)
        self.startNode = stagingNode
        self.startPath = tree.path(of: id)
        self.firstNode = first
    }

    /// Exclusions are matched against real paths, the only kind a scan ever sees.
    private static func resolve(_ paths: [String]) -> [[UInt8]] {
        paths.map { path in
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &resolved) != nil else { return Array(path.utf8) }
            return resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        }
    }

    // MARK: Control

    /// Runs the scan to completion on the calling thread, using worker threads for the work.
    @discardableResult
    public func run() throws -> FileTree {
        queue.push([Job(node: startNode, path: Self.duplicate(startPath), length: startPath.utf8.count)])

        let threads = DispatchGroup()
        for _ in 0..<max(1, options.threadCount) {
            threads.enter()
            let thread = Thread { [self] in
                work()
                threads.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.name = "DiskScanner"
            thread.start()
        }
        threads.wait()

        if cancelled.load(ordering: .relaxed) { throw ScanError.cancelled }
        if outOfMemory.load(ordering: .relaxed) { throw ScanError.outOfMemory }

        // A refresh leaves the tree alone, as the interface may be reading it. See `commit`.
        if firstNode == 0 {
            let results = shared.withLock { $0 }
            tree.finishScan(from: firstNode, hardLinks: results.hardLinks)
            tree.directoryCount = directoriesSeen.load(ordering: .relaxed)
            tree.unreadableCount = unreadable.load(ordering: .relaxed)
            tree.issues = results.issues
            tree.updateVolumeSpace()
        }
        return tree
    }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    /// Finishes a refresh by swapping in what `run()` found. As this changes the tree, the caller
    /// has to keep readers out while it runs.
    public func commit(replacing id: NodeID) {
        let results = shared.withLock { $0 }
        tree.finishScan(from: firstNode, hardLinks: results.hardLinks)
        tree.commitRefresh(of: id, staging: startNode)
        tree.updateVolumeSpace()
    }

    public var progress: Progress {
        Progress(
            files: filesSeen.load(ordering: .relaxed),
            directories: directoriesSeen.load(ordering: .relaxed),
            bytes: bytesSeen.load(ordering: .relaxed),
            currentPath: shared.withLock { $0.currentPath }
        )
    }

    // MARK: Worker threads

    private struct Job {
        let node: NodeID
        let path: UnsafeMutablePointer<CChar>
        let length: Int
    }

    private struct Entry {
        var nameRef: UInt64
        var logicalSize: UInt64
        var physicalSize: UInt64
        var fileID: UInt64
        var device: Int32
        var linkCount: UInt32
        var modificationTime: UInt32
        var extensionID: UInt16
        var flags: NodeFlags
    }

    /// State owned by one thread, so that the hot path takes no locks.
    private struct Worker {
        static let bufferSize = 256 * 1024
        static let nameChunkSize = 1 << 20

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        var entries: [Entry] = []
        var jobs: [Job] = []
        var hardLinks: [HardLink] = []
        var extensionIDs: [UInt64: UInt16] = [:]
        var nameChunkNext = 0
        var nameChunkEnd = 0
        var directoriesUntilPathUpdate = 0
    }

    private func work() {
        // A disk scanner must never cause iCloud to download anything.
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
            IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        )

        var worker = Worker()
        defer { worker.buffer.deallocate() }
        worker.entries.reserveCapacity(1024)

        while let job = queue.pop() {
            if !cancelled.load(ordering: .relaxed), !outOfMemory.load(ordering: .relaxed) {
                scan(job, &worker)
            }
            job.path.deallocate()
            queue.finishedOne()
        }

        if !worker.hardLinks.isEmpty {
            let links = worker.hardLinks
            shared.withLock { $0.hardLinks.append(contentsOf: links) }
        }
    }

    private func scan(_ job: Job, _ worker: inout Worker) {
        directoriesSeen.add(1, ordering: .relaxed)
        if worker.directoriesUntilPathUpdate == 0 {
            worker.directoriesUntilPathUpdate = 64
            let path = String(cString: job.path)
            shared.withLock { $0.currentPath = path }
        }
        worker.directoriesUntilPathUpdate -= 1

        let descriptor = Self.openDirectory(job.path, length: job.length)
        guard descriptor >= 0 else {
            noteUnreadable(job, code: errno)
            return
        }
        defer { close(descriptor) }

        worker.entries.removeAll(keepingCapacity: true)
        var attributes = Self.requestedAttributes
        while true {
            let count = getattrlistbulk(descriptor, &attributes, worker.buffer, Worker.bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                noteUnreadable(job, code: errno)
                break
            }
            guard readEntries(count: Int(count), &worker) else {
                outOfMemory.store(true, ordering: .relaxed)
                return
            }
            if cancelled.load(ordering: .relaxed) { return }
        }
        guard !worker.entries.isEmpty else { return }
        addChildren(of: job, &worker)
    }

    /// Stores the entries gathered in `worker`, and queues the directories among them.
    private func addChildren(of job: Job, _ worker: inout Worker) {
        let count = worker.entries.count
        guard let first = tree.nodeArena.allocate(count), tree.childArena.allocate(count) != nil else {
            outOfMemory.store(true, ordering: .relaxed)
            return
        }

        let nodes = tree.nodes
        let slots = tree.childSlots
        var files: UInt64 = 0
        var bytes: UInt64 = 0
        worker.jobs.removeAll(keepingCapacity: true)

        for index in 0..<count {
            let entry = worker.entries[index]
            let id = first + index
            let isDirectory = entry.flags.contains(.directory)
            nodes[id] = Node(
                logicalSize: entry.logicalSize,
                physicalSize: entry.physicalSize,
                nameRef: entry.nameRef,
                parent: job.node,
                firstChild: 0,
                childCount: 0,
                fileCount: isDirectory ? 0 : 1,
                modificationTime: entry.modificationTime,
                extensionID: entry.extensionID,
                flags: entry.flags
            )
            slots[id] = NodeID(id)

            if isDirectory {
                if !entry.flags.contains(.mountPoint), !entry.flags.contains(.dataless) {
                    enqueue(child: NodeID(id), of: job, &worker)
                }
            } else {
                files += 1
                bytes &+= entry.physicalSize
                if entry.linkCount > 1 {
                    worker.hardLinks.append(HardLink(device: entry.device, fileID: entry.fileID, node: NodeID(id)))
                }
            }
        }

        nodes[Int(job.node)].firstChild = UInt32(first)
        nodes[Int(job.node)].childCount = UInt32(count)
        filesSeen.add(files, ordering: .relaxed)
        bytesSeen.add(bytes, ordering: .relaxed)
        if !worker.jobs.isEmpty {
            queue.push(worker.jobs)
        }
    }

    private func enqueue(child id: NodeID, of job: Job, _ worker: inout Worker) {
        let name = tree.nameBytes(of: id)
        let needsSeparator = job.length > 0 && job.path[job.length - 1] != CChar(UInt8(ascii: "/"))
        let length = job.length + (needsSeparator ? 1 : 0) + name.count
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        path.update(from: job.path, count: job.length)
        var position = job.length
        if needsSeparator {
            path[position] = CChar(UInt8(ascii: "/"))
            position += 1
        }
        name.withMemoryRebound(to: CChar.self) { bytes in
            if let source = bytes.baseAddress {
                (path + position).update(from: source, count: bytes.count)
            }
        }
        path[length] = 0

        if isExcluded(path, length: length) {
            path.deallocate()
            return
        }
        worker.jobs.append(Job(node: id, path: path, length: length))
    }

    private func isExcluded(_ path: UnsafePointer<CChar>, length: Int) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        return excludedPaths.contains { excluded in
            excluded.count == length && memcmp(excluded, path, length) == 0
        }
    }

    private func noteUnreadable(_ job: Job, code: Int32) {
        tree.nodes[Int(job.node)].flags.insert(.unreadable)
        unreadable.add(1, ordering: .relaxed)
        let path = String(cString: job.path)
        shared.withLock { results in
            if results.issues.count < Self.maximumIssues {
                results.issues.append(ScanIssue(path: path, code: code))
            }
        }
    }

    // MARK: Decoding attribute buffers

    private static let returnedAttributes: attrgroup_t = 0x8000_0000
    private static let errorAttribute: attrgroup_t = 0x2000_0000
    private static let nameAttribute = attrgroup_t(ATTR_CMN_NAME)
    private static let deviceAttribute = attrgroup_t(ATTR_CMN_DEVID)
    private static let typeAttribute = attrgroup_t(ATTR_CMN_OBJTYPE)
    private static let modificationAttribute = attrgroup_t(ATTR_CMN_MODTIME)
    private static let accessAttribute = attrgroup_t(ATTR_CMN_ACCESSMASK)
    private static let flagsAttribute = attrgroup_t(ATTR_CMN_FLAGS)
    private static let fileIDAttribute = attrgroup_t(ATTR_CMN_FILEID)
    private static let mountStatusAttribute = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
    private static let linkCountAttribute = attrgroup_t(ATTR_FILE_LINKCOUNT)
    private static let totalSizeAttribute = attrgroup_t(ATTR_FILE_TOTALSIZE)
    private static let allocatedSizeAttribute = attrgroup_t(ATTR_FILE_ALLOCSIZE)

    private static let requestedAttributes = attrlist(
        bitmapcount: u_short(ATTR_BIT_MAP_COUNT),
        reserved: 0,
        commonattr: returnedAttributes | errorAttribute | nameAttribute | deviceAttribute | typeAttribute
            | modificationAttribute | accessAttribute | flagsAttribute | fileIDAttribute,
        volattr: 0,
        dirattr: mountStatusAttribute,
        fileattr: linkCountAttribute | totalSizeAttribute | allocatedSizeAttribute,
        forkattr: 0
    )

    /// Decodes one buffer of entries. Each entry starts with its length and a bitmap of the
    /// attributes it really contains, followed by those attributes in a fixed order.
    private func readEntries(count: Int, _ worker: inout Worker) -> Bool {
        var cursor = UnsafeRawPointer(worker.buffer)
        for _ in 0..<count {
            let entryLength = Int(cursor.loadUnaligned(as: UInt32.self))
            var field = cursor + 4
            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field += MemoryLayout<attribute_set_t>.size
            defer { cursor += entryLength }

            let common = returned.commonattr
            if common & Self.errorAttribute != 0 { field += 4 }

            guard common & Self.nameAttribute != 0 else { continue }
            let nameReference = field.loadUnaligned(as: attrreference_t.self)
            let namePointer = (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
            // The stored length counts the terminating NUL.
            let nameLength = max(0, Int(nameReference.attr_length) - 1)
            field += MemoryLayout<attrreference_t>.size

            var entry = Entry(
                nameRef: 0, logicalSize: 0, physicalSize: 0, fileID: 0, device: 0, linkCount: 1,
                modificationTime: 0, extensionID: ReservedExtension.none, flags: []
            )
            if common & Self.deviceAttribute != 0 {
                entry.device = field.loadUnaligned(as: Int32.self)
                field += 4
            }
            var objectType: UInt32 = 0
            if common & Self.typeAttribute != 0 {
                objectType = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            if common & Self.modificationAttribute != 0 {
                let time = field.loadUnaligned(as: timespec.self)
                entry.modificationTime = UInt32(clamping: time.tv_sec)
                field += MemoryLayout<timespec>.size
            }
            var mode: UInt32 = 0
            if common & Self.accessAttribute != 0 {
                mode = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            if common & Self.flagsAttribute != 0 {
                let flags = field.loadUnaligned(as: UInt32.self)
                if flags & UInt32(bitPattern: SF_DATALESS) != 0 { entry.flags.insert(.dataless) }
                if flags & UInt32(UF_COMPRESSED) != 0 { entry.flags.insert(.compressed) }
                field += 4
            }
            if common & Self.fileIDAttribute != 0 {
                entry.fileID = field.loadUnaligned(as: UInt64.self)
                field += 8
            }
            if returned.dirattr & Self.mountStatusAttribute != 0 {
                let status = field.loadUnaligned(as: UInt32.self)
                if status & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0 {
                    entry.flags.insert(.mountPoint)
                }
                field += 4
            }
            if returned.fileattr & Self.linkCountAttribute != 0 {
                entry.linkCount = field.loadUnaligned(as: UInt32.self)
                field += 4
            }
            if returned.fileattr & Self.totalSizeAttribute != 0 {
                entry.logicalSize = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                field += 8
            }
            if returned.fileattr & Self.allocatedSizeAttribute != 0 {
                entry.physicalSize = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                field += 8
            }

            switch objectType {
            case UInt32(VDIR.rawValue):
                entry.flags.insert(.directory)
                entry.extensionID = extensionID(of: namePointer, length: nameLength, fallback: ReservedExtension.folder, &worker)
            case UInt32(VREG.rawValue):
                let fallback = mode & 0o111 != 0 ? ReservedExtension.executable : ReservedExtension.none
                entry.extensionID = extensionID(of: namePointer, length: nameLength, fallback: fallback, &worker)
            case UInt32(VLNK.rawValue):
                entry.flags.insert(.symlink)
                entry.extensionID = ReservedExtension.symlink
            default:
                entry.extensionID = ReservedExtension.special
            }

            guard let reference = storeName(namePointer, length: nameLength, &worker) else { return false }
            entry.nameRef = reference
            worker.entries.append(entry)
        }
        return true
    }

    /// Copies a name into this thread's current chunk of the name arena.
    @inline(__always)
    private func storeName(_ name: UnsafePointer<UInt8>, length: Int, _ worker: inout Worker) -> UInt64? {
        if worker.nameChunkNext + length > worker.nameChunkEnd {
            let size = max(Worker.nameChunkSize, length)
            guard let start = tree.nameArena.allocate(size) else { return nil }
            worker.nameChunkNext = start
            worker.nameChunkEnd = start + size
        }
        let offset = worker.nameChunkNext
        (tree.nameArena.base + offset).update(from: name, count: length)
        worker.nameChunkNext += length
        return FileTree.nameReference(offset: offset, length: length)
    }

    @inline(__always)
    private func extensionID(
        of name: UnsafePointer<UInt8>,
        length: Int,
        fallback: UInt16,
        _ worker: inout Worker
    ) -> UInt16 {
        guard let found = fileExtension(of: name, length: length) else { return fallback }
        if let id = worker.extensionIDs[found.hash] { return id }
        let id = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: found.length) { lowercase in
            for index in 0..<found.length {
                lowercase[index] = lowercased(name[found.start + index])
            }
            return tree.extensions.intern(hash: found.hash, bytes: UnsafeBufferPointer(lowercase))
        }
        worker.extensionIDs[found.hash] = id
        return id
    }

    // MARK: Paths

    private static func duplicate(_ path: String) -> UnsafeMutablePointer<CChar> {
        let bytes = path.utf8CString
        let copy = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { copy.update(from: $0.baseAddress!, count: bytes.count) }
        return copy
    }

    /// Opens a directory, including one whose path is too long for `open(2)` to take in one go.
    private static func openDirectory(_ path: UnsafePointer<CChar>, length: Int) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        if length < Int(PATH_MAX) { return open(path, flags) }

        var descriptor = open("/", flags)
        var start = 1
        let limit = Int(PATH_MAX) - 1
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(PATH_MAX)) { piece -> Int32 in
            while descriptor >= 0, start < length {
                var end = min(start + limit, length)
                if end < length {
                    while end > start, path[end] != CChar(UInt8(ascii: "/")) { end -= 1 }
                }
                guard end > start else {
                    close(descriptor)
                    errno = ENAMETOOLONG
                    return -1
                }
                piece.baseAddress!.update(from: path + start, count: end - start)
                piece[end - start] = 0
                let next = openat(descriptor, piece.baseAddress!, flags)
                let failure = errno
                close(descriptor)
                errno = failure
                descriptor = next
                start = end + 1
            }
            return descriptor
        }
    }

    // MARK: Sharing work

    /// A stack of directories waiting to be read. Taking the newest first keeps the backlog small
    /// compared to walking breadth first.
    private final class WorkQueue: @unchecked Sendable {
        private let condition = NSCondition()
        private var jobs: [Job] = []
        private var active = 0
        private var waiting = 0

        func push(_ newJobs: [Job]) {
            condition.lock()
            jobs.append(contentsOf: newJobs)
            if waiting > 0 { condition.broadcast() }
            condition.unlock()
        }

        /// Returns the next job, waiting for one if other threads may yet produce some. Returns
        /// nil once all work is done.
        func pop() -> Job? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let job = jobs.popLast() {
                    active += 1
                    return job
                }
                if active == 0 {
                    condition.broadcast()
                    return nil
                }
                waiting += 1
                condition.wait()
                waiting -= 1
            }
        }

        func finishedOne() {
            condition.lock()
            active -= 1
            if active == 0, jobs.isEmpty { condition.broadcast() }
            condition.unlock()
        }
    }
}
