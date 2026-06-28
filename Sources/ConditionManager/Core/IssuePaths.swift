import Foundation

// Resolves the per-goal folder used to keep a goal's definition and attachments
// together under one number-named folder (goal-NN). On a dev build the folders
// live in <repo>/.claude/issue so they are git-tracked and browsable; otherwise
// they fall back to <data>/issue. One source of truth so call sites never branch
// on which store is active (mirrors AppPaths.base/sub).
enum IssuePaths {
    // The root that holds every goal-NN folder. An explicit CM_DATA_DIR override
    // (tests / throwaway runs) always wins and stays inside that data dir, so tests
    // never write into the real repo. A normal dev build uses the git-tracked
    // <repo>/.claude/issue; an installed app falls back to <data>/issue.
    static var root: URL {
        let override = ProcessInfo.processInfo.environment["CM_DATA_DIR"] ?? ""
        let url: URL
        if override.isEmpty, let proj = AppPaths.projectRoot {
            url = proj.appendingPathComponent(".claude/issue", isDirectory: true)
        } else {
            url = AppPaths.sub("issue")
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // "goal-07" style label (seq zero-padded to two digits). nil for an
    // unnumbered goal (seq <= 0), which gets no folder until a number is assigned.
    static func label(seq: Int) -> String? {
        guard seq > 0 else { return nil }
        return "goal-" + (seq < 10 ? "0" : "") + String(seq)
    }

    // Folder holding one goal's definition + attachments. nil for seq <= 0.
    static func goalDir(seq: Int) -> URL? {
        guard let name = label(seq: seq) else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    // attachments/ subfolder where uploaded files are stored. nil for seq <= 0.
    static func attachmentsDir(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("attachments", isDirectory: true)
    }

    // The goal definition document (goal.md) inside the goal folder.
    static func definitionURL(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("goal.md")
    }

    // Legacy flat definition doc (.claude/issue/goal-NN.md) from before the folder
    // layout. Used for lazy migration into goalDir/goal.md on first page open.
    static func legacyDefinitionURL(seq: Int) -> URL? {
        guard let name = label(seq: seq) else { return nil }
        return root.appendingPathComponent(name + ".md")
    }
}
