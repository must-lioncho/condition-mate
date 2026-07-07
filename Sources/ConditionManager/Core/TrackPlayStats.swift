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
//
// Strategy dimension (v2, 2026-07-08): playback time is additionally tagged with the
// BGM selection STRATEGY that produced it, so strategies can be compared in retrospect:
//   전략1 · 액티비티 적응형   — activity-adaptive nearest-BPM only (the original). Its data
//                              showed the problem: a few tracks dominated the play time.
//   전략2 · 모드 플레이리스트 — per-session-mode playlists with pinned openers.
//   전략3 · 플랜 맵          — pre-planned (평일/주말 × 시간대) theme pools (BGMPlanMap);
//                              adaptive selection runs inside the planned pool.
// All data accumulated before v2 is migrated as strategy 1; new time accrues under the
// stored `activeStrategy` (NOT hardcoded — adding a future 전략4 is a data append: a new
// BGMStrategy entry + bumping activeStrategy; see migrateCatalog()).
struct TrackPlayStat: Codable {
    var key: String
    var title: String
    var seconds: Double = 0     // cumulative audible seconds
    var plays: Int = 0          // number of times the director selected this track
    var lastPlayedAt: Double = 0
    var strategy: Int = 1       // BGM strategy this time accrued under (legacy rows = 1)

    enum CodingKeys: String, CodingKey { case key, title, seconds, plays, lastPlayedAt, strategy }

    init(key: String, title: String, seconds: Double = 0, plays: Int = 0,
         lastPlayedAt: Double = 0, strategy: Int = 1) {
        self.key = key; self.title = title; self.seconds = seconds
        self.plays = plays; self.lastPlayedAt = lastPlayedAt; self.strategy = strategy
    }

    // Tolerant decoding: rows written before v2 have no `strategy` field → 전략1.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        lastPlayedAt = try c.decodeIfPresent(Double.self, forKey: .lastPlayedAt) ?? 0
        strategy = try c.decodeIfPresent(Int.self, forKey: .strategy) ?? 1
    }
}

// One BGM selection strategy, for the 액티비티 tab's 전략 히스토리 section (retrospection).
// `endedAt` empty = 진행 중. Stored alongside the stats so retro memos can be edited in
// the same file later (display-only for now).
struct BGMStrategy: Codable {
    var id: Int
    var name: String            // e.g. "액티비티 적응형"
    var startedAt: String       // "yyyy-MM-dd"; empty = unknown (before tracking began)
    var endedAt: String         // "yyyy-MM-dd"; empty = 진행 중
    var summary: String         // one-line description
    var retro: String           // retrospective memo
}

final class TrackPlayStatsStore {

    // Keyed by "\(strategy)|\(filename)" so the same track accrues separately per strategy.
    private(set) var stats: [String: TrackPlayStat] = [:]
    // The strategy new playback time accrues under. Stored in the JSON (seeded, never
    // hardcoded at the accrual sites) so a future strategy switch is a data change.
    private(set) var activeStrategy = 3
    private(set) var strategies: [BGMStrategy] = []

    private let fileURL: URL

    // The known strategies, seeded on migration and on fresh installs. 전략2 began
    // 2026-07-08 (the per-mode playlist change); 전략1 is everything before it. 전략3
    // (플랜 맵) superseded 전략2 the same day — the mode lists remain as its fallback.
    private static let seedStrategies: [BGMStrategy] = [
        BGMStrategy(id: 1, name: "액티비티 적응형", startedAt: "", endedAt: "2026-07-08",
                    summary: "활동 강도만 반영한 적응형 선곡",
                    retro: "특정 곡 편중(상위 1~3곡이 재생시간 독식) 문제로 전략2로 개선"),
        BGMStrategy(id: 2, name: "모드 플레이리스트", startedAt: "2026-07-08", endedAt: "2026-07-08",
                    summary: "포모도로/스프린트/트래커 모드별 플레이리스트 + 고정 첫 곡, BPM 적응은 리스트 내부로 제한",
                    retro: "곡 편중은 줄였지만 요일·시간대 상황을 반영하지 못해 전략3(플랜 맵)으로 확장 — 모드 리스트는 플랜 공백 시 폴백으로 유지"),
        BGMStrategy(id: 3, name: "플랜 맵", startedAt: "2026-07-08", endedAt: "",
                    summary: "요일(평일/주말)×시간대 사전 계획 맵(bgm-plan.json)이 테마 폴더 풀을 지정, 액티비티 적응 선곡은 풀 내부로 제한. 계획은 고급 모델이 미리, 실행은 앱이 즉시",
                    retro: ""),
    ]

    private static func statKey(strategy: Int, key: String) -> String { "\(strategy)|\(key)" }

    init() {
        fileURL = AppPaths.base.appendingPathComponent("track-playstats.json")
        load()
    }

