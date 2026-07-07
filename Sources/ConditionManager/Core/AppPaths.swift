import Foundation

// Single source for the data directory. Overridable via CM_DATA_DIR so tests
// (and throwaway runs) never touch the user's real ~/.condition-manager data.
enum AppPaths {
    // Project root when running a dev build, derived from the executable path: a SwiftPM
    // binary lives at <root>/.build/.../ConditionManager. Returns nil for a packaged/
    // installed app (no "/.build/" segment), which then uses the ~/.condition-manager store.
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
        // 2. Dev build: keep the store next to the code in <root>/.localdata, regardless of
        //    how the binary was launched (raw exec or dev-run.sh). This makes the data dir
        //    launch-independent, so a raw launch and dev-run can never diverge into two stores.
        if let root = devProjectRoot {
            let url = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(".localdata", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        // 3. Installed/normal default: a single home-profile store at ~/.condition-manager.
        //    Unifies what used to be split between ~/Library/Application Support/ConditionManager
        //    and the workspace-level .condition-manager. Dev builds still isolate into
        //    <root>/.localdata (case 2), so dev runs never touch this production store.
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".condition-manager", isDirectory: true)
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

    // True when NOT using the real ~/.condition-manager store — i.e. a CM_DATA_DIR override
    // or a dev build running out of <root>/.localdata. Surfaced in the dashboard as a "DEV"
    // badge so the active dataset is never mistaken for production, and used to keep the
    // Policy 3 title stamper from mutating the real Claude store during dev runs.
    static var isCustom: Bool {
        if !(ProcessInfo.processInfo.environment["CM_DATA_DIR"] ?? "").isEmpty { return true }
        return devProjectRoot != nil
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
