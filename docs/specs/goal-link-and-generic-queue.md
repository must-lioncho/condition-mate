# SPEC — Goal Link Model + Generic Async Queue Tab

Status: Ready to dispatch
Owner: manager-pm (proposal) / SPEC.md owned by manager-qa
Target app: `projects/condition-manager` (macOS menu-bar app, Swift + in-window WKWebView dashboard)
Related memory: goals-safe-write, agents-page (GET whitelist), session-goal-suppress, data-layout

---

## 요약 (한국어)

- goal-233의 부모를 goal-01로 바꾸려다 아무 일도 안 일어난 건 버그가 아니라 설계 방어입니다. 233이 이미 자식(240·260)을 가진 부모라서 `setParent()`가 2단계 중첩을 막으려 조용히 거부합니다 (`ReviewStore.swift:637-638`, `660-662`).
- 2단계 트리는 안 만듭니다 (렌더·드래그·롤업·삭제/아카이브까지 약 15곳이 흔들림). 대신 **링크(link) 모델**을 추가합니다: 화면 계층은 그대로 1단계 평면, 대신 "내보내기(컨텍스트 압축)"만 링크를 따라 체인 전체를 재귀로 따라갑니다.
- 링크 동작 = 링크 거는 목표를 **최상위로 승격**(`parent=""`)하면서 링크를 기록합니다. "233을 01에 링크" → 233이 최상위가 되고 233→01 링크가 남습니다. 승격 전/후를 그림으로 보여주는 확인 다이얼로그를 띄웁니다.
- 기존 "AI 큐" 인프라를 **범용 비동기 작업 큐 탭**으로 일반화합니다. 오래 걸리는 AI 작업(중복분석·링크맵/내보내기 합성·리포트 생성)을 큐에 던져두고 백그라운드에서 돌리고, 결과(HTML 카드)를 큐 탭에서 봅니다 — "머리 비우고 던져두기". AI 큐 리뷰 UI는 목록 뷰의 인라인 박스에서 **완전히 큐 탭으로 이전**합니다(입력 "AI 추가"는 목록에 남고 리뷰/결과만 이동).
- "내보내기"는 인라인이 아니라 **큐 잡("linkmap")** 으로 실행됩니다. 백그라운드에서 링크 체인을 걸어 노드-링크 지도(실선=부모자식, 보라 점선=링크) HTML과 압축 컨텍스트를 만들어 큐 탭 카드로 올립니다.
- 진행 순서: Phase 0 240/260 중복정리 → Phase 1 링크 모델(백엔드+최소 UI) → Phase 2 범용 큐 탭 → Phase 3 링크맵/내보내기 잡 → Phase 4 manager-qa 검증. goals.json 직접 쓰기 금지, 모든 변경은 앱 API 경유.

---

## 0. Scope, non-goals, invariants

### In scope
Goal-to-goal LINK model (flat display + link-following export), and generalization of the existing AI 큐 into a general-purpose async background-job queue surfaced as its own dashboard tab, with "내보내기(export/compress)" reimplemented as a queued `linkmap` job.

### Non-goals (explicitly OUT — do not touch)
- 2-level tree nesting. The display hierarchy stays flat 1-level.
- Board/group tree rendering, drag-reorder ordering (`reorderGoals`, `dropOn`), rollup/derived status (`derivedStatus`), delete/archive cascade logic. None of these change.
- The `setParent` guards at `ReviewStore.swift:630-642` and `648-667` are NOT relaxed. Links coexist with, and never bypass, the flat-hierarchy rule.

### Hard invariants (must hold in every phase)
1. **Never write `goals.json` directly.** All goal mutations go through app POST APIs (memory: goals-safe-write). New link mutations are POST like `/api/goal/queue/*`.
2. **GET whitelist.** Any new GET route/page MUST be added to the `DashboardServer` GET dispatch in `respond(...)` (`DashboardServer.swift:184-258`). New mutations are POST under `/api/...` (already caught by the `POST && hasPrefix("/api/")` branch at `:188`).
3. **Headless `claude -p` workers set `CM_SUPPRESS_SESSION_GOAL=1`** (memory: session-goal-suppress) — same as `aiDedupVerdict` today.
4. **Backward-compat decoders.** Every new `Goal` / queue-item field decodes via `decodeIfPresent(...) ?? default` (same pattern as `Goal.parent` at `ReviewStore.swift:142` and `AIQueueItem` at `:336-350`). Existing on-disk JSON must still load unchanged.
5. **Single data store** at `~/.condition-manager`, resolution order `CM_DATA_DIR → <repo>/.localdata → ~/.condition-manager` (memory: data-layout). SPEC + ledger currently live at `~/.condition-manager/SPEC.md` and `~/.condition-manager/ledger/agent-update-log.jsonl`.

### Anchor corrections (verified against current code, 2026-07-06)
The originating brief cited a few stale line numbers. Confirmed current anchors:
- `VIEW_DEFS` is at `DashboardContent.swift:2563` (not 2502).
- `aiQueueBoxHTML` at `:1710`; `renderAiQueue` `:1871`; `rerenderAiQueue` `:1878`; `queueAdd` `:1885`; `queueSkip` `:1894`; `queuePromptStart` `:1951`; `_qConfirm` state `:1865`.
- The export builders are the JS `buildMarkdown` at `:3997` and `renderReport` at `:4011` (client-side; these are what actually compose the export/report shown in the 프리뷰 tab). The `#aiQueue` mount div is at `:642` inside `#inputView`.
- `setView` `:2619`, `applyView` `:2621`, `fillActiveView` `:2642`, `renderTabs` `:2577`.
- POST `/api/goal/parent` route: `AppDelegate.swift:2987`. Queue routes: `/queue/add` `:2926`, `/queue/enqueue` `:2938`, `/queue/resolve` `:2951`, `/queue/refine` `:2883`, `/queue/cli` `:2905`.
- Worker: `kickAIQueueWorker` `:3337`, `drainAIQueue` `:3348`, `aiDedupVerdict` `:3377`.

