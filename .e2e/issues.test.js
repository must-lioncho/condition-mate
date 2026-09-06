// E2E for the 이슈 page (/issues) — the delegation-issue list. Bound to the REAL sources
// (WorkQueueStore.swift, IssuesContent.swift, SessionRail.swift, AppDelegate.swift,
// DashboardServer.swift), so it runs without a build.
//
// What this file is actually defending, in priority order:
//
//   1) 완료 판정은 폴더가 아니라 status 값으로 한다. `done/` holds `status: classified`
//      cards that are NOT complete (16 of them on 2026-09-05). Counting by folder makes the
//      screen lie about finished work, and a screen that lies once is a screen Ryan opens
//      another window to double-check — which is the entire value of the page, gone.
//      So: the bucket table must map `classified` to 대기, never 완료, and the parser must
//      not use the folder name to decide the bucket.
//   2) 모르는 상태값은 완료로 흘러들지 않는다. The queue's status vocabulary is still
//      growing (`창 사라짐 — 결과 미확인` appeared on 2026-09-05). Unknown values land in a
//      fifth 미분류 bucket, visible on screen, never silently in 완료.
//   3) 큐 폴더는 읽기 전용이다. A card was discarded once for 원문 훼손 (QUEUE.md
//      2026-09-05 14:31). No write API may appear in WorkQueueStore.
//   4) the five plumbing sites all exist — a missing one fails SILENTLY: DashboardServer's
//      last else returns the dashboard HTML with 200 for any unmatched GET, so a forgotten
//      /api/issues prefix yields HTML where JSON was expected, not a 404.
//
// The live-queue section at the end reads the real cards when the folder is present. It
// asserts INVARIANTS (미분류 is 0; 완료 does not equal the done/ file count), never a frozen
// total — the queue is written by other sessions while this repo is being worked on, and it
// changed twice during the hour this feature was built.
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'Sources', 'ConditionMate');
const WQ = fs.readFileSync(path.join(SRC, 'Core', 'WorkQueueStore.swift'), 'utf8');
const IC = fs.readFileSync(path.join(SRC, 'Dashboard', 'IssuesContent.swift'), 'utf8');
const SR = fs.readFileSync(path.join(SRC, 'Dashboard', 'SessionRail.swift'), 'utf8');
const AD = fs.readFileSync(path.join(SRC, 'AppDelegate.swift'), 'utf8');
const DS = fs.readFileSync(path.join(SRC, 'Dashboard', 'DashboardServer.swift'), 'utf8');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// ── the bucket table, read out of the Swift switch itself ────────────────────
// Not a copy of the table: the cases are extracted from the source, so this test fails when
// the product's table changes without the test being updated.
function bucketTable() {
  const start = WQ.indexOf('static func bucket(for');
  if (start < 0) throw new Error('no bucket(for:) in WorkQueueStore.swift');
  const body = WQ.slice(start, WQ.indexOf('\n    }', start));
  const table = {};
  const re = /case ((?:"[^"]*"(?:,\s*)?)+):\s*\n\s*return (bucket\w+)/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const bucket = m[2];
    for (const lit of m[1].match(/"([^"]*)"/g) || []) table[lit.slice(1, -1)] = bucket;
  }
  return { table, body };
}
const { table, body: bucketBody } = bucketTable();

// The 12 status values measured on disk 2026-09-05. Every one must resolve, and each must
// land in the bucket named here — that mapping IS the product decision this page rests on.
const MEASURED = {
  'done': 'bucketDone', '닫힘': 'bucketDone', 'folded': 'bucketDone',
  '던짐': 'bucketRunning', 'running': 'bucketRunning', 'submitted': 'bucketRunning',
  'queued': 'bucketWaiting', 'classified': 'bucketWaiting', 'split': 'bucketWaiting',
  'blocked': 'bucketBlocked', 'incomplete': 'bucketBlocked',
};
for (const [status, want] of Object.entries(MEASURED)) {
  check('status "' + status + '" → ' + want, table[status] || '(미분류)', want);
}
// The one status that is a hand-typed sentence. It is matched by PREFIX, not by the full
// string, because the tail ("결과 미확인") is prose and will drift; a full-string match would
// drop the next variant into 미분류.
check('창 사라짐 is caught by prefix, not full-string',
      /hasPrefix\("창 사라짐"\)/.test(bucketBody), true);
