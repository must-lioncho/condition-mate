import Foundation

// Resolves the per-goal folder used to keep a goal's definition and attachments
// together under one number-named folder (goal-NN). On a dev build the folders
// live in <repo>/.issue so they are git-tracked and browsable; otherwise they
// fall back to <data>/issue. One source of truth so call sites never branch on
// which store is active (mirrors AppPaths.base/sub).
//
// A goal's definition is split into two versions (see .doc/goal-policy.md):
//   goal-core.md   — 핵심 버전 (concise, human/boss-facing report)
//   goal-detail.md — 디테일 버전 (full detail for AI execution)
// Both follow the same four sections: 문제정의·예상결과·예상해결방안·예상테스트시나리오.
enum IssuePaths {
    // The root that holds every goal-NN folder: <data>/issue, always. Dev builds used to
    // keep goals in <repo>/.issue (git-tracked), but that split the goal set from the
    // installed app's ~/.condition-manager/issue — the same dev/prod divergence that made
    // data "disappear". Unified 2026-07-09 with AppPaths.base: every build follows the
    // active data dir, so a CM_DATA_DIR override (tests) still isolates automatically.
    static var root: URL {
        AppPaths.sub("issue")
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

    // One subtask's folder under goal-NN/tasks/<task>. The subtask page roots its docs,
    // chat, attachments and CLI here so each subtask is worked on in isolation. nil for
    // seq <= 0 or a path-unsafe task name (.. / empty rejected). The task name may carry
    // spaces and colons (e.g. "task15-1500:1 KWT-cc2c"), so it is treated as one component.
    static func taskDir(seq: Int, task: String) -> URL? {
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("/"), t != "..", !t.hasPrefix("."),
              let tasks = tasksDir(seq: seq) else { return nil }
        return tasks.appendingPathComponent(t, isDirectory: true)
    }

    // attachments/ subfolder where uploaded files are stored. nil for seq <= 0.
    static func attachmentsDir(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("attachments", isDirectory: true)
    }

    // tasks/ subfolder holding this goal's subtasks. Each child folder is one subtask
    // (Jira-style), optionally carrying a _task.md anchor with frontmatter. Surfaced on
    // the goal page as the 부분과제 section. nil for seq <= 0.
    static func tasksDir(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("tasks", isDirectory: true)
    }

    // The goal definition document (goal.md) inside the goal folder. Legacy single
    // version, now superseded by the core/detail split below; still resolved for
    // lazy migration into goal-detail.md on first page open.
    static func definitionURL(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("goal.md")
    }

    // 핵심 버전 (concise, human-facing) document inside the goal folder.
    static func coreURL(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("goal-core.md")
    }

    // 디테일 버전 (full detail for AI) document inside the goal folder.
    static func detailURL(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("goal-detail.md")
    }

    // Folder holding the per-goal "목표 명확화" chat (its own ChatStore lives here),
    // kept separate from attachments/ so chat images never mix with evidence files.
    static func chatDir(seq: Int) -> URL? {
        goalDir(seq: seq)?.appendingPathComponent("chat", isDirectory: true)
    }

    // Legacy flat definition doc (.issue/goal-NN.md) from before the folder layout.
    // Used for lazy migration into goalDir/goal-detail.md on first page open.
    static func legacyDefinitionURL(seq: Int) -> URL? {
        guard let name = label(seq: seq) else { return nil }
        return root.appendingPathComponent(name + ".md")
    }
}
