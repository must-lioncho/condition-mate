// E2E for the 목표 추가 page's MERGED queue (2026-07-19 simple/detail 큐 병합) + 담김 영속,
// bound to the REAL source (GoalAddContent.swift). Asserts:
//   1) gaTallyAdd stamps ts and persists the list — localStorage 캐시 + 디바운스된
//      POST /api/goal/tally (서버 settings.json 영속). dynamic 포트가 origin 을 바꿔
//      localStorage 를 리셋해도(앱 업데이트/재시작) 기록이 남는다
//   2) gaTallyRender draws newest-first (원본 인덱스 유지) and puts a date chip (t-when)
//      only on rows from previous days — 오늘 행엔 없음
//   3) gaTallyPersist caps the stored history at the most recent 100 entries
//   4) the restore block prefers the SERVER-injected copy (window._gaTallyHist), falls
//      back to localStorage only when the server copy is empty, and resumes polling
//      (gaTallyWatch(true)) when an unresolved AI 큐 row exists; search mode skips restore
//   5) gaTallyClear wipes only RESOLVED rows (display/local cache + server) — 미확정 큐
//      행(검토 대상)은 남는다
//   6) merged queue behavior: unresolved rows expand IN PLACE (▸ → QueuePanel 검토 카드,
//      default closed), resolved rows fold into the 큐 히스토리 section (bottom, default
//      closed, click to open); gaQueueResolved/gaQueueUndone host hooks flip rows instantly
//   7) header markup: seg toggles (gaQSeg/CHAT·DETAIL) are GONE; 큐 히스토리 section ships
//      collapsed; ?q=detail boot expands unresolved rows + opens the history
//   8) the dashboard's 큐 탭 stays GONE (redirects, 큐 노티, exportLinkmap → /goal-add
//      ?q=detail), and QueuePanel is now a card library delegating renders to the host
//      (renderAiQueue → gaQueueRender hook; resolve/undo → gaQueueResolved/gaQueueUndone)
const fs = require('fs');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/GoalAddContent.swift', 'utf8');
const DC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
const QP = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/QueuePanel.swift', 'utf8');
function fn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}
// window.name=function(){...} extractor (host hooks are assigned, not declared).
function fnExpr(src, marker) {
  const start = src.indexOf(marker);
  if (start < 0) throw new Error('no expr ' + marker);
  let depth = 0;
  for (let k = src.indexOf('{', start); k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(src.indexOf('function', start), k + 1); }
  }
  throw new Error('unbalanced ' + marker);
}

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

function stubEl() {
  return { on: null,
           classList: { add() {}, remove() {}, toggle(c, v) { this._on = !!v; },
                        contains(c) { return !!this._on; } },
           style: {}, textContent: '', innerHTML: '', value: '', focused: false,
           focus() { this.focused = true; } };
}

