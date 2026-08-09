import Foundation

// Read-only loader for the per-track authoring tags file <musicRoot>/bgm-tags.json.
//
// The tags file is authored OFFLINE (gen-bgm-tags.py + a manual pass) and copied into
// the music folder next to the theme subfolders; the app never writes or seeds it.
// Schema (version 1):
//   { "version":1, "tracks":[ { "path":"office/[172] 거대한 약속.mp3", "arc":"peak",
//     "tier":"집중", "purpose":"…", "energy":74, … } ] }
// `path` is the track's path RELATIVE to the music root (the same root BPMLibrary
// scans) and is the join key: theme folder + "/" + filename, or just the filename for
// a root-level file. arc ∈ intro|build|peak|resolve|ambient; tier ∈
// 가볍게|라운지|집중|초집중 (ambient tracks carry no tier).
//
// A missing or unparsable file is a NORMAL state (fresh folder, tags not authored
// yet): the map is simply empty, callers render blank per-track fields, and only a
// log line records it — no banner, no error propagation (workspace rule).
final class BGMTags {

    struct Tag {
        let arc: String        // intro | build | peak | resolve | ambient
        let tier: String       // 가볍게 | 라운지 | 집중 | 초집중 ("" = none, e.g. ambient)
        let purpose: String    // per-track 선곡 목적 copy
        let energy: Int        // 0-100 authored energy (0 = untagged)
    }

    static let fileName = "bgm-tags.json"

    // Relative path (join key, see header) -> tag. Empty when no tags file exists.
    private(set) var byPath: [String: Tag] = [:]

    // (Re)load the tags next to the given music root. Called alongside every
    // library rescan so the map always mirrors the folder the library was built from.
    func load(musicRoot: String) {
        byPath = [:]
        let url = URL(fileURLWithPath: musicRoot, isDirectory: true)
            .appendingPathComponent(Self.fileName)
        guard let data = try? Data(contentsOf: url) else {
            // No tags file — quiet empty map (only a debug-gated trace, not an error).
            if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil {
                AppLog.log("[bgm-tags] no tags file at \(url.path) — per-track tags empty")
            }
            return
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]] else {
            AppLog.log("[bgm-tags] unparsable \(url.path) — per-track tags empty")
            return
        }
        for t in tracks {
            guard let path = t["path"] as? String, !path.isEmpty else { continue }
            byPath[path] = Tag(arc: t["arc"] as? String ?? "",
                               tier: t["tier"] as? String ?? "",
                               purpose: t["purpose"] as? String ?? "",
                               energy: t["energy"] as? Int ?? 0)
        }
        if ProcessInfo.processInfo.environment["CM_DEBUG"] != nil {
            AppLog.log("[bgm-tags] loaded \(byPath.count) tags from \(url.path)")
        }
    }

    // Lookup by the music-root-relative path (the join key).
    func tag(forRelativePath path: String) -> Tag? { byPath[path] }
}
