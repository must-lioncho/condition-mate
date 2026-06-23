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
        // Start of the current "응답 대기"(waiting) window (nil = not waiting). Set when
        // the agent parks waiting for a human (AskUserQuestion / permission / stall) and
        // cleared on resume. It is DISPLAY-ONLY: it measures how long we have been
        // waiting and is NEVER added to trackedSeconds, so waiting time can never inflate
        // the honest "how long did the agent actually work" figure. See
        // .doc/waiting-signal-policy.md.
        var waitingSince: Date? = nil
        // Claude Code session id this goal mirrors ("" = a normal hand-made goal).
        // When set, the goal is auto-managed by session hooks: it flips to in_progress
        // while the agent works a turn and back to backlog (대기) when it stops, so
        // trackedSeconds accrues only real active time — the honest answer to
        // "how long did the agent actually run vs just burn tokens".
        var sessionId: String = ""
        // Absolute path to the Claude Code transcript (.jsonl) backing this session,
        // when known. Lets the dashboard open a readable view without re-deriving the
        // path. May be empty for older session goals — the server then falls back to
        // locating <sessionId>.jsonl under ~/.claude/projects.
        var transcriptPath: String = ""

        // Concurrency-aware AI work fields. These only matter once two or more goals
        // run in_progress at once (only possible with AI), where naive parallelism
        // wastes tokens and degrades quality. They make that trade-off visible:
        //   energy  - % of the user's finite 100% capacity allocated to this goal
        //             while in_progress. The sum across in_progress goals must stay
        //             <= 100% (enforced/warned in the dashboard, not here).
        //   agents  - assigned agents (e.g. ["agent1","agent2"]); relevant at 3+ concurrent.
        //   tokens  - cumulative tokens spent (in thousands, K).
        //   value   - produced value score (arbitrary points).
        // value/tokens = ROI, computed client-side, distinguishes steady output from token burn.
        var energy: Int = 0
        var agents: [String] = []
        var tokens: Int = 0
        var value: Int = 0
        // Completion evidence (links + files) — persistent, so finished goals stay
        // discoverable with their supporting material long after the day they closed.
        var evidence: [Evidence] = []
        // Scheduling fields for the 일정관리 (resource management) view.
        //   targetAt    - planned target/deadline (nil = unscheduled).
        //   completedAt - when the goal actually finished. Auto-stamped on the first
        //                 transition to done (setStatus / recordSession "end") when unset,
        //                 and manually editable in the schedule view. Cleared if the goal
        //                 leaves done, so it always reflects the CURRENT completion.
        var targetAt: Date? = nil
        var completedAt: Date? = nil

        init(id: String, seq: Int = 0, text: String, parent: String = "",
             status: String = "backlog", trackedSeconds: Double = 0, startedAt: Date? = nil,
             waitingSince: Date? = nil,
             energy: Int = 0, agents: [String] = [], tokens: Int = 0, value: Int = 0,
             evidence: [Evidence] = [], sessionId: String = "", transcriptPath: String = "",
             targetAt: Date? = nil, completedAt: Date? = nil) {
            self.id = id; self.seq = seq; self.text = text; self.parent = parent
            self.status = status; self.trackedSeconds = trackedSeconds; self.startedAt = startedAt
            self.waitingSince = waitingSince
            self.energy = energy; self.agents = agents; self.tokens = tokens; self.value = value
            self.evidence = evidence; self.sessionId = sessionId; self.transcriptPath = transcriptPath
            self.targetAt = targetAt; self.completedAt = completedAt
        }

        // Tolerant decoder: fields added over time (seq, status, energy, ...) may be absent
        // in older goals.json. Swift's synthesized Decodable would THROW on a missing
        // key (it ignores default values), wiping every goal on load — so decode each
        // optional-with-default field via decodeIfPresent and fall back to its default.
        enum CodingKeys: String, CodingKey {
            case id, seq, text, parent, status, trackedSeconds, startedAt, waitingSince, energy, agents, tokens, value, evidence, sessionId, transcriptPath, targetAt, completedAt
        }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decode(String.self, forKey: .text)
            seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            parent = try c.decodeIfPresent(String.self, forKey: .parent) ?? ""
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "backlog"
            trackedSeconds = try c.decodeIfPresent(Double.self, forKey: .trackedSeconds) ?? 0
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            waitingSince = try c.decodeIfPresent(Date.self, forKey: .waitingSince)
            energy = try c.decodeIfPresent(Int.self, forKey: .energy) ?? 0
            agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
            tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            value = try c.decodeIfPresent(Int.self, forKey: .value) ?? 0
            evidence = try c.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath) ?? ""
            targetAt = try c.decodeIfPresent(Date.self, forKey: .targetAt)
            completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        }
    }

    // A piece of completion evidence attached to a goal — a web link or a file.
    // Files are copied into the app's evidence store; `filename` is the stored name
    // (served back via /evidence/<goalId>/<id>). Links keep their URL in `url`.
    struct Evidence: Codable {
        var id: String            // UUID (internal key, also the URL path segment)
        var kind: String          // "link" | "file"
        var title: String         // display label (link title / original file name)
        var url: String = ""      // link: the URL; file: ""
        var filename: String = "" // file: stored file name on disk; link: ""
        var addedAt: Date

        init(id: String, kind: String, title: String, url: String = "",
             filename: String = "", addedAt: Date) {
            self.id = id; self.kind = kind; self.title = title
            self.url = url; self.filename = filename; self.addedAt = addedAt
        }

        // Tolerant decoder (same rationale as Goal): tolerate missing fields.
        enum CodingKeys: String, CodingKey { case id, kind, title, url, filename, addedAt }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "link"
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
            addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    // Valid status values; anything else is rejected. `waiting` (응답 대기) is the
    // parked-for-human state: the clock is stopped (startedAt nil) while in it.
    // backlog  - 대기: the loop's queue. The ONLY status the auto-loop picks up.
    // in_progress - 진행: actively worked.
    // waiting  - 응답 대기: parked for a human decision (auto-detected; loop hands to user).
    // stopped  - 중지: user-held pause. NOT cancelled; the loop must skip it until resumed.
    // cancelled - 취소: abandoned; the loop ignores it permanently.
    // done     - 완료: finished.
    // stopped/cancelled are user-authoritative holds — see recordSession (session hooks
    // never resurrect them) and the loop eligibility rule (.doc/loop-status-design.md).
    static let validStatuses: Set<String> = ["backlog", "in_progress", "waiting", "stopped", "cancelled", "done"]

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

    // True only when we hold a trustworthy in-memory picture of goals: either the
    // file was genuinely absent (first run) or it decoded cleanly. While false, a
    // load failed and saveGoals() MUST NOT overwrite the on-disk file — otherwise a
    // transient read/decode failure would silently destroy real data.
    private var loadSucceeded = false

    private func loadGoals() {
        // Missing file = genuine first run: nothing to load, safe to save later.
        guard FileManager.default.fileExists(atPath: goalsURL.path) else {
            loadSucceeded = true
            return
        }
        guard let data = try? Data(contentsOf: goalsURL) else {
            // Existing file we could not read: treat as transient. Keep loadSucceeded
            // false so saveGoals() refuses to clobber it.
            loadSucceeded = false
            return
        }
        guard let g = try? JSONDecoder().decode([Goal].self, from: data) else {
            // File exists but is undecodable: preserve a copy before anything can
            // overwrite it, then stay in read-only mode (loadSucceeded = false).
            backupGoalsFile(reason: "corrupt")
            loadSucceeded = false
            return
        }
        goals = g
        loadSucceeded = true
        migrateSeq()
    }

    // Copy the current on-disk goals.json aside (best-effort) so a destructive or
    // failed load can always be recovered from goals.<reason>-<timestamp>.json.
    private func backupGoalsFile(reason: String) {
        guard FileManager.default.fileExists(atPath: goalsURL.path) else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dst = dir.appendingPathComponent("goals.\(reason)-\(f.string(from: Date())).json")
        try? FileManager.default.copyItem(at: goalsURL, to: dst)
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
        // Never let a failed/empty in-memory state destroy real on-disk data.
        // 1) If we never successfully loaded, refuse to write at all.
        // 2) If we're about to write an empty list over a non-empty file, that is a
        //    suspicious destructive overwrite (the exact data-loss path): back the
        //    existing file up first, then proceed.
        if !loadSucceeded { return }
        if goals.isEmpty,
           let onDisk = try? Data(contentsOf: goalsURL),
           let existing = try? JSONDecoder().decode([Goal].self, from: onDisk),
           !existing.isEmpty {
            backupGoalsFile(reason: "rescued")
        }
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

    // Change a goal's workflow status, banking tracked time on every transition.
    // Concurrent in_progress goals ARE allowed: before AI a person could only run
    // one task at a time, but agents make 2-3+ parallel goals real. The dashboard
    // uses the concurrent in_progress count to gate energy/agent inputs, so this no
    // longer forces a single in_progress goal. Each running goal accrues wall-clock
    // time independently (intentional: parallel work multiplies output per minute).
    func setStatus(id: String, status: String) {
        guard Self.validStatuses.contains(status),
              let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()

        if status == "in_progress" {
            // Start (or keep) the target's session; leave other running goals alone.
            if goals[idx].startedAt == nil { goals[idx].startedAt = now }
            goals[idx].status = "in_progress"
        } else {
            // Leaving in_progress -> bank the live session, then set new status.
            if let started = goals[idx].startedAt {
                goals[idx].trackedSeconds += max(0, now.timeIntervalSince(started))
                goals[idx].startedAt = nil
            }
            goals[idx].status = status
        }
        // waitingSince tracks ONLY the waiting window; set it on entry, clear it on any
        // other transition so it never leaks into a non-waiting state.
        goals[idx].waitingSince = (status == "waiting") ? now : nil
        stampCompletion(idx, now: now)
        saveGoals()
    }

    // Keep completedAt in sync with the done status: stamp `now` on the first entry to
    // done when it is still unset (a manual edit therefore survives), and clear it the
    // moment a goal leaves done so a reopened goal never carries a stale finish time.
    private func stampCompletion(_ idx: Int, now: Date) {
        if goals[idx].status == "done" {
            if goals[idx].completedAt == nil { goals[idx].completedAt = now }
        } else {
            goals[idx].completedAt = nil
        }
    }

    // Rename a goal's title from the dashboard. Works for both hand-made and
    // session-mirrored goals. Returns the updated goal so the caller can mirror the
    // new title back into the session transcript (for session goals) — without that,
    // the next session event would re-derive the title from the transcript's aiTitle
    // and clobber the manual rename. Empty titles are rejected: a goal keeps a label.
    @discardableResult
    func setGoalTitle(id: String, title: String) -> Goal? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = goals.firstIndex(where: { $0.id == id }) else { return nil }
        goals[idx].text = t
        saveGoals()
        return goals[idx]
    }

    // MARK: Claude Code session mirroring

    // Drive a goal from a Claude Code session lifecycle event. The goal is keyed by
    // the session id and auto-created on first sight, so the hooks need no goal id:
    //   start  - session opened: ensure the goal exists (대기/backlog), don't disturb a live run
    //   active - agent started working a turn: in_progress (진행), begin a timed session
    //   wait   - agent parked waiting for a human (응답 대기/waiting): bank elapsed active
    //            time and STOP the clock, so the waiting window is not counted as work
    //   idle   - agent finished a turn (Stop hook): also awaiting the human, so it shares
    //            the `wait` state — Claude Code flags an ended turn as "입력 필요" too, and
    //            mapping it to backlog desynced the dashboard from that. Banks time + stops
    //            the clock identically; only resumes to in_progress when the turn restarts.
    //   end    - session closed: 완료 (done), bank any final active time
    // Net effect: trackedSeconds accumulates only the active windows (active->wait/idle),
    // which is the real "how long did the agent actually run" figure — the waiting window
    // is explicitly excluded. See .doc/waiting-signal-policy.md.
    func recordSession(sessionId: String, event: String, text: String = "", transcriptPath: String = "") {
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty else { return }
        let now = Date()

        // `text` carries the session's latest aiTitle (Claude Code's auto-generated
        // title, read from the transcript by the hook). It is empty early on, before
        // a title exists, so it only ever fills in / refreshes — never wipes — a label.
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tpath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)

        let idx: Int
        if let i = goals.firstIndex(where: { $0.sessionId == sid }) {
            idx = i
            if !label.isEmpty { goals[idx].text = label }   // refresh to the current aiTitle
        } else {
            let title = label.isEmpty ? "Claude 세션 \(sid.prefix(8))" : label
            goals.append(Goal(id: UUID().uuidString, seq: nextSeq(), text: title, sessionId: sid))
            idx = goals.count - 1
        }
        if !tpath.isEmpty { goals[idx].transcriptPath = tpath }   // remember where to read

        // A user-held goal (중지/취소) is authoritative. The session hooks still refresh its
        // label/transcript above, but must NOT resurrect its status or bank time: the loop
        // skips these, so an incoming active/idle/end can never silently pull a stopped or
        // cancelled goal back into the queue. Only a manual setStatus moves it out of the hold.
        if goals[idx].status == "stopped" || goals[idx].status == "cancelled" {
            saveGoals(); return
        }

        // Bank the live timed session (if any) back into trackedSeconds.
        func bankLive() {
            if let started = goals[idx].startedAt {
                goals[idx].trackedSeconds += max(0, now.timeIntervalSince(started))
                goals[idx].startedAt = nil
            }
        }

        switch event {
        case "active":
            // Resume work: start a fresh timed window and leave any waiting state.
            if goals[idx].startedAt == nil { goals[idx].startedAt = now }
            goals[idx].waitingSince = nil
            goals[idx].status = "in_progress"
        case "wait", "idle":
            // Park for a human (Notification's `wait` or an ended turn's `idle` — both mean
            // the agent handed control back and Claude Code shows "입력 필요"). Bank what was
            // worked so far, stop the clock, remember when the wait began. Idempotent —
            // re-entering keeps the first `since` so the ⏳ countdown doesn't reset.
            bankLive()
            if goals[idx].status != "waiting" { goals[idx].waitingSince = now }
            goals[idx].status = "waiting"
        case "end":
            bankLive()
            goals[idx].waitingSince = nil
            goals[idx].status = "done"
        default: // "start" — just ensure it exists; never interrupt an active run.
            if goals[idx].status == "in_progress" { bankLive() }
            goals[idx].waitingSince = nil
            goals[idx].status = "backlog"
        }
        stampCompletion(idx, now: now)
        saveGoals()
    }

    // Manually attach an existing goal to a Claude Code session (the dashboard's
    // "connect" action, after the user picks a transcript file). Refuses if another
    // goal already mirrors that session id, so the session<->goal link stays 1:1.
    @discardableResult
    func connectSession(goalId: String, sessionId: String, transcriptPath: String) -> Bool {
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty,
              let idx = goals.firstIndex(where: { $0.id == goalId }),
              !goals.contains(where: { $0.id != goalId && $0.sessionId == sid }) else { return false }
        goals[idx].sessionId = sid
        goals[idx].transcriptPath = transcriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        saveGoals()
        return true
    }

    // MARK: Concurrency-aware AI work fields

    // Energy % allocated to a goal while in_progress, clamped to 0...100. The sum
    // across in_progress goals is capped at 100% in the dashboard (warned, not here).
    func setEnergy(id: String, energy: Int) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].energy = max(0, min(100, energy))
        saveGoals()
    }
    // Replace the assigned-agent list (trimmed, empties dropped, order preserved).
    func setAgents(id: String, agents: [String]) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].agents = agents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        saveGoals()
    }
    // Cumulative tokens spent (in K), never negative.
    func setTokens(id: String, tokens: Int) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].tokens = max(0, tokens)
        saveGoals()
    }
    // Produced value score, never negative.
    func setValue(id: String, value: Int) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].value = max(0, value)
        saveGoals()
    }

    // MARK: Scheduling (target / completion datetimes)

    // Set or clear (nil) a goal's planned target/deadline. Used by the 일정관리 view.
    func setTargetAt(id: String, date: Date?) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].targetAt = date
        saveGoals()
    }
    // Manually set or clear (nil) a goal's completion time, overriding the auto-stamp.
    func setCompletedAt(id: String, date: Date?) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].completedAt = date
        saveGoals()
    }

    // MARK: Completion evidence (links + files)

    // Append a piece of evidence to a goal and return it (nil if the goal is gone).
    // File bytes are written to disk by the caller; here we only store metadata.
    func addEvidence(goalId: String, kind: String, title: String,
                     url: String = "", filename: String = "") -> Evidence? {
        guard let idx = goals.firstIndex(where: { $0.id == goalId }) else { return nil }
        let ev = Evidence(id: UUID().uuidString, kind: kind, title: title,
                          url: url, filename: filename, addedAt: Date())
        goals[idx].evidence.append(ev)
        saveGoals()
        return ev
    }

    // Remove one evidence item; returns it so the caller can delete its file (if any).
    @discardableResult
    func removeEvidence(goalId: String, evidenceId: String) -> Evidence? {
        guard let gi = goals.firstIndex(where: { $0.id == goalId }),
              let ei = goals[gi].evidence.firstIndex(where: { $0.id == evidenceId }) else { return nil }
        let removed = goals[gi].evidence.remove(at: ei)
        saveGoals()
        return removed
    }

    // Look up a single evidence item (used when serving a stored file).
    func evidence(goalId: String, evidenceId: String) -> Evidence? {
        goals.first(where: { $0.id == goalId })?.evidence.first(where: { $0.id == evidenceId })
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
