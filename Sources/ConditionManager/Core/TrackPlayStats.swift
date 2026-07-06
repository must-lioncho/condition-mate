import Foundation

// Cumulative per-track play time, so the BGM 관리 page can rank tracks by how long
// each has actually been heard — the direct answer to "같은 음원만 도는 것 같은데"
// (is one track dominating?). Identity is the file name (the same key as
// TrackPreference), so stats survive library re-scans as long as the file stays put.
//
// AudioEngine owns the timing: it is the single chokepoint for play/pause/resume/stop
// and knows exactly when a track is audible, so it hands finished segments here via
// addSeconds(...) and bumps the play count via bumpPlay(...) on each fresh selection.
// A long-running track's in-flight segment is folded in at read time (see AppDelegate's
// bgmStatsJSON) so the ranking stays fresh without writing on every tick.
struct TrackPlayStat: Codable {
    var key: String
    var title: String
    var seconds: Double = 0     // cumulative audible seconds
    var plays: Int = 0          // number of times the director selected this track
    var lastPlayedAt: Double = 0
}

final class TrackPlayStatsStore {

    private(set) var stats: [String: TrackPlayStat] = [:]
    private let fileURL: URL

    init() {
        fileURL = AppPaths.base.appendingPathComponent("track-playstats.json")
        load()
    }

    // Accrue one finished play segment (called when a track stops being audible).
    func addSeconds(key: String, title: String, seconds: Double) {
        guard seconds > 0 else { return }
        var s = stats[key] ?? TrackPlayStat(key: key, title: title)
        if !title.isEmpty && title != "-" { s.title = title }
        s.seconds += seconds
        s.lastPlayedAt = Date().timeIntervalSince1970
        stats[key] = s
        save()
    }

    // Count a fresh selection of this track (a new play() call, not a resume).
    func bumpPlay(key: String, title: String) {
        var s = stats[key] ?? TrackPlayStat(key: key, title: title)
        if !title.isEmpty && title != "-" { s.title = title }
        s.plays += 1
        s.lastPlayedAt = Date().timeIntervalSince1970
        stats[key] = s
        save()
    }

    // Wipe all history (dashboard "초기화" button).
    func reset() {
        stats = [:]
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TrackPlayStat].self, from: data) else { return }
        stats = Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(stats.values)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
