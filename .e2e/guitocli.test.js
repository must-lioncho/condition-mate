// E2E for the goal-add GUI→CLI live toggle (gaGuiToCli/gaCliWaitTurn), bound to the REAL
// source (GoalAddContent.swift). Asserts the no-abort contract:
//   1) toggling to CLI while a turn is RUNNING never posts chat2/stop|session/stop —
//      the turn keeps running in the background (사용자 요구: 탭 이동은 중단이 아니다)
//   2) while the turn runs the terminal is NOT connected yet (no cli/start); the CLI view
//      shows a waiting state and polls /api/goal/chat2/state on the turn's own channel
//   3) the poll hits the sess channel (&sess=1) for 이어가기 turns
//   4) once state reports running=false the terminal connects (gaCliEnter)
//   5) toggling back to GUI mid-wait (body loses 'cli') stops the poll — no stray connect
//   6) toggling with NO running turn connects the terminal immediately
const fs = require('fs');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/GoalAddContent.swift', 'utf8');
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

function boot(gs) {
  const env = { posts: [], fetches: [], cliEnters: [], states: [], intervals: [], body: ['sess'] };
  global.$ = () => ({ set textContent(v) {}, set innerHTML(v) {}, get textContent() { return ''; } });
  global.document = { title: '', body: { classList: {
    add(c) { if (!env.body.includes(c)) env.body.push(c); },
    remove(c) { env.body = env.body.filter(x => x !== c); },
    contains(c) { return env.body.includes(c); }
  } } };
  global.pad2 = n => (n < 10 ? '0' : '') + n;
  global.post = (path, obj) => { env.posts.push({ path, obj });
    return Promise.resolve({ json: () => Promise.resolve({ ok: true }) }); };
  // fetch resolves with the CURRENT value of env.stateRunning at call time
  global.fetch = url => { env.fetches.push(url);
    return Promise.resolve({ json: () => Promise.resolve({ running: env.stateRunning }) }); };
  global.gsWorking = () => {};
  global.cliState = txt => { env.states.push(txt); };
  global.gaCliEnter = (seq, t) => { env.cliEnters.push(seq); };
  global.setTimeout = (f, ms) => f();
  global.setInterval = (f, ms) => { env.intervals.push(f); return env.intervals.length; };
  global.clearInterval = () => {};
  global._gaSessSeq = 495;
  global._gs = gs;
  global._gaCliWaitT = null;
  for (const n of ['gaGuiToCli', 'gaCliWaitTurn'])
    eval.call(global, 'global.' + n + ' = ' + fn(GA, n));
  return env;
}
// setTimeout is patched to run inline above, so flush the fetch→json→handler
// promise chain with a few microtask hops instead
const tick = async () => { for (let i = 0; i < 6; i++) await Promise.resolve(); };

async function run() {
  // ── 1+2+3+4: running sess turn — no stop, wait for completion, then connect ──
  let env = boot({ seq: 495, sess: true, running: true, es: { close() { env.esClosed = true; } } });
  env.stateRunning = true;
  global.gaGuiToCli();
  check('running turn: NO stop is posted (중단하지 않음)', env.posts.map(p => p.path), []);
  check('running turn: SSE is closed, view leaves sess', [!!env.esClosed, env.body.includes('sess')], [true, false]);
  check('running turn: terminal NOT connected yet', env.cliEnters, []);
  check('waiting state is shown in the CLI status line',
        env.states.length === 1 && env.states[0].includes('중단하지 않고'), true);
  const poll = env.intervals[0];
  check('a state poll is armed', typeof poll, 'function');
  poll(); await tick();
  check('poll hits the sess channel while running', env.fetches, ['/api/goal/chat2/state?seq=495&sess=1']);
  check('still running → still no terminal', env.cliEnters, []);
  env.stateRunning = false;
  poll(); await tick();
  check('turn finished → terminal connects (gaCliEnter)', env.cliEnters, [495]);

  // ── 3: messenger-channel turn (sess=false) polls without &sess=1 ──
  env = boot({ seq: 495, sess: false, running: true, es: null });
  env.stateRunning = true;
  global.gaGuiToCli();
  env.intervals[0](); await tick();
  check('messenger turn polls the plain channel', env.fetches, ['/api/goal/chat2/state?seq=495']);

  // ── 5: toggling back to GUI mid-wait stops the poll ──
  env = boot({ seq: 495, sess: true, running: true, es: null });
  env.stateRunning = false;   // turn would be done, but the user already left CLI
  global.gaGuiToCli();
  global.document.body.classList.remove('cli');   // gaCliToGui equivalent
  env.intervals[0](); await tick();
  check('leaving CLI mid-wait: poll aborts, no stray connect', [env.fetches.length, env.cliEnters], [0, []]);

  // ── 6: no running turn → immediate connect, no poll ──
  env = boot({ seq: 495, sess: true, running: false, es: null });
  global.gaGuiToCli();
  check('idle toggle connects immediately', env.cliEnters, [495]);
  check('idle toggle arms no poll', env.intervals.length, 0);

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