// ── harness: eval the merged-queue functions against stubbed DOM/storage ──
function boot() {
  const env = { els: {}, local: {}, href: '', watch: [] };
  const el = id => (env.els[id] = env.els[id] || stubEl());
  global.$ = el;
  const cls = new Set();
  global.document = { getElementById: el, addEventListener() {},
                      activeElement: null,
                      body: { classList: {
                        contains: c => cls.has(c),
                        toggle(c, v) { const on = (v === undefined) ? !cls.has(c) : !!v;
                                       on ? cls.add(c) : cls.delete(c); return on; },
                        add: c => cls.add(c), remove: c => cls.delete(c) } } };
  env.cls = cls;
  global.window = global;
  global._gaSearchMode = false;
  global.localStorage = { setItem: (k, v) => { env.local[k] = v; },
                          getItem: k => env.local[k] ?? null,
                          removeItem: k => { delete env.local[k]; } };
  global.location = { set href(v) { env.href = v; }, get href() { return env.href; } };
  global.esc = s => String(s == null ? '-' : s);
  global.pad2 = n => (n < 10 ? '0' : '') + n;
  global.vtev = () => {};
  global.clearInterval = () => {};
  env.posts = [];
  global.post = (path, obj) => { env.posts.push({ path, obj });
    return Promise.resolve({ json: () => Promise.resolve({ ok: true }) }); };
  // 디바운스(500ms)를 즉시 실행으로 접는다 — 테스트에서 서버 POST 를 동기 관찰
  global.setTimeout = fn => { fn(); return 0; };
  global.clearTimeout = () => {};
  global._gaTallySaveT = null;
  global._gaTallyLastSaved = '';
  global.window._gaTallyHist = [];   // 서버 주입본 기본값 — 각 케이스가 덮어쓴다
  // 표시 타임존 스텁 — gaTallyWhen 은 CMTimeFilter.parts 로만 날짜를 본다 (raw getter 금지 컨벤션)
  const parts = ms => { const d = new Date(ms);
    return { y: d.getUTCFullYear(), mo: d.getUTCMonth() + 1, d: d.getUTCDate(), h: 0, mi: 0, s: 0, wd: 0 }; };
  global.CMTimeFilter = { parts };
  Object.assign(global.window, { CMTimeFilter: global.CMTimeFilter });
  global._gaTally = [];
  global._gaHistOpen = false;
  global._gaTallyTimer = null;
  global.gaTallyWatch = now => { env.watch.push(!!now); };
  global.gaGoalBorn = () => {};
  global._gaFindIds = [];            // AI검색(findOnly) 카드 상태 — gaQueueResolved 가 먼저 본다
  global.gaFindRender = () => {};
  // 펼침 행 저장/복원(GoalAddContent.swift:841·845). 이 파일의 관심사가 아니라 스텁으로 둔다.
  // 스텁이 없으면 조용히 삼켜져 엉뚱한 실패로 보인다:
  //  - gaOpenPersist 는 gaTallyPersist 첫 줄에서 불린다 → 빠지면 렌더가 통째로 죽는다.
  //  - gaOpenRestoreSet 은 복원 블록의 try{}catch(e){} 안이라 ReferenceError 가 삼켜지고,
  //    복원이 조용히 중단돼 히스토리 단정들이 "got=[]" 로 떨어진다(제품 결함처럼 보인다).
  global.gaOpenPersist = () => {};
  global.gaOpenRestoreSet = () => ({});   // 저장된 펼침 없음 = 전부 접힌 채 복원
  for (const n of ['gaIsQ', 'gaTallyAdd', 'gaTallyStrip', 'gaTallyPersist', 'gaTallyClear', 'gaTallyWhen',
                   'gaTallyChip', 'gaTallyActiveRow', 'gaTallyHistInfo', 'gaTallyRowHTML',
                   'gaTallyDetHTML', 'gaTallyToggle', 'gaHistToggle', 'gaJobsRender', 'gaTallyRender'])
    eval.call(global, 'global.' + n + ' = ' + fn(GA, n));
  return env;
}

// 복원 블록(함수가 아닌 top-level 코드)을 마커로 잘라 eval — 실제 소스 그대로 돌린다.
function restoreBlock() {
  const m = GA.indexOf('── 큐 목록 복원');
  if (m < 0) throw new Error('restore block marker missing');
  const start = GA.lastIndexOf('\n', m) + 1;
  const end = GA.indexOf('// ── 추가/AI추가/검색', m);
  if (end < 0) throw new Error('restore block end marker missing');
  return GA.slice(start, end);
}