---

## 1. Data model (generalized)

### 1.1 Goal — add `links`

`Goal` gains one field (declared near `parent`/`archived` in `ReviewStore.swift:80-106`, decoded in the tolerant decoder `:137-164`):

```
var links: [String] = []   // linked goal ids (child side records the link; display stays flat)
```

- CodingKeys: add `links` to the enum at `:135`.
- Decoder line (add after `parent` at `:142`):
  `links = try c.decodeIfPresent([String].self, forKey: .links) ?? []`
- Add `links` to `init(...)` signature (default `[]`) and to the assignment block, mirroring `linkedSessions`.
- Semantics: a link is directional, stored on the SOURCE goal (the one that "links to" a target). "233 links to 01" ⇒ goal-233 (`id_233`) has `links = [..., id_01]`. Export following is directional from source → target.

### 1.2 AIQueueItem → generalized job item

Rather than introduce a second struct, **generalize the existing `AIQueueItem`** (`ReviewStore.swift:291-351`) so the dedup queue and the new job kinds share one array (`aiQueue`, `:384`), one worker, and one render path. Add these fields (all `decodeIfPresent`-defaulted so existing queue.json loads unchanged):

```
var jobKind: String = "dedup"    // "dedup" (legacy AI 큐 item) | "linkmap" | "report" | ...
var title: String = ""           // human label for the queue card (falls back to `text`)
var resultHTML: String = ""      // rendered HTML result for jobKind != "dedup" (shown in the card)
var error: String = ""           // non-empty when the job failed; card shows it + a 재시도 button
```

- CodingKeys enum (`:327`): append `jobKind, title, resultHTML, error`.
- Decoder (`:336-350`), append:
  - `jobKind = try c.decodeIfPresent(String.self, forKey: .jobKind) ?? "dedup"`
  - `title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""`
  - `resultHTML = try c.decodeIfPresent(String.self, forKey: .resultHTML) ?? ""`
  - `error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""`
- `init(...)` (`:328-335`): add the four params with defaults; assign them.

### 1.3 How existing dedup items map onto the generalized item (no break)

| Concept | Legacy dedup item | Generalized item |
|---|---|---|
| what kind of job | (implicit: dedup) | `jobKind = "dedup"` (decoder default → legacy items keep working) |
| lifecycle | `status ∈ {pending, analyzing, ready}` | unchanged; new job kinds reuse the SAME three values (`pending` → `analyzing` → `ready`) |
| card label | `text` | `title` if set, else `text` (dedup items leave `title=""` → falls back) |
| result payload | `note` + `matches` (dedup verdict) | dedup unchanged; new kinds put rendered output in `resultHTML` |
| failure | (dedup treats claude-fail as clean verdict) | new kinds set `error` and stay `ready` so the card shows 재시도 |

Status vocabulary stays exactly `pending / analyzing / ready` (`AIQueueItem` doc `:299-305`). "ready" means "terminal, user can act": for dedup = awaiting 추가/수정/스킵; for linkmap/report = result (or error) is ready to view. No new status values — this keeps `resetStaleAnalyzing`, `claimNextPending`, `completeAnalysis` untouched in shape.

---

## Phase 0 — Dedup goal-240 / goal-260

**Goal:** Before any link work, resolve whether goal-240 and goal-260 (current children of goal-233) are genuine distinct work or duplicates, so the link graph starts clean. This is a DATA task, not a code change.

**Files / functions:** none (data only). Uses the existing dedup path: enqueue via `/api/goal/queue/enqueue` (`AppDelegate.swift:2938`) or run the analysis mentally from the 프리뷰. Any consolidation is done via existing goal APIs (`/api/goal/status` for cancel, `/api/goal/parent` to detach), never by editing `goals.json`.

**Data-model diffs:** none.

**API contract:** existing only. To cancel a duplicate: `POST /api/goal/status {"id":"<id>","status":"cancelled"}`. To detach: `POST /api/goal/parent {"id":"<id>","parent":""}`.

**UI:** none.

**Build order:**
1. Read goal-233/240/260 definitions and transcripts (프리뷰 tab or `/goal?n=NN`).
2. Decide: keep both, merge one into the other, or cancel a duplicate.
3. Apply the decision via the existing goal APIs above.

**Acceptance criteria:**
- goal-233's child set is intentionally decided (documented in the task result), and no `goals.json` was hand-edited (verify via git diff on the store is empty for manual edits; all changes went through the running app and appear in `app.log`).

**Risks + mitigations:**
- Risk: cancelling a child the user still wants. Mitigation: `cancelled` is reversible (status back to `backlog`); never delete. Surface the decision to the user before applying.

**Independently verifiable?** Yes — inspect goal-233 children after the pass; no dependency on later phases. This phase can be skipped/deferred without blocking Phase 1.

---

## Phase 1 — Link model (backend + minimal UI)

**Goal:** Store goal-to-goal links; add a mutation that promotes the source goal to top-level AND records the link; show a link indicator on rows that have links. Display hierarchy stays flat.

### Files / functions to change
- `ReviewStore.swift`
  - `Goal` struct `:80-106` (add `links`), decoder `:137-164`, CodingKeys `:135`, `init` `:108-127`. (See §1.1.)
  - New store method (near `setParent` at `:630`):
    ```
    // Link source→target: promote the source to top-level (parent="") AND record the link.
    // Flat display is preserved; only export follows links. No-op if either id is missing,
    // ids are equal, or the link already exists.
    func linkGoal(id source: String, to target: String)
    func unlinkGoal(id source: String, from target: String)
    ```
    Both call `saveGoals()`. `linkGoal` sets `goals[srcIdx].parent = ""` then appends `target` to `links` if absent. Guard: `source != target`, both exist.
