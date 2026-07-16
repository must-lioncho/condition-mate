// E2E for the 목표 추가 page's 세션시작 button + 작업 폴더/브랜치 UX, bound to the REAL
// sources (GoalAddContent.swift, AppDelegate.swift). Asserts:
//   1) gaStart (GUI 토글) posts /api/goal/add and enters the INLINE session view (gsEnter)
//      with the new seq — 세션시작 = 추가 + 같은 화면에서 AI 첫 턴 (페이지 이동 없음)
//   1a) gaStart (CLI 토글, 기본) posts add then enters the IN-PAGE CLI terminal view
//      (gaCliEnter → /api/goal/cli/start with the goal text as seed). 헤더 토글 클릭 =
//      디폴트 변경 (cm.gaUiMode 영속)
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
  global.gaTallyAdd = () => {};
  global.gaAfterSubmit = () => {};
  env.reply = { ok: true, seq: 0 };
  env.branchReply = { ok: true, git: false, current: '', branches: [] };
  global.post = (path, obj) => { env.posts.push({ path, obj });
    return Promise.resolve({ json: () => Promise.resolve(env.reply) }); };
  global.fetch = url => { env.fetches.push(url);
    return Promise.resolve({ json: () => Promise.resolve(env.branchReply) }); };
  global._gaUi = 'cli';   // 헤더 CLI/GUI 토글 상태 — 페이지 기본값과 동일
  global._gaSessSeq = 0;  // 세션 뷰가 열린 목표 seq (0=세션 없음) — gaUiSet 라이브 전환이 참조
  for (const n of ['gaExec', 'gaPayload', 'gaStart', 'gaUiSet', 'gaUiSync',
                   'gaFolderBtnSync', 'gaFolderGo',
                   'gaFolderBrowse', 'gaFolderSet', 'gaFolderPersist', 'gaFolderCustom',
                   'gaFolderRender', 'gaRecents', 'gaRecentsPut',
                   'gaBranchSync', 'gaBranchSet', 'gaBranchRender', 'gaBranchList'])
    eval.call(global, 'global.' + n + ' = ' + fn(GA, n));
  return env;
}
const tick = () => new Promise(r => setTimeout(r, 0));

async function run() {
  // 1) 세션시작(GUI 토글): add → seq → 페이지 이동 없이 인라인 세션 뷰 진입 (gsEnter).
  let env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = '  결제 모듈 리팩터링\n디테일 포함  ';
  global._gaComp.mode = 'plan';
  global._gaUi = 'gui';
  env.reply = { ok: true, seq: 42 };
  global.gsEnter = (seq, text) => { env.gsEntered = { seq, text }; };
  global.gaStart();
  await tick();
  check('세션시작 posts /api/goal/add', env.posts.map(p => p.path), ['/api/goal/add']);
  check('enters the inline session view with the new seq', env.gsEntered,
        { seq: 42, text: '결제 모듈 리팩터링\n디테일 포함' });
  check('no page navigation (stays on goal-add)', env.href, '');
  check('draft cleared on session start', env.draftCleared, true);

  // 1a) 세션시작(CLI 토글, 기본값): add → 페이지 안 임베디드 터미널 뷰 진입 (gaCliEnter).
  //     GUI 세션 뷰(gsEnter)에는 안 들어간다.
  env = bootGA();
  env.els.gaText = stubEl(); env.els.gaText.value = 'CLI로 시작할 목표';
  env.reply = { ok: true, seq: 43 };
  global.gsEnter = () => { env.gsEntered = true; };
  global.gaCliEnter = (seq, text) => { env.cliEntered = { seq, text }; };
  global.gaStart();
  await tick(); await tick();
  check('CLI 세션시작 posts /api/goal/add only', env.posts.map(p => p.path), ['/api/goal/add']);
  check('enters the in-page CLI terminal view', env.cliEntered,
        { seq: 43, text: 'CLI로 시작할 목표' });
  check('CLI mode never enters the GUI session view', env.gsEntered === undefined, true);
  check('draft cleared on CLI session start', env.draftCleared, true);

  // 1a-2) 토글: 클릭이 곧 디폴트 변경 — cm.gaUiMode 영속, 기본 cli.
  env = bootGA();
  global.gaUiSet('gui');
  check('toggle persists the new default', env.local['cm.gaUiMode'], 'gui');
  check('toggle marks the GUI button on', [env.els.gaUiGui.className, env.els.gaUiCli.className],
        ['on', '']);
  global.gaUiSet('cli');
  check('toggle back to cli persists', env.local['cm.gaUiMode'], 'cli');

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
  check('button disabled while in flight', env.els.gaStartBtn.disabled, true);
  await tick();
  check('failed add re-enables the button', env.els.gaStartBtn.disabled, false);
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

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
