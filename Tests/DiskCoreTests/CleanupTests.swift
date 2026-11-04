import Foundation
import Testing
@testable import DiskCore

@Suite struct CleanupTests {
    private func rule(
        _ id: String,
        _ paths: [String],
        safety: String = "safe",
        except: [String]? = nil,
        olderThanDays: Int? = nil
    ) throws -> CleanupRule {
        var fields: [String: Any] = [
            "id": id, "title": id, "why": "because", "paths": paths, "safety": safety, "action": "trash",
        ]
        if let except { fields["except"] = except }
        if let olderThanDays { fields["olderThanDays"] = olderThanDays }
        let data = try JSONSerialization.data(withJSONObject: [fields])
        return try #require(try CleanupRule.load(from: data).first)
    }

    private func suggestions(_ folder: TemporaryFolder, _ rules: [CleanupRule]) throws -> ([CleanupSuggestion], FileTree) {
        let tree = try DiskScanner(path: folder.path).run()
        var context = CleanupContext(home: folder.path, temporary: folder.path + "/temp")
        context.smallest = 10_000
        return (tree.cleanupSuggestions(rules: rules, context: context, options: DisplayOptions()), tree)
    }

    @Test func findsWhatARuleDescribes() throws {
        let folder = try TemporaryFolder()
        try folder.write("Library/Caches/Homebrew/bottle.tar.gz", bytes: 500_000)
        try folder.write("Library/Caches/other/file", bytes: 500_000)

        let (found, tree) = try suggestions(folder, [try rule("brew", ["~/Library/Caches/Homebrew"])])

        #expect(found.count == 1)
        #expect(found[0].nodes == [try tree.id("Library/Caches/Homebrew")])
        #expect(found[0].bytes == tree.size(of: found[0].nodes[0], .physical))
    }

    @Test func leavesOutWhatDoesNotExistOrIsTooSmall() throws {
        let folder = try TemporaryFolder()
        try folder.write("Library/Logs/tiny.log", bytes: 10)

        let (found, _) = try suggestions(folder, [try rule("missing", ["~/nowhere"]), try rule("logs", ["~/Library/Logs/*"])])

        #expect(found.isEmpty)
    }

    @Test func ignoresPathsOutsideTheScan() throws {
        let folder = try TemporaryFolder()
        try folder.write("Library/Logs/app.log", bytes: 500_000)

        let (found, _) = try suggestions(folder, [try rule("elsewhere", ["/private/tmp/*"])])

        #expect(found.isEmpty)
    }

    @Test func wildcardsMatchTheContentsNotTheFolder() throws {
        let folder = try TemporaryFolder()
        try folder.write("temp/old-one", bytes: 500_000)
        try folder.write("temp/old-two", bytes: 400_000)

        let (found, tree) = try suggestions(folder, [try rule("temp", ["$TMPDIR/*"])])

        #expect(found.first?.nodes.count == 2)
        #expect(found.first?.nodes.contains(try tree.id("temp")) == false)
        #expect(found.first?.nodes.first == (try tree.id("temp/old-one")), "largest first")
    }

    @Test func aSpecificRuleWinsOverAGeneralOne() throws {
        let folder = try TemporaryFolder()
        try folder.write("Library/Caches/Google/Chrome/data", bytes: 500_000)
        try folder.write("Library/Caches/Homebrew/bottle", bytes: 500_000)
        try folder.write("Library/Caches/SomeApp/data", bytes: 500_000)

        let (found, tree) = try suggestions(folder, [
            try rule("browsers", ["~/Library/Caches/Google/Chrome"]),
            try rule("brew", ["~/Library/Caches/Homebrew"]),
            try rule("apps", ["~/Library/Caches/*"]),
        ])

        let apps = try #require(found.first { $0.rule.id == "apps" })
        #expect(apps.nodes == [try tree.id("Library/Caches/SomeApp")], "not Homebrew, and not Google above Chrome")
    }

    @Test func exceptionsAreLeftAlone() throws {
        let folder = try TemporaryFolder()
        try folder.write("Library/Caches/com.apple.something/data", bytes: 500_000)
        try folder.write("Library/Caches/SomeApp/data", bytes: 500_000)

        let (found, tree) = try suggestions(folder, [try rule("apps", ["~/Library/Caches/*"], except: ["com.apple.*"])])

        #expect(found.first?.nodes == [try tree.id("Library/Caches/SomeApp")])
    }

    @Test func recentItemsAreLeftAlone() throws {
        let folder = try TemporaryFolder()
        let old = try folder.write("temp/old", bytes: 500_000)
        try folder.write("temp/recent", bytes: 500_000)
        let longAgo = Date(timeIntervalSinceNow: -10 * 86400)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

        let (found, tree) = try suggestions(folder, [try rule("temp", ["$TMPDIR/*"], olderThanDays: 7)])

        #expect(found.first?.nodes == [try tree.id("temp/old")])
    }

