import Foundation

// Single source for the data directory. Overridable via CM_DATA_DIR so tests
// (and throwaway runs) never touch the user's real Application Support data.
enum AppPaths {
    static var base: URL {
        if let custom = ProcessInfo.processInfo.environment["CM_DATA_DIR"], !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
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

    // True when the data dir was overridden via CM_DATA_DIR (a dev/throwaway run),
    // i.e. NOT the real Application Support store. Surfaced in the dashboard as a
    // "DEV" badge so the active dataset is never mistaken for production.
    static var isCustom: Bool {
        !(ProcessInfo.processInfo.environment["CM_DATA_DIR"] ?? "").isEmpty
    }
    // Short label for the active data dir (its folder name), shown next to the badge.
    static var label: String { base.lastPathComponent }
}
