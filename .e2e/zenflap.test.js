// E2E for the zen window start/stop flap fix, bound to the REAL source (SessionRail.swift).
// Bug (2026-08-07, Loom): clicking start expanded the window, then a stale /api/session/state
// poll (in flight, or landing before the start committed server-side) reported working=false
// and cmChRender's zen edge re-narrowed it — expand→re-narrow→expand flapping with a black
// board for seconds (app.log 14:22:50.763 expand / 14:22:50.776 re-narrow, 13ms apart).
// Fix: an optimistic-action latch (cmChPendWant/cmChPendUntil) holds the clicked state until
// the server echoes it or the deadline passes; stale payloads also must not overwrite the
// fresh clock (cmChSecs/cmChWall) or the chosen mode.
//
// Extracts cmChFire / cmChSync / cmChRender / cmChToggle from the Swift source and drives
// them with a scripted fetch: each cmChSync() consumes the next queued state payload.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');

function balanced(start) {
  let depth = 0;
  for (let k = SRC.indexOf('{', start); k < SRC.length; k++) {
    if (SRC[k] === '{') depth++;
    else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); }
  }
  throw new Error('unbalanced at ' + start);
}
function fn(name) {              // function NAME(){...}
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  return balanced(start);
}
function assigned(name) {        // window.NAME=function(){...}
  const marker = 'window.' + name + '=function';
  const at = SRC.indexOf(marker);
  if (at < 0) throw new Error('no assigned fn ' + name);
  return balanced(at + ('window.' + name + '=').length);
}

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// Minimal DOM stubs — cmChRender only pokes classes/labels/styles on rail elements.
function stubEl() {
  return { classList: { add() {}, remove() {}, toggle() {} }, style: {},
           textContent: '', innerHTML: '', title: '',
           querySelector() { return stubEl(); }, querySelectorAll() { return []; } };
}

// The window through the zen channel: reveal→wide, narrow→folded. Only genuine
// transitions are recorded (the real cmZenReveal/cmZenEnter no-op via the body class).
function boot() {
  const env = { wide: false, moves: [], posts: [], states: [] };
  global.document = { getElementById: () => stubEl() };
  global.cmZenReveal = () => { if (!env.wide) { env.wide = true; env.moves.push('expand'); } };
  global.cmZenEnter  = () => { if (env.wide) { env.wide = false; env.moves.push('narrow'); } };
  global.fetch = (url, opts) => {
    if (opts && opts.method === 'POST') {
      env.posts.push(JSON.parse(opts.body).action);
      return new Promise(() => {});   // control POST never resolves — the test drives polls itself
    }
    const d = env.states.shift();     // /api/session/state → next scripted payload
    return Promise.resolve({ json: () => Promise.resolve(d) });
  };
  // State the real functions share (free vars → globals here, module vars in the app).
  global.cmChRun = false; global.cmChMuted = false; global.cmChSecs = 0;
  global.cmChWall = 0; global.cmChToday = 0; global.cmChCountdown = null;
  global.cmChCdTimer = null; global.cmChPendWant = null; global.cmChPendUntil = 0;
  global.cmChBooted = true; global.cmChReward = false; global.cmChDone = false;
  global.cmChDailyN = 0; global.CMCH_DAILY_GOAL = 2; global.cmChMode = 'pomodoro';
  global.cmChSprintStart = 0; global.cmChSprintTarget = 0; global.cmZenWasRun = false;
  // Render helpers not under test.
  global.cmChClearCd = () => {}; global.cmChBoot = () => {};
  global.cmChView = () => ({ text: '', frac: 0 });
  global.cmChSyncModeBtns = () => {}; global.cmChModeLabel = () => '';
  global.cmChFmt = () => ''; global.cmChDur = () => ''; global.cmCondRenderHp = () => {};
  global.cmChPomoSecs = () => 1500; global.cmChHarvest = () => {};
  eval('global.cmChSync=' + fn('cmChSync').replace('function cmChSync(', 'function ('));
  eval('global.cmChFire=' + fn('cmChFire').replace('function cmChFire(', 'function ('));
  eval('global.cmChRender=' + fn('cmChRender').replace('function cmChRender(', 'function ('));
  eval('global.cmChToggle=' + assigned('cmChToggle'));
  return env;
}
const settle = () => new Promise(r => setImmediate(r));
async function poll(env, state) { env.states.push(state); global.cmChSync(); await settle(); await settle(); }

(async () => {
  // ---------- 1. Start click → expand; the stale poll must NOT re-narrow ----------
  let env = boot();
  await poll(env, { working: false });                 // settled idle
  global.cmChToggle();                                 // user clicks start
  check('start click posts start', env.posts, ['start']);
  check('start click expands once', env.moves, ['expand']);
  // A poll that was already in flight lands with the OLD state and the OLD session's clock.
  await poll(env, { working: false, mode: 'sprint', seconds: 88, wall: 1490 });
  check('stale poll never re-narrows (the flap)', env.moves, ['expand']);
  check('stale poll cannot flip cmChRun', global.cmChRun, true);
  check('stale clock never overwrites the fresh one', [global.cmChSecs, global.cmChWall], [0, 0]);
  check('stale mode never overwrites the chosen one', global.cmChMode, 'pomodoro');
  check('latch still armed', global.cmChPendWant, true);

  // ---------- 2. Server echoes running → latch clears, server owns state again ----------
  await poll(env, { working: true, mode: 'pomodoro', seconds: 3, wall: 3 });
  check('confirming poll clears the latch', global.cmChPendWant, null);
  check('confirmed clock applies', [global.cmChSecs, global.cmChWall], [3, 3]);
  // A LATER genuine external stop (⌘S elsewhere, server-side 완주) must still fold — the
  // latch only shields the click window, it never makes polls advisory forever.
  await poll(env, { working: false });
  check('post-latch external stop folds once', env.moves, ['expand', 'narrow']);

  // ---------- 3. Stop click → narrow; the stale running poll must NOT re-expand ----------
  env = boot();
  await poll(env, { working: true, mode: 'pomodoro', seconds: 60, wall: 60 });
  check('running state expands', env.moves, ['expand']);
  global.cmChToggle();                                 // user clicks stop
  check('stop click posts stop', env.posts, ['stop']);
  check('stop click narrows once', env.moves, ['expand', 'narrow']);
  await poll(env, { working: true, mode: 'pomodoro', seconds: 61, wall: 61 });
  check('stale running poll never re-expands', env.moves, ['expand', 'narrow']);
  check('stale running poll cannot flip cmChRun', global.cmChRun, false);
  await poll(env, { working: false });
  check('confirming stop clears the latch', global.cmChPendWant, null);

  // ---------- 4. Latch deadline: server never confirms → believe the server ----------
  env = boot();
  await poll(env, { working: false });
  global.cmChToggle();                                 // start that will fail server-side
  global.cmChPendUntil = Date.now() - 1;               // deadline passed
  await poll(env, { working: false });
  check('expired latch yields to the server', global.cmChRun, false);
  check('expired latch folds the window back', env.moves, ['expand', 'narrow']);
  check('expired latch is released', global.cmChPendWant, null);

  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
