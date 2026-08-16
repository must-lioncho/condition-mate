// E2E for the zen fold-on-stop behavior, bound to the REAL source (SessionRail.swift).
// Extracts the zen block (launch-load branches + cmZenReveal/cmZenEnter) and asserts:
//   1) a stop TRANSITION on the dashboard ('/') hides the board in place (cm-zen class)
//   2) a stop TRANSITION on any OTHER rail page (goal 세부 페이지 등) folds the window
//      AND leaves for '/?zen=1' — the detail page itself is the leftover memory, so it
//      must not linger behind the narrow window
//   3) loading '/' with ?zen=1 enters zen directly and strips the param (so a later
//      reload of a revealed board doesn't re-hide it)
//   4) guards hold: a hidden/covered page never folds, an already-zen page is a no-op
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }
const ZEN = slice("try{ if(location.pathname==='/' && !sessionStorage.getItem('cmChArmed'))", 'var cmZenWasRun=false');

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// Fresh browser-global stubs per scenario; evaluating ZEN also runs the load-time branches.
function boot(opts) {
  const classes = new Set();
  const env = {
    posted: [],                  // webkit cmzen messages
    replaced: [],                // history.replaceState URLs
    navigatedTo: null,           // location.href assignment
    classes,
  };
  global.window = global;
  global.document = {
    hidden: !!opts.hidden,
    body: { classList: {
      add: (...cs) => cs.forEach(c => classes.add(c)),
      remove: (...cs) => cs.forEach(c => classes.delete(c)),
      contains: c => classes.has(c),
    } },
  };
  global.sessionStorage = { getItem: () => (opts.armed ? '1' : null), setItem: () => {} };
  global.webkit = { messageHandlers: { cmzen: { postMessage: m => env.posted.push(m) } } };
  global.history = { replaceState: (s, t, url) => env.replaced.push(url) };
  global.location = {
    pathname: opts.pathname, search: opts.search || '',
    set href(v) { env.navigatedTo = v; }, get href() { return env.navigatedTo; },
  };
  eval(ZEN);
  return env;
}

// 1) Stop on the dashboard: hide the board in place, fold the window, stay on '/'.
let env = boot({ pathname: '/', armed: true });
cmZenEnter();
check('dashboard stop hides board in place', document.body.classList.contains('cm-zen'), true);
check('dashboard stop folds window', env.posted, ['narrow']);
check('dashboard stop does not navigate', env.navigatedTo, null);

// 2) Stop on the goal detail page: fold the window and leave for the zen dashboard.
env = boot({ pathname: '/goal', search: '?n=423', armed: true });
cmZenEnter();
check('goal-page stop folds window', env.posted, ['narrow']);
check('goal-page stop leaves for zen dashboard', env.navigatedTo, '/?zen=1');

// 3) Landing on '/?zen=1' (arrival from a goal-page stop): zen from the first frame,
//    window folded (idempotent with the pre-navigation fold), param stripped.
env = boot({ pathname: '/', search: '?zen=1', armed: true });
check('?zen=1 load enters zen', document.body.classList.contains('cm-zen'), true);
check('?zen=1 load folds window', env.posted, ['narrow']);
check('?zen=1 load strips the param', env.replaced, ['/']);

// 4) Guards: a covered/detached page must never fold the window from behind,
//    and re-entering while already zen is a no-op (no double narrow).
env = boot({ pathname: '/goal', search: '?n=423', armed: true, hidden: true });
cmZenEnter();
check('hidden page never folds or navigates', [env.posted, env.navigatedTo], [[], null]);
env = boot({ pathname: '/', armed: true });
cmZenEnter(); cmZenEnter();
check('already-zen re-enter is a no-op', env.posted, ['narrow']);

// 5) Plain in-session dashboard load (armed, no ?zen=1): board stays visible.
env = boot({ pathname: '/', armed: true });
check('idle navigation keeps the board', document.body.classList.contains('cm-zen'), false);

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
