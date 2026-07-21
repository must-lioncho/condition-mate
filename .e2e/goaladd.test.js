// E2E for the 목표 추가 page's GUI시작/GUI열기 + merged header (세그 토글 제거) + 작업
// 폴더/브랜치 UX, bound to the REAL sources (GoalAddContent.swift, AppDelegate.swift). Asserts:
//   1) gaStart() (GUI시작 버튼) posts /api/goal/add and enters the INLINE session
//      view (gsEnter) with the new seq — 추가 + 같은 화면에서 AI 첫 턴 (페이지 이동 없음).
//      CLI 시작 경로는 제거됨 (2026-07-19, CLI 미사용)
//   1b) session-view turns post /api/goal/chat2/say with the goal seq, composer mode, the
//      session allowlist, per-turn images, and modeOverride only when forcing a mode
//   2) a failed add (ok:false / no seq) re-enables the button and never enters the session
//   3) gaFolderGo routes by input state: empty → native 찾기 (/api/folders/pick),
//      typed path → 지정 (gaFolderCustom), and gaFolderBtnSync relabels accordingly
//   4) gaFolderSet persists the last folder to localStorage (cm.gaFolder) — next visit's
//      default — and selecting 기본 stores an empty cwd
//   5) branch chip: git folder shows the chip defaulting to the folder's LAST-USED branch
//      (falling back to the checked-out branch), a non-git folder hides it, and the choice
//      rides gaExec/gaPayload only alongside a cwd
//   6) recent folders are MRU-ordered (cm.gaFolderRecents) and the folder menu lists them
//      first — 마지막 사용 폴더가 맨 위
//   7) the goal page's sendTeamKick consumes cmGoalKick as a plain kick: preset '' (no team
//      preamble), the stashed mode, and the stashed text as the first chat2 turn
const fs = require('fs');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/GoalAddContent.swift', 'utf8');
const AD = fs.readFileSync(__dirname + '/../Sources/ConditionManager/AppDelegate.swift', 'utf8');
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

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

function stubEl() {
  return { classList: { add() {}, remove() {}, toggle() {} }, style: {},
           textContent: '', innerHTML: '', title: '', value: '', disabled: false,
           querySelector() { return null; } };
}

// ── goal-add page harness: eval the page functions against stubbed DOM/fetch/storage ──
function bootGA() {
  const env = { els: {}, posts: [], fetches: [], local: {}, session: {}, href: '' };
  const el = id => (env.els[id] = env.els[id] || stubEl());
  global.window = global;   // gaRecents reads window._gaServerCtx (server-injected recents)
  global.$ = el;
  global.document = { getElementById: el, addEventListener() {}, removeEventListener() {} };
  global.localStorage = { setItem: (k, v) => { env.local[k] = v; },
                          getItem: k => env.local[k] ?? null,
                          removeItem: k => { delete env.local[k]; } };
  global.sessionStorage = { setItem: (k, v) => { env.session[k] = v; },
                            getItem: k => env.session[k] ?? null,
                            removeItem: k => { delete env.session[k]; } };
  global.location = { set href(v) { env.href = v; }, get href() { return env.href; } };
  global.esc = s => String(s == null ? '-' : s);
  global._gaComp = { images: [], effort: '', mode: '', cwd: '', branch: '' };
  global._gaCtx = { sprint: 0, parent: '', bump: false, label: '' };
  global._gaFolders = null;
  global._gaBranchInfo = null; global._gaBranchQ = '';
  global.gaClearDraft = () => { env.draftCleared = true; };
  global.gaComposerPersist = () => {};   // server-persisted composer ctx — not under test
  global.gaTallyAdd = () => {};
  global.gaAfterSubmit = () => {};
  env.reply = { ok: true, seq: 0 };
  env.branchReply = { ok: true, git: false, current: '', branches: [] };
  global.post = (path, obj) => { env.posts.push({ path, obj });
    return Promise.resolve({ json: () => Promise.resolve(env.reply) }); };
  global.fetch = url => { env.fetches.push(url);
    return Promise.resolve({ json: () => Promise.resolve(env.branchReply) }); };
  global._gaSessSeq = 0;  // 세션 뷰가 열린 목표 seq (0=세션 없음)
  for (const n of ['gaExec', 'gaPayload', 'gaStart',
                   'gaFolderBtnSync', 'gaFolderGo',
                   'gaFolderBrowse', 'gaFolderSet', 'gaFolderPersist', 'gaFolderCustom',
                   'gaFolderRender', 'gaRecents', 'gaRecentsPut',
                   'gaBranchSync', 'gaBranchSet', 'gaBranchRender', 'gaBranchList'])
    eval.call(global, 'global.' + n + ' = ' + fn(GA, n));
  return env;
}
const tick = () => new Promise(r => setTimeout(r, 0));