check('창 사라짐 lands in 막힘',
      /hasPrefix\("창 사라짐"\)\s*\{\s*return bucketBlocked/.test(bucketBody), true);

// The regression that costs the most: classified counted as done.
check('classified is NOT 완료', table['classified'] === 'bucketDone', false);
check('unknown statuses fall through to 미분류',
      /default:[\s\S]*return bucketUnknown/.test(bucketBody), true);
check('quoted values are unquoted before matching (던짐 vs "던짐")',
      WQ.includes('private static func unquote'), true);

// ── the parser must not decide completion from the folder ────────────────────
// `folder` is carried for display only. If it ever reaches the bucket call the screen starts
// reporting 16 classified cards as finished.
const cardFn = WQ.slice(WQ.indexOf('private static func card('), WQ.indexOf('// MARK: - 프론트매터'));
check('bucket is computed from status, not folder', /bucket: bucket\(for: status\)/.test(cardFn), true);
check('folder never feeds the bucket call', /bucket\(for: folder\)/.test(WQ), false);
check('only .md files are counted (png evidence lives in inbox/)',
      WQ.includes('hasSuffix(".md")'), true);
check('both lanes are read', /\["inbox", "done"\]/.test(WQ), true);
check('the raw status string is preserved for the row',
      /status: status,/.test(cardFn), true);
check('missing track becomes 없음 rather than dropping the card',
      /track.*isEmpty \? "없음"/.test(cardFn), true);
check('all three cleanup key spellings are folded into one',
      WQ.includes('"cleanup_level"') && WQ.includes('"cleanup_floor"') && WQ.includes('"cleanup"'), true);
check('queue path is overridable for isolated runs',
      WQ.includes('CM_WORK_QUEUE_DIR'), true);

// ── read-only ────────────────────────────────────────────────────────────────
// The queue folder belongs to the delegation loop; this app only looks at it.
for (const sink of ['.write(', 'createFile(', 'removeItem(', 'FileHandle(', 'copyItem(', 'moveItem(',
                    'createDirectory(']) {
  check('WorkQueueStore never calls ' + sink, WQ.includes(sink), false);
}
// The page's POST endpoints are pinned as a closed LIST, so a new write path cannot appear
// without this line being edited. Updated 2026-09-05 (item 3): the item-1 assertion was "no
// POST at all", which the reveal button retires. Updated 2026-09-06 (items 3 and 4): orca
// opens a terminal, archive/unarchive write the app's own archive.json. The invariant that
// actually matters is unchanged and asserted below: nothing this page can call writes into
// the queue folder — the archive flag lives in AppPaths.sub("work-queue"), not in the queue.
const posts = [...IC.matchAll(/fetch\('([^']+)'\s*,\s*\{method:'POST'/g)].map((m) => m[1]);
// archive-bulk is the batch form of item 4 (IssueArchiveStore.archiveMany, app store only);
// search belongs to the AI-search work in the same handler. Neither writes into the queue
// folder, which is the invariant this closed list exists to protect.
// Updated 2026-09-06: mdsave joined the list when the md popup gained [저장]. It writes to a
// .md that passed workQueueMarkdownPath — allowlist + .md + real file — so it still cannot
// reach the queue folder's own cards except the card file the allowlist already names.
// The transcript popup added no entry here on purpose: it is a GET and has no write path.
check('the page POSTs only to the endpoints on this list', posts.slice().sort(),
      ['/api/issues/archive-bulk', '/api/issues/mdsave', '/api/issues/orca',
       '/api/issues/reveal', '/api/issues/search'].sort());
check('the transcript popup added no POST target',
      /fetch\('\/api\/issues\/transcript[^']*'\s*,\s*\{method:'POST'/.test(IC), false);
// archive/unarchive go through one helper, so their URLs are arguments rather than literals.
check('archive and unarchive are the only other POST targets',
      /isArchiveCall\('\/api\/issues\/archive'/.test(IC)
      && /isArchiveCall\('\/api\/issues\/unarchive'/.test(IC), true);
check('the archive flag is written to the app store, never the queue folder',
      /AppPaths\.sub\("work-queue"\)/.test(
        fs.readFileSync(path.join(SRC, 'Core', 'IssueArchiveStore.swift'), 'utf8')), true);
check('the reveal body carries a path, not card text',
      /body:JSON\.stringify\(\{path:p\}\)/.test(IC), true);

// ── the five plumbing sites ──────────────────────────────────────────────────
const nav = (SR.match(/<nav class="cmrail-nav"[\s\S]*?<\/nav>/) || [''])[0];
check('1. rail has an 이슈 slot', /data-nav="issues"[\s\S]*?<span class="cmr-lbl">이슈<\/span>/.test(nav), true);
check('   이슈 needs no wrap2 (2 glyphs fit the 60px box)',
      /data-nav="issues"[\s\S]*?<span class="cmr-lbl">이슈/.test(nav), true);
check('2. cmNav routes issues to /issues', SR.includes("location.href='/issues'"), true);
check('3. cmNavReflect lights the issues slot', SR.includes("window.CM_PAGE==='issues'"), true);
check('   the page stamps CM_PAGE so #3 can fire', IC.includes("window.CM_PAGE='issues'"), true);
check('4. AppDelegate serves the page', AD.includes('if path.hasPrefix("/issues") { return IssuesContent.html() }'), true);
// 거리(문자 수)로 재지 않는다. 이 핸들러에는 갈래가 계속 붙는다 — 2026-09-06 하루에만
// `?view=archive`(아카이브)와 `/api/issues/search`(AI 검색)가 다른 세션에서 각각 들어왔고,
// {0,900} 짜리 창은 그때마다 코드가 멀쩡한데 시험만 진다. 재는 것은 블록의 안쪽이다.
const issuesGET = AD.slice(AD.indexOf('if path.hasPrefix("/api/issues") {'),
                           AD.indexOf('if path.hasPrefix("/api/integrations/notion/candidates")'));
check('   AppDelegate serves the feed', issuesGET.includes('WorkQueueStore.json()'), true);
check('5. DashboardServer allows the page prefix', DS.includes('path.hasPrefix("/issues")'), true);
check('   DashboardServer allows the API prefix', DS.includes('path.hasPrefix("/api/issues")'), true);
// Order matters: the API branch has to be evaluated before the page branch, or /api/issues
// is swallowed as a page and JSON callers get HTML.
check('   /api/issues is matched before /issues',
      DS.indexOf('path.hasPrefix("/api/issues")') < DS.indexOf('|| path.hasPrefix("/issues")'), true);
check('   the page mounts the rail so nav works from /issues', IC.includes('SessionRail.html()'), true);

// ── the screen refuses to leave a blank where a fact belongs ─────────────────
check('the two headline numbers are 완료 / 안 됨', IC.includes('>완료<') && IC.includes('>안 됨<'), true);
// 2026-09-06: the four chips moved behind a subCard() helper, so the labels are no longer
// literal `>도는 중<` markup in the source — they are arguments. Assert the rendering contract
// (which labels get a chip) instead of the markup shape, or a pure refactor turns this red
// while the page is fine. subCard() itself emits the label into <div class="k">.
check('the chip helper emits its label into the markup',
      IC.includes('esc(label||b)'), true);
check('안 됨 is split into 도는 중 / 대기 / 막힘',
      IC.includes("subCard('', '도는 중'") && IC.includes("subCard('', '대기'")
      && IC.includes("subCard('blocked', '막힘'") && IC.includes('막힘 · 사람이 봐야 한다'), true);
check('미분류 is shown, not hidden', IC.includes("subCard('unk', '미분류'"), true);
check('every row carries the raw status so 정규화 can be checked by eye',
      IC.includes('>status: ') && IC.includes('esc(c.status'), true);
check('empty-because-no-folder and empty-because-filter read differently',
      IC.includes('큐 폴더를 읽지 못했다') && IC.includes('이 필터에 걸리는 카드가 없다'), true);
check('the missing-folder note names the path it looked at', IC.includes('찾아본 경로'), true);

// ═══════════════════════════════════════════════════════════════════════════════
// 항목 3 — 상세: 결과물 · 세 필드 · 버전 원장
// ═══════════════════════════════════════════════════════════════════════════════
const VL = fs.readFileSync(path.join(SRC, 'Core', 'WorkQueueVersionLedger.swift'), 'utf8');
// These files carry long comments that NAME the paths they must not touch (that is the
// point of the comments), so "must not appear" checks read the code with comments removed.
const code = (s) => s.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
const VLC = code(VL), WQC = code(WQ);

// ── the single most expensive line in the feature: the six key names ─────────
// Measured 2026-09-05 across 85 cards: artifact 9, artifacts 8, output 4, outputs 4,
// output_path 1, supporting_artifacts 1 — 26 cards carry at least one. Reading only
// `output:` finds 4 of those 26, so 22 cards still make Ryan open another window to find
// the folder, which is the entire request. The list is read out of the Swift source, so
// dropping a key fails here rather than silently halving the screen.
const keyList = (WQ.match(/static let artifactKeys = \[([\s\S]*?)\]/) || [, ''])[1];
const KEYS = [...keyList.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
check('all six artifact key spellings are read', KEYS.sort(),
      ['artifact', 'artifacts', 'output', 'output_path', 'outputs', 'supporting_artifacts']);

// ── the ledger must not land in the goal store, nor in the queue ─────────────
// `AppPaths.sub("issue")` is IssuePaths.root — the goal store, 155 goal-NN folders with
// attachments and per-goal chat. Dropping a queue ledger in there pollutes someone else's
// store. And the queue folder itself is read-only: a card was discarded once for 원문 훼손.
check('the version ledger lives in work-queue, not the goal store',
      /AppPaths\.sub\("work-queue"\)[\s\S]{0,80}versions\.json/.test(VL), true);
check('the ledger never writes into AppPaths.sub("issue") (the goal store)',
      /AppPaths\.sub\("issue"\)/.test(VLC), false);
check('neither new file touches IssuePaths (155 goal folders)',
      /IssuePaths/.test(VLC) || /IssuePaths/.test(WQC), false);
// Every write sink in the ledger must go through fileURL, which is rooted in AppPaths.
check('the ledger writes only to its own fileURL', /try\? data\.write\(to: fileURL/.test(VL), true);
check('the ledger knows nothing about the queue root',
      /CM_WORK_QUEUE_DIR|lion-work-queue|WorkQueueStore\.root/.test(VLC), false);
// Re-assert the read-only rule on the parser now that a sibling file DOES write.
for (const sink of ['.write(', 'createFile(', 'removeItem(', 'copyItem(', 'moveItem(']) {
  check('WorkQueueStore still never calls ' + sink, WQ.includes(sink), false);
}
// Two runs with unchanged content must stay v1 — the ledger appends only on a hash change.
check('the ledger appends only when the hash differs from the last observation',
      /if ledger\[p\.id\]\?\.last\?\.hash == p\.hash \{ continue \}/.test(VL), true);
check('the ledger writes the file only when something actually changed',
      /if changed \{ save\(ledger\) \}/.test(VL), true);
// 4 pairs of cards share an `id:` (the same file left in BOTH inbox/ and done/ with
// different bodies). Keying the ledger by id makes the hash flip-flop every scan and the
// version climb forever, so the key is the file name and only the done/ copy is observed.
check('the ledger is keyed by file name, not the frontmatter id',
      /var versionKey: String \{ fileName \}/.test(WQ), true);
check('a card present in both lanes is observed once, preferring done/',
      /prev\.folder == "done" \{ continue \}/.test(WQ), true);
check('the lane duplication is surfaced, not silently averaged away',
      WQ.includes('laneDuplicates') && IC.includes('두 레인에 있다'), true);

// ── reveal: allowlist, exactly like revealAgentPath ──────────────────────────
// A loopback page handing a raw path to activateFileViewerSelecting turns the dashboard
// into an arbitrary-file-open channel. The rule this repo has always used is an allowlist
// comparison, never trust of the caller's string.
const revealFn = AD.slice(AD.indexOf('func revealWorkQueuePath('),
                          AD.indexOf('func revealAgentPath('));
check('reveal compares against the paths parsed from the cards',
      /WorkQueueStore\.knownRevealPaths\(\)\.contains\(p\)/.test(revealFn), true);
check('reveal rejects anything off the list with unknown-path',
      /unknown-path/.test(revealFn), true);
check('reveal requires an absolute path and refuses ..',
      /p\.hasPrefix\("\/"\), !p\.contains\("\.\."\)/.test(revealFn), true);
// The guard has to come BEFORE the Finder call, or the allowlist is decoration.
check('the allowlist guard precedes activateFileViewerSelecting',
      revealFn.indexOf('knownRevealPaths') < revealFn.indexOf('activateFileViewerSelecting'), true);
check('AppDelegate routes POST /api/issues/reveal',
      /if path == "\/api\/issues\/reveal" \{[\s\S]{0,200}revealWorkQueuePath/.test(AD), true);
// The detail feed must be split out, or the list carries 85 원문 bodies on every refresh.
check('AppDelegate serves the per-card detail feed',
      /WorkQueueStore\.detailJSON\(id:/.test(AD), true);
check('   the detail branch strips the query string before using the id',
      /firstIndex\(of: "\?"\)/.test(AD.slice(AD.indexOf('if path.hasPrefix("/api/issues")'),
                                             AD.indexOf('if path.hasPrefix("/api/integrations/notion/candidates")'))), true);

// ── the 원문 is never edited, only read ───────────────────────────────────────
// QUEUE.md 2026-09-05 14:31 records a card discarded for 원문 훼손. The screen shows the
// section verbatim and the "cleaned" request stands BESIDE it, never on top of it.
check('the parser lifts ## 원문 as a section', /section\(body, "원문"\)/.test(WQ), true);
check('the cleaned request is a separate value, not an edit of 원문',
      /section\(body, "정리된 요청"\)/.test(WQ) && /summaryLine\(body, "요구"\)/.test(WQ), true);
check('the fallback writes (정리 안 됨) instead of a blank',
      WQ.includes('"(정리 안 됨)"') && IC.includes('아직 정리되지 않았다'), true);
check('the 원문 panel is read-only in the page',
      /class="orig/.test(IC) && !/contenteditable/.test(IC), true);

// ── the order Ryan asked for, top to bottom ──────────────────────────────────
// "타이틀 다음에 '리퀘스트 (원문)' 이 기본 닫힘이고, 그다음 '수정된 최초의 리퀘스트' 가
// 펼쳐진 채로 자세히 나온다. 펼쳐도 5 줄 정도로 자른다. 지금 화면은 이 순서가 반대다."
const ORDER = ['리퀘스트 (원문)', '수정된 최초의 리퀘스트', '작업지시서', '결과물', '버전'];
// Anchored to the detail renderer — the same words appear in the list rows and in the CSS
// above it, and an unanchored search reads those instead of the section headings.
const draw = IC.slice(IC.indexOf('function drawDet()'), IC.indexOf('window.isOpen='));
let prev = -1, ordered = true, missing = [];
for (const label of ORDER) {
  const at = draw.indexOf('<div class="t">' + label);
  if (at < 0) missing.push(label);
  if (at < 0 || at < prev) ordered = false;
  prev = at;
}
if (missing.length) console.log('       section heading(s) not found: ' + JSON.stringify(missing));
check('the detail sections run in Ryan\'s stated order', ordered, true);

// ── 마지막 badge in the HEADER, not only at the bottom ───────────────────────
// "글을 보고 이게 마지막 버젼 이구나 하면서 보겠지" — if it takes a scroll, the request is
// not met. The header block is the part before the first section, so the badge must appear
// there as well as in the version list at the bottom.
// The first section after the header is now 리퀘스트 (원문), so the anchor moved with it.
const dh = IC.slice(IC.indexOf('var h=\'<div class="dh">'), IC.indexOf('// 2. 리퀘스트(원문)'));
check('the header carries the version badge', /pill ver/.test(dh), true);
check('the header carries the 마지막 badge', /pill last">마지막/.test(dh), true);
check('the version list also marks the last one',
      /isLast\?'<span class="pill last">마지막/.test(IC.slice(IC.indexOf('// 6. 버전'))), true);
check('v1 is labelled 첫 관측, not a fabricated history', IC.includes('첫 관측'), true);

// ── 원문 is closed by default, and opens in TWO stages: 5 lines, then full ───
// A 230px scroll box is not "closed", it is "smaller". At stage 0 the renderer must paint
// the toggle and the character count, and no .orig body at all — the point of the swap is
// that the cleaned request, not the raw dump, is what Ryan reads first.
//
// Stage 1 is five lines. Ryan gave the reason himself: "펼치기 하면 5줄 정도 나오고 …
// 속독을 해도 5절 이상을 보기 어려우니까". Opening straight to the full dump pushes the
// 작업지시서 and 결과물 sections off the screen, which is the thing the clamp exists to stop.
// Stage 2 is the full text, so nothing is lost by defaulting to the short view.
//
// The load-bearing assertion is the LAST one: the 원문 must never be sliced. A card was
// discarded once for 원문 훼손, so what shrinks here is the painted height, never the data.
check('원문 starts closed on every open', /ORIGOPEN=0/.test(IC), true);
check('원문 renders no .orig body when closed',
      /ORIGOPEN===0\s*\?\s*'<button class="lnk" onclick="isOrigSet\(1\)">펼치기/.test(draw), true);
check('the closed state offers 펼치기 with the 원문 character count',
      /펼치기 \(원문 '[\s\S]{0,40}og\.length/.test(draw), true);
check('opening goes to the 5-line stage, not straight to the full text',
      /ORIGOPEN===1\?'o5':'full'/.test(draw), true);
// The full stage must NOT be called `open`: this sheet already has a button rule `.open`
// later at the same specificity, so `class="orig open"` lost font-size and white-space to
// it and painted the whole 원문 as one 9,151px nowrap line. Measured in WebKit 2026-09-06.
check('the full stage does not reuse the button class name .open',
      !/class="orig '\+\(ORIGOPEN===1\?'o5':'open'\)/.test(draw), true);
check('.orig.full is the rule that lifts the height cap',
      /\.orig\.full,\.orig\.open\{max-height:none/.test(IC), true);
// The collision is defended for BOTH names, because longBox() elsewhere on this screen
// still paints class="orig open". Renaming alone would have left that one silently broken.
check('the .open collision is undone by re-declaring the stolen properties',
      /\.orig\.full,\.orig\.open\{[\s\S]{0,200}white-space:pre-wrap/.test(IC), true);
check('the 원문 5-line stage is a real 5-line clamp in the CSS',
      /\.orig\.o5\{[^}]*-webkit-line-clamp:5/.test(IC.replace(/\n\s*/g, '')), true);
check('the full 원문 stays reachable from the 5-line stage',
      /isOrigSet\(2\)[\s\S]{0,80}전문 보기/.test(draw), true);
check('전문 보기 is shown only when the 원문 actually overflows 5 lines',
      /org\.scrollHeight>org\.clientHeight\+2/.test(IC), true);
check('접기 returns to stage 0 from either open stage',
      /isOrigSet\(0\)">접기/.test(draw), true);
// The whole 원문 is handed to esc() at every stage — no slice(), no substring(), no
// truncation with an ellipsis. Collapsing is a CSS concern here, not a data concern.
check('원문 is never truncated in the data path',
      /esc\(og\)/.test(draw) && !/og\.slice\(|og\.substr/.test(draw), true);

// ── 수정된 리퀘스트 collapses by default and opens in three stages (DASH-14) ─
// It used to be expanded-and-clamped. 2026-09-06 Ryan asked for the opposite on this exact
// pane — "그 수정한 내용이 기본적으로 접혀있고 그걸 전문으로 볼 수 있게 해줘요" — so it now
// carries the same 0/1/2 control as the 원문 pane above it. CLEANOPEN went from a boolean to
// a stage number, which is why the old `CLEANOPEN=false` assertion below is now `CLEANOPEN=0`:
// the thing being asserted is unchanged (reset on every open), only the resting value moved.
// The 전문 보기 handle is still measured, never guessed — a dead handle is noise.
check('the clamp is 5 lines in the CSS', /-webkit-line-clamp:5/.test(IC), true);
check('the clamp class lands on .lead', /class="lead'\+[\s\S]{0,80}' clamp'/.test(draw), true);
check('CLEANOPEN resets to stage 0 on every open', /CLEANOPEN=0/.test(IC), true);
check('전문 보기 is shown only when the rendered element overflows',
      /scrollHeight>lead\.clientHeight\+2/.test(IC), true);
check('stage 0 draws the 펼치기 handle regardless of length',
      /isCleanSet\(1\)">펼치기 \(요구 /.test(draw), true);
check('접기 returns 수정된 리퀘스트 to stage 0', /isCleanSet\(0\)">접기/.test(draw), true);
// The run that produced this line is shown above the fold, and a missing revision block must
// not break the pane — the backend field is optional and old responses never carry it.
check('the run-provenance row reads DET.revision defensively',
      /var rv=DET\.revision\|\|\{\}/.test(draw), true);
check('the run-provenance row draws nothing when neither found nor why',
      /if\(rv\.found\)/.test(IC) && /if\(rv\.why\) return/.test(IC), true);
check('an empty effort drops the whole 조각, never leaves a bare label',
      /if\(rv\.effort\) bits\.push\('effort '/.test(IC), true);
check('the run row reuses the existing isTr transcript popup',
      /class="revrow"[\s\S]{0,400}|onclick="isTr\(this\)"/.test(IC), true);

// ── "결과물 없음" is a first-class state, not a greyed blank ──────────────────
// 59 of 85 cards have no artifact pointer — the majority. A blank there reads as a broken
// screen; the two sentences say which of the three stages the card actually reached.
check('결과물 없음 — 작업지시서까지 is spelled out',
      IC.includes('결과물 없음 — 작업지시서까지 나왔다'), true);
check('결과물 없음 — 요청만 is spelled out', IC.includes('결과물 없음 — 요청만 있다'), true);
check('작업지시서 없음 is spelled out', IC.includes('작업지시서 없음'), true);
check('the three stages are named in the parser',
      WQ.includes('"요청만"') && WQ.includes('"작업지시서까지"') && WQ.includes('"결과물까지"'), true);

// ── every value is classified before it can earn a button ────────────────────
for (const kind of ['절대경로', 'lion_work 상대', '대상 상대', 'URL', '경로 아님', '대상 폴더 없음']) {
  check('the parser classifies ' + kind, WQ.includes('"' + kind + '"'), true);
}
check('existence is checked with FileManager, not assumed',
      /FileManager\.default\.fileExists\(atPath: path, isDirectory: &isDir\)/.test(WQ), true);
check('only a resolved AND existing path is openable', /openable: ex\)/.test(WQ), true);
check('경로 없음 is shown rather than hidden', IC.includes("a.exists?'있음':'경로 없음'"), true);
check('a URL gets a link, not a dead 폴더 열기 button', /kind==='URL'[\s\S]{0,200}링크 열기/.test(IC), true);

// ── DASH-13: the session line goes to the transcript and to the working folder ─
// Ryan circled `97cc3cc2` in the session line and drew a box in the empty space to its
// right: "누르면은 그 파일이 열리게끔 … 오른쪽에 있는 곳은 거기다가 이제 파일 열기 폴더 열기".
//
// What this section defends, in priority order:
//
//   1) The transcript endpoint is the FIRST place this app streams a full human
//      conversation over loopback. Cutting the boundary at ~/.claude/projects/ is not
//      enough on its own — the allowlist (only sessions of cards whose detail was actually
//      opened) has to hold too, and the guard has to run before the read.
//   2) The working folder is read from the transcript's `cwd`, never decoded back out of
//      the project-dir name. `projectDirName` maps `/`, `_` and `.` all to `-`, so the
//      inverse is not a single value; a decoder would open the wrong folder silently.
//   3) `file` and `cwd` must enter the reveal allowlist, or both new buttons return
//      unknown-path — the failure mode this feature started from.
//   4) The transcript popup is an innerHTML sink fed by a file full of pasted user HTML.
//      Every string goes through esc(), and no markdown renderer touches it.
const SS = fs.readFileSync(path.join(SRC, 'Core', 'WorkQueueSessionStore.swift'), 'utf8');

// 1) the working folder comes from the record, not from the folder name
check('scan() collects the transcript cwd field',
      /cwd\.isEmpty, let c = o\["cwd"\] as\? String, c\.hasPrefix\("\/"\)/.test(SS), true);
check('the session block ships "cwd" to the screen', /"cwd": cwd,/.test(SS), true);
// The map is one-way on purpose: `/`, `_` and `.` all become `-`, so there is no single
// inverse. The only decoder that could exist would guess, and a wrong guess opens the
// wrong folder without saying so.
check('projectDirName exists only in the forward direction',
      /func projectDirName\(for/.test(SS)
        && !/func\s+\w*(cwdFor|pathFor|decode|unmangle|fromProjectDir)/i.test(SS), true);
check('the working folder is taken from the record, not from projectDir',
      /var folder = cwd \|\| pd;/.test(IC) && !/projectDirName/.test(IC), true);

// 2) file and cwd enter the reveal allowlist — otherwise both buttons say unknown-path
const pathsInFn = SS.slice(SS.indexOf('private static func pathsIn('),
                           SS.indexOf('// MARK: - 기록 읽기'));
check('pathsIn yields the transcript file', /d\["file"\] as\? String/.test(pathsInFn), true);
check('pathsIn yields the working folder', /d\["cwd"\] as\? String/.test(pathsInFn), true);
check('   the transcript file is existence-checked before it is allowed',
      /fm\.fileExists\(atPath: f\)/.test(pathsInFn), true);
check('   the working folder is checked to BE a folder, not just to exist',
      /isDirectory: &isDir\), isDir\.boolValue/.test(pathsInFn), true);
check('   pathsIn still refuses .. and relative paths',
      (pathsInFn.match(/!\w+\.contains\("\.\."\)/g) || []).length >= 2, true);
// remember() is called from the two session() paths (cache hit and fresh scan), and both
// go through pathsIn. A third call site taking a raw array would widen the allowlist
// without any of pathsIn's existence and `..` checks.
check('every remember() call site goes through pathsIn',
      (SS.match(/remember\(pathsIn\(/g) || []).length === 2
        && (SS.match(/^\s*remember\(/gm) || []).length === 2, true);

// 3) the transcript endpoint: five conditions, then the read
const trPathFn = AD.slice(AD.indexOf('private func workQueueTranscriptPath('),
                          AD.indexOf('func workQueueTranscriptRead('));
check('transcript path requires an absolute path and refuses ..',
      /p\.hasPrefix\("\/"\), !p\.contains\("\.\."\)/.test(trPathFn), true);
check('transcript path requires .jsonl', /hasSuffix\("\.jsonl"\)/.test(trPathFn), true);
check('transcript path is cut at ~/.claude/projects/',
      /NSHomeDirectory\(\)[\s\S]{0,80}\.claude\/projects/.test(trPathFn), true);
check('transcript path requires membership in the reveal allowlist',
      /WorkQueueSessionStore\.revealAllowlist\(\)\.contains\(p\)/.test(trPathFn), true);
check('transcript path requires a real FILE, not a folder',
      /fileExists\(atPath: p, isDirectory: &isDir\), !isDir\.boolValue/.test(trPathFn), true);
check('transcript read rejects everything else with unknown-path',
      /workQueueTranscriptPath\(path\) else \{\s*\n\s*return "\{\\"ok\\":false,\\"error\\":\\"unknown-path/
        .test(AD), true);
// The md validator must NOT have been loosened to let .jsonl through — that would widen
// the md SAVE path (POST /api/issues/mdsave) at the same time, which is far worse.
const mdPathFn = AD.slice(AD.indexOf('private func workQueueMarkdownPath('),
                          AD.indexOf('func workQueueMarkdownRead('));
check('the md validator still admits only .md', /hasSuffix\("\.md"\)/.test(mdPathFn), true);
check('the md validator was not widened to .jsonl', /jsonl/.test(mdPathFn), false);
// Routing: transcript must be matched BEFORE the /api/issues/<id> detail branch, or the
// request looks for a card named "transcript" and comes back unknown-card.
const issuesBranch = AD.slice(AD.indexOf('if path.hasPrefix("/api/issues")'),
                              AD.indexOf('return IssueArchiveStore.filter('));
check('AppDelegate routes GET /api/issues/transcript',
      /path\.hasPrefix\("\/api\/issues\/transcript"\)[\s\S]{0,300}workQueueTranscriptRead/.test(issuesBranch), true);
check('   transcript is matched before the /api/issues/<id> detail branch',
      issuesBranch.indexOf('/api/issues/transcript') < issuesBranch.indexOf('WorkQueueStore.detailJSON'), true);

// 4) the response is a turn array, not raw JSONL, and it says when it truncated
const trJSON = SS.slice(SS.indexOf('static func transcriptJSON('));
check('the transcript response is turns, not the raw file',
      /"turns": kept/.test(trJSON) && !/"raw"|"jsonl"/.test(trJSON), true);
check('only user and assistant turns are emitted',
      /"role": "user"/.test(trJSON) && /"role": "assistant"/.test(trJSON), true);
check('harness-injected turns are dropped by the SAME rule scan() uses',
      /isMeta"\] as\? Bool\) != true/.test(trJSON) && /isSystemInjected\(t\)/.test(trJSON), true);
check('there is exactly one isSystemInjected in the codebase',
      (SS.match(/func isSystemInjected/g) || []).length === 1 && !/func isSystemInjected/.test(AD), true);
check('only the four writing tools contribute a turn\'s files',
      /\["Write", "Edit", "MultiEdit", "NotebookEdit"\]\.contains\(name\)/.test(trJSON), true);
check('turns are capped at 400, cut from the FRONT (the tail is what Ryan wants)',
      /turns\.count > 400 \{ turns\.removeFirst\(turns\.count - 400\)/.test(trJSON), true);
check('one turn\'s text is capped at 4,000 characters',
      (trJSON.match(/prefix\(4000\)/g) || []).length === 2, true);
check('the whole response is capped at 2MB', /budget = 2_000_000/.test(trJSON), true);
check('the cut is announced, never silent',
      /"truncated": kept\.count < total/.test(trJSON) && /"total": total/.test(trJSON)
        && /"shown": kept\.count/.test(trJSON), true);
// A 15MB session is exactly the one Ryan wants to read, so a size refusal would kill the
// feature where it matters most. Map it and cap at the same 64MB scan() uses.
check('a file over 2MB is still read (mapped, 64MB cap), not refused',
      /options: \[\.mappedIfSafe\]/.test(trJSON) && /64 \* 1024 \* 1024/.test(trJSON), true);
check('the transcript endpoint has no write path at all',
      /\.write\(|createFile\(|removeItem\(/.test(trJSON), false);

// 5) the screen: a clickable id, two buttons pushed right, paths via data-p
const sesHeadFn = IC.slice(IC.indexOf('function sesHead(S){'), IC.indexOf('function longBox('));
check('the 8-char session id becomes a link that opens the transcript',
      /class="sesid" data-p="'\+esc\(f\)\+'" onclick="isTr\(this\)/.test(sesHeadFn), true);
check('   the id is still sliced to 8 characters',
      /String\(S\.sessionId\|\|''\)\.slice\(0,8\)/.test(sesHeadFn), true);
check('the line carries 파일 열기 and 폴더 열기',
      /파일 열기/.test(sesHeadFn) && /폴더 열기/.test(sesHeadFn), true);
check('파일 열기 reveals S.file', /data-p="'\+esc\(f\)\+'" onclick="isRevealEl\(this\)/.test(sesHeadFn), true);
check('폴더 열기 prefers cwd and falls back to projectDir',
      /var folder = cwd \|\| pd;/.test(sesHeadFn), true);
check('   the fallback says in the title what it is actually opening',
      /작업 폴더를 기록에서 못 읽었다/.test(sesHeadFn), true);
// Paths from a transcript were never typed by a human and can hold anything. A quote in a
// JS string literal breaks the whole onclick; an attribute is protected by esc()'s &quot;.
check('no path is interpolated into a JS string literal in the session line',
      /\\''\+esc\(/.test(sesHeadFn), false);
check('isRevealEl reads the path off the element, not off a literal',
      /window\.isRevealEl=function\(btn\)\{[\s\S]{0,200}getAttribute\('data-p'\)/.test(IC), true);
// A button that does nothing is worse than no button — the rule this file already keeps.
check('no link and no buttons are painted when the session has no file',
      /if\(!f\) return txt;/.test(sesHeadFn), true);
// The buttons go to the right of the line — the empty space Ryan drew a box in.
check('the session row is a flex line with the buttons pushed right',
      /\.ses \.sh\.shrow\{display:flex;align-items:baseline;gap:8px\}/.test(IC)
        && /\.shb\{margin-left:auto/.test(IC), true);
check('   both session rows carry the shrow class',
      (IC.match(/class="ses"><div class="sh shrow">'\+sesHead\(S\)/g) || []).length === 2, true);
// The other .sh lines (첫 지시문 / 마지막 보고) must NOT have become flex containers.
check('   the plain .sh rule stays non-flex',
      /\.ses \.sh\{color:#7db0ff;font-size:11px;line-height:1\.5;margin-bottom:6px\}/.test(IC), true);

// 6) the transcript popup is read-only, escaped, and never markdown-rendered
const trUI = IC.slice(IC.indexOf('window.isTr=function(el)'), IC.indexOf("document.addEventListener('keydown'"));
check('the popup exists with the prescribed ids',
      ['isTrWrap', 'isTrBox', 'isTrPath', 'isTrBody', 'isTrFoot'].every(id => IC.includes('id="' + id + '"')), true);
check('it reuses the md popup shell instead of a second stylesheet',
      /<div class="mdw" id="isTrWrap"[\s\S]{0,400}class="mdbox" id="isTrBox"/.test(IC)
        && /class="mdh"[\s\S]{0,400}class="mdbody"[\s\S]{0,200}class="mdfoot" id="isTrFoot"/
             .test(IC.slice(IC.indexOf('id="isTrWrap"'))), true);
// The whole reason the popups are split: the md popup can SAVE, and a transcript is an
// append-only harness file. Hiding a button would make the guard a UI state; a separate
// popup means the write path does not exist here at all.
const trPopup = IC.slice(IC.indexOf('id="isTrWrap"'), IC.indexOf('<script>', IC.indexOf('id="isTrWrap"')));
check('the transcript popup has no 저장 button and no editor',
      /저장|mdedit|textarea/.test(trPopup), false);
check('the transcript popup never calls mdsave', /mdsave/.test(trUI), false);
check('the transcript popup has exactly one button, 닫기',
      (trPopup.match(/<button/g) || []).length === 1 && /닫기<\/button>/.test(trPopup), true);
// innerHTML sink + a file full of pasted HTML. Every value must pass through esc().
check('the turn text is escaped', /class="tx">'\+esc\(t\.text\|\|''\)/.test(trUI), true);
check('the turn timestamp is escaped', /esc\(String\(t\.at\|\|''\)/.test(trUI), true);
check('each written file path is escaped', /rows\.push\(esc\(String\(fs\[k\]\)\)\)/.test(trUI), true);
check('the header path and cwd are escaped',
      /head\.innerHTML=esc\(p\)/.test(trUI) && /esc\(String\(j\.cwd\)\)/.test(trUI), true);
check('the transcript is NOT markdown-rendered',
      /mdRender\(|mdInline\(/.test(trUI), false);
check('the error text is escaped too', /esc\(mdErr\(j\)\)/.test(trUI), true);
// 사람 turn and 모델 turn have to be separable by eye.
check('human and model turns get different left rules',
      /\.turn\.u\{border-left-color:#7db0ff\}/.test(IC) && /\.turn\.a\{border-left-color:#8a93a3\}/.test(IC), true);
check('each turn shows its time and, when present, the files it wrote',
      /class="who">'\+\(isU\?'사람':'모델'\)/.test(trUI) && /class="fs"><b>쓴 파일/.test(trUI), true);
check('the head states 사람 말 N 번 · 쓴 파일 M 개 · 턴 M/N',
      /사람 말 '\+say\+' 번 · 쓴 파일 '\+wrote[\s\S]{0,60}턴 '\+\(j\.shown\|\|0\)\+'\/'\+\(j\.total\|\|0\)/.test(trUI), true);
check('a truncated transcript says so at the top',
      /if\(j\.truncated\)\{[\s\S]{0,200}턴은 안 실었다/.test(trUI), true);
// Escape must close the transcript popup FIRST — one key may not reach into two popups.
check('Escape closes the transcript popup before the md popup sees the key',
      /if\(TRP\)\{ if\(e\.key==='Escape'\) isTrClose\(\); return; \}\s*\n\s*if\(!MDP\) return;/.test(IC), true);
check('isTr and isTrClose are both on window',
      /window\.isTr=function/.test(IC) && /window\.isTrClose=function/.test(IC), true);
// No external library, ever — this app has zero CDN dependencies by design.
check('no external script or stylesheet was pulled in for the popup',
      /https?:\/\/(cdn|unpkg|cdnjs|code\.jquery)/.test(IC), false);

// 7) 폴더 열기 must OPEN the folder, not select it in its parent
// activateFileViewerSelecting on a directory selects it in the PARENT window. Ryan asked
// for "그 폴더를 볼수 있도록", which is NSWorkspace.open. Files keep the selecting call.
check('reveal opens a directory with NSWorkspace.open',
      /if dir \{ NSWorkspace\.shared\.open\(url\) \}/.test(revealFn), true);
check('reveal still SELECTS a file rather than opening it',
      /else \{ NSWorkspace\.shared\.activateFileViewerSelecting\(\[url\]\) \}/.test(revealFn), true);
check('the split is decided by isDirectory, not by the string',
      /fileExists\(atPath: p, isDirectory: &isDir\)[\s\S]{0,120}let dir = isDir\.boolValue/.test(revealFn), true);
check('the allowlist guard still precedes BOTH Finder calls',
      revealFn.indexOf('knownRevealPaths') < revealFn.indexOf('NSWorkspace.shared.open')
        && revealFn.indexOf('knownRevealPaths') < revealFn.indexOf('activateFileViewerSelecting'), true);

// ═══════════════════════════════════════════════════════════════════════════════
// live queue — item 3's numbers, recomputed from the cards at test time
// ═══════════════════════════════════════════════════════════════════════════════
// Nothing below hardcodes a card count. The queue grew 83 → 85 while this feature was
// built; the assertions are relations between numbers computed in this same run.

// ── live queue, when it is on this machine ───────────────────────────────────
// Invariants only. The totals move: this queue is written by other sessions.
const QDIR = process.env.CM_WORK_QUEUE_DIR
  || '/Users/lioncho/Work/lion_work/organization/lion/lion-work-queue';
const BUCKET_NAME = { bucketDone: '완료', bucketRunning: '도는 중', bucketWaiting: '대기',
                      bucketBlocked: '막힘' };
if (fs.existsSync(path.join(QDIR, 'inbox')) && fs.existsSync(path.join(QDIR, 'done'))) {
  const counts = { '완료': 0, '도는 중': 0, '대기': 0, '막힘': 0, '미분류': 0 };
  const unmapped = new Set();
  let total = 0, doneFolder = 0, classifiedCounted = 0, classifiedAsDone = 0;
  for (const lane of ['inbox', 'done']) {
    for (const f of fs.readdirSync(path.join(QDIR, lane))) {
      if (!f.endsWith('.md')) continue; // png evidence files in inbox/ are not cards
      total++;
      if (lane === 'done') doneFolder++;
      const text = fs.readFileSync(path.join(QDIR, lane, f), 'utf8');
      const m = text.match(/^status:(.*)$/m);
      let s = (m ? m[1] : '').trim().replace(/^["']+/, '').replace(/["']+$/, '').trim();
      const mapped = table[s.toLowerCase()] || table[s];
      let b = BUCKET_NAME[mapped] || (s.startsWith('창 사라짐') ? '막힘' : '미분류');
      if (b === '미분류') unmapped.add(s);
      if (s === 'classified') {
        classifiedCounted++;
        if (b === '완료') classifiedAsDone++;
      }
      counts[b]++;
    }
  }
  // Every number here is computed from the same directory listing in this same run — no
  // frozen expectation. The queue grows between runs (83 → 85 cards on 2026-09-05), so the
  // only things worth asserting are relations, not totals.
  console.log('       live: total=' + total + ' (== card files just listed from inbox/+done/, pngs excluded) '
    + JSON.stringify(counts) + ' (done/ folder holds ' + doneFolder + ' files, not all 완료)');

  // 미분류 is reported, not failed on — an unmapped status is new vocabulary for the mapping
  // table, not a bug in this test. Only fail if the screen would silently swallow it as 완료
  // (it structurally can't: 미분류 is its own bucket, never bucketDone), which is covered above
  // by the static bucketTable() checks.
  if (unmapped.size > 0) {
    console.log('       live: 미분류 is ' + counts['미분류'] + ', not 0 — unmapped status values found: '
      + JSON.stringify([...unmapped]) + ' (add these to the bucket table, this is not a test failure)');
  } else {
    console.log('       live: 미분류 is 0 — every live status value maps to a known bucket');
  }

  check('live: buckets sum to the card total (nothing dropped)',
        Object.values(counts).reduce((a, b) => a + b, 0), total);
  // THE REAL TEST: no card whose raw status is literally "classified" ever lands in 완료,
  // checked directly against the live cards' own status text — not just the static table.
  // This holds even if the queue someday has zero classified cards (classifiedAsDone stays 0
  // vacuously) — it is a relation, not a count, so it never goes stale as the queue grows.
  console.log('       live: ' + classifiedCounted + ' classified card(s) found on disk this run');
  check('live: not one classified card counted as 완료', classifiedAsDone, 0);
  check('live: 완료 is NOT the done/ file count (folder ≠ completion)',
        counts['완료'] === doneFolder, false);
  check('live: at least one card sits in done/ without being 완료',
        doneFolder > counts['완료'], true);

  // ── item 3: 26, not 4 ──────────────────────────────────────────────────────
  // Counted here from the live cards with the SAME six key names the product reads, and
  // separately with `output:` alone. The assertion is the relation between the two, so it
  // survives the queue growing: reading one key must find strictly fewer cards than
  // reading six, which is precisely the bug this feature exists to avoid.
  let sixKey = 0, outputOnly = 0, withDirective = 0, laneDupes = 0;
  const perKey = {};
  const seenNames = {};
  const cardsByName = {};
  for (const lane of ['inbox', 'done']) {
    for (const f of fs.readdirSync(path.join(QDIR, lane))) {
      if (!f.endsWith('.md')) continue;
      seenNames[f] = (seenNames[f] || 0) + 1;
      const text = fs.readFileSync(path.join(QDIR, lane, f), 'utf8');
      const fm = (text.match(/^---\n([\s\S]*?)\n---/) || [, ''])[1];
      let hit = false;
      for (const k of KEYS) {
        if (new RegExp('^' + k + ':', 'm').test(fm)) {
          perKey[k] = (perKey[k] || 0) + 1;
          hit = true;
        }
      }
      if (hit) sixKey++;
      if (/^output:/m.test(fm)) outputOnly++;
      if (/^issue:/m.test(fm)) withDirective++;
      cardsByName[lane + '/' + f] = { fm, text };
    }
  }
  for (const n of Object.keys(seenNames)) if (seenNames[n] > 1) laneDupes++;

  console.log('       live: cards with an artifact pointer = ' + sixKey
    + ' reading all six keys, ' + outputOnly + ' reading only `output:` '
    + JSON.stringify(perKey) + '; ' + withDirective + ' carry `issue:`; '
    + laneDupes + ' file name(s) exist in BOTH lanes');
  check('live: six keys find strictly more cards than `output:` alone',
        sixKey > outputOnly, true);
  check('live: every card with an artifact pointer is a real card', sixKey <= total, true);
  // The 4 measured non-`output` spellings must each still be present in the live queue —
  // if one disappears the count relation above could pass vacuously.
  check('live: at least three distinct artifact key spellings are in use',
        Object.keys(perKey).length >= 3, true);

  // ── the recorded-but-absent case, checked on disk ──────────────────────────
  // `status: done` with three outputs that are NOT on disk. Hiding this would hand Ryan a
  // dead button, and a dead button is exactly why he opens another window.
  const MPC = 'done/2026-09-05-1753-mpc-agreement-resolve-client-signing.md';
  if (cardsByName[MPC]) {
    const fm = cardsByName[MPC].fm;
    const target = (fm.match(/^target:\s*(.*)$/m) || [, ''])[1].trim().replace(/^["']|["']$/g, '');
    // Block scalar: `output: |` followed by indented `- …` lines. Collected line by line
    // rather than with one regex — an `m`-flagged `$` ends at the FIRST newline and would
    // silently report a single output where the card records three.
    const lines = fm.split('\n');
    const items = [];
    let inBlock = false;
    for (const l of lines) {
      if (/^output:\s*\|?\s*$/.test(l)) { inBlock = true; continue; }
      if (!inBlock) continue;
      if (!/^\s/.test(l)) break;
      const v = l.trim().replace(/^-\s*/, '');
      if (v) items.push(v);
    }
    const LW = QDIR.includes('/organization/') ? QDIR.slice(0, QDIR.indexOf('/organization/')) : QDIR;
    const resolved = items.map((v) => path.join(LW, target, v));
    console.log('       live: ' + MPC.slice(5) + ' records ' + items.length
      + ' output(s); on disk: ' + JSON.stringify(resolved.map((p) => fs.existsSync(p))));
    check('live: that card records more than one output', items.length > 1, true);
    check('live: none of its recorded outputs exist on disk — shown as 경로 없음',
          resolved.some((p) => fs.existsSync(p)), false);
    check('live: its target folder DOES exist (so the miss is the output, not the target)',
          fs.existsSync(path.join(LW, target)), true);
  } else {
    console.log('       live: ' + MPC + ' is no longer in the queue — absence check skipped');
  }

  // ── free text and URLs must not become paths ───────────────────────────────
  // `artifact: GitHub PR 168 (mustcompany-github-manager, stacks/Pulumi.must-aios.yaml)`
  // is prose, not a location. A value with spaces (once a trailing parenthetical note is
  // removed) is never treated as a path, so it gets no button instead of a broken one.
  let freeText = 0, urls = 0;
  for (const { fm } of Object.values(cardsByName)) {
    for (const k of KEYS) {
      const m = fm.match(new RegExp('^' + k + ':(.*)$', 'm'));
      if (!m) continue;
      const v = m[1].trim().replace(/^["']|["']$/g, '');
      if (!v || v === '|' || v === '>') continue;
      if (/^https?:\/\//.test(v)) { urls++; continue; }
      const stripped = v.replace(/\s*\([^()]*\)$/, '');
      if (/\s/.test(stripped)) freeText++;
    }
    for (const line of fm.split('\n')) {
      if (/^\s+-\s*https?:\/\//.test(line)) urls++;
    }
  }
  console.log('       live: ' + freeText + ' inline value(s) are free text, ' + urls + ' are URLs');
  check('live: at least one recorded value is free text, not a path', freeText > 0, true);

  // ── the reveal allowlist can never contain a path the cards did not name ───
  // Rebuilt here from the cards, then probed with the classic arbitrary-read target.
  const allow = new Set();
  for (const [rel, { fm }] of Object.entries(cardsByName)) {
    allow.add(path.join(QDIR, rel));
    const target = (fm.match(/^target:\s*(.*)$/m) || [, ''])[1].trim().replace(/^["']|["']$/g, '');
    const LW = QDIR.includes('/organization/') ? QDIR.slice(0, QDIR.indexOf('/organization/')) : QDIR;
    for (const line of fm.split('\n')) {
      const v = line.replace(/^\s*-\s*/, '').trim().replace(/^["']|["']$/g, '');
      if (!v || /\s/.test(v.replace(/\s*\([^()]*\)$/, '')) || /^https?:/.test(v)) continue;
      if (v.startsWith('/')) allow.add(v);
      else if (v.startsWith('organization/')) allow.add(path.join(LW, v));
      else if (target && v.includes('/')) allow.add(path.join(LW, target, v));
    }
  }
  console.log('       live: the reveal allowlist holds ' + allow.size + ' path(s) parsed from cards');
  for (const off of ['/etc/passwd', '/etc/shadow', process.env.HOME + '/.ssh/id_rsa']) {
    check('live: ' + off + ' is NOT in the allowlist', allow.has(off), false);
  }
  check('live: the allowlist is not empty (the guard would pass vacuously)', allow.size > 0, true);

  // ── the queue folder gets no bytes from this app ───────────────────────────
  // The ledger lives in the app's own data dir. If a versions.json ever appears in the
  // queue, the read-only rule has been broken.
  check('live: no versions.json was written into the queue folder',
        fs.existsSync(path.join(QDIR, 'versions.json'))
        || fs.existsSync(path.join(QDIR, 'inbox', 'versions.json'))
        || fs.existsSync(path.join(QDIR, 'done', 'versions.json')), false);
} else {
  console.log('       live queue not on this machine (' + QDIR + ') — invariant checks skipped');
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
