import Foundation

// 장비 + 숙련도 ledger (see tests/prototypes/equipment-test.html for the design prototype).
//
// Six equipment categories — the rail's nav abilities (대화·스킬·위임·워커·팀) plus
// 플러그인 — each carry a proficiency level 0..7 and an XP gauge. The OVERALL level
// is the ROUNDED AVERAGE of the six (min 1), so Lv.7 완전자율 requires mastering
// everything, not grinding one skill.
//
// EXP is granted only by a SUCCESSFUL pomodoro (the rail dial hitting 25:00): the
// full reward goes to the single most-used category during that window, judged from
// real usage logs (AppDelegate.equipmentUsage). No usage at all → 대화 (기본기).
//
// Market EXP (level balancing): a new model ships roughly monthly, so the market
// level advances +1 per month from the epoch (2026-07 = 시장 Lv.1) and every
// level-up cost inflates ×1.3 per step, compound. Already-earned levels are kept;
// only future level-ups get more expensive.
//
// Persisted at AppPaths.base/equipment.json (same single-store layout as the rest).
final class EquipmentStore {

    static let categories = ["chat", "skills", "delegate", "cron", "team", "plugin"]
    static let names = ["chat": "대화", "skills": "스킬", "delegate": "위임",
                        "cron": "워커", "team": "팀", "plugin": "플러그인"]

    // Overall-level names, index 1..7 (the representative growth path).
    static let levelNames = ["", "대화형", "스킬 사용", "플러그인 연동", "에이전트 위임",
                             "워커 자동화", "팀 오케스트레이션", "완전자율"]

    static let rewardXP = 80          // XP per successful pomodoro
    static let rainSummonCost = 200   // XP spent to summon a 폭우 리셋 from the 장비 page
    static let maxLevel = 7

    struct Prof: Codable { var lv: Int; var xp: Int }

    struct Award: Codable {
        var at: Double                // epoch seconds
        var category: String          // who received the XP
        var xp: Int
        var usage: [String: Int]      // the counted window (for the ledger view)
        var leveledTo: Int            // new level if this award leveled up, else 0
    }

    private struct FileShape: Codable {
        var prof: [String: Prof]
        var awards: [Award]
        var epochYear: Int
        var epochMonth: Int
    }

    private(set) var prof: [String: Prof] = [:]
    private(set) var awards: [Award] = []
    // Market epoch (시장 Lv.1 month). Stored in the file so it's data, not code.
    private var epochYear = 2026
    private var epochMonth = 7

    private let fileURL: URL
    private let lock = NSLock()       // server queue writes vs. reads

    init(fileURL: URL = AppPaths.base.appendingPathComponent("equipment.json")) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Market EXP

    func marketLevel(now: Date = Date()) -> Int {
        let c = Calendar.current.dateComponents([.year, .month], from: now)
        let months = ((c.year ?? epochYear) - epochYear) * 12 + ((c.month ?? epochMonth) - epochMonth)
        return max(1, months + 1)
    }

    func inflation(now: Date = Date()) -> Double {
        pow(1.3, Double(marketLevel(now: now) - 1))
    }

    // XP required to go from `lv` to lv+1, at today's market.
    func xpNeed(_ lv: Int, now: Date = Date()) -> Int {
        Int((Double(60 + lv * 40) * inflation(now: now)).rounded())
    }

    // MARK: - Progression

    // Grant XP with level-ups (cap Lv.7). Returns the new level if it leveled, else 0.
    @discardableResult
    func addXP(_ category: String, _ amount: Int, now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard var p = prof[category], p.lv < Self.maxLevel else { return 0 }
        p.xp += amount
        var leveled = 0
        while p.lv < Self.maxLevel && p.xp >= xpNeed(p.lv, now: now) {
            p.xp -= xpNeed(p.lv, now: now)
            p.lv += 1
            leveled = p.lv
        }
        if p.lv >= Self.maxLevel { p.xp = 0 }   // mastered — gauge stays full
        prof[category] = p
        saveLocked()
        return leveled
    }

    // Spend accumulated XP progress — the 경험치로 폭우소환 gate. Draws only from the
    // per-category XP gauges (never levels, so hard-won mastery is safe), highest gauge
    // first so the cost comes out of surplus progress. Returns the amount actually spent,
    // or nil if the pooled gauges can't cover `amount` — the summon is then refused so the
    // user is never charged for nothing.
    @discardableResult
    func spendXP(_ amount: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        let pool = Self.categories.reduce(0) { $0 + (prof[$1]?.xp ?? 0) }
        guard pool >= amount else { return nil }
        var remaining = amount
        for c in Self.categories.sorted(by: { (prof[$0]?.xp ?? 0) > (prof[$1]?.xp ?? 0) }) {
            if remaining <= 0 { break }
            guard var p = prof[c], p.xp > 0 else { continue }
            let take = min(p.xp, remaining)
            p.xp -= take
            remaining -= take
            prof[c] = p
        }
        saveLocked()
        return amount
    }

