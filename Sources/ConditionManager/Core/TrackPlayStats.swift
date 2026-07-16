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
//   전략4 · 상태 인지형      — keeps the plan map as the executing hypothesis and scores
//                              each slot's hit/miss from actions.jsonl feedback (dislike/
//                              mute/completion). Phase 1 observes and displays only —
//                              selection and the plan file are untouched.
// All data accumulated before v2 is migrated as strategy 1; new time accrues under the
// stored `activeStrategy` (NOT hardcoded — adding a future 전략5 is a data append: a new
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
    private(set) var activeStrategy = 5
    private(set) var strategies: [BGMStrategy] = []

    private let fileURL: URL

    // 전략3's retrospective, seeded when the 3→4 migration closes it (and on fresh
    // installs). One constant so the migration and the seed catalog cannot drift.
    private static let strategy3RetroSeed =
        "요일×시간대 사전 계획은 실제로 잘 맞았지만(2026-07-10 00:00 '금 심야·애프터 라운지' 슬롯이 '딱 적절한 타이밍'으로 첫 적중), 계획이 맞는지/틀리는지 검증할 피드백 루프가 없었다 — actions.jsonl 기반 슬롯별 hit/miss 관측·교정 레이어(전략4)로 확장. 플랜 맵은 대체되지 않고 전략4의 실행 가설로 유지."

    // 전략4's retrospective, seeded when the 4→5 migration closes it (and on fresh
    // installs). Same drift-guard role as strategy3RetroSeed.
    private static let strategy4RetroSeed =
        "슬롯별 hit/miss 관측 레이어는 자리를 잡았지만 Phase1이 관측·표시만 하고 선곡을 바꾸지 않아, 챌린지 모드(25분/스프린트/트래커)를 무엇을 골라도 같은 음악이 나오는 문제(플랜 슬롯이 선곡을 독점, 모드 선택이 무의미)가 남았다 — 모드를 BPM 밴드로 선곡에 재연결(전략5). 플랜 pool과 슬롯 hit/miss 채점은 전략5의 실행 가설로 유지."

    // The known strategies, seeded on migration and on fresh installs. 전략2 began
    // 2026-07-08 (the per-mode playlist change); 전략1 is everything before it. 전략3
    // (플랜 맵) superseded 전략2 the same day — the mode lists remain as its fallback.
    // 전략4 (상태 인지형) opened 2026-07-10: the plan map keeps executing while the app
    // scores each slot's hit/miss from actions.jsonl (Phase 1: observe/display only).
    // 전략5 (모드 에너지) opened the same day: it reconnects the challenge mode to
    // selection by targeting a mode-specific BPM region of the same plan pool — the
    // plan pool and slot scoring stay untouched as its hypothesis.
    private static let seedStrategies: [BGMStrategy] = [
        BGMStrategy(id: 1, name: "액티비티 적응형", startedAt: "", endedAt: "2026-07-08",
                    summary: "활동 강도만 반영한 적응형 선곡",
                    retro: "특정 곡 편중(상위 1~3곡이 재생시간 독식) 문제로 전략2로 개선"),
        BGMStrategy(id: 2, name: "모드 플레이리스트", startedAt: "2026-07-08", endedAt: "2026-07-08",
                    summary: "포모도로/스프린트/트래커 모드별 플레이리스트 + 고정 첫 곡, BPM 적응은 리스트 내부로 제한",
                    retro: "곡 편중은 줄였지만 요일·시간대 상황을 반영하지 못해 전략3(플랜 맵)으로 확장 — 모드 리스트는 플랜 공백 시 폴백으로 유지"),
        BGMStrategy(id: 3, name: "플랜 맵", startedAt: "2026-07-08", endedAt: "2026-07-10",
                    summary: "요일(평일/주말)×시간대 사전 계획 맵(bgm-plan.json)이 테마 폴더 풀을 지정, 액티비티 적응 선곡은 풀 내부로 제한. 계획은 고급 모델이 미리, 실행은 앱이 즉시",
                    retro: strategy3RetroSeed),
        BGMStrategy(id: 4, name: "상태 인지형", startedAt: "2026-07-10", endedAt: "2026-07-10",
                    summary: "전략3 플랜 맵을 가설로 유지하고, 컨디션맵 업무시작(8h 갭)·세션 진행/유휴·심야 활동과 actions.jsonl 피드백(싫어요·뮤트·완주)을 슬롯별 hit/miss로 채점하는 폐루프. 계획을 실행하며 동시에 검증·교정. Phase1은 관측·표시만(선곡·플랜 무변경).",
                    retro: strategy4RetroSeed),
        BGMStrategy(id: 5, name: "모드 에너지", startedAt: "2026-07-10", endedAt: "",
                    summary: "전략3 플랜 pool과 전략4 슬롯 관측을 그대로 유지한 채, 챌린지 모드(25분/스프린트/트래커)를 선곡에 재연결. Phase1: 모드마다 플랜 밴드의 다른 BPM 구간(포모도로=집중 중속, 스프린트=고속 상승, 트래커=저속 앰비언트)을 타깃. Phase2: BPM 태그 없는 평탄 풀에서도 파일명 해시 버킷 소프트 페널티로 모드별 선곡을 분리. 게이트(inActivePool)·플랜 맵은 불변.",
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
        activeStrategy = 5
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

    // One-time catalog migrations for files saved before a newer strategy existed:
    // close the previous strategy (if still open), seed its retro (if untouched),
    // append the new entry, and point new accrual at it. Each step is idempotent —
    // once the catalog contains the new id it is a no-op, so user-edited retro memos
    // are never overwritten.
    private func migrateCatalog() {
        var changed = false
        // 2 → 3 (2026-07-08, 플랜 맵).
        if !strategies.contains(where: { $0.id == 3 }) {
            if let i = strategies.firstIndex(where: { $0.id == 2 }) {
                if strategies[i].endedAt.isEmpty { strategies[i].endedAt = "2026-07-08" }
                if strategies[i].retro.isEmpty {
                    strategies[i].retro = Self.seedStrategies[1].retro
                }
            }
            if let entry = Self.seedStrategies.first(where: { $0.id == 3 }) {
                strategies.append(entry)
            }
            activeStrategy = 3
            changed = true
        }
        // 3 → 4 (2026-07-10, 상태 인지형): close 전략3, seed its 3→4 transition retro,
        // append 전략4, and accrue new playback time under the observation regime.
        if !strategies.contains(where: { $0.id == 4 }) {
            if let i = strategies.firstIndex(where: { $0.id == 3 }) {
                if strategies[i].endedAt.isEmpty { strategies[i].endedAt = "2026-07-10" }
                if strategies[i].retro.isEmpty { strategies[i].retro = Self.strategy3RetroSeed }
            }
            if let entry = Self.seedStrategies.first(where: { $0.id == 4 }) {
                strategies.append(entry)
            }
            activeStrategy = 4
            changed = true
        }
        // 4 → 5 (2026-07-10, 모드 에너지): close 전략4, seed its 4→5 transition retro,
        // append 전략5, and accrue new playback time under mode-energy selection. 전략4's
        // slot scoring keeps running (it replays actions.jsonl, independent of activeStrategy).
        if !strategies.contains(where: { $0.id == 5 }) {
            if let i = strategies.firstIndex(where: { $0.id == 4 }) {
                if strategies[i].endedAt.isEmpty { strategies[i].endedAt = "2026-07-10" }
                if strategies[i].retro.isEmpty { strategies[i].retro = Self.strategy4RetroSeed }
            }
            if let entry = Self.seedStrategies.first(where: { $0.id == 5 }) {
                strategies.append(entry)
            }
            activeStrategy = 5
            changed = true
        }
        if changed { save() }
    }

    private func save() {
        let file = FileV2(version: 2, activeStrategy: activeStrategy,
                          strategies: strategies, stats: Array(stats.values))
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
