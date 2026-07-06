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
        // What KIND of wait this is, when status == "waiting", so the left rail can color
        // it the way Claude Desktop does: "permission" = 확인 요청 (the agent needs the user
        // to approve a tool — blue) vs "decision" = 의사결정 요청 (an ended turn / open
        // question awaiting a human answer — amber). Empty when not waiting. Set by the
        // session hook from Claude Code's Notification message; see Scripts/cc-session-hook.sh.
        var waitKind: String = ""
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
        // Extra Claude Code session ids the user manually linked to this goal from the
        // goal page (the "세션 연결" picker). The page already knows three sessions on its
        // own — the lifecycle session (sessionId above), the messenger chat, and the
        // in-page CLI — so this list holds only the additionally-attached ones. Each is
        // resolved to its transcript on demand to show its last-used time and a resume
        // command, so a goal worked across several sessions can be picked back up.
        var linkedSessions: [String] = []

        // Goal-to-goal LINKS (source side records the link). The display hierarchy stays
        // flat 1-level; a link does NOT nest goals. Creating a link promotes THIS goal to
        // top-level (parent="") and appends the target's id here. Only export/compression
        // follows links (directional: source → target). See docs/specs/goal-link-and-generic-queue.md.
        var links: [String] = []   // linked goal ids (child side records the link; display stays flat)

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

        // Sprint membership (지라식 스프린트 = 릴리즈 단위). The number is the user-typed
        // sprint id (0 = unassigned / backlog). `released` marks a goal that has been
        // committed via the 릴리즈 action: it is hidden from the active list and recorded
        // in a Release (releaseId), and a 복원 clears both flags to bring it back.
        var sprint: Int = 0
        // Bump out (아이디어 인박스). The raw brain-dump tier that sits BELOW Backlog: a
        // freshly-thrown, un-organized idea lands here first, then gets promoted up to
        // Backlog (나중에 할 것) and eventually into a Sprint (지금 할 것). Orthogonal to
        // `sprint` on purpose — a bumped goal belongs to no sprint yet (sprint stays 0),
        // so this flag alone decides the Bump out bucket regardless of parent inheritance.
        // Assigning a real bucket (setGoalSprint) clears it — 정리되면 인박스에서 빠진다.
        var bump: Bool = false
        var released: Bool = false
        var releaseId: String = ""

        // Manual archive (보관). Distinct from `released` (a sprint commit): the user
        // explicitly stows a goal away so it drops out of every ACTIVE view — 목록·그룹·
        // 테이블·일정·스프린트 보드 — yet stays fully intact and searchable in the 아카이브
        // view, where a 보관 해제 brings it straight back. Unlike release it needs no sprint
        // and mints no Release record: it is a reversible "put this out of sight" switch.
        var archived: Bool = false

        // Priority (우선순위): 5-level bucket, default "medium". Display-only — it does NOT
        // reorder the list (the sprint board shows it as a colored dot); it just lets the
        // user triage which work matters most. Order: urgent > high > medium > low > lowest.
        var priority: String = "medium"

        init(id: String, seq: Int = 0, text: String, parent: String = "",
             status: String = "backlog", trackedSeconds: Double = 0, startedAt: Date? = nil,
             waitingSince: Date? = nil, waitKind: String = "",
             energy: Int = 0, agents: [String] = [], tokens: Int = 0, value: Int = 0,
             evidence: [Evidence] = [], sessionId: String = "", transcriptPath: String = "",
             linkedSessions: [String] = [], links: [String] = [],
             targetAt: Date? = nil, completedAt: Date? = nil,
             sprint: Int = 0, bump: Bool = false, released: Bool = false, releaseId: String = "",
             archived: Bool = false,
             priority: String = "medium") {
            self.id = id; self.seq = seq; self.text = text; self.parent = parent
            self.status = status; self.trackedSeconds = trackedSeconds; self.startedAt = startedAt
            self.waitingSince = waitingSince; self.waitKind = waitKind
            self.energy = energy; self.agents = agents; self.tokens = tokens; self.value = value
            self.evidence = evidence; self.sessionId = sessionId; self.transcriptPath = transcriptPath
            self.linkedSessions = linkedSessions; self.links = links
            self.targetAt = targetAt; self.completedAt = completedAt
            self.sprint = sprint; self.bump = bump; self.released = released; self.releaseId = releaseId
            self.archived = archived
            self.priority = priority
        }

        // Tolerant decoder: fields added over time (seq, status, energy, ...) may be absent
        // in older goals.json. Swift's synthesized Decodable would THROW on a missing
        // key (it ignores default values), wiping every goal on load — so decode each
        // optional-with-default field via decodeIfPresent and fall back to its default.
        enum CodingKeys: String, CodingKey {
            case id, seq, text, parent, status, trackedSeconds, startedAt, waitingSince, waitKind, energy, agents, tokens, value, evidence, sessionId, transcriptPath, linkedSessions, links, targetAt, completedAt, sprint, bump, released, releaseId, archived, priority
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
            waitKind = try c.decodeIfPresent(String.self, forKey: .waitKind) ?? ""
            energy = try c.decodeIfPresent(Int.self, forKey: .energy) ?? 0
            agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
            tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
            value = try c.decodeIfPresent(Int.self, forKey: .value) ?? 0
            evidence = try c.decodeIfPresent([Evidence].self, forKey: .evidence) ?? []
            sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath) ?? ""
            linkedSessions = try c.decodeIfPresent([String].self, forKey: .linkedSessions) ?? []
            links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
            targetAt = try c.decodeIfPresent(Date.self, forKey: .targetAt)
            completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
            sprint = try c.decodeIfPresent(Int.self, forKey: .sprint) ?? 0
            bump = try c.decodeIfPresent(Bool.self, forKey: .bump) ?? false
            released = try c.decodeIfPresent(Bool.self, forKey: .released) ?? false
            releaseId = try c.decodeIfPresent(String.self, forKey: .releaseId) ?? ""
            archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
            priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
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

    // A release (커밋) — a snapshot taken when the user closes out a sprint's finished
    // work. It records WHEN the release happened and WHAT value it produced, so the
    // release page reads like a commit log ("내가 언제 릴리즈했고 어떤 가치를 만들었나").
    // The committed goals are marked released (hidden from the active list); titles are
    // snapshotted so the log stays readable even if a goal is later renamed/removed.
    struct Release: Codable {
        var id: String
        var sprint: Int            // sprint number released (0 = released across all sprints)
        // User-facing code snapshot at release time, UNIQUE per release. A sprint can ship
        // in several commits; each release keeps its own advancing code (26-2, 26-3, 26-4…)
        // so the 완료 로그 never shows the same code twice. Empty for 미배정 (sprint 0); older
        // records with no code fall back to the sprint's current code at display time.
        var code: String
        var releasedAt: Date
        var value: Int             // summed produced value of the committed goals
        var goalIds: [String]      // ids of the goals committed (for 복원/restore)
        var titles: [String]       // title snapshot at release time (readable log)

        enum CodingKeys: String, CodingKey { case id, sprint, code, releasedAt, value, goalIds, titles }
        init(id: String, sprint: Int, code: String = "", releasedAt: Date, value: Int, goalIds: [String], titles: [String]) {
            self.id = id; self.sprint = sprint; self.code = code; self.releasedAt = releasedAt
            self.value = value; self.goalIds = goalIds; self.titles = titles
        }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            sprint = try c.decodeIfPresent(Int.self, forKey: .sprint) ?? 0
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
            releasedAt = try c.decodeIfPresent(Date.self, forKey: .releasedAt) ?? Date(timeIntervalSince1970: 0)
            value = try c.decodeIfPresent(Int.self, forKey: .value) ?? 0
            goalIds = try c.decodeIfPresent([String].self, forKey: .goalIds) ?? []
            titles = try c.decodeIfPresent([String].self, forKey: .titles) ?? []
        }
    }

    // A sprint definition. Per the policy (.claude/doc/sprint-policy.md) a sprint is just
    // "a bundle of goals + a length", so it carries only WHAT it aims to ship (goalText,
    // the 결과물) and HOW LONG (durationKind: 1d/2d/3d/1w/2w/1m). No start/end clock — the
    // user explicitly does not want time fields; the length is a tag, not a schedule.
    struct Sprint: Codable {
        var number: Int            // internal stable id goals reference (unique, never reused)
        var code: String           // user-facing id "YY-n" (e.g. 26-1) — uniqueness + year context
        var goalText: String       // 결과물 / 예상 결과 — what this sprint completes
        var durationKind: String   // 1d | 2d | 3d | 1w | 2w | 1m
        var startAt: Date?         // auto-filled on create (now); user fine-tunes
        var targetAt: Date?        // auto = startAt + duration; user fine-tunes (목표 날짜)
        var createdAt: Date
        // closed = released. A released sprint drops out of the active board and filter;
        // its record lives on in the 완료 로그. 복원 reopens it.
        var closed: Bool = false

        enum CodingKeys: String, CodingKey { case number, code, goalText, durationKind, startAt, targetAt, createdAt, closed }
        init(number: Int, code: String = "", goalText: String, durationKind: String,
             startAt: Date? = nil, targetAt: Date? = nil, createdAt: Date, closed: Bool = false) {
            self.number = number; self.code = code; self.goalText = goalText
            self.durationKind = durationKind; self.startAt = startAt; self.targetAt = targetAt
            self.createdAt = createdAt; self.closed = closed
        }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            number = try c.decode(Int.self, forKey: .number)
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
            goalText = try c.decodeIfPresent(String.self, forKey: .goalText) ?? ""
            durationKind = try c.decodeIfPresent(String.self, forKey: .durationKind) ?? "1d"
            startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
            targetAt = try c.decodeIfPresent(Date.self, forKey: .targetAt)
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        }
    }
    static let validDurations: Set<String> = ["1d", "2d", "3d", "1w", "2w", "1m"]

    // A single similar/overlapping goal the AI dedup pass flagged for a candidate.
    // `seq` points at the existing goal; `text` snapshots its title (so the queue
    // stays readable even if that goal is later renamed); `why` is the AI's short
    // Korean reason for the overlap.
    struct QueueMatch: Codable {
        var seq: Int
        var text: String = ""
        var why: String = ""
        enum CodingKeys: String, CodingKey { case seq, text, why }
        init(seq: Int, text: String = "", why: String = "") { self.seq = seq; self.text = text; self.why = why }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        }
    }

    // A deferred ("later") AI-add candidate. When AI추가 flags a possible duplicate and
    // the user is not ready to decide, the candidate is parked here instead of becoming
    // a goal. The user later reviews the queue one item at a time and chooses 추가/스킵/수정.
    // This is the "에너지 아끼기" path: pile up decisions, resolve them in a batch.
    struct AIQueueItem: Codable {
        var id: String
        var text: String                 // the candidate goal text
        var parent: String = ""          // optional parent goal UUID ("" = top-level)
        var sprint: Int = 0              // target sprint to land in when promoted (0 = backlog)
        var note: String = ""            // AI's short summary of the overlap
        var matches: [QueueMatch] = []   // similar existing goals the AI flagged
        var createdAt: Date
        // Lifecycle stage of the candidate ("bump out" queue):
        // pending   - just dumped by the user; awaiting background AI analysis.
        // analyzing - the serial worker is currently running `claude -p` on it.
        // ready     - analysis done; awaiting the user's one-tap 추가/수정/스킵 decision.
        // Legacy items parked before this field existed default to "ready" (they were
        // already analyzed when they hit the old "later" pile), so they behave as before.
        var status: String = "ready"
        var duplicate: Bool = false      // AI verdict: candidate overlaps an existing goal (recurring OR duplicate)
        // AI verdict axis distinguishing WHY it overlaps, so the review UI can recommend the
        // right action instead of always "skip":
        //   new       - genuinely new goal → recommend 추가 (top-level).
        //   recurring - repeats/continues an existing goal's work (matches[0]) → recommend
        //               adding it as a run/subtask UNDER that goal, not skipping.
        //   duplicate - the same goal already exists with nothing new to do → recommend 스킵.
        // Legacy items (analyzed before this field) decode as duplicate?"duplicate":"new".
        var kind: String = "new"
        // Claude session id for the prompt-refine CONVERSATION on this item. The refine
        // loop (프롬프트 → 생성 → 새 결과 → 다시 프롬프트) continues ONE session so each new
        // prompt builds on the prior turns and the similar-goal context, instead of starting
        // fresh every time. Empty until the first refine; then resumed via `claude --resume`.
        var refineSession: String = ""
        // The user's ORIGINAL raw brain-dump captured at enqueue, kept verbatim even
        // after `text` is rewritten by prompt-refine. Holds hints the one-line goal
        // loses — content keywords and "2일전" style time cues — which the dedup search
        // (RelatedGoalSearch) mines to find related goals whose title never mentions
        // the work. Defaults to the candidate text when no richer prompt was supplied.
        var originPrompt: String = ""
        // Generalized async-job fields (Phase 2). The AI 큐 is no longer dedup-only; it is a
        // general background-job queue. Legacy queue.json items have none of these keys, so
        // every one decodes to jobKind=="dedup" and behaves exactly as before.
        //   jobKind    - "dedup" (legacy AI 큐 candidate) | "linkmap" | "report" | ... (Phase 3+ producers).
        //   title      - human label for the queue card (falls back to `text` when empty).
        //   resultHTML - rendered HTML result for non-dedup jobs (shown in the card).
        //   error      - non-empty when a non-dedup job failed; the card shows it + a 재시도 button.
        var jobKind: String = "dedup"
        var title: String = ""
        var resultHTML: String = ""
        var error: String = ""
        // 검색(찾기만) 후보: AI목표와 똑같이 dedup 분석(RelatedGoalSearch + judge)을 돌려 비슷한
        // 기존 목표(matches)를 찾지만, 결과 카드는 그 매치만 보여줄 뿐 목표를 만들지 않는다.
        // (AI목표 = 찾고+만들기, 검색 = 찾기만). Legacy items decode to false.
        var findOnly: Bool = false

        // AI PLACEMENT VERDICT (Option D — orthogonal to the dedup `kind` axis above). The
        // judge now also decides WHERE the promoted goal should land, so the queue card can
        // pre-fill the promote form. These are SUGGESTIONS: the user can override every one of
        // them at resolve time (resolveQueueItem honors client-supplied parentSeq/priority).
        //   placement        - "top": stand-alone task or a brand-new parent (no parent).
        //                       "sub": attach UNDER an existing goal (suggestedParentSeq).
        //   suggestedParentSeq - #seq of the suggested parent when placement=="sub" (0 for top).
        //   priority         - AI-suggested 5-level bucket (mirrors Goal.priority values).
        //   confidence       - 0.0...1.0 self-rated confidence in the placement call.
        //   rationale        - short Korean sentence explaining the placement (card tooltip).
        // Legacy items (parked before Option D) decode placement="top", confidence=0 so the
        // card falls back to "새 태스크로 추가" exactly as before.
        var placement: String = "top"
        var suggestedParentSeq: Int = 0
        var priority: String = "medium"
        var confidence: Double = 0
        var rationale: String = ""

        enum CodingKeys: String, CodingKey { case id, text, parent, sprint, note, matches, createdAt, status, duplicate, kind, refineSession, originPrompt, jobKind, title, resultHTML, error, findOnly, placement, suggestedParentSeq, priority, confidence, rationale }
        init(id: String, text: String, parent: String = "", sprint: Int = 0, note: String = "",
             matches: [QueueMatch] = [], createdAt: Date, status: String = "ready", duplicate: Bool = false,
             kind: String = "new", refineSession: String = "", originPrompt: String = "",
             jobKind: String = "dedup", title: String = "", resultHTML: String = "", error: String = "",
             findOnly: Bool = false,
             placement: String = "top", suggestedParentSeq: Int = 0, priority: String = "medium",
             confidence: Double = 0, rationale: String = "") {
            self.id = id; self.text = text; self.parent = parent; self.sprint = sprint
            self.note = note; self.matches = matches; self.createdAt = createdAt
            self.status = status; self.duplicate = duplicate; self.kind = kind; self.refineSession = refineSession
            self.originPrompt = originPrompt
            self.jobKind = jobKind; self.title = title; self.resultHTML = resultHTML; self.error = error
            self.findOnly = findOnly
            self.placement = placement; self.suggestedParentSeq = suggestedParentSeq
            self.priority = priority; self.confidence = confidence; self.rationale = rationale
        }
        init(from dec: Decoder) throws {
            let c = try dec.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
            parent = try c.decodeIfPresent(String.self, forKey: .parent) ?? ""
            sprint = try c.decodeIfPresent(Int.self, forKey: .sprint) ?? 0
            note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
            matches = try c.decodeIfPresent([QueueMatch].self, forKey: .matches) ?? []
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ready"
            duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? (duplicate ? "duplicate" : "new")
            refineSession = try c.decodeIfPresent(String.self, forKey: .refineSession) ?? ""
            originPrompt = try c.decodeIfPresent(String.self, forKey: .originPrompt) ?? ""
            jobKind = try c.decodeIfPresent(String.self, forKey: .jobKind) ?? "dedup"
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            resultHTML = try c.decodeIfPresent(String.self, forKey: .resultHTML) ?? ""
            error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            findOnly = try c.decodeIfPresent(Bool.self, forKey: .findOnly) ?? false
            placement = try c.decodeIfPresent(String.self, forKey: .placement) ?? "top"
            suggestedParentSeq = try c.decodeIfPresent(Int.self, forKey: .suggestedParentSeq) ?? 0
            priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "medium"
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
            rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
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
    private let releasesURL: URL
    private let sprintsURL: URL
    private let queueURL: URL
    private let dayFmt: DateFormatter
    private(set) var goals: [Goal] = []
    private(set) var releases: [Release] = []
    private(set) var sprints: [Sprint] = []
    private(set) var aiQueue: [AIQueueItem] = []

    // The "current" sprint for live timers (the challenge dial's 스프린트 mode): the open (not
    // closed) sprint with the highest number; if every sprint is closed, the highest-numbered one.
    // nil when no sprints exist.
    var currentSprint: Sprint? {
        sprints.filter { !$0.closed }.max(by: { $0.number < $1.number })
            ?? sprints.max(by: { $0.number < $1.number })
    }

    init() {
        dir = AppPaths.sub("review")
        goalsURL = dir.appendingPathComponent("goals.json")
        releasesURL = dir.appendingPathComponent("releases.json")
        sprintsURL = dir.appendingPathComponent("sprints.json")
        queueURL = dir.appendingPathComponent("ai-queue.json")

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        dayFmt = f

        loadGoals()
        loadReleases()
        loadSprints()
        loadQueue()
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
        normalizeBump()
    }

    // One-time normalization for the deferred-seq migration (Option A): every stored Goal
    // already has a unique seq (migrateSeq guarantees it), so a legacy bump=true goal is now
    // just a normal numbered backlog goal. The un-numbered idea inbox moved entirely to the
    // pending queue, so clear the residual bump flag on load. This deletes no goals — it only
    // drops them out of the retired Bump out bucket. Idempotent: after the first save, no
    // goal carries bump=true and this is a no-op.
    private func normalizeBump() {
        var changed = false
        for i in goals.indices where goals[i].bump {
            goals[i].bump = false; changed = true
        }
        if changed { saveGoals() }
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
    // Returns the new goal's #seq (0 if the text was empty and nothing was added), so
    // callers can build a link to the created goal's page.
    //
    // NUMBERING RULE (deferred seq, Option A): a real Goal is minted here — and ONLY here —
    // with a UNIQUE, IMMUTABLE seq. An un-numbered brain-dump idea must NOT reach this path;
    // it lives solely in the pending queue (queue.json) until promotion via resolveQueueItem
    // ("add"), which calls back into addGoal. The legacy `bump` parameter is DEAD: idea
    // creation no longer produces a numbered bump goal (that made a double-inbox with the
    // queue). The field is kept only for backward-compat decoding of old goals — new goals
    // are never written with bump=true. See setGoalBump (demotion removed).
    @discardableResult
    func addGoal(text: String, parent: String = "", sprint: Int = 0) -> Int {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        let seq = nextSeq()
        goals.append(Goal(id: UUID().uuidString, seq: seq, text: t, parent: parent,
                          sprint: max(0, sprint)))
        saveGoals()
        return seq
    }
    func removeGoal(id: String) {
        // Remove the goal and re-parent (delete) its children too.
        goals.removeAll { $0.id == id || $0.parent == id }
        saveGoals()
    }

    // MARK: AI dedup queue (the "later" pile)

    private func loadQueue() {
        guard FileManager.default.fileExists(atPath: queueURL.path),
              let data = try? Data(contentsOf: queueURL),
              let q = try? JSONDecoder().decode([AIQueueItem].self, from: data) else { return }
        aiQueue = q
        // No worker runs at load time, so any "analyzing" item is orphaned from a previous
        // run that died mid-analysis. Revert it to "pending" so the launch kick re-picks it.
        var changed = false
        for i in aiQueue.indices where aiQueue[i].status == "analyzing" {
            aiQueue[i].status = "pending"; changed = true
        }
        if changed { saveQueue() }
    }
    private func saveQueue() {
        if let data = try? JSONEncoder().encode(aiQueue) { try? data.write(to: queueURL, options: .atomic) }
    }
    // Park a flagged candidate for later review (the legacy "later" button). Lands as
    // "ready" because the verdict (note/matches) is already known at this point.
    func addQueueItem(text: String, parent: String, note: String, matches: [QueueMatch]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        aiQueue.append(AIQueueItem(id: UUID().uuidString, text: t, parent: parent,
                                   note: note, matches: matches, createdAt: Date(), status: "ready"))
        saveQueue()
    }

    // "Bump out" path: instantly park a freshly-dumped candidate as "pending" so the user
    // never waits on the AI. The background worker (kickAIQueueWorker) picks it up, analyzes
    // it, and flips it to "ready". Returns the new id (caller kicks the worker).
    @discardableResult
    func enqueuePending(text: String, parent: String = "", sprint: Int = 0, origin: String? = nil,
                        findOnly: Bool = false) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Snapshot the raw prompt now so refine can't erase the hints (defaults to the
        // candidate text when the caller has nothing richer to offer).
        let o = (origin ?? t).trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        aiQueue.append(AIQueueItem(id: id, text: t, parent: parent, sprint: max(0, sprint),
                                   createdAt: Date(), status: "pending", originPrompt: o.isEmpty ? t : o,
                                   findOnly: findOnly))
        saveQueue()
        return id
    }

    // Worker step 1: atomically claim the oldest pending candidate by flipping it to
    // "analyzing" and returning a snapshot. Returns nil when there is nothing to analyze.
    // Call on main for thread-safe store access.
    func claimNextPending() -> AIQueueItem? {
        guard let idx = aiQueue.firstIndex(where: { $0.status == "pending" }) else { return nil }
        aiQueue[idx].status = "analyzing"
        saveQueue()
        return aiQueue[idx]
    }

    // Worker step 2: record the AI verdict and flip the item to "ready" for user review.
    // No-op if the item was resolved/skipped while analysis was in flight. Call on main.
    // Besides the dedup axis (duplicate/kind/matches) this now also persists the orthogonal
    // PLACEMENT verdict (placement/suggestedParentSeq/priority/confidence/rationale) so the
    // queue card can pre-fill the promote form. `priority` is validated against the 5-level
    // bucket; an unknown value falls back to "medium".
    func completeAnalysis(id: String, duplicate: Bool, kind: String, note: String, matches: [QueueMatch],
                          placement: String = "top", suggestedParentSeq: Int = 0,
                          priority: String = "medium", confidence: Double = 0, rationale: String = "") {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return }
        aiQueue[idx].status = "ready"
        aiQueue[idx].duplicate = duplicate
        aiQueue[idx].kind = kind
        aiQueue[idx].note = note
        aiQueue[idx].matches = matches
        aiQueue[idx].placement = (placement == "sub") ? "sub" : "top"
        aiQueue[idx].suggestedParentSeq = max(0, suggestedParentSeq)
        aiQueue[idx].priority = ReviewStore.validPriorities.contains(priority) ? priority : "medium"
        aiQueue[idx].confidence = max(0, min(1, confidence))
        aiQueue[idx].rationale = rationale
        saveQueue()
    }

    // Generic job enqueue (Phase 2): park a non-dedup background job (linkmap/report/...)
    // as "pending" so the serial worker picks it up. Parallel to enqueuePending, but sets
    // jobKind/title instead of a dedup candidate. Returns the new id (caller kicks the worker).
    @discardableResult
    func enqueueJob(jobKind: String, title: String, origin: String? = nil) -> String? {
        let k = jobKind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return nil }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = (origin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        aiQueue.append(AIQueueItem(id: id, text: t, createdAt: Date(), status: "pending",
                                   originPrompt: o, jobKind: k, title: t))
        saveQueue()
        return id
    }

    // Worker step 2 for non-dedup jobs: record the rendered result (or error) and flip the
    // item to "ready". Parallel to completeAnalysis. No-op if the item was removed meanwhile.
    func completeJob(id: String, resultHTML: String, error: String = "") {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return }
        aiQueue[idx].status = "ready"
        aiQueue[idx].resultHTML = resultHTML
        aiQueue[idx].error = error
        saveQueue()
    }

    // Phase 2 queue-tab actions ------------------------------------------------------------
    // Re-enqueue a failed/finished job: clear its error and flip it back to "pending" so the
    // worker re-runs it. Returns true if the item exists (caller kicks the worker).
    @discardableResult
    func retryQueueItem(id: String) -> Bool {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return false }
        aiQueue[idx].status = "pending"
        aiQueue[idx].error = ""
        saveQueue()
        return true
    }

    // Drop a finished job card. Guard: never remove an item that is still "analyzing"
    // (the worker holds it). Returns true when an item was actually removed.
    @discardableResult
    func removeQueueItem(id: String) -> Bool {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return false }
        guard aiQueue[idx].status != "analyzing" else { return false }
        aiQueue.remove(at: idx)
        saveQueue()
        return true
    }

    // Prompt-refine: replace a queued candidate's text (and refinement note) with a
    // model-rewritten result, keeping it queued as "ready" for another review round.
    // The user drives this by giving a free-text prompt; the loop repeats until they
    // accept (추가) or drop (스킵). No-op if the item was resolved while the refine ran.
    // Returns true on success so the caller can report accordingly. Call on main.
    @discardableResult
    func refineQueueItem(id: String, text: String, note: String, session: String = "") -> Bool {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        aiQueue[idx].text = t
        aiQueue[idx].note = note
        aiQueue[idx].status = "ready"
        if !session.isEmpty { aiQueue[idx].refineSession = session }   // keep the conversation id to resume next round
        saveQueue()
        return true
    }

    // True when any candidate still needs analysis — used to decide whether to (re)kick
    // the worker (e.g. on launch, to resume items left pending by a previous run).
    var hasPendingAnalysis: Bool { aiQueue.contains { $0.status == "pending" } }
    // The structured result of promoting a queued candidate ("add"). Carries the new goal's
    // #seq plus whether the AI/user's requested parent actually took — so the caller (and the
    // dashboard) can tell the user "attached under #N" vs "couldn't nest, added at top level".
    struct ResolveResult {
        var seq: Int              // the newly created goal's #seq
        var parentSeq: Int        // the effective parent #seq (0 = top-level)
        var parentFallback: Bool  // true when a requested sub-parent was rejected → fell back to top
    }

    // Resolve one queued candidate. "add" promotes it to a real goal (using `text` if
    // given, else the stored text), "edit" rewrites the stored text and keeps it queued,
    // "skip" (or anything else) just drops it.
    //
    // PROMOTION (Option A + D, one call): "add" is the ONLY place an un-numbered idea becomes
    // a numbered Goal — addGoal mints the seq here. Parent resolution honors the USER's
    // override first. The `parentSeq` argument distinguishes "no override" from "explicit
    // top-level": a sentinel of -1 (or below) means "no override → use the AI's
    // suggestedParentSeq when placement==sub, else top-level"; 0 means "explicit TOP-LEVEL
    // (ignore the AI's sub suggestion)"; > 0 means "explicit parent #seq". If the resolved parent is a
    // valid top-level goal, setParent attaches the new goal as a sub-task; the 1-level-tree
    // guard inside setParent (parent must itself be top-level; a goal with children can't be
    // re-parented) is RESPECTED — if attaching would create 2-level nesting or a cycle, it is
    // rejected and the goal stays TOP-LEVEL (parentFallback=true). Priority is applied when the
    // client (or AI) supplied a valid bucket.
    // Returns a ResolveResult on "add" (so the caller can report placement), nil otherwise.
    @discardableResult
    func resolveQueueItem(id: String, action: String, text: String?, parentSeq: Int = -1,
                          priority: String? = nil) -> ResolveResult? {
        guard let idx = aiQueue.firstIndex(where: { $0.id == id }) else { return nil }
        let item = aiQueue[idx]
        var result: ResolveResult? = nil
        switch action {
        case "add":
            let final = (text?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? item.text
            // Parent #seq precedence: explicit client override (>= 0, including an explicit 0 =
            // force top-level) > AI suggestion (sub only) > stored parent. A sentinel < 0 means
            // the client passed no override, so we defer to the AI's suggestion.
            //
            // `forceTopLevel` records an EXPLICIT parentSeq==0 from the client — this must win
            // over the queue item's own stored parent below (an explicit "make it top-level"
            // override should never silently fall back to a stored sub-parent).
            let forceTopLevel = (parentSeq == 0)
            let effParentSeq: Int
            if parentSeq >= 0 {
                // Explicit client override (0 = force top-level, > 0 = specific parent #seq).
                effParentSeq = parentSeq
            } else if item.placement == "sub" && item.suggestedParentSeq > 0 {
                effParentSeq = item.suggestedParentSeq
            } else {
                effParentSeq = 0
            }
            // Create the goal top-level first (unique seq minted in addGoal), then attempt the
            // sub-attach through setParent so its 1-level guard is the single source of truth.
            let newSeq = addGoal(text: final, sprint: item.sprint)
            // Locate the just-created goal by seq (addGoal appends it).
            guard let gIdx = goals.firstIndex(where: { $0.seq == newSeq }) else {
                aiQueue.remove(at: idx); saveQueue()
                return newSeq > 0 ? ResolveResult(seq: newSeq, parentSeq: 0, parentFallback: false) : nil
            }
            let newGoalId = goals[gIdx].id
            var attachedParentSeq = 0
            var fallback = false
            // Resolve the requested parent #seq to a live goal id; a stale/absent #seq or the
            // queue item's own stored parent id both feed the same guarded attach.
            let requestedParentId: String
            if effParentSeq > 0 {
                requestedParentId = goals.first(where: { $0.seq == effParentSeq })?.id ?? ""
            } else if forceTopLevel {
                requestedParentId = ""   // explicit top-level override wins over any stored parent
            } else {
                requestedParentId = item.parent   // may be "" (top-level)
            }
            if !requestedParentId.isEmpty {
                setParent(id: newGoalId, parent: requestedParentId)   // enforces 1-level tree
                // Verify the attach actually took (setParent rejects 2-level / cycles silently).
                if let after = goals.first(where: { $0.id == newGoalId }), after.parent == requestedParentId {
                    attachedParentSeq = goals.first(where: { $0.id == requestedParentId })?.seq ?? 0
                } else {
                    // Rejected by the 1-level guard → the goal stays top-level. Note the fallback
                    // only when a sub-attach was actually requested (not for a plain top-level add).
                    fallback = (effParentSeq > 0)
                }
            }
            // Apply the (AI- or client-suggested) priority when valid; empty/invalid = keep default.
            let wantPriority = priority?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (item.priority.isEmpty ? nil : item.priority)
            if let pr = wantPriority, ReviewStore.validPriorities.contains(pr) {
                setGoalPriority(ids: [newGoalId], priority: pr)
            }
            aiQueue.remove(at: idx)
            result = ResolveResult(seq: newSeq, parentSeq: attachedParentSeq, parentFallback: fallback)
        case "edit":
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            aiQueue[idx].text = t
        default:   // "skip" and unknown actions drop the item
            aiQueue.remove(at: idx)
        }
        saveQueue()
        return result
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

    // Set/clear the parent of many goals at once. The board's Cmd-drag "fill-down" paints a
    // whole column of rows with one parent, so coalesce into a single save (one disk write,
    // one client refresh) like setGoalPriority. Each id is validated independently against the
    // same 1-level hierarchy rule; ids that would nest 2 levels or self-reference are skipped.
    func setParent(ids: [String], parent: String) {
        var changed = false
        if parent.isEmpty {
            let wanted = Set(ids)
            for i in goals.indices where wanted.contains(goals[i].id) && !goals[i].parent.isEmpty {
                goals[i].parent = ""; changed = true
            }
        } else {
            // Parent must exist and be top-level. A goal that is itself a parent (has children)
            // cannot become a child; a goal cannot be its own parent.
            guard let p = goals.first(where: { $0.id == parent }), p.parent.isEmpty else { return }
            for id in ids where id != parent {
                guard let idx = goals.firstIndex(where: { $0.id == id }),
                      goals[idx].parent != parent,
                      !goals.contains(where: { $0.parent == id }) else { continue }
                goals[idx].parent = parent; changed = true
            }
        }
        if changed { saveGoals() }
    }

    // MARK: Goal links

    // Link source→target: promote the source to top-level (parent="") AND record the link.
    // Flat display is preserved; only export follows links. This is a SEPARATE sanctioned
    // path from setParent — it never nests and never touches the setParent flat-hierarchy
    // guards. No-op if either id is missing, ids are equal, or the link already exists.
    func linkGoal(id source: String, to target: String) {
        guard source != target,
              let sIdx = goals.firstIndex(where: { $0.id == source }),
              goals.contains(where: { $0.id == target }) else { return }
        goals[sIdx].parent = ""                       // promote source to top-level
        if !goals[sIdx].links.contains(target) {      // idempotent append
            goals[sIdx].links.append(target)
        }
        saveGoals()
    }

    // Remove a source→target link. Does NOT re-parent (promotion is a one-way, user-confirmed
    // act — see Phase 1 Q2). No-op if the source goal is missing.
    func unlinkGoal(id source: String, from target: String) {
        guard let sIdx = goals.firstIndex(where: { $0.id == source }) else { return }
        goals[sIdx].links.removeAll { $0 == target }
        saveGoals()
    }

    // MARK: Sprint / Release

    // Assign (or clear with 0) a goal's sprint number. Negative is clamped to 0.
    // sprint: >0 = that sprint; 0 = unassigned/Backlog (children inherit parent's sprint);
    // -1 = explicitly detached Backlog (a child that does NOT follow its parent's sprint).
    func setGoalSprint(id: String, sprint: Int) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].sprint = max(-1, sprint)
        goals[idx].bump = false   // 정리해 스프린트/Backlog로 배정하면 Bump out 인박스에서 빠진다
        saveGoals()
    }

    // DEMOTION REMOVED (deferred-seq / Option A). A numbered Goal can NO LONGER be sent back
    // to the un-numbered idea inbox: doing so would strand a seq (breaking the UNIQUE+IMMUTABLE
    // invariant) or force renumbering. The un-numbered inbox is now exclusively the pending
    // queue (queue.json); promotion out of it is resolveQueueItem("add"). This function only
    // ever CLEARS the legacy bump flag (never sets it true) so any stray bumped goal can still
    // be normalized into Backlog. `bump` is legacy/back-compat only.
    func setGoalBump(id: String, bump: Bool) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        // Ignore requests to bump=true (demotion is disabled); only allow clearing.
        guard goals[idx].bump else { return }
        goals[idx].bump = false
        saveGoals()
    }

    // 보관 / 보관 해제: manually stow a goal away (or bring it back). Archiving hides the goal
    // from every active view but preserves it whole in the 아카이브 view — it is a pure,
    // reversible visibility switch (no sprint change, no Release record). Archiving a PARENT
    // also archives its children so a stowed branch does not leave orphans floating in the
    // active list; un-archiving the parent (or any child) is done one goal at a time.
    func setArchived(id: String, archived: Bool) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].archived = archived
        if archived {
            for i in goals.indices where goals[i].parent == id { goals[i].archived = true }
        }
        saveGoals()
    }

    // Valid 5-level priority buckets (urgent > high > medium > low > lowest).
    static let validPriorities: Set<String> = ["urgent", "high", "medium", "low", "lowest"]

    // Set the priority of one or many goals in a single pass. The board's Cmd-drag "paint"
    // sends a whole batch of ids at once, so coalesce them into a single save (one disk
    // write, one client refresh) instead of N round-trips. Unknown priority values and
    // unknown ids are ignored.
    func setGoalPriority(ids: [String], priority: String) {
        guard ReviewStore.validPriorities.contains(priority) else { return }
        let wanted = Set(ids)
        var changed = false
        for i in goals.indices where wanted.contains(goals[i].id) && goals[i].priority != priority {
            goals[i].priority = priority
            changed = true
        }
        if changed { saveGoals() }
    }

    // Effective sprint of a goal — MUST mirror the board's boardSprint() so "what shows in a
    // sprint group" equals "what that sprint commits". A goal's own sprint wins; a child with
    // no own sprint (0) inherits its (top-level) parent's sprint; a negative sprint is an
    // explicit Backlog and never inherits. Without this, completed sub-items (own sprint 0)
    // roll up under their parent's sprint on the board yet were dropped by an own-field commit.
    private func effectiveSprint(_ g: Goal) -> Int {
        if g.sprint > 0 { return g.sprint }
        if g.sprint < 0 { return 0 }
        if !g.parent.isEmpty, let p = goals.first(where: { $0.id == g.parent }) {
            return max(0, p.sprint)
        }
        return 0
    }

    // Release (커밋) the finished work: take every done, not-yet-released goal matching the
    // filter and commit it. Completion is judged by each goal's OWN status — a PARENT is NEVER
    // auto-committed from its finished children. A big parent is a long-lived history container
    // the user closes MANUALLY (sets its own status to done) only when the work branches; until
    // then it stays active so all lineage lives under one goal. Sprint membership still uses the
    // EFFECTIVE (inherited) sprint so completed sub-items (own sprint 0) ship with the parent's
    // sprint group they visually belong to. Results are GROUPED BY SPRINT — one Release record
    // per sprint number — so the release log always shows which sprint shipped (번호 + 결과물).
    // Each released sprint is also marked closed, dropping it from the 스프린트 관리 list.
    // `sprint == nil` releases across all sprints (still grouped per sprint).
    @discardableResult
    func releaseSprint(_ sprint: Int?) -> [Release] {
        let targets = goals.indices.filter { i in
            !goals[i].released && goals[i].status == "done" &&
            (sprint == nil || effectiveSprint(goals[i]) == sprint!)
        }
        guard !targets.isEmpty else { return [] }
        var groups: [Int: [Int]] = [:]
        for i in targets { groups[effectiveSprint(goals[i]), default: []].append(i) }
        let now = Date()
        var created: [Release] = []
        for (sp, members) in groups.sorted(by: { $0.key < $1.key }) {
            let rid = UUID().uuidString
            let value = members.reduce(0) { $0 + goals[$1].value }
            let rel = Release(id: rid, sprint: sp, code: nextReleaseCode(forSprint: sp),
                              releasedAt: now, value: value,
                              goalIds: members.map { goals[$0].id },
                              titles: members.map { goals[$0].text })
            for i in members { goals[i].released = true; goals[i].releaseId = rid }
            releases.insert(rel, at: 0)   // newest first (commit log order)
            created.append(rel)
            // Close the sprint only once it is fully shipped — if unfinished (non-released)
            // goals remain in it (by effective membership), keep it open so leftover work shows.
            if sp > 0, let si = sprints.firstIndex(where: { $0.number == sp }),
               !goals.contains(where: { effectiveSprint($0) == sp && !$0.released }) {
                sprints[si].closed = true
            }
        }
        saveGoals(); saveReleases(); saveSprints()
        return created
    }

    // Complete a sprint and roll forward. This is the "Complete sprint" action — the
    // bump-out / reset moment (see .doc/sprint-policy.md). In one step it: (1) commits the
    // sprint's finished goals to the 완료 로그, (2) opens a fresh successor sprint (auto
    // start=now, target=now+24h, 1d default — editable), (3) carries every still-unfinished
    // goal of the old sprint into that successor so no work is dropped, and (4) closes the
    // old sprint. Returning the successor lets the caller surface its new code (26-2 → 26-3).
    // The unique sprint code always advances — never reused — so company resource tracking
    // keeps a monotonic period id. Releasing without rolling is still available via
    // releaseSprint (used for the "모든 스프린트" commit path).
    @discardableResult
    func completeSprint(_ number: Int) -> Sprint? {
        guard sprints.contains(where: { $0.number == number }) else { return nil }
        // 1. Commit finished work (done + not-yet-released). Safe when nothing is done —
        //    releaseSprint just returns []; we still close and roll forward below.
        releaseSprint(number)
        // 2. Open the successor (auto 24h window, 1d default).
        let next = createSprint(goalText: "", durationKind: "1d")
        // 3. Carry every still-unfinished goal of the old sprint into the successor.
        for i in goals.indices where goals[i].sprint == number && !goals[i].released {
            goals[i].sprint = next.number
        }
        // 4. Close the old sprint regardless of whether it had finished goals to commit.
        if let si = sprints.firstIndex(where: { $0.number == number }) {
            sprints[si].closed = true
        }
        saveGoals(); saveSprints()
        return next
    }

    // Restore (복원) a release: bring its goals back into the active list, reopen its sprint
    // (so it returns to 스프린트 관리), and drop the release record.
    func restoreRelease(id: String) {
        guard let ri = releases.firstIndex(where: { $0.id == id }) else { return }
        let sp = releases[ri].sprint
        let ids = Set(releases[ri].goalIds)
        for i in goals.indices where goals[i].releaseId == id || ids.contains(goals[i].id) {
            goals[i].released = false; goals[i].releaseId = ""
        }
        if sp > 0, let si = sprints.firstIndex(where: { $0.number == sp }) { sprints[si].closed = false }
        releases.remove(at: ri)
        saveGoals(); saveReleases(); saveSprints()
    }

    private func loadReleases() {
        guard FileManager.default.fileExists(atPath: releasesURL.path),
              let data = try? Data(contentsOf: releasesURL),
              let r = try? JSONDecoder().decode([Release].self, from: data) else { return }
        releases = r
    }
    private func saveReleases() {
        if let data = try? JSONEncoder().encode(releases) {
            try? data.write(to: releasesURL, options: .atomic)
        }
    }

    // Next sprint number: max existing + 1, never reused (mirrors nextSeq for goals).
    private func nextSprintNumber() -> Int { (sprints.map { $0.number }.max() ?? 0) + 1 }

    // Highest used "YY-n" index for a year across BOTH defined sprints and already-issued
    // release codes. Release codes live only on Release records (a partial re-release mints
    // its own code), so a code minter that scanned sprints alone could collide with one a
    // release already took. Scanning both keeps the year sequence unique and monotonic.
    private func maxYearCode(_ yy: Int) -> Int {
        let prefix = "\(yy)-"
        func n(_ code: String) -> Int? {
            guard code.hasPrefix(prefix) else { return nil }
            return Int(code.dropFirst(prefix.count))
        }
        return (sprints.compactMap { n($0.code) } + releases.compactMap { n($0.code) }).max() ?? 0
    }

    // Next user-facing code "YY-n": YY = 2-digit current year, n = max existing n for that
    // year + 1. Year-scoped sequence keeps codes short, unique, and meaningful (26-1, 26-2…).
    private func nextSprintCode() -> String {
        let yy = Calendar.current.component(.year, from: Date()) % 100
        return "\(yy)-\(maxYearCode(yy) + 1)"
    }

    // Code stamped on a new release. The FIRST commit of a sprint keeps the sprint's own
    // code; any LATER partial commit of the same sprint (its code already claimed by an
    // earlier release) splits off under a fresh advancing code, so the release log never
    // shows the same code twice. 미배정 (sprint 0) carries no code.
    private func nextReleaseCode(forSprint sp: Int) -> String {
        guard sp > 0 else { return "" }
        let own = sprints.first(where: { $0.number == sp })?.code ?? ""
        if !own.isEmpty && !releases.contains(where: { $0.code == own }) { return own }
        let yy = Calendar.current.component(.year, from: Date()) % 100
        return "\(yy)-\(maxYearCode(yy) + 1)"
    }
    // Add a duration tag to a date (1d/2d/3d/1w/2w/1m). Used to auto-fill targetAt.
    private func addDuration(_ d: Date, _ kind: String) -> Date {
        var c = DateComponents()
        switch kind {
        case "2d": c.day = 2
        case "3d": c.day = 3
        case "1w": c.day = 7
        case "2w": c.day = 14
        case "1m": c.month = 1
        default:   c.day = 1   // 1d
        }
        return Calendar.current.date(byAdding: c, to: d) ?? d
    }

    // Create a sprint. startAt auto-fills to now, targetAt to now + duration (both editable).
    @discardableResult
    func createSprint(goalText: String, durationKind: String) -> Sprint {
        let dur = Self.validDurations.contains(durationKind) ? durationKind : "1d"
        let now = Date()
        let s = Sprint(number: nextSprintNumber(), code: nextSprintCode(),
                       goalText: goalText.trimmingCharacters(in: .whitespacesAndNewlines),
                       durationKind: dur, startAt: now, targetAt: addDuration(now, dur),
                       createdAt: now)
        sprints.append(s)
        saveSprints()
        return s
    }
    // Update a sprint. Each arg is applied only when provided. Changing the duration
    // recomputes targetAt from startAt UNLESS targetAt is explicitly supplied too. The
    // date args are Date?? so .none = leave alone, .some(nil) = clear, .some(date) = set.
    func updateSprint(number: Int, goalText: String? = nil, durationKind: String? = nil,
                      startAt: Date?? = nil, targetAt: Date?? = nil) {
        guard let idx = sprints.firstIndex(where: { $0.number == number }) else { return }
        if let t = goalText { sprints[idx].goalText = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let d = durationKind, Self.validDurations.contains(d) {
            sprints[idx].durationKind = d
            if case .none = targetAt, let st = sprints[idx].startAt {
                sprints[idx].targetAt = addDuration(st, d)   // keep target in step with duration
            }
        }
        if case let .some(s) = startAt { sprints[idx].startAt = s }
        if case let .some(t) = targetAt { sprints[idx].targetAt = t }
        saveSprints()
    }
    // Delete a sprint definition and unassign every goal that pointed at it (-> backlog).
    func deleteSprint(number: Int) {
        sprints.removeAll { $0.number == number }
        for i in goals.indices where goals[i].sprint == number { goals[i].sprint = 0 }
        saveSprints(); saveGoals()
    }
    private func loadSprints() {
        guard FileManager.default.fileExists(atPath: sprintsURL.path),
              let data = try? Data(contentsOf: sprintsURL),
              let s = try? JSONDecoder().decode([Sprint].self, from: data) else { return }
        sprints = s
        migrateSprints()
    }
    // Backfill code (YY-n) and auto dates for sprints saved before those fields existed.
    private func migrateSprints() {
        var changed = false
        for i in sprints.indices where sprints[i].code.isEmpty {
            sprints[i].code = nextSprintCode(); changed = true
        }
        for i in sprints.indices where sprints[i].startAt == nil {
            let base = sprints[i].createdAt.timeIntervalSince1970 > 0 ? sprints[i].createdAt : Date()
            sprints[i].startAt = base
            if sprints[i].targetAt == nil { sprints[i].targetAt = addDuration(base, sprints[i].durationKind) }
            changed = true
        }
        if changed { saveSprints() }
    }
    private func saveSprints() {
        if let data = try? JSONEncoder().encode(sprints) {
            try? data.write(to: sprintsURL, options: .atomic)
        }
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
    func recordSession(sessionId: String, event: String, text: String = "", transcriptPath: String = "", waitKind: String = "") {
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

        // A user-held goal (완료/중지/취소) is authoritative. The session hooks still refresh
        // its label/transcript above, but must NOT resurrect its status or bank time: the loop
        // skips these, so an incoming active/idle/end/start can never silently pull a done,
        // stopped, or cancelled goal back into the queue. done is included because a manual
        // 완료 is a terminal user decision — without this a live session's next event (e.g.
        // "start" → backlog) reopens it, so a just-completed goal reverts to 대기 on refresh.
        // Only a manual setStatus moves any of these out of the hold.
        if goals[idx].status == "done" || goals[idx].status == "stopped" || goals[idx].status == "cancelled" {
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
            goals[idx].waitKind = ""
            goals[idx].status = "in_progress"
        case "wait", "idle":
            // Park for a human (Notification's `wait` or an ended turn's `idle` — both mean
            // the agent handed control back and Claude Code shows "입력 필요"). Bank what was
            // worked so far, stop the clock, remember when the wait began. Idempotent —
            // re-entering keeps the first `since` so the ⏳ countdown doesn't reset.
            // waitKind splits the wait into 확인 요청(permission) vs 의사결정 요청(decision);
            // an ended turn (idle) with no explicit kind is a decision-style wait.
            bankLive()
            if goals[idx].status != "waiting" {
                // Fresh transition into waiting: stamp the start and the kind (default decision).
                goals[idx].waitingSince = now
                goals[idx].waitKind = waitKind.isEmpty ? "decision" : waitKind
            } else if !waitKind.isEmpty {
                // Already waiting: only an explicit kind (from the hook's Notification message)
                // refines it — so a transcript-inferred reconcile tick can't clobber permission.
                goals[idx].waitKind = waitKind
            }
            goals[idx].status = "waiting"
        case "end":
            bankLive()
            goals[idx].waitingSince = nil
            goals[idx].waitKind = ""
            goals[idx].status = "done"
        default: // "start" — just ensure it exists; never interrupt an active run.
            if goals[idx].status == "in_progress" { bankLive() }
            goals[idx].waitingSince = nil
            goals[idx].waitKind = ""
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

    // Add an extra session id to a goal's manually-linked list (the goal page's "세션 연결"
    // picker). Many-to-one: a goal may gather several sessions. Skips the goal's own
    // primary sessionId (already shown) and duplicates. Returns false for an unknown seq.
    @discardableResult
    func linkGoalSession(seq: Int, sessionId: String) -> Bool {
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, let idx = goals.firstIndex(where: { $0.seq == seq }) else { return false }
        if goals[idx].sessionId == sid || goals[idx].linkedSessions.contains(sid) { return true }
        goals[idx].linkedSessions.append(sid)
        saveGoals()
        return true
    }

    // Remove a manually-linked session id from a goal. No-op (returns false) when the
    // id is the goal's primary sessionId or not in the list — those aren't user-removable here.
    @discardableResult
    func unlinkGoalSession(seq: Int, sessionId: String) -> Bool {
        let sid = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = goals.firstIndex(where: { $0.seq == seq }),
              let pos = goals[idx].linkedSessions.firstIndex(of: sid) else { return false }
        goals[idx].linkedSessions.remove(at: pos)
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
