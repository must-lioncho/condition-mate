import Foundation

// Learned per-track preference, driven by explicit (dislike button) and — later —
// implicit (volume-down) signals. See .issue/goal-11.md.
//
// Identity is the file name, matching how BPMLibrary derives a track's title, so
// the preference survives library re-scans as long as the file stays put.
//
// `score` is a 0...1 weight where 1.0 is neutral/preferred. A dislike lowers it
// and also opens a short "cooldown" during which the track is skipped outright.
// After the cooldown the track is merely down-weighted (not banned), and the
// score decays back toward neutral over a few days so a one-off mood doesn't
// blacklist a track forever.
struct TrackPreference: Codable {
    var key: String
    var score: Double = 1.0      // 0...1, 1 = neutral
    var dislikeCount: Int = 0
    var lastSignalAt: Double = 0 // epoch seconds of the last signal
    var cooldownUntil: Double = 0 // epoch seconds; while > now the track is skipped
}

final class TrackPreferenceStore {

    private(set) var prefs: [String: TrackPreference] = [:]
    private let fileURL: URL

    // Tunables (see goal-11 open questions).
    private let dislikePenalty = 0.5     // score drop per dislike
    private let penaltyScaleBPM = 40.0   // score 0 => +40 "virtual BPM" of distance
    private let recoveryHalfLifeDays = 3.0 // how fast score climbs back to 1.0

    init() {
        fileURL = AppPaths.base.appendingPathComponent("track-prefs.json")
        load()
    }

    // MARK: - Signals

    // Record an explicit dislike: drop the (decayed) score further and start a
    // cooldown window during which the track is excluded from selection.
    func recordDislike(key: String, at now: Date, cooldown: TimeInterval) {
        let t = now.timeIntervalSince1970
        var p = prefs[key] ?? TrackPreference(key: key)
        let current = decayedScore(p, now: t)
        p.score = max(0.0, current - dislikePenalty)
        p.dislikeCount += 1
        p.lastSignalAt = t
        p.cooldownUntil = t + cooldown
        prefs[key] = p
        save()
    }

    // MARK: - Selection inputs

    // Extra "virtual BPM" distance for a track, so a disliked track ranks lower
    // than a slightly-further-but-liked one. 0 for neutral/unknown tracks.
    func bpmPenalty(key: String, now: Date) -> Double {
        guard let p = prefs[key] else { return 0 }
        let s = decayedScore(p, now: now.timeIntervalSince1970)
        return (1.0 - s) * penaltyScaleBPM
    }

    // Whether the track is in its post-dislike cooldown and should be skipped.
    func isBlocked(key: String, now: Date) -> Bool {
        guard let p = prefs[key] else { return false }
        return p.cooldownUntil > now.timeIntervalSince1970
    }

    // MARK: - Decay

    // Score recovers from its stored value at lastSignalAt back toward 1.0 with a
    // fixed half-life, so negative signals fade unless reinforced.
    private func decayedScore(_ p: TrackPreference, now: Double) -> Double {
        guard p.score < 1.0 else { return 1.0 }
        let elapsedDays = max(0, (now - p.lastSignalAt) / 86400)
        let gap = 1.0 - p.score
        let recovered = 1.0 - gap * pow(0.5, elapsedDays / recoveryHalfLifeDays)
        return min(1.0, max(0.0, recovered))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TrackPreference].self, from: data) else { return }
        prefs = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(prefs.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