- `AppDelegate.swift`
  - New POST cases in the `switch path` block (alongside `/api/goal/parent` at `:2987`):
    `/api/goal/link` and `/api/goal/unlink`. POST is already whitelisted (`DashboardServer.swift:188`), so no GET-whitelist edit here.
- `DashboardContent.swift`
  - Row rendering: add a link indicator dot to goal rows that have `links.length`. Reuse the existing dot style used by the release-log / parent indicator (find the `.pill`/dot styles near `gpill` `:2530`; match the existing dot visual — do NOT invent a new CSS system).
  - Right-click (contextmenu) handler on a goal row → menu item "링크로 연결" → opens a goal-search popup (reuse the existing goal picker pattern used by `gPickParent` `:2668` / parent-by-number `setParentByNumber` `:2515`) to choose the target → confirm dialog showing before/after promotion graphic (mock already approved) → on confirm, `post('/api/goal/link',{id:source,target:tgtId})`.

### Data-model diffs
- `Goal.links: [String]` added (§1.1). No other struct changes in Phase 1.

### API contract
`POST /api/goal/link`
- Request: `{"id":"<sourceGoalId>","target":"<targetGoalId>"}`
- Behavior: promote source to top-level (`parent=""`), append `target` to `source.links` if not present. Idempotent.
- Response: `{"ok":true}` on success; `{"ok":false,"error":"not-found"|"self"}` otherwise.

`POST /api/goal/unlink`
- Request: `{"id":"<sourceGoalId>","target":"<targetGoalId>"}`
- Behavior: remove `target` from `source.links`. Does NOT re-parent (promotion is not undone automatically).
- Response: `{"ok":true}` / `{"ok":false,"error":"not-found"}`.

### UI changes
- Link indicator dot on rows with `links`. Hover/title: "링크됨: goal-NN…".
- Row context menu adds "링크로 연결".
- Goal-search popup to pick the target (accepts `goal-01`, `01`, `1`, matched by stable `seq` like `setParentByNumber`).
- Confirm dialog with before/after promotion graphic; explicit 확인/취소.

### Build order
1. `ReviewStore`: add `links` field + decoder/init/CodingKeys. Build (`swift build`) — verify existing `goals.json` still loads (goal count unchanged in `app.log`).
2. `ReviewStore`: add `linkGoal` / `unlinkGoal`.
3. `AppDelegate`: add `/api/goal/link` + `/api/goal/unlink` POST cases.
4. `DashboardContent`: link dot on rows.
5. `DashboardContent`: context menu → picker → confirm dialog → POST.

### Acceptance criteria (observable/testable)
- AC1: Right-click goal-233 → "링크로 연결" → pick goal-01 → confirm ⇒ goal-233 becomes top-level (`parent==""`) AND `goal-233.links` contains goal-01's id. Verify via `/data.json` (source goal's `parent` empty, `links` populated) and `app.log`.
- AC2: Rows with links show the link dot; rows without links do not.
- AC3: Backward-compat — a `goals.json` written before this change loads with every goal's `links == []`, goal count unchanged.
- AC4: The flat-hierarchy `setParent` guards are unchanged: attempting to set goal-233 (still a parent of others) as a child of goal-01 via `/api/goal/parent` still silently no-ops (unchanged behavior). Linking is the sanctioned path.
- AC5: `/api/goal/link` is idempotent (calling twice does not duplicate the link id).

### Risks + mitigations
- Risk: link creates a hidden many-to-one that later confuses export. Mitigation: export uses a visited-set (Phase 3) to dedup and break cycles.
- Risk: promotion (`parent=""`) surprises the user by moving a goal out of its group. Mitigation: the before/after confirm dialog is mandatory; user sees the promotion before it happens.
- Risk: unlink leaving an orphan-promoted goal. Mitigation: documented — unlink does not re-parent; that is intentional (promotion is a one-way user-confirmed act).

### Independently verifiable? Yes — Phase 1 ships and is testable without the queue or export changes.

---

## Phase 2 — Generic queue tab (generalize AI 큐)

**Goal:** Turn the AI 큐 into a general-purpose async job queue with its OWN dashboard tab. The tab lists every job (all `jobKind`s) with status + result + actions. Existing dedup items appear in it unchanged.

### Files / functions to change
- `ReviewStore.swift`: generalized `AIQueueItem` fields (§1.2). New helpers:
  - `enqueueJob(jobKind:title:origin:) -> String?` — like `enqueuePending` (`:526`) but sets `jobKind`/`title`; returns id; caller kicks the worker.
  - `completeJob(id:resultHTML:error:)` — sets `resultHTML`/`error`, flips `status="ready"` (parallel to `completeAnalysis` `:552`).
- `AppDelegate.swift`:
  - Worker generalization: `drainAIQueue` (`:3348`) currently always calls `aiDedupVerdict`. Branch on `item.jobKind`: `"dedup"` → existing `aiDedupVerdict` + `completeAnalysis` (UNCHANGED path); other kinds → a per-kind runner that produces `resultHTML` (Phase 3 supplies the `linkmap` runner) + `completeJob`. Keep the single serial `aiWorkerQueue` drain loop.
  - Queue read for the tab: the tab reads the queue from the existing payload. Confirm `/data.json` (or `/live.json`) already carries `aiQueue`; if the tab needs a dedicated feed, add `GET /api/queue/list` and **add it to the GET whitelist** at `DashboardServer.swift:234-239`.
  - New POST cases: `/api/queue/retry` (re-enqueue a failed job: set `status="pending"`, clear `error`, kick worker) and `/api/queue/remove` (drop a finished job card).