    // Accrue one finished play segment (called when a track stops being audible),
    // tagged with the active strategy.
    func addSeconds(key: String, title: String, seconds: Double) {
        guard seconds > 0 else { return }
        let sk = Self.statKey(strategy: activeStrategy, key: key)
        var s = stats[sk] ?? TrackPlayStat(key: key, title: title, strategy: activeStrategy)
        if !title.isEmpty && title != "-" { s.title = title }
        s.seconds += seconds
        s.lastPlayedAt = Date().timeIntervalSince1970
        stats[sk] = s
        save()
    }

    // Count a fresh selection of this track (a new play() call, not a resume).
    func bumpPlay(key: String, title: String) {
        let sk = Self.statKey(strategy: activeStrategy, key: key)
        var s = stats[sk] ?? TrackPlayStat(key: key, title: title, strategy: activeStrategy)
        if !title.isEmpty && title != "-" { s.title = title }
        s.plays += 1
        s.lastPlayedAt = Date().timeIntervalSince1970
        stats[sk] = s
        save()
    }

    // Per-track totals for one strategy (or merged across all when nil), keyed by
    // filename — the shape bgmStatsJSON ranks. Merging sums seconds/plays and keeps
    // the freshest lastPlayedAt.
    func totals(strategy: Int?) -> [String: TrackPlayStat] {
        var out: [String: TrackPlayStat] = [:]
        for s in stats.values {
            if let want = strategy, s.strategy != want { continue }
            if var acc = out[s.key] {
                acc.seconds += s.seconds
                acc.plays += s.plays
                acc.lastPlayedAt = max(acc.lastPlayedAt, s.lastPlayedAt)
                if !s.title.isEmpty && s.title != "-" { acc.title = s.title }
                out[s.key] = acc
            } else {
                out[s.key] = s
            }
        }
        return out
    }

    // Wipe play history — the dashboard "초기화" button. Scoped to one strategy when
    // given (the ranking filter's selection); nil wipes every strategy's data. The
    // strategy catalog and activeStrategy are never touched by a reset.
    func reset(strategy: Int?) {
        if let want = strategy {
            stats = stats.filter { $0.value.strategy != want }
        } else {
            stats = [:]
        }
        save()
    }

    // MARK: - Persistence

    // v2 file shape. v1 was a bare [TrackPlayStat] array (no strategy field).
    private struct FileV2: Codable {
        var version: Int
        var activeStrategy: Int
        var strategies: [BGMStrategy]
        var stats: [TrackPlayStat]
    }

    private func load() {
        defer { seedStrategiesIfNeeded(); migrateCatalog() }
        guard let data = try? Data(contentsOf: fileURL) else { return }   // fresh install
        if let v2 = try? JSONDecoder().decode(FileV2.self, from: data) {
            activeStrategy = v2.activeStrategy
            strategies = v2.strategies
            stats = Dictionary(v2.stats.map { (Self.statKey(strategy: $0.strategy, key: $0.key), $0) },
                               uniquingKeysWith: { a, _ in a })
            return
        }
        // One-time v1 → v2 migration: everything accumulated so far ran under 전략1
        // (액티비티 적응형), so tag it all strategy 1 and start accruing new time under
        // the newest strategy. Idempotent — once saved as v2 the branch above always wins. The original
        // v1 file is kept as a .v1.bak sibling so no data can be lost by the rewrite.
        guard let list = try? JSONDecoder().decode([TrackPlayStat].self, from: data) else { return }
        let backupURL = fileURL.deletingPathExtension().appendingPathExtension("v1.bak.json")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            try? data.write(to: backupURL, options: .atomic)
        }
        stats = Dictionary(list.map { row -> (String, TrackPlayStat) in
            var s = row
            s.strategy = 1
            return (Self.statKey(strategy: 1, key: s.key), s)
        }, uniquingKeysWith: { a, _ in a })
        activeStrategy = 3
        strategies = Self.seedStrategies
        save()
    }

    // Fresh installs (and any file missing the catalog) still get the strategy history
    // and the active id; existing catalogs are left untouched (retro memos are edited
    // in the stored file, not re-seeded).
    private func seedStrategiesIfNeeded() {
        guard strategies.isEmpty else { return }
        strategies = Self.seedStrategies
        save()
    }

    // One-time 전략2 → 전략3 catalog migration for files saved before 전략3 existed:
    // close 전략2 (if still open), append the 전략3 entry, and point new accrual at it.
    // Idempotent — once the catalog contains id 3 this is a no-op, so user-edited
    // retro memos are never overwritten.
    private func migrateCatalog() {
        guard !strategies.contains(where: { $0.id == 3 }) else { return }
        if let i = strategies.firstIndex(where: { $0.id == 2 }) {
            if strategies[i].endedAt.isEmpty { strategies[i].endedAt = "2026-07-08" }
            if strategies[i].retro.isEmpty {
                strategies[i].retro = Self.seedStrategies[1].retro
            }
        }
        strategies.append(Self.seedStrategies[2])
        activeStrategy = 3
        save()
    }

    private func save() {
        let file = FileV2(version: 2, activeStrategy: activeStrategy,
                          strategies: strategies, stats: Array(stats.values))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
