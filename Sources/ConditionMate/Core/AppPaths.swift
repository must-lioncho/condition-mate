import Foundation

// Single source for the data directory. Overridable via CM_DATA_DIR so tests
// (and throwaway runs) never touch the user's real ~/.condition-mate data.
enum AppPaths {
    // Project root when running a dev build, derived from the executable path: a SwiftPM
    // binary lives at <root>/.build/.../ConditionMate. Returns nil for a packaged/
    // installed app (no "/.build/" segment), which then uses the ~/.condition-mate store.
    private static var devProjectRoot: String? {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).path
        guard let r = exe.range(of: "/.build/") else { return nil }
        return String(exe[..<r.lowerBound])
    }

    static var base: URL {
        // 1. Explicit override (tests / throwaway runs) always wins.
        if let custom = ProcessInfo.processInfo.environment["CM_DATA_DIR"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // 2. Single store for EVERY build: ~/.condition-mate. Dev builds used to isolate
        //    into <root>/.localdata, but running dev and prod against two stores made data
        //    "disappear" whenever the user switched apps (goals/settings/stats diverged per
        //    store). Unified 2026-07-09: dev, dev-watch, and the installed app all read and
        //    write the same home-profile store; only an explicit CM_DATA_DIR (case 1) isolates.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".condition-mate", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Repo working-tree root when running a dev build (binary under <root>/.build/),
    // else nil for a packaged/installed app. Used by IssuePaths to keep per-goal
    // folders (definition + attachments) git-tracked under <root>/.issue.
    static var projectRoot: URL? {
        guard let root = devProjectRoot else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    static func sub(_ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // True when NOT using the real ~/.condition-mate store — i.e. an explicit CM_DATA_DIR
    // override (tests / throwaway runs). Surfaced in the dashboard as a "DEV" badge so the
    // active dataset is never mistaken for production, and used to keep the Policy 3 title
    // stamper from mutating the real Claude store during isolated runs. Dev builds no longer
    // count as custom: since the 2026-07-09 unification they share the production store. A
    // CM_DATA_DIR that RESOLVES to the home store (e.g. injected by .claude settings) is the
    // real store, not an isolation — compare resolved paths, not mere env presence.
    static var isCustom: Bool {
        let override = ProcessInfo.processInfo.environment["CM_DATA_DIR"] ?? ""
        guard !override.isEmpty else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".condition-mate", isDirectory: true)
        return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL.path
            != home.standardizedFileURL.path
    }
    // Short label for the active data dir (its folder name), shown next to the badge.
    static var label: String { base.lastPathComponent }

    // Dev-mode flag, set by Scripts/dev-watch.sh (CM_DEV=1). When on, the app must not grab
    // the foreground or pop its window in front on a rebuild-relaunch — a watch loop restarts
    // the process on every save, so an intrusive relaunch keeps covering the editor. The switch
    // is EXPLICIT (env only), never inferred, so packaged/installed and dev-run behavior are
    // unchanged unless the watch loop opts in.
    static var isDev: Bool {
        !(ProcessInfo.processInfo.environment["CM_DEV"] ?? "").isEmpty
    }

    // Opt back into launch auto-open while in dev, for sessions where you ARE iterating on the
    // dashboard UI and want to see it after each rebuild (CM_DEV_AUTO_OPEN=1). Off by default so
    // the common case (working in the editor) is never interrupted.
    static var devAutoOpen: Bool {
        !(ProcessInfo.processInfo.environment["CM_DEV_AUTO_OPEN"] ?? "").isEmpty
    }
}
