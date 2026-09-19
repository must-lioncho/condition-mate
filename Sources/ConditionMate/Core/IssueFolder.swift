import Foundation

// Where a delegation issue file is CREATED. One source of truth, so no call site has to
// decide between "the folder the agent was invoked in" and "the folder the user picked".
//
// WHY this is not IssuePaths: IssuePaths.root is the goal store (goal-NN folders +
// attachments + per-goal chat) and lives under AppPaths.base. Repointing that root would
// orphan every existing goal folder. An issue is a different object — it belongs to the
// PROJECT the work was delegated from, not to the app's own data dir — so it gets its own
// resolver and its own setting.
//
// Two layers, in order:
//   1. cm.issueFolder — an explicit folder the user picked in 설정. Wins whenever set.
//   2. the invoking session's working directory — <cwd>/issue. This is the default the
//      user asked for: "에이전트를 부르는 곳에 생기는 거고". Delegating from lion_work puts
//      the issue in lion_work; delegating from a project puts it in that project. Nothing
//      to configure per project, which is the point when 40 of them run in parallel.
//   3. AppPaths.sub("issue") — last resort only, when the caller has no cwd at all
//      (e.g. an issue created from a menu action outside any session).
//
// ASSUMPTIONS recorded here because this was executed without asking (L1):
//   - The default appends "issue" to the cwd rather than dropping .md files loose in the
//     project root. Every repo in this workspace already carries an issue/ folder
//     (lion-condition-mate/issue/*.md), so this matches what is already on disk.
//   - The override is used VERBATIM — no "issue" is appended to it. A folder the user
//     picked by hand is the folder they meant; silently creating a subfolder inside it
//     would mean the path shown in 설정 is not the path files land in.
//   - "issue" is singular, matching this app's own vocabulary (IssuePaths,
//     AppPaths.sub("issue")). ~/.must-aios/issues (plural) was one hand-typed choice, not
//     a convention, and it becomes just another value of the override.
enum IssueFolder {
    // The user's explicit choice, or nil when they have not made one.
    static var override: URL? {
        let s = (Settings.shared.issueFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
    }

    // True while no override is set — the folder follows whoever invoked the agent.
    static var isDefault: Bool { override == nil }

    // The default folder for a session working in `cwd`. Empty cwd falls back to the app's
    // own store so a caller with no session context still gets a real, writable folder.
    static func defaultRoot(cwd: String) -> URL {
        let c = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return AppPaths.sub("issue") }
        return URL(fileURLWithPath: (c as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("issue", isDirectory: true)
    }

    // THE call site everything else should use: the folder an issue raised by a session
    // working in `cwd` belongs in. Does not touch the disk — see `ensured` for that.
    static func resolved(cwd: String = "") -> URL {
        override ?? defaultRoot(cwd: cwd)
    }

    // Same as `resolved`, but creates the folder so a write can follow immediately.
    // Returns nil when the folder cannot be created (a picked folder that has since been
    // deleted or is not writable) — the caller must say so rather than write elsewhere,
    // since silently relocating an issue is exactly the confusion this setting removes.
    static func ensured(cwd: String = "") -> URL? {
        let url = resolved(cwd: cwd)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return url
    }

    // Persist (or clear) the user's choice. A blank string resets to the cwd default.
    // Tilde is expanded on the way in so what 설정 displays is what the filesystem sees.
    static func setOverride(_ folder: String) {
        let t = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.issueFolder = t.isEmpty ? nil : (t as NSString).expandingTildeInPath
    }

    // Human-facing label for 설정 — either the picked path, or a sentence saying the
    // folder follows the caller. The default has no single path to print, so printing one
    // would be a lie the moment the next session runs somewhere else.
    static var displayLabel: String {
        override?.path ?? "에이전트를 부른 폴더 · <작업폴더>/issue"
    }
}
