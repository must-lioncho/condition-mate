import Foundation

// Persists the value-confirmation pipeline data:
//   - goals (priority list, global)
//   - per-day review: self-score + per-goal contribution, AI filter result,
//     admin score (coming soon).
// Confirmed value is 0 until the self + AI stages are done (admin pending).
final class ReviewStore {

    struct Goal: Codable {
        var id: String
        // Stable, user-visible number assigned once at creation. UNIQUE and
        // IMMUTABLE: it never changes on drag-and-drop reorder (which only changes
        // list position/priority). This is the "id" the user reads and references
        // in the 부모# field; `id` (UUID) stays the internal key.
        var seq: Int = 0
        var text: String
        var parent: String = ""   // parent goal id ("" = top-level)
        // Workflow status. Only one goal may be "in_progress" at a time.
        var status: String = "backlog"    // backlog | in_progress | done
        var trackedSeconds: Double = 0    // banked active time (excludes the live session)
        var startedAt: Date? = nil        // start of the current in_progress session (nil = not running)

        init(id: String, seq: Int = 0, text: String, parent: String = "",
             status: String = "backlog", trackedSeconds: Double = 0, startedAt: Date? = nil) {
            self.id = id; self.seq = seq; self.text = text; self.parent = parent
            self.status = status; self.trackedSeconds = trackedSeconds; self.startedAt = startedAt
        }

        // Tolerant decoder: fields added over time (seq, status, ...) may be absent
        // in older goals.json. Swift's synthesized Decodable would THROW on a missing
        // key (it ignores default values), wiping every goal on load — so decode each
        // optional-with-default field via decodeIfPresent and fall back to its default.
        enum CodingKeys: String, CodingKey { case id, seq, text, parent, status, trackedSeconds, startedAt }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            parent = try c.decodeIfPresent(String.self, forKey: .parent) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "backlog"
            trackedSeconds = try c.decodeIfPresent(Double.self, forKey: .trackedSeconds) ?? 0
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        }
    }

    // Valid status values; anything else is rejected.
    static let validStatuses: Set<String> = ["backlog", "in_progress", "done"]

    struct DayReview: Codable {
        var selfScore: Int? = nil               // 0-100, user's honest value estimate
        var contributions: [String: Int] = [:]  // goalID -> % contributed today
        var notes: [String: String] = [:]       // goalID -> per-goal review note
        var submittedSelf: Bool = false
        var aiScore: Int? = nil                  // 0-100 abuse-filter confidence
        var aiNote: String = ""
        var adminScore: Int? = nil               // coming soon (always nil for now)
    }

    private let dir: URL
    private let goalsURL: URL
    private let dayFmt: DateFormatter
    private(set) var goals: [Goal] = []

    init() {
        dir = AppPaths.sub("review")
        goalsURL = dir.appendingPathComponent("goals.json")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        dayFmt = f

        loadGoals()
    }

    var todayKey: String { dayFmt.string(from: Date()) }

    // MARK: Goals

    private func loadGoals() {
        guard let data = try? Data(contentsOf: goalsURL),
              let g = try? JSONDecoder().decode([Goal].self, from: data) else { return }
        goals = g
        migrateSeq()
    }
    // Backfill stable seq for legacy goals saved before the field existed (seq <= 0).
    // Numbers are assigned uniquely and never reused, then persisted so they stay fixed.
    private func migrateSeq() {
        var used = Set(goals.map { $0.seq }.filter { $0 > 0 })
        var next = (used.max() ?? 0) + 1
        var changed = false
        for i in goals.indices where goals[i].seq <= 0 {
            while used.contains(next) { next += 1 }
            goals[i].seq = next; used.insert(next); next += 1; changed = true
        }
        if changed { saveGoals() }
    }
    private func nextSeq() -> Int { (goals.map { $0.seq }.max() ?? 0) + 1 }
    private func saveGoals() {
        if let data = try? JSONEncoder().encode(goals) { try? data.write(to: goalsURL, options: .atomic) }
    }
    func addGoal(text: String, parent: String = "") {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        goals.append(Goal(id: UUID().uuidString, seq: nextSeq(), text: t, parent: parent))
        saveGoals()
    }
    func removeGoal(id: String) {
        // Remove the goal and re-parent (delete) its children too.
        goals.removeAll { $0.id == id || $0.parent == id }
        saveGoals()
    }

    // Reorder goals to match the given id order (priority list, drag-and-drop).
    // Ids missing from `order` keep their relative order and are appended at the end.
    func reorderGoals(order: [String]) {
        var byId: [String: Goal] = [:]
        for g in goals { byId[g.id] = g }
        var reordered: [Goal] = []
        var placed = Set<String>()
        for id in order {
            if let g = byId[id], !placed.contains(id) { reordered.append(g); placed.insert(id) }
        }
        for g in goals where !placed.contains(g.id) { reordered.append(g) }
        guard reordered.count == goals.count else { return }   // sanity: never drop/duplicate
        goals = reordered
        saveGoals()
    }

    // Set/clear a goal's parent anytime. Enforces a clean 1-level hierarchy.
    func setParent(id: String, parent: String) {
        guard let idx = goals.firstIndex(where: { $0.id == id }), id != parent else { return }
        if parent.isEmpty {
            goals[idx].parent = ""
        } else {
            // Parent must exist and itself be top-level; the goal must not
            // already be a parent (no 2-level nesting / cycles).
            guard let p = goals.first(where: { $0.id == parent }), p.parent.isEmpty,
                  !goals.contains(where: { $0.parent == id }) else { return }
            goals[idx].parent = parent
        }
        saveGoals()
    }

    // Change a goal's workflow status, enforcing a single in_progress goal and
    // banking tracked time on every transition.
    func setStatus(id: String, status: String) {
        guard Self.validStatuses.contains(status),
              let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()

        // Bank the live session of whichever goal is currently running.
        func bank(_ i: Int) {
            if let started = goals[i].startedAt {
                goals[i].trackedSeconds += max(0, now.timeIntervalSince(started))
                goals[i].startedAt = nil
            }
        }

        if status == "in_progress" {
            // Pause every other running goal (single in_progress invariant).
            for i in goals.indices where i != idx && goals[i].status == "in_progress" {
                bank(i)
                goals[i].status = "backlog"
            }
            // Start (or keep) the target's session.
            if goals[idx].startedAt == nil { goals[idx].startedAt = now }
            goals[idx].status = "in_progress"
        } else {
            // Leaving in_progress -> bank the live session, then set new status.
            bank(idx)
            goals[idx].status = status
        }
        saveGoals()
    }

    // Effective tracked seconds including the live (unbanked) session, if running.
    func effectiveTracked(_ g: Goal, now: Date = Date()) -> Double {
        guard let started = g.startedAt else { return g.trackedSeconds }
        return g.trackedSeconds + max(0, now.timeIntervalSince(started))
    }

    // MARK: Per-day review

    private func reviewURL(_ day: String) -> URL { dir.appendingPathComponent("review-\(day).json") }

    func review(_ day: String) -> DayReview {
        guard let data = try? Data(contentsOf: reviewURL(day)),
              let r = try? JSONDecoder().decode(DayReview.self, from: data) else { return DayReview() }
        return r
    }
    func saveReview(_ r: DayReview, day: String) {
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: reviewURL(day), options: .atomic) }
    }
}
