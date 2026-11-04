import Foundation
import Synchronization
import UniformTypeIdentifiers

/// What a kind of file is for. Colours can go by this, so that video looks the same on every disk.
public enum KindFamily: Int, Sendable, CaseIterable {
    case video, image, audio, archive, application, document, data
}

/// A human-readable category of file, like "PNG image".
public struct FileKind: Sendable, Hashable {
    public let name: String
    public let family: KindFamily
}

/// Extension identifiers with a fixed meaning. Real extensions are numbered after these.
enum ReservedExtension {
    static let none: UInt16 = 0
    static let executable: UInt16 = 1
    static let folder: UInt16 = 2
    static let symlink: UInt16 = 3
    static let special: UInt16 = 4
    static let freeSpace: UInt16 = 5
    static let otherSpace: UInt16 = 6
    static let count = 7
}

/// Interns file extensions during a scan, so the scanner never compares strings per file and
/// Launch Services is consulted once per distinct extension rather than once per file.
final class ExtensionRegistry: Sendable {
    private struct State {
        var idsByHash: [UInt64: UInt16] = [:]
        var names: [String] = []
    }

    private let state = Mutex(State())

    /// Beyond this many distinct extensions, the rest are treated as having none.
    static let maximumCount = Int(UInt16.max) - ReservedExtension.count

    /// Registers an extension whose lowercase bytes are `bytes`, returning its identifier.
    func intern(hash: UInt64, bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        state.withLock { state in
            if let id = state.idsByHash[hash] { return id }
            guard state.names.count < Self.maximumCount else { return ReservedExtension.none }
            let id = UInt16(state.names.count + ReservedExtension.count)
            state.idsByHash[hash] = id
            state.names.append(String(decoding: bytes, as: UTF8.self))
            return id
        }
    }

    var names: [String] {
        state.withLock { $0.names }
    }
}

/// The kinds found in a tree, plus how extensions map onto them.
public struct KindTable: Sendable {
    public private(set) var kinds: [FileKind] = []
    private var kindIDsByName: [String: KindID] = [:]
    /// Indexed by extension identifier.
    private(set) var kindOfExtension: [KindID] = []
    /// Indexed by extension identifier.
    private(set) var extensionIsPackage: [Bool] = []
    /// How many entries of the registry have been resolved so far.
    private var resolvedExtensions = 0

    public private(set) var folder: KindID = 0
    public private(set) var freeSpace: KindID = 0
    public private(set) var otherSpace: KindID = 0

    init() {
        // In the order of the identifiers in `ReservedExtension`.
        let reserved = [
            "Document",
            Self.describe(.unixExecutable, fallback: "Unix Executable File"),
            Self.describe(.folder, fallback: "Folder"),
            Self.describe(.symbolicLink, fallback: "Symbolic Link"),
            "Special File",
            "Free Space",
            "Other Space",
        ]
        for name in reserved {
            kindOfExtension.append(intern(name, family: .data))
            extensionIsPackage.append(false)
        }
        folder = kindOfExtension[Int(ReservedExtension.folder)]
        freeSpace = kindOfExtension[Int(ReservedExtension.freeSpace)]
        otherSpace = kindOfExtension[Int(ReservedExtension.otherSpace)]
    }

    private mutating func intern(_ name: String, family: KindFamily) -> KindID {
        if let id = kindIDsByName[name] { return id }
        guard kinds.count < Int(KindID.max) else { return 0 }
        let id = KindID(kinds.count)
        kinds.append(FileKind(name: name, family: family))
        kindIDsByName[name] = id
        return id
    }

    /// Looks up everything the registry has learned since the last call.
    mutating func resolve(extensions names: [String]) {
        guard names.count > resolvedExtensions else { return }
        let pending = Array(names[resolvedExtensions...])
        let results = Self.classify(pending)
        for result in results {
            kindOfExtension.append(intern(result.kind, family: result.family))
            extensionIsPackage.append(result.isPackage)
        }
        resolvedExtensions = names.count
    }