    @Test func findsFoldersAtAnyDepthButNotInsideToolsOrEachOther() throws {
        let folder = try TemporaryFolder()
        try folder.write("work/site/node_modules/a/index.js", bytes: 500_000)
        try folder.write("work/site/node_modules/a/node_modules/b/index.js", bytes: 500_000)
        try folder.write("old/deep/down/tool/node_modules/c.js", bytes: 500_000)
        try folder.write(".vscode/extensions/x/node_modules/d.js", bytes: 500_000)
        try folder.write("Library/Application Support/App/node_modules/e.js", bytes: 500_000)
        try folder.write("Some.app/Contents/Resources/node_modules/f.js", bytes: 500_000)

        let (found, tree) = try suggestions(folder, [try rule("modules", ["~/**/node_modules"], safety: "review")])

        let expected = Set([try tree.id("work/site/node_modules"), try tree.id("old/deep/down/tool/node_modules")])
        #expect(Set(try #require(found.first).nodes) == expected)
    }

    @Test func whatIsSafeComesFirstThenTheLargest() throws {
        let folder = try TemporaryFolder()
        try folder.write("a/file", bytes: 900_000)
        try folder.write("b/file", bytes: 100_000)
        try folder.write("c/file", bytes: 300_000)

        let (found, _) = try suggestions(folder, [
            try rule("a", ["~/a"], safety: "review"), try rule("b", ["~/b"]), try rule("c", ["~/c"]),
        ])

        #expect(found.map(\.rule.id) == ["c", "b", "a"])
    }

    // MARK: The catalogue

    private func catalogue() throws -> [CleanupRule] {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try CleanupRule.load(from: Data(contentsOf: project.appendingPathComponent("Resources/CleanupRules.json")))
    }

    @Test func everyRuleIsComplete() throws {
        let rules = try catalogue()
        #expect(rules.count > 30)
        #expect(Set(rules.map(\.id)).count == rules.count, "ids are unique")
        for rule in rules {
            #expect(!rule.title.isEmpty && !rule.why.isEmpty && !rule.paths.isEmpty, "\(rule.id)")
            #expect((rule.action == .command) == (rule.command != nil), "\(rule.id): a command goes with that action only")
            for path in rule.paths {
                #expect(path.hasPrefix("~/") || path.hasPrefix("/") || path.hasPrefix("$TMPDIR/"), "\(path)")
            }
        }
    }

    /// The catalogue is meant to grow, so this is what keeps it from ever pointing at someone's work.
    @Test func noRuleReachesForPersonalFilesOrTheSystem() throws {
        let personal = [
            "~/Documents", "~/Desktop", "~/Pictures", "~/Movies", "~/Music", "~/Public",
            "~/Library/Mail", "~/Library/Messages", "~/Library/Photos", "~/Library/Keychains",
            "~/Library/Mobile Documents", "~/Library/CloudStorage",
        ]
        let system = ["/System", "/usr", "/bin", "/sbin", "/etc", "/Library", "/private/var/db", "/private/var/folders"]
        let wholeFolders = [
            "~", "~/Library", "~/Library/Caches", "~/Library/Logs", "~/Library/Application Support",
            "~/Downloads", "~/.cache", "/Applications", "/private/tmp", "/private/var/tmp", "$TMPDIR",
        ]
        for rule in try catalogue() {
            for path in rule.paths {
                #expect(!(personal + system).contains { path == $0 || path.hasPrefix($0 + "/") }, "\(rule.id): \(path)")
                #expect(!wholeFolders.contains(path), "\(rule.id) would take away \(path) itself")
            }
        }
    }

    @Test func nothingInDownloadsOrTemporaryFoldersGoesWithoutALook() throws {
        for rule in try catalogue() where rule.paths.contains(where: {
            $0.hasPrefix("~/Downloads") || $0.hasPrefix("/private/tmp") || $0.hasPrefix("$TMPDIR") || $0.contains("**")
        }) {
            #expect(rule.safety == .review, "\(rule.id)")
            #expect(rule.olderThanDays != nil, "\(rule.id) must leave recent things alone")
        }
    }

    @Test func commandsNeitherEscalateNorDeleteByHand() throws {
        for rule in try catalogue() {
            guard let command = rule.command else { continue }
            let words = command.split(whereSeparator: { " ;&|".contains($0) }).map(String.init)
            #expect(!words.contains("sudo"), "\(rule.id)")
            #expect(!words.contains("rm"), "\(rule.id)")
        }
    }
}
