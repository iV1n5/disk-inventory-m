import Darwin
import Foundation

/// How sure it is that something can go.
public enum CleanupSafety: String, Sendable, Decodable {
    /// Rebuilt or downloaded again when needed: the worst that can happen is a slower start.
    case safe
    /// It might matter to someone, so a person should look first.
    case review
}

/// What is offered for something that could go.
public enum CleanupAction: String, Sendable, Decodable {
    /// Moving it to the Trash, which can be undone.
    case trash
    /// A command for the Terminal. The tool that made the files knows best how to clean them up.
    case command
    /// Only pointing it out.
    case reveal
}

/// One thing that tends to take up space for no good reason. These live in
/// `Resources/CleanupRules.json`, in order: the first rule to claim an item keeps it, so specific
/// rules go before general ones.
///
/// A path starts with `~`, `$TMPDIR` or `/`. Its components may use `*`, and `**` stands for any
/// depth, leaving out hidden folders, `Library` and packages, where tools keep copies of their own.
public struct CleanupRule: Sendable, Decodable, Identifiable {
    public let id: String
    public let title: String
    public let why: String
    public let paths: [String]
    public let safety: CleanupSafety
    public let action: CleanupAction
    public let command: String?
    /// Names to leave alone, among what `paths` matches.
    public let except: [String]?
    /// Leaves alone what changed more recently than this.
    public let olderThanDays: Int?

    public static func load(from data: Data) throws -> [CleanupRule] {
        try JSONDecoder().decode([CleanupRule].self, from: data)
    }
}

/// What a rule found in a tree.
public struct CleanupSuggestion: Sendable {
    public let rule: CleanupRule
    /// Largest first.
    public let nodes: [NodeID]
    public let bytes: UInt64
}

/// What rules are matched against, besides the tree.
public struct CleanupContext: Sendable {
    public var home: String
    public var temporary: String
    public var now = Date()
    /// Below this size in bytes, a suggestion isn't worth anyone's time.
    public var smallest: UInt64 = 1_000_000

    public init(home: String = NSHomeDirectory(), temporary: String = NSTemporaryDirectory()) {
        self.home = Self.realPath(home)
        self.temporary = Self.realPath(temporary)
    }

    /// Scans report real paths, and the temporary folder is behind a symlink.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func expand(_ pattern: String) -> String {
        if pattern == "~" || pattern.hasPrefix("~/") { return home + pattern.dropFirst() }
        if pattern.hasPrefix("$TMPDIR") { return temporary + pattern.dropFirst("$TMPDIR".count) }
        return pattern
    }
}

extension FileTree {
    /// What the rules find here, with what is safe first and the largest first within that.
    public func cleanupSuggestions(
        rules: [CleanupRule],
        context: CleanupContext,
        options: DisplayOptions
    ) -> [CleanupSuggestion] {
        let mode = options.sizeMode
        let oldest = context.now.timeIntervalSince1970
        // Claims keep anything from being counted twice, through itself or through a parent.
        var claimed = Set<NodeID>()
        var aboveClaimed = Set<NodeID>()
        var suggestions: [CleanupSuggestion] = []

        for rule in rules {
            let limit = rule.olderThanDays.map { oldest - Double($0) * 86400 }
            var found: [NodeID] = []
            for pattern in rule.paths {
                for id in matches(of: context.expand(pattern)) {
                    let node = nodes[Int(id)]
                    guard node.size(mode) > 0, !node.flags.contains(.symlink) else { continue }
                    if let limit, Double(node.modificationTime) > limit { continue }
                    if let except = rule.except, except.contains(where: { fnmatch($0, name(of: id), 0) == 0 }) { continue }
                    let ancestry = ancestry(of: id)
                    guard !aboveClaimed.contains(id), !ancestry.contains(where: claimed.contains) else { continue }
                    found.append(id)
                }
            }
            let bytes = found.reduce(UInt64(0)) { $0 + size(of: $1, mode) }
            guard bytes >= context.smallest else { continue }
            for id in found {
                claimed.insert(id)
                aboveClaimed.formUnion(ancestry(of: id).dropLast())
            }
            found.sort { size(of: $0, mode) > size(of: $1, mode) }
            suggestions.append(CleanupSuggestion(rule: rule, nodes: found, bytes: bytes))
        }
        suggestions.sort {
            $0.rule.safety == $1.rule.safety ? $0.bytes > $1.bytes : $0.rule.safety == .safe
        }
        return suggestions
    }

    /// What a path pattern leads to in this tree. Anything outside of it leads nowhere.
    private func matches(of pattern: String) -> [NodeID] {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard pattern.hasPrefix(prefix) else { return [] }
        let components = pattern.dropFirst(prefix.count).split(separator: "/").map(String.init)
        var current = [root]
        var index = 0
        while index < components.count {
            let component = components[index]
            if component == "**", index + 1 < components.count {
                current = folders(named: components[index + 1], below: current)
                index += 2
                continue
            }
            current = current.flatMap { parent in
                children(of: parent).filter { fnmatch(component, name(of: $0), 0) == 0 }
            }
            index += 1
        }
        return current
    }

    private func folders(named name: String, below start: [NodeID]) -> [NodeID] {
        let wanted = Array(name.utf8)
        let library = Array("Library".utf8)
        var found: [NodeID] = []
        var pending = start
        while let folder = pending.popLast() {
            for child in children(of: folder) {
                let node = nodes[Int(child)]
                guard node.isDirectory, !node.flags.contains(.package) else { continue }
                let bytes = nameBytes(of: child)
                if bytes.elementsEqual(wanted) {
                    found.append(child)
                } else if bytes.first != UInt8(ascii: "."), !bytes.elementsEqual(library) {
                    pending.append(child)
                }
            }
        }
        return found
    }
}