async function run() {
  // 1) GUI시작 버튼: add → seq → 페이지 이동 없이 인라인 세션 뷰 진입 (gsEnter).
  let env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = '  결제 모듈 리팩터링\n디테일 포함  ';
  global._gaComp.mode = 'plan';
  env.reply = { ok: true, seq: 42 };
  global.gsEnter = (seq, text) => { env.gsEntered = { seq, text }; };
  global.gaStart();
  await tick();
  check('GUI시작 posts /api/goal/add', env.posts.map(p => p.path), ['/api/goal/add']);
  check('enters the inline session view with the new seq', env.gsEntered,
        { seq: 42, text: '결제 모듈 리팩터링\n디테일 포함' });
  check('no page navigation (stays on goal-add)', env.href, '');
  check('draft cleared on session start', env.draftCleared, true);

  // 1b) session-view turns: chat2/say payload carries seq/mode/allow/images/modeOverride.
  env = bootGA();
  global._gs = { seq: 42, mode: 'plan', allow: ['Bash'], running: false, lastMode: '' };
  global._gsImgs = [];
  global.gsWorking = () => {}; global.gsNote = () => {};
  global.gsUser = () => {}; global.gsThumbsRender = () => {};
  for (const n of ['gsPost', 'gsSend']) eval.call(global, 'global.' + n + ' = ' + fn(GA, n));
  global.gsPost('첫 턴', []);
  await tick();
  let say = env.posts[0];
  check('session turn posts chat2/say', say.path, '/api/goal/chat2/say');
  check('turn payload: seq/mode/allow', [say.obj.seq, say.obj.mode, say.obj.allow], [42, 'plan', ['Bash']]);
  check('plain turn carries no images/override', ['images' in say.obj, 'modeOverride' in say.obj], [false, false]);
  global.gsPost('계획 승인', [], true);
  check('forced-mode turn sets modeOverride', env.posts[1].obj.modeOverride, true);
  env.els.gsIn = stubEl(); env.els.gsIn.value = '스크린샷 확인해줘';
  global._gsImgs = [{ data: 'data:image/png;base64,x', name: 's.png' }];
  global.gsSend();
  await tick();
  say = env.posts[2];
  check('composer turn attaches per-turn images', say.obj.images.map(i => i.name), ['s.png']);
  check('per-turn images cleared after send', global._gsImgs, []);
  global._gs.running = true; env.els.gsIn.value = '진행 중 입력';
  global.gsSend();
  check('no send while a turn is running', env.posts.length, 3);

  // 2) failed add: button re-enabled, no navigation, session never entered.
  env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = '실패 케이스';
  env.reply = { ok: false };
  global.gsEnter = () => { env.gsEntered = true; };
  global.gaStart();
  check('button disabled while in flight', env.els.gaStartGui.disabled, true);
  await tick();
  check('failed add re-enables the button', env.els.gaStartGui.disabled, false);
  check('failed add never navigates', env.href, '');
  check('failed add never enters the session view', env.gsEntered === undefined, true);

  // 3) 찾기/지정 routing + label sync.
  env = bootGA();
  env.els.gaFolderCustom = stubEl(); env.els.gaFolderGo = stubEl();
  global.gaFolderBtnSync();
  check('empty input labels the button 찾기', env.els.gaFolderGo.textContent, '찾기');
  env.reply = { ok: true, path: '/Users/x/repo', name: 'repo' };
  global.gaFolderGo();
  await tick();
  check('empty input → native picker', env.posts.map(p => p.path), ['/api/folders/pick']);
  check('picked folder applied', global._gaComp.cwd, '/Users/x/repo');
  env.els.gaFolderCustom.value = '/Users/x/other';
  global.gaFolderBtnSync();
  check('typed path relabels to 지정', env.els.gaFolderGo.textContent, '지정');
  global.gaFolderGo();
  check('typed path → direct set (no extra POST)', env.posts.length, 1);
  check('typed folder applied', global._gaComp.cwd, '/Users/x/other');

  // 4) last-folder persistence (cm.gaFolder) — 기본 selection stores empty cwd.
  check('folder choice persisted', JSON.parse(env.local['cm.gaFolder']).cwd, '/Users/x/other');
  global.gaFolderSet('', '기본 (목표 폴더)');
  check('기본 persists an empty cwd', JSON.parse(env.local['cm.gaFolder']).cwd, '');

  // 5) branch chip: git folder → chip shown, last-used branch preferred over current.
  env = bootGA();
  env.local['cm.gaFolderRecents'] = JSON.stringify(
    [{ cwd: '/Users/x/repo', name: 'repo', branch: 'feat/x' }]);
  env.branchReply = { ok: true, git: true, current: 'main', branches: ['main', 'feat/x', 'qa-fix/1'] };
  global.gaFolderSet('/Users/x/repo', 'repo');
  await tick();
  check('branch list fetched for the folder', env.fetches,
        ['/api/folders/branches?path=' + encodeURIComponent('/Users/x/repo')]);
  check('last-used branch wins over current', global._gaComp.branch, 'feat/x');
  check('branch chip shown for a git folder', env.els.gaBranchWrap.style.display, '');
  check('branch persisted with the folder', JSON.parse(env.local['cm.gaFolder']).branch, 'feat/x');
  // vanished saved branch → fall back to the checked-out branch.
  env.local['cm.gaFolderRecents'] = JSON.stringify(
    [{ cwd: '/Users/x/repo', name: 'repo', branch: 'gone-branch' }]);
  global.gaFolderSet('/Users/x/repo', 'repo');
  await tick();
  check('vanished branch falls back to current', global._gaComp.branch, 'main');
  // non-git folder → chip hidden, branch cleared, payload carries no branch.
  env.branchReply = { ok: true, git: false, current: '', branches: [] };
  global.gaFolderSet('/Users/x/plain', 'plain');
  await tick();
  check('non-git folder hides the chip', env.els.gaBranchWrap.style.display, 'none');
  check('non-git folder clears the branch', global._gaComp.branch, '');
  // payload: branch rides only alongside a cwd.
  global._gaComp.cwd = '/Users/x/repo'; global._gaComp.branch = 'feat/x';
  check('payload carries cwd+branch', (p => [p.cwd, p.branch])(global.gaPayload('t')),
        ['/Users/x/repo', 'feat/x']);
  global._gaComp.cwd = '';
  check('no cwd → no branch in payload', 'branch' in global.gaPayload('t'), false);

  // 6) recents are MRU-ordered and render first in the folder menu.
  env = bootGA();
  global.gaRecentsPut('/a', 'A', '');
  global.gaRecentsPut('/b', 'B', '');
  global.gaRecentsPut('/a', 'A', 'main');   // re-use /a → moves to front, keeps branch
  check('recents MRU order', global.gaRecents().map(x => x.cwd), ['/a', '/b']);
  check('recents remember the branch', global.gaRecents()[0].branch, 'main');
  global._gaFolders = [{ path: '/preset', name: 'P', git: true },
                       { path: '/b', name: 'B', git: false }];
  global.gaFolderRender();
  const menu = env.els.gaFolderMenu.innerHTML;
  const order = ['/a', '/b', '/preset'].map(p => menu.indexOf('>' + p + '<'));
  check('menu lists recents before presets', order[0] < order[1] && order[1] < order[2], true);
  check('preset already recent is not repeated',
        menu.split('>/b<').length - 1, 1);

  // 7) goal page consumes cmGoalKick as a plain kick (preset '', stashed mode).
  const kenv = { session: { 'cmGoalKick:42': JSON.stringify({ text: '결제 모듈 리팩터링', mode: 'plan' }) },
                 fetches: [] };
  global.TASK = ''; global.SEQ = 42; global.streaming = false;
  global.sessionStorage = { getItem: k => kenv.session[k] ?? null,
                            removeItem: k => { delete kenv.session[k]; },
                            setItem: (k, v) => { kenv.session[k] = v; } };
  global.document = { getElementById: () => ({ querySelector: () => null,
    appendChild() {}, scrollTop: 0, scrollHeight: 0 }) };
  global.bubble = () => ({}); global.openStream = () => { kenv.streamOpened = true; };
  global.persistedAllow = () => [];
  global.fetch = (url, opts) => { kenv.fetches.push({ url, body: JSON.parse(opts.body) });
    return Promise.resolve({ json: () => Promise.resolve({ ok: true }) }); };
  eval.call(global, 'global.sendTeamKick = ' + fn(AD, 'sendTeamKick'));
  global.sendTeamKick();
  await tick();
  check('goal kick fires one chat2 turn', kenv.fetches.map(f => f.url), ['/api/goal/chat2/say']);
  const b = kenv.fetches[0].body;
  check('plain kick: no team preamble', b.preset, '');
  check('kick carries the composer mode', b.mode, 'plan');
  check('kick text = the composer input', b.text, '결제 모듈 리팩터링');
  check('kick consumed (one-shot)', kenv.session['cmGoalKick:42'] === undefined, true);
  check('stream opened before the turn', kenv.streamOpened, true);

  // 8) 헤더 토글 병합 (2026-07-19): goal-add 헤더의 세그 토글(simple-큐/detail-큐 ·
  //    CHAT/DETAIL)이 모두 사라졌다 — 검토는 큐 행 펼침, 목표 페이지는 세션 부제목 링크.
  //    목표 페이지 seg(pgUiSeg)는 그대로 CHAT(ui=gui 링크)+DETAIL 만.
  const seg = (AD.match(/id="pgUiSeg".*?<\/div>/s) || [''])[0];
  check('goal page seg: CHAT → gui session view',
        seg.includes("ui=gui'") && seg.includes('>CHAT<'), true);
  check('goal page seg dropped CLI/GUI buttons',
        seg.includes('>CLI<') || seg.includes('>GUI<') || seg.includes('ui=cli'), false);
  check('goal-add header dropped ALL seg toggles (큐 병합)',
        GA.includes('id="gaUiChat"') || GA.includes('id="gaUiDash"')
        || GA.includes('id="gaQSeg"') || GA.includes('gaQGo('), false);
  check('goal-add header dropped the CLI/GUI toggle',
        GA.includes('id="gaUiCli"') || GA.includes('id="gaUiGui"') || GA.includes('cm.gaUiMode'), false);
  check('CLI시작 button is gone', GA.includes('gaStartCli'), false);
  // gsEnter 가 레일 복원용 마지막 탭 기록(cm.lastTab=gui) + 레일 "보는 중" 스탬프
  // (/api/goal/viewing — /goal 이동 없이도 왼쪽 레일 세션 목록에 뜬다)를 남긴다.
  const gsEnterSrc = fn(GA, 'gsEnter');
  check('gsEnter stamps cm.lastTab=gui', gsEnterSrc.includes("cm.lastTab.'+seq,'gui'"), true);
  check('gsEnter stamps rail 보는 중 (/api/goal/viewing)',
        gsEnterSrc.includes("'/api/goal/viewing'"), true);
  check('gsEnterResume stamps rail 보는 중',
        fn(GA, 'gsEnterResume').includes("'/api/goal/viewing'"), true);
  check('server route /api/goal/viewing → markActiveGoal',
        /\/api\/goal\/viewing[\s\S]{0,400}markActiveGoal/.test(AD), true);
  // GUI열기: 큐 행에서 바로 세션 — 이미 목표면 gsEnterResume, 미확정 행이면 승격(resolve add)
  // 후 gsEnter(첫 턴=행 텍스트).
  const gui = fn(GA, 'gaTallyGui');
  check('GUI열기: existing goal → resume session view', gui.includes('gsEnterResume(x.seq)'), true);
  check('GUI열기: unresolved row → promote then start',
        gui.includes("'/api/goal/queue/resolve'") && gui.includes('gsEnter(d.seq,x.text)'), true);
  // 이어가기 채널에 연결 세션이 없으면(no-session) 메신저 채널로 조용히 폴백해 재전송한다.
  const gsPostSrc = fn(GA, 'gsPost');
  check('no-session → silent chat2 fallback',
        gsPostSrc.includes("d.error==='no-session'") && gsPostSrc.includes('_gs.sess=false'), true);

  // 9) AI검색 버튼: findOnly 큐 파이프라인 — 목표를 만들지 않고 유사도 분석만.
  //    추가 모드: 'AI 검색' 행으로 큐 목록에 담긴다(자동 펼침) — 닫기 전까지 큐에 남아
  //    재진입·새로고침에도 복원된다. 검색 모드(레일 검색 페이지 — 큐 목록 없음)에서만
  //    #gaResults 인라인 카드. 전용 버튼은 검색 모드에서 숨긴다(primary 리라벨과 중복).
  check('AI검색 button in the action row', GA.includes('id="gaAiSearchBtn"'), true);
  check('AI검색 hidden in search mode (primary 리라벨과 중복)',
        /gaAiSearchBtn'\); if\(asB\) asB\.style\.display='none'/.test(GA), true);
  check('search-mode primary routes through the same gaAiSearch',
        fn(GA, 'gaAi').includes('gaAiSearch(); return;'), true);
  check('find cards render without a search-mode gate',
        fn(GA, 'gaFindRender').includes('_gaSearchMode'), false);
  // 추가 모드: 결과 카드 대신 큐 행으로 담긴다.
  env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = ' 결제 리팩터링 ';
  global._gaSearchMode = false;
  global._gaFindIds = []; global._gaFindSeen = {}; global._gaFindTimer = null;
  global.vtev = () => {};
  const tallyRows = [];
  global.gaTallyAdd = (kind, text) => { const e = { kind, text, id: '', st: '', open: false }; tallyRows.push(e); return e; };
  global.gaTallyRender = () => { env.tallyRendered = true; };
  global.gaTallyWatch = now => { env.tallyWatch = !!now; };
  global.gaFindRender = force => { env.findRendered = !!force; };
  global.gaFindWatch = () => { env.findWatch = true; };
  env.reply = { ok: true, id: 'f1' };
  eval.call(global, 'global.gaAiSearch = ' + fn(GA, 'gaAiSearch'));
  global.gaAiSearch();
  await tick();
  check('AI검색 posts a findOnly enqueue', env.posts.map(p => [p.path, p.obj.search]),
        [['/api/goal/queue/enqueue', true]]);
  check('AI검색 sends trimmed text, no goal payload',
        [env.posts[0].obj.text, 'sprint' in env.posts[0].obj, 'images' in env.posts[0].obj],
        ['결제 리팩터링', false, false]);
  check('추가 모드: 큐에 AI 검색 행으로 담긴다 (자동 펼침 + 큐 id 연결)',
        tallyRows.map(x => [x.kind, x.text, x.id, x.st, x.open]),
        [['AI 검색', '결제 리팩터링', 'f1', 'pending', true]]);
  check('추가 모드: 행 렌더 + 상태 폴링 재개(즉시 폴)', [env.tallyRendered, env.tallyWatch], [true, true]);
  check('추가 모드: 임시 결과 카드 경로는 타지 않는다', [global._gaFindIds, !!env.findRendered], [[], false]);
  check('AI검색 never posts /api/goal/add (목표 없음)', env.posts.some(p => p.path === '/api/goal/add'), false);
  // 검색 모드: 기존 #gaResults 카드 경로 유지.
  env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = '결제';
  global._gaSearchMode = true;
  global._gaFindIds = []; global._gaFindSeen = {}; global._gaFindTimer = null;
  global.vtev = () => {};
  global.gaFindRender = force => { env.findRendered = !!force; };
  global.gaFindWatch = () => { env.findWatch = true; };
  env.reply = { ok: true, id: 'f2' };
  eval.call(global, 'global.gaAiSearch = ' + fn(GA, 'gaAiSearch'));
  global.gaAiSearch();
  await tick();
  check('검색 모드: 결과 카드 경로 유지 (_gaFindIds + 렌더/워치)',
        [global._gaFindIds, env.findRendered, env.findWatch], [['f2'], true, true]);

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