    private static func describe(_ type: UTType, fallback: String) -> String {
        capitalized(type.localizedDescription ?? fallback)
    }

    /// Recent versions of macOS describe types in lower case, as if mid-sentence.
    private static func capitalized(_ description: String) -> String {
        description.prefix(1).uppercased() + description.dropFirst()
    }

    /// The order matters: an Office document is also a zip archive, and source code is also text.
    private static func family(of type: UTType) -> KindFamily {
        func isAny(_ types: UTType...) -> Bool { types.contains { type.conforms(to: $0) } }
        if isAny(.audio) { return .audio }
        if isAny(.movie, .audiovisualContent) { return .video }
        if isAny(.image) { return .image }
        if isAny(.application, .applicationBundle) { return .application }
        if isAny(.sourceCode, .script, .json, .xml, .propertyList, .commaSeparatedText, .tabSeparatedText, .log) {
            return .data
        }
        if isAny(.compositeContent, .presentation, .spreadsheet, .pdf, .epub, .emailMessage, .text) { return .document }
        if isAny(.archive, .diskImage) { return .archive }
        // Installers can be bundles, which macOS doesn't count as archives. To a person they are one.
        return type.identifier.hasPrefix("com.apple.installer-") ? .archive : .data
    }

    private static func classify(_ names: [String]) -> [Classification] {
        let results = ClassificationResults(count: names.count)
        DispatchQueue.concurrentPerform(iterations: names.count) { index in
            let name = names[index]
            let fallback = "\(name.uppercased()) File"
            // The lookup only considers types conforming to what it is told, and by default that
            // is plain data, which packages are not. So they take a lookup of their own.
            if let package = UTType(filenameExtension: name, conformingTo: .package), !package.isDynamic {
                let kind = describe(package, fallback: fallback)
                results.store(Classification(kind: kind, isPackage: true, family: family(of: package)), at: index)
            } else if let type = UTType(filenameExtension: name), !type.isDynamic {
                let kind = describe(type, fallback: fallback)
                results.store(Classification(kind: kind, isPackage: false, family: family(of: type)), at: index)
            } else {
                results.store(Classification(kind: fallback, isPackage: false, family: .data), at: index)
            }
        }
        return results.values
    }
}

/// What is known about an extension.
private struct Classification {
    var kind = ""
    var isPackage = false
    var family = KindFamily.data
}

/// Lets `concurrentPerform` iterations write to distinct slots of one buffer.
private final class ClassificationResults: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Classification>

    init(count: Int) {
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: Classification())
    }

    deinit {
        buffer.deinitialize()
        buffer.deallocate()
    }

    func store(_ value: Classification, at index: Int) {
        buffer[index] = value
    }

    var values: [Classification] {
        Array(buffer)
    }
}

/// Finds the extension of a file name and hashes it, ignoring case.
///
/// Only returns something that plausibly is an extension. Purely numeric suffixes are rejected
/// so that rotated logs (`.1`) and version numbers don't each become a kind of their own.
@inline(__always)
func fileExtension(
    of name: UnsafePointer<UInt8>,
    length: Int
) -> (hash: UInt64, start: Int, length: Int)? {
    let maximumLength = 16
    var index = length - 1
    let lowest = max(1, length - maximumLength - 1)
    var hasLetter = false
    while index >= lowest {
        let byte = name[index]
        if byte == UInt8(ascii: ".") { break }
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            hasLetter = true
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "+"):
            break
        default:
            return nil
        }
        index -= 1
    }
    guard index >= lowest, name[index] == UInt8(ascii: "."), index < length - 1, hasLetter else {
        return nil
    }
    let start = index + 1
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for position in start..<length {
        hash = (hash ^ UInt64(lowercased(name[position]))) &* 0x0000_0100_0000_01b3
    }
    return (hash, start, length - start)
}

@inline(__always)
func lowercased(_ byte: UInt8) -> UInt8 {
    (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte | 0x20 : byte
}