- `DashboardContent.swift`:
  - `VIEW_DEFS` (`:2563`): add `{k:'queue',t:'큐'}`.
  - Add a `#queueView` container in the dashboard HTML (mirror the other `#xxxView` containers).
  - `applyView` (`:2621`): add `const qv=$('queueView'); qv.style.display=(_view==='queue')?'':'none';`.
  - `fillActiveView` (`:2642`): add `else if(_view==='queue'){ ... renderQueueTab(r); }` (blank the other hosts like the sibling branches).
  - `renderQueueTab(r)`: renders each `aiQueue` item as a card. For `jobKind==='dedup'` reuse the existing `aiQueueBoxHTML` row rendering (`:1710`). For other kinds, render a card with title, status (pending/실행 중/ready), and — when ready — the `resultHTML` (view/download), or `error` + 재시도. **DECIDED (Q1 — full migration):** the dedup review UI moves ENTIRELY into `#queueView`; it is NO longer rendered in `#inputView`.
  - **MOVE the inline AI 큐 review box out of `#inputView`.** Remove the `#aiQueue` mount div from `#inputView` (`:642`) and the `renderAiQueue` call that fills it (`:1871`, invoked from the input-view render path). The 큐 tab (`#queueView`) becomes the SOLE home for the AI 큐 review UI. Relocate — do NOT rewrite — the existing behavior so it renders inside `#queueView`: `aiQueueBoxHTML` row rendering (`:1710`), the number-select 추가/수정/스킵 actions (`queueAdd` `:1885` / `queueSkip` `:1894`), the 5s confirm countdown (`_qConfirm` `:1865`, `queuePromptStart`/confirm timers), the "다시 프롬프트"/refine panel, and focus preservation (`rerenderAiQueue` `:1878`). These keep their exact logic; only their mount point changes to `#queueView`.
  - **Enqueue triggers stay put.** The "AI 추가" field in the input view still POSTs to `/api/goal/queue/enqueue` (`AppDelegate.swift:2938`) — only the REVIEW/RESULT surface moves. After a successful enqueue, optionally surface a subtle hint/badge on the 큐 tab (e.g. an unread count on the tab label) pointing the user to the 큐 tab.
  - **Empty state.** `#queueView` with zero jobs shows a defined empty state (e.g. "큐가 비어 있습니다 — AI 추가로 후보를 던지거나 내보내기를 실행하면 여기에 쌓입니다"), not a blank container.

### Data-model diffs
- Generalized `AIQueueItem` (§1.2): `jobKind`, `title`, `resultHTML`, `error`.

### API contract
- `POST /api/queue/retry` — `{"id":"<jobId>"}` → sets `status="pending"`, clears `error`, kicks worker. Response `{"ok":true}` / `{"ok":false,"error":"not-found"}`.
- `POST /api/queue/remove` — `{"id":"<jobId>"}` → removes the item from `aiQueue`, saves. Response `{"ok":true}`. (Guard: only allow removing `ready`/errored jobs, not `analyzing`.)
- `GET /api/queue/list` (only if a dedicated feed is needed) — returns `{"items":[<AIQueueItem>...]}`. MUST be added to the GET whitelist.

### UI changes
- New "큐" tab in the view-tab bar; it is the SOLE home for the AI 큐 review UI.
- The inline AI 큐 review box is REMOVED from the 목록/input view (`#inputView`). Enqueue triggers ("AI 추가" field) stay in the input view; only the review/result surface moves.
- Queue tab shows all jobs as cards: label, status badge (reuse the `.qrun`/`.qdot` pulse from `aiQueueBoxHTML` `:1720`), and per-kind body/actions.
- Dedup items keep their 추가/수정/스킵 controls, 5s confirm countdown, and refine panel — now inside `#queueView`. Job items get 보기/재시도/다운로드/닫기.
- Empty state defined for `#queueView` when no jobs exist.
- Optional: an unread/count hint on the 큐 tab label after an enqueue.

### Build order
1. `ReviewStore`: generalize `AIQueueItem` (§1.2) + `enqueueJob`/`completeJob`. Build; verify existing queue.json loads (legacy items get `jobKind="dedup"`).
2. `AppDelegate`: branch `drainAIQueue` on `jobKind` (dedup path unchanged); add `/api/queue/retry`, `/api/queue/remove`; add `/api/queue/list` + whitelist if used.
3. `DashboardContent`: `VIEW_DEFS` + `#queueView` + `applyView` + `fillActiveView` + `renderQueueTab`; MOVE the dedup review UI from `#inputView` into `#queueView` (remove `#aiQueue` div `:642` + its `renderAiQueue` fill from the input path); define the empty state.

### Acceptance criteria
- AC1: A "큐" tab appears in the view-tab bar and, when selected, shows exactly the current `aiQueue` items; other views blank correctly (DASH-2 invariant holds — `runQaAudit` finds no id-collision).
- AC2: Existing dedup items render in the queue tab with their 추가/수정/스킵 flow intact (no regression in AI 큐 behavior), including the 5s confirm countdown, the refine ("다시 프롬프트") panel, and focus preservation across the 5s re-render.
- AC3: Backward-compat — legacy queue.json loads; every legacy item reports `jobKind=="dedup"`.
- AC4: A job with `error` set shows the error text and a 재시도 button; 재시도 flips it back to `pending` and the worker re-runs it (observable in `app.log`).
- AC5: The single serial worker still drains one item at a time (no concurrent `claude -p`); confirm the guard (`aiWorkerRunning`) is untouched.
- AC6 (Q1 migration): The 목록/input view NO LONGER contains a queue review box (the `#aiQueue` box is gone from `#inputView`). ALL queue review/confirm/result happens in the 큐 tab. The "AI 추가" enqueue field still works and still posts to `/api/goal/queue/enqueue`; the newly enqueued item appears in the 큐 tab (not under the goals input).
- AC7 (empty state): With an empty `aiQueue`, the 큐 tab shows a defined empty-state message, not a blank container.