async function run() {
  // 1) add stamps ts + persists
  let env = boot();
  const DAY = 86400000;
  global.gaTallyAdd('AI 큐', '안녕1');
  const e2 = global.gaTallyAdd('직접 추가', '안녕2');
  e2.seq = 7;
  global.gaTallyRender();
  check('add stamps ts', global._gaTally.every(x => x.ts > 0), true);
  check('add starts collapsed (open=false)', global._gaTally.every(x => !x.open), true);
  const stored = JSON.parse(env.local['cm.gaTallyHist']);
  check('history persisted (kind/text/seq)',
        stored.map(x => [x.kind, x.text, x.seq]),
        [['AI 큐', '안녕1', 0], ['직접 추가', '안녕2', 7]]);
  const tallyPosts = env.posts.filter(p => p.path === '/api/goal/tally');
  check('history persisted to the SERVER too', tallyPosts.length > 0, true);
  check('server payload mirrors the list',
        tallyPosts[tallyPosts.length - 1].obj.list.map(x => x.text), ['안녕1', '안녕2']);

  // 2) newest-first render + date chip only on old rows
  global._gaTally[0].ts = Date.now() - 3 * DAY;   // 안녕1 = 3일 전
  global.gaTallyRender();
  const html = env.els['gaTallyList'].innerHTML;
  check('newest row drawn first', html.indexOf('안녕2') < html.indexOf('안녕1'), true);
  const rows = html.split('t-row').slice(1);
  check('old row gets a date chip', rows[1].includes('t-when'), true);
  check('today row has no date chip', rows[0].includes('t-when'), false);

  // 3) persist caps at the most recent 100
  env = boot();
  for (let i = 0; i < 105; i++) global.gaTallyAdd('AI 큐', 'g' + i);
  const capped = JSON.parse(env.local['cm.gaTallyHist']);
  check('storage capped at 100', capped.length, 100);
  check('cap keeps the latest', [capped[0].text, capped[99].text], ['g5', 'g104']);

  // 4) restore: 서버 주입본 우선 (업데이트/재시작 = 새 origin 이라 localStorage 는 비어 있다)
  env = boot();
  global.window._gaTallyHist = [
    { kind: 'AI 큐', text: '미확정', id: 'q1', st: 'pending', seq: 0, resolved: '', ts: 1 },
    { kind: '직접 추가', text: '확정됨', id: '', st: '', seq: 12, resolved: '', ts: 2 }];
  eval.call(global, restoreBlock());
  check('restore rebuilds the list from the SERVER copy', global._gaTally.map(x => x.text), ['미확정', '확정됨']);
  check('restore resumes watch (immediate poll)', env.watch, [true]);
  check('restored rows are not fresh — 확정분은 큐 히스토리로 접힌다',
        global._gaTally.map(x => global.gaTallyActiveRow(x)), [true, false]);
  // 서버본이 비어 있으면 같은 origin 캐시(localStorage)로 폴백
  env = boot();
  env.local['cm.gaTallyHist'] = JSON.stringify([{ kind: 'AI 큐', text: '캐시복원', ts: 1 }]);
  eval.call(global, restoreBlock());
  check('empty server copy falls back to localStorage', global._gaTally.map(x => x.text), ['캐시복원']);
  // 서버본이 있으면 localStorage 는 무시된다 (서버가 진실)
  env = boot();
  global.window._gaTallyHist = [{ kind: 'AI 큐', text: '서버본', ts: 2 }];
  env.local['cm.gaTallyHist'] = JSON.stringify([{ kind: 'AI 큐', text: '낡은캐시', ts: 1 }]);
  eval.call(global, restoreBlock());
  check('server copy wins over localStorage', global._gaTally.map(x => x.text), ['서버본']);
  // resolved-only history: 폴링은 재개하지 않는다
  env = boot();
  env.local['cm.gaTallyHist'] = JSON.stringify(
    [{ kind: 'AI 큐', text: '끝', id: 'q9', st: 'ready', seq: 3, resolved: 'add', ts: 1 }]);
  eval.call(global, restoreBlock());
  check('all-resolved history: no watch', env.watch, []);
  // search mode skips restore
  env = boot();
  global._gaSearchMode = true;
  env.local['cm.gaTallyHist'] = JSON.stringify([{ kind: 'AI 큐', text: 'x', ts: 1 }]);
  eval.call(global, restoreBlock());
  check('search mode skips restore', global._gaTally.length, 0);

  // 5) clear wipes resolved rows only (display + storage + server)
  env = boot();
  global.gaTallyAdd('AI 큐', '지울것');            // id 없음(enqueue 전) → 확정 취급, 지워진다
  const keep = global.gaTallyAdd('AI 큐', '검토중'); keep.id = 'q1';
  global.gaTallyClear();
  check('clear keeps unresolved queue rows', global._gaTally.map(x => x.text), ['검토중']);
  check('clear rewrites storage', JSON.parse(env.local['cm.gaTallyHist'] || '[]').map(x => x.text), ['검토중']);
  const clearPosts = env.posts.filter(p => p.path === '/api/goal/tally').map(p => p.obj.list.length);
  check('clear posts the pruned list to the server', clearPosts.includes(1), true);
  // Swift 쪽 배선: 엔드포인트 + 렌더 주입 (소스 어서션)
  const AD = fs.readFileSync(__dirname + '/../Sources/ConditionMate/AppDelegate.swift', 'utf8');
  check('server has the /api/goal/tally route', AD.includes('if path == "/api/goal/tally"'), true);
  check('render injects the server copy', GA.includes('window._gaTallyHist=\\#(tallyHist)'), true);

  // 6) merged queue: per-row expand (default closed) + 큐 히스토리 fold (default closed)
  env = boot();
  const r1 = global.gaTallyAdd('AI 큐', '검토대상'); r1.id = 'q1'; r1.st = 'ready';
  const r2 = global.gaTallyAdd('AI 큐', '이미확정'); r2.id = 'q2'; r2.resolved = 'add'; r2.seq = 9; r2.fresh = false;
  global._lastAiQueue = [{ id: 'q1', text: '검토대상', status: 'ready' }];
  global.qItemCardHTML = it => '<div class="qcard-stub">' + it.id + '</div>';
  global.gaTallyRender();
  check('active 큐 count = unresolved rows only', env.els.gaTallyN.textContent, '1');
  check('rows start collapsed (no inline card)', env.els.gaTallyList.innerHTML.includes('qcard-stub'), false);
  check('row carries expand toggle + GUI열기',
        env.els.gaTallyList.innerHTML.includes('gaTallyToggle(0)')
        && env.els.gaTallyList.innerHTML.includes('gaTallyGui(0)'), true);
  check('resolved row folds out of the active list', env.els.gaTallyList.innerHTML.includes('이미확정'), false);
  check('큐 히스토리 counts the folded rows', env.els.gaHistN.textContent, '1');
  check('큐 히스토리 body closed by default', env.els.gaHistBody.style.display, 'none');
  global.gaTallyToggle(0);
  check('expand renders the review card inline (QueuePanel)', env.els.gaTallyList.innerHTML.includes('qcard-stub'), true);
  global.gaTallyToggle(0);
  check('expand toggles back closed', env.els.gaTallyList.innerHTML.includes('qcard-stub'), false);
  global.gaHistToggle();
  check('큐 히스토리 opens on click', env.els.gaHistBody.style.display, '');
  check('큐 히스토리 lists the resolved row', env.els.gaHistBody.innerHTML.includes('이미확정'), true);
  check('resolved row offers GUI열기 (세션 바로 열기)', env.els.gaHistBody.innerHTML.includes('gaTallyGui(1)'), true);
  // host hooks: 확정/번복이 행을 즉시 뒤집는다 (5초 폴 대기 없음)
  eval.call(global, 'global.gaQueueResolved = ' + fnExpr(GA, 'window.gaQueueResolved=function'));
  eval.call(global, 'global.gaQueueUndone = ' + fnExpr(GA, 'window.gaQueueUndone=function'));
  global.gaQueueResolved('q1', { action: 'add', seq: 33 });
  check('resolve hook flips the row immediately',
        [global._gaTally[0].resolved, global._gaTally[0].seq], ['add', 33]);
  env.watch.length = 0;
  global.gaQueueUndone('q2');
  check('undo hook restores the row to pending',
        [global._gaTally[1].resolved, global._gaTally[1].st, global._gaTally[1].seq], ['', 'pending', 0]);
  check('undo hook resumes polling', env.watch, [true]);

  // 6b) AI 검색(findOnly) 행: AI검색 결과가 큐에 담겨 남는다 — 펼치면 검색 카드, 닫기(skip)는
  //     결정이 아니라 카드 닫기이므로 '닫힘'으로 표기. findOnly 항목은 목표를 만들지 않으므로
  //     GUI열기(승격) 버튼은 걸지 않는다.
  env = boot();
  const rs = global.gaTallyAdd('AI 검색', '결제 검색'); rs.id = 'qs1'; rs.st = 'ready';
  global._lastAiQueue = [{ id: 'qs1', text: '결제 검색', status: 'ready', findOnly: true }];
  global.gaTallyRender();
  check('AI 검색 row counts as active 큐', env.els.gaTallyN.textContent, '1');
  check('AI 검색 row expands but offers no GUI열기 (승격 금지)',
        [env.els.gaTallyList.innerHTML.includes('gaTallyToggle(0)'),
         env.els.gaTallyList.innerHTML.includes('gaTallyGui(0)')], [true, false]);
  global.gaTallyToggle(0);
  check('AI 검색 expand renders the search card inline', env.els.gaTallyList.innerHTML.includes('qcard-stub'), true);
  check('AI 검색 ready chip = 완료', global.gaTallyChip(rs).includes('완료'), true);
  global.gaQueueResolved('qs1', { action: 'skip' });
  check('닫기(skip) → row stays with 닫힘 chip',
        [global._gaTally[0].resolved, global.gaTallyChip(global._gaTally[0]).includes('닫힘')], ['skip', true]);
  check('AI 검색 row persists in history strip (kind 유지)',
        JSON.parse(env.local['cm.gaTallyHist']).map(x => x.kind), ['AI 검색']);

  // 7) header markup: seg toggles gone, 큐 히스토리 ships collapsed, ?q=detail boot
  check('header seg toggles are gone', /id="gaQSeg"|id="gaQSimple"|id="gaQDetail"|id="gaUiSeg"/.test(GA), false);
  check('큐 히스토리 section ships collapsed', /id="gaHistBody" style="display:none/.test(GA), true);
  check('큐 히스토리 header toggles', GA.includes('onclick="gaHistToggle()"'), true);
  check('?q=detail expands unresolved rows and opens the history',
        GA.includes("_qs.get('q')==='detail'") && GA.includes('x.open=true')
        && GA.includes('_gaHistOpen=true'), true);

  // 8) 큐 탭 완전 이전 유지 + QueuePanel = 호스트 위임 카드 라이브러리
  check('dashboard VIEW_DEFS has no queue tab', /\{k:'queue'/.test(DC), false);
  check('dashboard queue renderer moved out', /function renderAiQueue|function aiQueueBoxHTML/.test(DC), false);
  check('dashboard #queueView removed', /id="queueView"/.test(DC), false);
  check('old #view=queue hash redirects to chat 큐',
        DC.includes("if(_view==='queue'){ location.replace('/goal-add?q=detail'); return; }"), true);
  check('큐 노티 routes to chat 큐', /id="qNoti" onclick="location\.href=\\'\/goal-add\?q=detail\\'"/.test(DC), true);
  check('qNav remnants gone', /qNav|qnav/.test(DC), false);
  // exportLinkmap: enqueue 후 chat 큐로 이동 (functional)
  env = boot();
  let posted = [];
  global.post = (path, obj) => { posted.push(path); return Promise.resolve({ json: () => Promise.resolve({}) }); };
  eval.call(global, 'global.exportLinkmap = ' + fn(DC, 'exportLinkmap'));
  global.exportLinkmap('g1');
  check('exportLinkmap enqueues the job', posted, ['/api/queue/enqueue-linkmap']);
  check('exportLinkmap opens chat 큐', env.href, '/goal-add?q=detail');
  // QueuePanel: 렌더는 호스트 훅으로, 확정/번복은 호스트 훅 통지
  check('QueuePanel owns the single-item review card', /function qItemCardHTML/.test(QP), true);
  check('renderAiQueue delegates to the host hook', QP.includes('window.gaQueueRender) gaQueueRender()'), true);
  check('resolve actions notify the host (add/task/skip)',
        QP.includes("gaQueueResolved(id,{action:'add'") && QP.includes("gaQueueResolved(id,{action:'task'")
        && QP.includes("gaQueueResolved(id,{action:'skip'})"), true);
  check('undo notifies the host', QP.includes('gaQueueUndone(h.qid)'), true);
  check('QueuePanel prompt uses inline panel (no dup modal)',
        QP.includes('function queuePromptChat(id){ queuePromptStart(id); }') && !/showDup/.test(QP.replace(/\/\/.*$/gm, '')), true);
  check('QueuePanel never calls dashboard load()',
        /(?<!qdRe)load\(\)/.test(QP.replace(/\/\/.*$/gm, '')), false);
  check('no separate detail surface remains',
        /qdetail|queueHost|qdEnter|qdLeave/.test(QP) || /qdetail|queueHost/.test(GA), false);
  // qdReload: /data.json → 상태 반영(qdSnap) + renderAiQueue (functional)
  env = boot();
  global._review = null; global._reviewAt = 0; global._qHist = [];
  global._goals = [];
  let rendered = null;
  global.renderAiQueue = items => { rendered = items; };
  global.Date = Object.assign(function () {}, { now: () => 42 });
  global.fetch = () => Promise.resolve({ json: () => Promise.resolve(
    { review: { goals: [{ seq: 1 }], aiQueue: [{ id: 'q1' }], queueHistory: [{ id: 'h1' }] } }) });
  eval.call(global, 'global.qdSnap = ' + fn(QP, 'qdSnap'));
  eval.call(global, 'global.qdReload = ' + fn(QP, 'qdReload'));
  await global.qdReload();
  check('qdReload renders the queue', rendered, [{ id: 'q1' }]);
  check('qdReload refreshes shared review cache', global._review.goals.length === 1 && global._qHist.length === 1, true);

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
