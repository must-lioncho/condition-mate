import Foundation

// 전략8 · 보링 로테이션. Boredom is the first-class signal: after weeks of the same
// active pools (2주~한 달 "같은 음원"), the library is force-rotated from cumulative
// play history so the user keeps hearing what they have NOT worn out.
//
// Cohorts (from all-strategy cumulative listened seconds + file age):
//   신선 (fresh)    — added within freshAgeDays OR heard under freshHeardMaxSeconds.
//                     Always selectable and slightly PREFERRED; membership is re-evaluated
//                     only on the biweekly epoch, so a new track gets 2 full weeks of
//                     protected exposure before joining the veteran rotation.
//   단골 (familiar) — everything else. Each WEEKLY epoch the most-heard half is benched
//                     and only the less-heard half stays active. Benched tracks accrue no
//                     time while active ones do, so the ranking self-inverts and the halves
//                     swap organically week over week — rotation driven by actual listening,
//                     equalizing total exposure across the library long-term.
//
// Integration is a SOFT re-ranking (virtual-BPM penalty) inside whatever pool the
// existing gates chose (폭우 > 장소 > 컨텍스트 > 플랜 > 모드 — all untouched): benched
// tracks rank far below active ones but a pool with only benched tracks still plays
// (no silence, no user-facing failure).
final class BoredomRotation {

    // A track as this layer sees it: stable filename identity + when the file appeared.
    // The app passes the url and file dates resolve lazily (cached, one stat per file
    // ever — the provider runs on every selection); tests inject addedAt directly.
    struct TrackInfo {
        let key: String
        let url: URL?
        let addedAt: Date?
        init(key: String, url: URL? = nil, addedAt: Date? = nil) {
            self.key = key; self.url = url; self.addedAt = addedAt
        }
    }

    // Persisted roster so a restart cannot reshuffle mid-week.
    struct Snapshot: Codable {
        var weekIndex: Int
        var biweekIndex: Int
        var freshKeys: [String]
        var benchedKeys: [String]
        var computedAt: Double
    }

    // Tunables.
    static let freshAgeDays: Double = 28            // file younger than this = 신선
    static let freshHeardMaxSeconds: Double = 20 * 60 // heard under 20min total = still 신선
    static let benchFraction: Double = 0.5          // benched share of the familiar cohort
    static let benchedPenalty: Double = 48          // virtual BPM: effectively last resort
    static let familiarBias: Double = 6             // active familiar ranks behind fresh at ties
    // Epoch anchor: Monday 2026-08-03 (display timezone). Weekly epochs flip on Mondays;
    // biweekly epochs every other Monday.
    private static let epochAnchor = DateComponents(year: 2026, month: 8, day: 3)

    // Wired by AppDelegate (the app owns the library and the play-stats store).
    var tracksProvider: (() -> [TrackInfo])?
    var heardSecondsProvider: (() -> [String: Double])?
    // Unit tests flip this off so a refresh can't append to the real actions.jsonl.
    var logEvents = true

    private(set) var snapshot: Snapshot?
    private var benched: Set<String> = []
    private var fresh: Set<String> = []
    private var knownKeys: Set<String> = []
    private var addedCache: [String: Date] = [:]
    private let fileURL: URL

    init(fileURL: URL = AppPaths.base.appendingPathComponent("boring-rotation.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = snap
            benched = Set(snap.benchedKeys)
            fresh = Set(snap.freshKeys)
            knownKeys = benched.union(fresh)   // familiar-active keys re-derive on refresh
        }
    }