### Risks + mitigations
- Risk: moving the dedup review box breaks the enqueue→review handoff (user enqueues in 목록 but review now lives in 큐). Mitigation: enqueue triggers stay in the input view; add a subtle 큐-tab hint/badge after enqueue so the user knows where the item went (AC6 confirms the item lands in the 큐 tab).
- Risk: relocating `_qConfirm`/refine/focus logic subtly breaks the 5s countdown or focus preservation. Mitigation: RELOCATE, do not rewrite — same functions, new mount point; AC2 explicitly re-verifies countdown + refine + focus.
- Risk: mixing dedup and job cards confuses the review flow. Mitigation: group by `jobKind` in `renderQueueTab` (dedup review section vs job-results section).
- Risk: DASH-2 id-collision regression if `#queueView` reuses shared ids (`tt_<id>`, `ev_<id>`). Mitigation: queue tab uses its own ids; `fillActiveView` blanks the shared hosts like every sibling branch.
- Risk: forgetting the GET whitelist for `/api/queue/list`. Mitigation: acceptance test curls the route and expects JSON, not the dashboard HTML fallback.

### Independently verifiable? Yes — Phase 2 ships the tab and generalized queue even before any `linkmap` runner exists (the tab will simply show dedup items). Depends on §1.2 only.

---

## Phase 3 — Linkmap / export job

**Goal:** Reimplement "내보내기" as a queued `linkmap` job. The job walks the link chain in the background, builds a node-link MAP as HTML, builds the compressed export, and posts the result into the queue tab as a card. Export following is link-aware and cycle-safe.

### Files / functions to change
- `DashboardContent.swift`:
  - Export following: the JS `buildMarkdown` (`:3997`) and `renderReport` (`:4011`) currently include only `parent`-children (`goals.filter(c=>c.parent===t.id)`). Add link-following: for each included top goal, recursively follow `g.links` (resolve id→goal), append the linked goal's section marked `↗ goal-NN (링크됨)`, and recurse through THAT goal's parent-children and links. Use a `visited` Set keyed by goal id to dedup and break cycles (01→233→…→01 terminates).
  - The "내보내기" button no longer runs inline — it POSTs `/api/queue/enqueue-linkmap` (fire-and-forget) and switches to the 큐 tab.
- `AppDelegate.swift`:
  - New POST `/api/queue/enqueue-linkmap` → `reviewStore.enqueueJob(jobKind:"linkmap", title:"내보내기 …", origin:<root goal id or scope>)` then `kickAIQueueWorker()`.
  - New `linkmap` runner (called from the `drainAIQueue` branch added in Phase 2). Runs OFF main. It:
    1. Snapshots goals on main (like `aiDedupVerdict` `:3381`).
    2. Walks the link chain from the root with a visited-set.
    3. Builds the node-link MAP HTML: nodes = goals; solid edges = parent-child; purple dashed edges = links; plus a summary (included count / link hops / duplicate warnings).
    4. Builds the compressed export markdown (link-aware, same visited-set).
    5. If it invokes `claude -p` for compression, it MUST set `CM_SUPPRESS_SESSION_GOAL=1` (memory).
    6. `completeJob(id:resultHTML:<map+export HTML>, error: <"" or message>)`.
  - Serving the result: the `resultHTML` is delivered in the queue payload (rendered in the card). If a downloadable/standalone HTML page is needed, add a GET route (e.g. `/queue/result?id=<jobId>`) and **add it to the GET whitelist** (`DashboardServer.swift:258` group, next to `/worker`, `/goal`).

### Data-model diffs
- Reuses generalized `AIQueueItem` (`jobKind="linkmap"`, `resultHTML`, `error`). No new fields beyond Phase 2.

### API contract
- `POST /api/queue/enqueue-linkmap` — `{"root":"<goalId>"}` (root = the goal the user exported from; scope walks its link chain). Response `{"ok":true,"id":"<jobId>"}`. Returns immediately (fire-and-forget).
- `GET /queue/result?id=<jobId>` (only if standalone view/download is needed) — returns the job's `resultHTML` as a full HTML page. MUST be whitelisted.

### UI changes
- "내보내기" becomes an enqueue action + auto-switch to 큐 tab (no inline blocking render).
- Queue card for a `linkmap` job shows: the node-link map (solid = parent-child, purple dashed = links), the summary line, the compressed export, and 보기/다운로드/재시도 actions.

### Build order (depends on Phase 1 links + Phase 2 queue tab)
1. JS export following: extend `buildMarkdown`/`renderReport` to follow `links` with a visited-set (pure client change; testable in 프리뷰 first).
2. `AppDelegate`: `linkmap` runner + `/api/queue/enqueue-linkmap` + wire into the Phase 2 `drainAIQueue` branch.
3. `DashboardContent`: "내보내기" → enqueue + switch to 큐; `renderQueueTab` linkmap card (map + summary + export).
4. Add `/queue/result` GET + whitelist if a standalone/download view is required.

### Acceptance criteria
- AC1: With goal-233 linked to goal-01, enqueuing a linkmap job from goal-01 produces a result whose export INCLUDES goal-233's section marked `↗ goal-233 (링크됨)`, followed recursively through 233's own children/links.
- AC2: A cycle (01→233→…→01) terminates and each goal appears once (visited-set dedup). The summary reports the duplicate/cycle warning rather than looping.
- AC3: The node-link map renders solid edges for parent-child and purple dashed edges for links; the summary shows included count and link hops.
- AC4: "내보내기" returns immediately (does not block the UI) and the result appears as a 큐 card when the worker finishes (observable in `app.log`: enqueue → analyzing → ready).
- AC5: Any `claude -p` invocation in the runner sets `CM_SUPPRESS_SESSION_GOAL=1` (verify no spurious mirrored session goal appears after a linkmap run).
- AC6: Any new GET route (`/queue/result`, `/api/queue/list`) returns its own payload, not the dashboard HTML — proving it was whitelisted.

### Risks + mitigations
- Risk: infinite recursion on link cycles. Mitigation: mandatory visited-set keyed by goal id; AC2 tests a deliberate cycle.
- Risk: export bloat when a link fans into a large subtree. Mitigation: summary surfaces included count; consider a max-hop guard (document the limit if added).
- Risk: worker starvation — a long linkmap job blocks dedup items (single serial worker). Mitigation: acceptable per user intent ("fire and forget"); note it. If it becomes a problem, a priority ordering is a follow-up, not this SPEC.

