import Foundation
import AVFoundation

// Scans a folder of audio files and indexes each track by BPM.
//
// BPM resolution order:
//   1. Filename convention  (e.g. "Track [128].mp3", "128bpm.mp3", "Track - 128.mp3")
//   2. Embedded metadata    (ID3 TBPM / iTunes beatsPerMinute)
// Files with no resolvable BPM are kept with a neutral defaultBPM (전략3's themed
// folders ship untagged, and skipping them would empty every plan-map pool); the
// unresolved count is still exposed as skippedCount for the debug log.
//
// Each track also carries its THEME: the first subfolder under the scan root
// (bgm/ship/... → "ship", a root-level file → ""). The 전략3 plan map addresses
// pools by these folder names.
final class BPMLibrary {

    struct Track {
        let url: URL
        let bpm: Double
        let title: String
        let theme: String          // first subfolder under the scan root ("" = root)
        let bpmResolved: Bool      // false = defaultBPM assigned (no filename/metadata BPM)
    }

    // Neutral tempo for untagged tracks: mid-band, so they neither hijack the
    // warmup floor nor the sustain ceiling. Within a plan pool of untagged tracks
    // the director rotates by recency instead of BPM distance.
    static let defaultBPM: Double = 110

    private(set) var tracks: [Track] = []
    private(set) var skippedCount: Int = 0

    private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf"]

    func load(folderPath: String) {
        tracks.removeAll()
        skippedCount = 0

        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let rootDepth = folder.standardizedFileURL.pathComponents.count
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let resolved = resolveBPM(for: url)
            if resolved == nil { skippedCount += 1 }
            let title = url.deletingPathExtension().lastPathComponent
            let comps = url.standardizedFileURL.pathComponents
            let theme = comps.count > rootDepth + 1 ? comps[rootDepth] : ""
            tracks.append(Track(url: url, bpm: resolved ?? Self.defaultBPM, title: title,
                                theme: theme, bpmResolved: resolved != nil))
        }
        tracks.sort { $0.bpm < $1.bpm }
    }

    // Closest track to a target BPM, optionally excluding the currently playing url.
    //
    // `penalty` adds "virtual BPM" distance to a track (learned dis-preference),
    // so a disliked track ranks below a slightly-further-but-liked one. `blocked`
    // skips a track entirely (post-dislike cooldown). Both default to no-ops, so
    // the plain nearest-BPM behavior is unchanged for callers that don't pass them.
    // If every non-excluded track is blocked, we fall back to the blocked pool
    // rather than going silent.
    func track(forTargetBPM target: Double,
               excluding: URL? = nil,
               penalty: (Track) -> Double = { _ in 0 },
               blocked: (Track) -> Bool = { _ in false }) -> Track? {
        let notExcluded = tracks.filter { $0.url != excluding }
        let base = notExcluded.isEmpty ? tracks : notExcluded
        let allowed = base.filter { !blocked($0) }
        let pool = allowed.isEmpty ? base : allowed
        return pool.min {
            (abs($0.bpm - target) + penalty($0)) < (abs($1.bpm - target) + penalty($1))
        }
    }

    var bpmRange: (min: Double, max: Double)? {
        guard let lo = tracks.first?.bpm, let hi = tracks.last?.bpm else { return nil }
        return (lo, hi)
    }

    // First track whose filename contains the given keyword (case-insensitive).
    // Used for scene mapping: the user pins specific songs to specific moments
    // (opening / settle / release) by name rather than by nearest BPM.
    func track(matchingKeyword keyword: String) -> Track? {
        tracks.first { $0.url.lastPathComponent.localizedCaseInsensitiveContains(keyword) }
    }

    // Exact-filename lookup. The per-mode playlists pin tracks by their stable
    // filename (including the [BPM] prefix) rather than a fuzzy keyword, so two
    // tracks sharing a title at different BPMs (e.g. the two Neural Ops Room
    // files) can't be confused.
    func track(named filename: String) -> Track? {
        tracks.first { $0.url.lastPathComponent == filename }
    }

    // MARK: - BPM parsing

    private func resolveBPM(for url: URL) -> Double? {
        if let fromName = bpmFromFilename(url.lastPathComponent) {
            return fromName
        }
        return bpmFromMetadata(url)
    }

    private func bpmFromFilename(_ name: String) -> Double? {
        // Patterns tried in order of confidence.
        let patterns = [
            #"(\d{2,3})\s*bpm"#,   // 128bpm / 128 BPM
            #"\[(\d{2,3})\]"#,      // [128]
            #"\((\d{2,3})\)"#,      // (128)
            #"[-_ ](\d{2,3})(?:[-_. ]|$)"# // Track - 128.mp3
        ]
        let lower = name.lowercased()
        for pattern in patterns {
            if let value = firstCapture(in: lower, pattern: pattern),
               let bpm = Double(value), (40...220).contains(bpm) {
                return bpm
            }
        }
        return nil
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func bpmFromMetadata(_ url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        // Best-effort read of already-available metadata. We match by identifier
        // string so it works for both ID3 (TBPM) and iTunes beatsPerMinute tags
        // without depending on SDK-version-specific symbols.
        for item in asset.metadata {
            let idString = item.identifier?.rawValue.lowercased() ?? ""
            let isBPM = idString.contains("bpm")
                || idString.contains("beatsperminute")
                || idString.contains("tbpm")
            guard isBPM else { continue }
            if let num = item.numberValue?.doubleValue, (40...220).contains(num) {
                return num
            }
            if let str = item.stringValue, let num = Double(str), (40...220).contains(num) {
                return num
            }
        }
        return nil
    }
}
