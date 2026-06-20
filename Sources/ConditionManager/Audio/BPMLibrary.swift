import Foundation
import AVFoundation

// Scans a folder of audio files and indexes each track by BPM.
//
// BPM resolution order:
//   1. Filename convention  (e.g. "Track [128].mp3", "128bpm.mp3", "Track - 128.mp3")
//   2. Embedded metadata    (ID3 TBPM / iTunes beatsPerMinute)
// Files with no resolvable BPM are skipped (logged count is exposed).
final class BPMLibrary {

    struct Track {
        let url: URL
        let bpm: Double
        let title: String
    }

    private(set) var tracks: [Track] = []
    private(set) var skippedCount: Int = 0

    private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf"]

    func load(folderPath: String) {
        tracks.removeAll()
        skippedCount = 0

        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if let bpm = resolveBPM(for: url) {
                let title = url.deletingPathExtension().lastPathComponent
                tracks.append(Track(url: url, bpm: bpm, title: title))
            } else {
                skippedCount += 1
            }
        }
        tracks.sort { $0.bpm < $1.bpm }
    }

    // Closest track to a target BPM, optionally excluding the currently playing url.
    func track(forTargetBPM target: Double, excluding: URL? = nil) -> Track? {
        let candidates = tracks.filter { $0.url != excluding }
        let pool = candidates.isEmpty ? tracks : candidates
        return pool.min { abs($0.bpm - target) < abs($1.bpm - target) }
    }

    var bpmRange: (min: Double, max: Double)? {
        guard let lo = tracks.first?.bpm, let hi = tracks.last?.bpm else { return nil }
        return (lo, hi)
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