### Independently verifiable? The JS export-following (step 1) is verifiable standalone in the 프리뷰 tab. The full queued job depends on Phase 1 (links exist) and Phase 2 (queue tab + generalized item + worker branch).

---

## Phase 4 — QA (manager-qa)

**Goal:** Regression + intent verification against SPEC.md for all new behavior, using the manager-qa playbook (isolated bundle, unique bundle id, `CM_QUIT_AFTER`, `app.log`).

**Files:** `~/.condition-manager/SPEC.md` (add the new items in §"SPEC.md edits" below), regenerate `SPEC.html`, append to `~/.condition-manager/ledger/agent-update-log.jsonl`.

**Build order:** run after Phases 1–3 land. Gate shipping on a manager-qa PASS.

**Acceptance criteria:** every AC in Phases 1–3 is verified against the corresponding new SPEC item, with evidence (log lines / `/data.json` / `/api/debug/snapshot`). Any miss triggers the QA fix-loop protocol (max 3 rounds, retro each round; memory: qa-fix-loop-protocol).

**Risks + mitigations:** assuming an un-pinned expectation. Mitigation: if a behavior could go two ways, it goes to OPEN QUESTIONS, not a guessed test.

---

## SPEC.md edits (item id + old→new)

Owner manager-qa applies these to `~/.condition-manager/SPEC.md` (bilingual EN/KO format, per the DASH/EP page style) and regenerates `SPEC.html` in the same change.

- **NEW DASH-6 — goal-to-goal LINK model (flat display, link-following export).**
  EN: A goal may LINK to another goal (`Goal.links: [String]`, source-side). Creating a link PROMOTES the source to top-level (`parent=""`) and records the link; a confirm dialog shows the before/after promotion. Display hierarchy stays flat 1-level (the `setParent` flat guards at `ReviewStore.swift:630-642/648-667` are unchanged). Rows with links show a link dot. Only export/compression follows links.
  KO: 한 목표는 다른 목표로 링크할 수 있다(`Goal.links`, 소스 쪽 기록). 링크를 만들면 소스가 최상위로 승격되고(`parent=""`) 링크가 기록되며, 확인 다이얼로그가 승격 전/후를 보여준다. 화면 계층은 1단계 평면 그대로다(위 `setParent` 방어는 변경 없음). 링크가 있는 행에는 링크 점이 표시된다. 링크는 내보내기(압축)에서만 따라간다.
  Verify: `POST /api/goal/link`, `/data.json` source `parent==""` + `links` populated; `app.log`.

- **NEW DASH-7 — generic async queue tab (generalized AI 큐); dedup review lives ONLY here.**
  EN: `VIEW_DEFS` includes `{k:'queue',t:'큐'}`. The queue tab is the SOLE home for the AI 큐 review UI — the inline queue box previously under the goals input in the 목록/input view is REMOVED. The tab lists all `aiQueue` jobs (`jobKind ∈ {dedup, linkmap, …}`) with status (`pending/analyzing/ready`), result (`resultHTML`) or `error`+재시도. Legacy dedup items (`jobKind` decoder default) render with their 추가/수정/스킵 flow, 5s confirm countdown, and refine panel unchanged — now inside `#queueView`. Enqueue triggers (the "AI 추가" field) stay in the input view and still POST `/api/goal/queue/enqueue`; only the review/result surface moved. The tab has a defined empty state when no jobs exist. One serial background worker drains jobs.
  KO: `VIEW_DEFS`에 `{k:'queue',t:'큐'}`가 포함된다. 큐 탭이 AI 큐 리뷰 UI의 유일한 자리이며, 예전에 목록/입력 뷰의 목표 입력 아래에 있던 인라인 큐 박스는 제거된다. 큐 탭은 모든 `aiQueue` 작업을 상태와 함께 나열하고, 결과(`resultHTML`) 또는 오류+재시도를 보여준다. 기존 dedup 항목은 추가/수정/스킵 흐름·5초 확인 카운트다운·다시 프롬프트 패널이 그대로 유지되며, 이제 `#queueView` 안에서 렌더된다. 후보를 던지는 입력("AI 추가")은 입력 뷰에 그대로 남아 여전히 `/api/goal/queue/enqueue`로 POST하고, 리뷰/결과 화면만 옮겨진다. 작업이 없을 때는 정의된 빈 상태를 보여준다. 백그라운드 워커는 직렬로 하나씩 처리한다.
  Verify: 큐 tab selects and populates only `#queueView` (DASH-2 holds); the 목록/input view has NO `#aiQueue` box; enqueue via "AI 추가" lands the item in the 큐 tab; empty `aiQueue` shows the empty-state message; `runQaAudit` clean.

- **NEW DASH-8 — "내보내기" runs as a queued linkmap job (link-aware, cycle-safe).**
  EN: "내보내기" enqueues a `linkmap` job instead of running inline. The background job walks the link chain with a visited-set (dedup + cycle-break), builds a node-link MAP HTML (solid = parent-child, purple dashed = links, + summary), builds the compressed export following links (linked sections marked `↗ goal-NN (링크됨)`), and posts the result as a queue card. `claude -p` invocations set `CM_SUPPRESS_SESSION_GOAL=1`.
  KO: "내보내기"는 인라인 실행 대신 `linkmap` 작업을 큐에 넣는다. 백그라운드에서 visited-set으로 링크 체인을 걸어(중복·사이클 방지) 노드-링크 지도 HTML(실선=부모자식, 보라 점선=링크, +요약)과 링크를 따라간 압축 내보내기(링크 섹션은 `↗ goal-NN (링크됨)` 표시)를 만들어 큐 카드로 올린다. `claude -p` 호출은 `CM_SUPPRESS_SESSION_GOAL=1`을 설정한다.
  Verify: enqueue from a linked goal → export includes the linked section; deliberate cycle terminates; new GET routes return own payload (whitelisted).