    // MARK: - Epoch math (pure, display-timezone wall clock)

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Settings.shared.displayTimeZone
        return cal
    }

    // Whole days since the Monday anchor; negative-safe floor division for the indexes.
    static func daysSinceAnchor(now: Date, cal: Calendar) -> Int {
        guard let anchor = cal.date(from: epochAnchor) else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: anchor),
                                  to: cal.startOfDay(for: now)).day ?? 0
    }
    static func weekIndex(days: Int) -> Int { Int(floor(Double(days) / 7)) }
    static func biweekIndex(days: Int) -> Int { Int(floor(Double(days) / 14)) }

    // MARK: - Pure cohort logic (unit-testable)

    static func isFresh(addedAt: Date?, heardSeconds: Double, now: Date) -> Bool {
        if let added = addedAt, now.timeIntervalSince(added) < freshAgeDays * 86400 { return true }
        return heardSeconds < freshHeardMaxSeconds
    }

    // The most-heard `benchFraction` of the familiar cohort, ties broken by key so the
    // result is deterministic for a given stats file.
    static func benchSet(familiar: [(key: String, heard: Double)]) -> Set<String> {
        guard familiar.count >= 2 else { return [] }
        let sorted = familiar.sorted {
            $0.heard != $1.heard ? $0.heard > $1.heard : $0.key < $1.key
        }
        let benchCount = Int(Double(familiar.count) * benchFraction)
        return Set(sorted.prefix(benchCount).map { $0.key })
    }

    // MARK: - Roster refresh

    // Cheap when nothing changed; recomputes on a weekly epoch flip (and re-evaluates
    // fresh membership only on the biweekly flip). Library newcomers mid-week are
    // classified incrementally without reshuffling the current bench.
    func refreshIfNeeded(now: Date = Date()) {
        let cal = Self.calendar()
        let days = Self.daysSinceAnchor(now: now, cal: cal)
        let wi = Self.weekIndex(days: days)
        let bi = Self.biweekIndex(days: days)
        let tracks = tracksProvider?() ?? []
        guard !tracks.isEmpty else { return }
        let keys = Set(tracks.map { $0.key })

        if let snap = snapshot, snap.weekIndex == wi {
            // Same week: only fold in tracks the roster has never seen (new files).
            let newcomers = keys.subtracting(knownKeys)
            guard !newcomers.isEmpty else { return }
            let heard = heardSecondsProvider?() ?? [:]
            for t in tracks where newcomers.contains(t.key) {
                if Self.isFresh(addedAt: addedAt(t), heardSeconds: heard[t.key] ?? 0, now: now) {
                    fresh.insert(t.key)
                }
                knownKeys.insert(t.key)
            }
            persist(weekIndex: wi, biweekIndex: snap.biweekIndex, now: now)
            return
        }

        let heard = heardSecondsProvider?() ?? [:]
        // Fresh cohort: sticky between biweekly epochs (a new track keeps its 2-week
        // protection across the weekly bench reshuffles), fully re-evaluated on the flip.
        if snapshot?.biweekIndex != bi || snapshot == nil {
            fresh = Set(tracks.filter {
                Self.isFresh(addedAt: addedAt($0), heardSeconds: heard[$0.key] ?? 0, now: now)
            }.map { $0.key })
        } else {
            fresh = fresh.intersection(keys)
        }
        let familiar = tracks.filter { !fresh.contains($0.key) }
            .map { (key: $0.key, heard: heard[$0.key] ?? 0) }
        benched = Self.benchSet(familiar: familiar)
        knownKeys = keys
        persist(weekIndex: wi, biweekIndex: bi, now: now)

        guard logEvents else { return }
        var e = ActionLog.Event()
        e.kind = "system"; e.action = "boringRotate"; e.category = "bgm"
        e.detail = "보링 로테이션 개편 · 활성 \(keys.count - benched.count)곡"
            + " (신선 \(fresh.count) · 단골 \(familiar.count - benched.count))"
            + " · 벤치 \(benched.count)곡 · \(wi)주차"
        ActionLog.shared.append(e)
    }

    private func persist(weekIndex: Int, biweekIndex: Int, now: Date) {
        let snap = Snapshot(weekIndex: weekIndex, biweekIndex: biweekIndex,
                            freshKeys: fresh.sorted(), benchedKeys: benched.sorted(),
                            computedAt: now.timeIntervalSince1970)
        snapshot = snap
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Selection interface

    func isBenched(key: String) -> Bool { benched.contains(key) }
    func isFresh(key: String) -> Bool { fresh.contains(key) }

    // Virtual-BPM re-ranking inside the active pool: fresh first, active familiar
    // next, benched effectively last (soft — a benched-only pool still plays).
    func penalty(key: String) -> Double {
        if benched.contains(key) { return Self.benchedPenalty }
        if fresh.contains(key) { return 0 }
        return Self.familiarBias
    }

    // File creation date (falls back to modification date) — "추가된 지 얼마 안 된".
    static func addedDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date)
    }

    // Injected date wins (tests); otherwise resolve from the file once and cache.
    private func addedAt(_ t: TrackInfo) -> Date? {
        if let d = t.addedAt { return d }
        if let d = addedCache[t.key] { return d }
        guard let url = t.url, let d = Self.addedDate(of: url) else { return nil }
        addedCache[t.key] = d
        return d
    }
}
