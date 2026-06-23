import Foundation

// Single source for the data directory. Overridable via CM_DATA_DIR so tests
// (and throwaway runs) never touch the user's real Application Support data.
enum AppPaths {
    // Project root when running a dev build, derived from the executable path: a SwiftPM
    // binary lives at <root>/.build/.../ConditionManager. Returns nil for a packaged/
    // installed app (no "/.build/" segment), which then uses the Application Support store.
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
        // 3. Installed app default.
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConditionManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func sub(_ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // True when NOT using the real Application Support store — i.e. a CM_DATA_DIR override
    // or a dev build running out of <root>/.localdata. Surfaced in the dashboard as a "DEV"
    // badge so the active dataset is never mistaken for production, and used to keep the
    // Policy 3 title stamper from mutating the real Claude store during dev runs.
    static var isCustom: Bool {
        if !(ProcessInfo.processInfo.environment["CM_DATA_DIR"] ?? "").isEmpty { return true }
        return devProjectRoot != nil
    }
    // Short label for the active data dir (its folder name), shown next to the badge.
    static var label: String { base.lastPathComponent }
}