- **EP page — new endpoints.** Add to P6 (Server / endpoints): `POST /api/goal/link`, `POST /api/goal/unlink`, `POST /api/queue/retry`, `POST /api/queue/remove`, `POST /api/queue/enqueue-linkmap`, and (if used) `GET /api/queue/list` + `GET /queue/result` with the note that both GETs are in the `DashboardServer` whitelist.

---

## Delegation plan (one ready-to-paste prompt per phase)

Ordering/dependency: Phase 0 (data, standalone) and Phase 1 (backend `links` + minimal UI) can start immediately and in parallel. Phase 2 depends on §1.2 (generalized item) but not on Phase 1. Phase 3 depends on BOTH Phase 1 (links exist) and Phase 2 (queue tab + worker branch). Phase 4 runs last and gates shipping. Recommended sequence: 1 → 2 → 3 → 4, with 0 done alongside 1.

### Phase 0 → (user decision, optionally general-purpose engineer)
```
Resolve whether goal-240 and goal-260 (children of goal-233) are duplicates or distinct work in the
Condition Manager app. Read each goal's definition/transcript via the 프리뷰 tab or /goal?n=NN. Do NOT
edit goals.json directly — apply any consolidation only through the running app's APIs
(POST /api/goal/status {"id","status":"cancelled"} to cancel a duplicate; POST /api/goal/parent
{"id","parent":""} to detach). Report your decision and the exact API calls made. Cancelling is
reversible; never delete.
```

### Phase 1 → expert-backend (Swift/store/API) then expert-frontend (row UI)
```
Implement the goal LINK model in projects/condition-manager. User: Korean speaker; user-facing strings
Korean, code comments English. Spec: docs/specs/goal-link-and-generic-queue.md (Phase 1). Do NOT edit
goals.json directly; do NOT relax the setParent flat-hierarchy guards (ReviewStore.swift:630-642,
648-667).
Backend (expert-backend):
- ReviewStore.swift: add `var links: [String] = []` to Goal (declare near :80-106; CodingKeys :135;
  decoder after :142 as `links = try c.decodeIfPresent([String].self, forKey:.links) ?? []`; add to
  init :108-127). Add store methods linkGoal(id source:to target:) and unlinkGoal(id source:from
  target:) near :630 — linkGoal sets source.parent="" then appends target to source.links if absent,
  then saveGoals(); guard source!=target and both exist; idempotent.
- AppDelegate.swift: add POST cases /api/goal/link and /api/goal/unlink alongside /api/goal/parent
  (:2987). Request {"id","target"}; responses per the spec's API contract.
Frontend (expert-frontend):
- DashboardContent.swift: add a link-indicator dot to goal rows with links.length, reusing the existing
  release-log/parent dot style (near gpill :2530) — do not invent new CSS. Add a row context menu item
  "링크로 연결" → goal-search popup (reuse the gPickParent/setParentByNumber :2515/:2668 pattern to pick
  the target by goal-NN/seq) → confirm dialog with a before/after promotion graphic (mock approved) →
  on confirm POST /api/goal/link {id:source,target}.
Build with `swift build`; confirm the existing ~/.condition-manager goals.json still loads (goal count
unchanged in app.log). Deliver: acceptance criteria AC1-AC5 from Phase 1 met.
```

### Phase 2 → expert-backend (store/worker/API) + expert-frontend (tab)
```
Generalize the AI 큐 into a general-purpose async queue tab in projects/condition-manager. User: Korean.
Spec: docs/specs/goal-link-and-generic-queue.md (Phase 2, §1.2). Any new GET route MUST be added to the
DashboardServer GET whitelist (DashboardServer.swift:234-258).
Backend (expert-backend):
- ReviewStore.swift: add fields to AIQueueItem (:291-351) — jobKind(default "dedup"), title, resultHTML,
  error — all decodeIfPresent-defaulted; update CodingKeys(:327), decoder(:336-350), init(:328-335). Add
  enqueueJob(jobKind:title:origin:)->String? (like enqueuePending :526) and completeJob(id:resultHTML:
  error:) (like completeAnalysis :552).
- AppDelegate.swift: in drainAIQueue (:3348) branch on item.jobKind — "dedup" keeps the existing
  aiDedupVerdict+completeAnalysis path UNCHANGED; other kinds call a per-kind runner + completeJob. Keep
  the single serial aiWorkerQueue. Add POST /api/queue/retry (status->pending, clear error, kick worker)
  and /api/queue/remove (drop a ready/errored item). If the tab needs a dedicated feed, add GET
  /api/queue/list and ADD IT TO THE GET WHITELIST (:234-239).
Frontend (expert-frontend):
- DashboardContent.swift: add {k:'queue',t:'큐'} to VIEW_DEFS (:2563); add #queueView container; wire
  applyView (:2621) and fillActiveView (:2642) branches (blank shared hosts like siblings); implement
  renderQueueTab(r) — dedup items reuse aiQueueBoxHTML (:1710) rows; other kinds render title/status/
  resultHTML or error+재시도. Preserve DASH-2 (no id collision; runQaAudit clean).
- Q1 FULL MIGRATION (decided): MOVE the dedup review UI ENTIRELY into #queueView. Remove the #aiQueue
  mount div from #inputView (:642) and its renderAiQueue fill from the input-view render path (:1871).
  RELOCATE — do not rewrite — the existing behavior into #queueView: number-select 추가/수정/스킵
  (queueAdd :1885 / queueSkip :1894), the 5s confirm countdown (_qConfirm :1865 + timers), the
  다시 프롬프트/refine panel (queuePromptStart :1951), and focus preservation (rerenderAiQueue :1878).
  Keep the enqueue triggers ("AI 추가" field → /api/goal/queue/enqueue :2938) IN the input view; only the
  review/result surface moves. Optionally add a subtle unread/count hint on the 큐 tab label after an
  enqueue. Define the 큐-tab empty state (no jobs yet).
Deliver: Phase 2 AC1-AC7. The 목록/input view has NO queue box; all review/result is in the 큐 tab;
enqueue via "AI 추가" still works and the item lands in the 큐 tab. Legacy queue.json loads with every
legacy item jobKind=="dedup".
```