    // 쓰다듬기 — the equipment page's pixel avatar click: +1 XP to the weakest gear
    // (lowest level, ties by lowest XP, then category order), so petting nudges the
    // roster toward balanced growth (overall level is the average). Returns the
    // receiving category and the new level if it leveled, or nil when everything is
    // already mastered. Taps are not appended to the awards ledger — 200 entries of
    // +1 would drown the pomodoro history.
    @discardableResult
    func tap(now: Date = Date()) -> (category: String, leveledTo: Int)? {
        lock.lock()
        var target: (c: String, p: Prof)? = nil
        for c in Self.categories {
            let p = prof[c] ?? Prof(lv: 0, xp: 0)
            guard p.lv < Self.maxLevel else { continue }
            if let t = target {
                if p.lv < t.p.lv || (p.lv == t.p.lv && p.xp < t.p.xp) { target = (c, p) }
            } else { target = (c, p) }
        }
        lock.unlock()
        guard let t = target else { return nil }
        return (t.c, addXP(t.c, 1, now: now))
    }

    // A successful pomodoro: the full reward goes to the most-used category.
    // Ties break by the categories order (chat first); no usage at all → 대화 (기본기).
    @discardableResult
    func recordPomodoro(usage: [String: Int], now: Date = Date()) -> Award {
        var best = "chat", bestN = 0
        for c in Self.categories {
            let n = usage[c] ?? 0
            if n > bestN { best = c; bestN = n }
        }
        let leveled = addXP(best, Self.rewardXP, now: now)
        let award = Award(at: now.timeIntervalSince1970, category: best,
                          xp: Self.rewardXP, usage: usage, leveledTo: leveled)
        lock.lock()
        awards.append(award)
        if awards.count > 200 { awards.removeFirst(awards.count - 200) }
        saveLocked()
        lock.unlock()
        return award
    }

    var average: Double {
        lock.lock(); defer { lock.unlock() }
        let sum = Self.categories.reduce(0) { $0 + (prof[$1]?.lv ?? 0) }
        return Double(sum) / Double(Self.categories.count)
    }

    var overallLevel: Int { max(1, Int(average.rounded())) }

    // MARK: - JSON payload (merged with the plugin list by AppDelegate.equipmentJSON)

    func statePayload(now: Date = Date()) -> [String: Any] {
        lock.lock()
        var cats: [String: Any] = [:]
        for c in Self.categories {
            let p = prof[c] ?? Prof(lv: 0, xp: 0)
            cats[c] = ["lv": p.lv, "xp": p.xp,
                       "need": p.lv >= Self.maxLevel ? 0 : xpNeed(p.lv, now: now),
                       "name": Self.names[c] ?? c]
        }
        let recent = awards.suffix(20).reversed().map { a -> [String: Any] in
            ["at": a.at, "category": a.category, "xp": a.xp,
             "usage": a.usage, "leveledTo": a.leveledTo]
        }
        lock.unlock()
        let avg = average
        let overall = overallLevel
        return [
            "categories": cats,
            "average": (avg * 10).rounded() / 10,
            "overall": overall,
            "overallName": Self.levelNames[min(max(overall, 1), 7)],
            "market": ["lv": marketLevel(now: now),
                       "inflation": (inflation(now: now) * 100).rounded() / 100,
                       "epoch": String(format: "%04d-%02d", epochYear, epochMonth)],
            "rewardXP": Self.rewardXP,
            "awards": Array(recent),
        ]
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let f = try? JSONDecoder().decode(FileShape.self, from: data) {
            prof = f.prof
            awards = f.awards
            epochYear = f.epochYear
            epochMonth = f.epochMonth
            // Tolerate categories added after the file was written.
            for c in Self.categories where prof[c] == nil { prof[c] = Prof(lv: 0, xp: 0) }
            return
        }
        seed()
        saveLocked()
    }

    // First run: the user self-assessed Lv.2 — chat-native (대화 6) with growing skill
    // use (스킬 4) → average 1.7 → overall Lv.2. Everything else starts unequipped.
    private func seed() {
        for c in Self.categories { prof[c] = Prof(lv: 0, xp: 0) }
        prof["chat"] = Prof(lv: 6, xp: 0)
        prof["skills"] = Prof(lv: 4, xp: 0)
    }

    private func saveLocked() {
        let f = FileShape(prof: prof, awards: awards,
                          epochYear: epochYear, epochMonth: epochMonth)
        if let data = try? JSONEncoder().encode(f) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