### Phase 3 → expert-frontend (JS export + tab card) + expert-backend (runner + route)
```
Reimplement "내보내기" as a queued linkmap job in projects/condition-manager. User: Korean. Spec:
docs/specs/goal-link-and-generic-queue.md (Phase 3). Depends on Phase 1 (Goal.links) and Phase 2
(generalized queue + worker branch). Headless claude -p MUST set CM_SUPPRESS_SESSION_GOAL=1. New GET
routes MUST be whitelisted (DashboardServer.swift:258 group).
Frontend (expert-frontend):
- DashboardContent.swift: extend buildMarkdown (:3997) and renderReport (:4011) to follow g.links
  recursively with a visited-set (dedup + cycle-break); mark linked sections "↗ goal-NN (링크됨)". Make
  "내보내기" POST /api/queue/enqueue-linkmap {root:<goalId>} and switch to the 큐 tab (no inline render).
  In renderQueueTab, render the linkmap card: node-link map (solid = parent-child, purple dashed =
  links) + summary (included count / link hops / duplicate warnings) + compressed export + 보기/다운로드/
  재시도.
Backend (expert-backend):
- AppDelegate.swift: add POST /api/queue/enqueue-linkmap → enqueueJob(jobKind:"linkmap",...) + kick. Add
  the linkmap runner invoked from the Phase 2 drainAIQueue branch: snapshot goals on main, walk the link
  chain with a visited-set, build the map+export HTML into resultHTML via completeJob; set
  CM_SUPPRESS_SESSION_GOAL=1 on any claude -p. If a standalone/download page is needed, add GET
  /queue/result?id=<jobId> and WHITELIST it.
Deliver: Phase 3 AC1-AC6, including a deliberate-cycle test that terminates.
```

### Phase 4 → manager-qa
```
Regression + intent QA for the goal LINK model + generic queue tab + queued linkmap export in
projects/condition-manager, against SPEC.md. User: Korean. Apply the SPEC.md edits from
docs/specs/goal-link-and-generic-queue.md (new DASH-6, DASH-7, DASH-8; EP endpoint additions) to
~/.condition-manager/SPEC.md, regenerate SPEC.html in the same change, and append one line to
~/.condition-manager/ledger/agent-update-log.jsonl. Verify every AC in Phases 1-3 using the manager-qa playbook
(isolated bundle, unique bundle id, CM_QUIT_AFTER, app.log; /data.json and /api/debug/snapshot as
evidence). Specifically confirm: (a) linking goal-233→goal-01 promotes 233 to top-level and records the
link; (b) the flat setParent guards are unchanged; (c) legacy goals.json/queue.json still load; (d) the
큐 tab populates only #queueView (DASH-2); (d2 — Q1 migration) the 목록/input view has NO queue box, ALL
dedup review/confirm/refine now happens in the 큐 tab with countdown+refine+focus intact, "AI 추가"
enqueue still works and the item lands in the 큐 tab, and the empty 큐 tab shows its empty-state message;
(e) export follows links with cycle-safe dedup; (f) new GET routes return their own payload
(whitelisted); (g) no spurious mirrored session goal after a linkmap run (CM_SUPPRESS_SESSION_GOAL). If
any expectation is unpinned or could go two ways, put it in OPEN QUESTIONS and ask — do not guess. On a
miss, run the QA fix-loop protocol (max 3 rounds, retro each).
```

---

## Ordering / dependency summary

- Phase 0: independent (data). Do alongside Phase 1.
- Phase 1: independent backend+UI. Ships and is testable alone.
- Phase 2: needs §1.2 (generalized `AIQueueItem`) only; not Phase 1. Tab is usable with just dedup items.
- Phase 3: needs Phase 1 (links) AND Phase 2 (queue tab + worker branch). The JS export-following sub-step is verifiable standalone in 프리뷰.
- Phase 4: last; gates shipping on manager-qa PASS against DASH-6/7/8.

Each phase has its own acceptance criteria and can be verified before the next begins.

---

## OPEN QUESTIONS — RESOLVED (2026-07-06, locked)

All four are decided; the spec above reflects these. No open questions remain.

- **Q1 — dedup review flow location. RESOLVED: FULL MIGRATION.** The dedup/AI review flow moves ENTIRELY into the new 큐 tab. The inline `#aiQueue` box under the goals input in `#inputView` is REMOVED; the 큐 tab is the sole home for the AI 큐 review UI. Enqueue triggers ("AI 추가" field → `/api/goal/queue/enqueue`) stay in the input view — only the review/result surface moves. All relocated behavior (추가/수정/스킵, 5s confirm countdown, refine panel, focus preservation) is preserved, just rendered inside `#queueView`. A 큐-tab empty state is defined. (Changed from the earlier "keep both" assumption. Encoded in Phase 2 files/build/AC6/AC7, DASH-7, and the Phase 2 delegation prompt.)
- **Q2 — unlink UX. RESOLVED: one-way, NO auto re-parent restoration.** Unlink removes the link only; it does not re-parent the promoted goal. (Matches the original assumption; Phase 1 `unlinkGoal` unchanged.)
- **Q3 — link indicator. RESOLVED: SOURCE only.** The link dot shows on the source goal (the one that links out); no inbound indicator on the target. (Matches the original assumption; DASH-6 unchanged.)
- **Q4 — export root scope. RESOLVED: SINGLE root goal's link chain only.** "내보내기" exports from one root goal passed as `{root}`, walking its link chain — not the whole board. (Matches the original assumption; Phase 3 API contract unchanged.)
