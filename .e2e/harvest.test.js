// E2E for the harvest-stage memory clear, bound to the REAL source (SessionRail.swift).
// Extracts cmChRenderReward and asserts:
//   1) the live 완주 transition (session was running on THIS page) folds the board (cmZenEnter)
//      exactly once — 수확 단계 = 인간 메모리 클리어
//   2) subsequent reward renders (orb still pending) never re-fold — a deliberate 둘러보기
//      reveal during a pending harvest is respected
//   3) a fresh page load mid-reward (cmZenWasRun=false) never folds — navigating around with
//      an unharvested orb must not yank the user back to the zen dashboard
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');
function fn(name) {
  const start = SRC.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = SRC.indexOf('{', start); k < SRC.length; k++) {
    if (SRC[k] === '{') depth++;
    else if (SRC[k] === '}') { depth--; if (depth === 0) return SRC.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// Minimal DOM stubs — the reward renderer only pokes classes/labels on rail elements.
function stubEl() {
  return { classList: { add() {}, remove() {}, toggle() {} }, style: {},
           textContent: '', innerHTML: '', title: '',
           querySelector() { return stubEl(); } };
}
function boot(opts) {
  const env = { zenEnters: 0 };
  global.document = { getElementById: () => stubEl() };
  global.cmZenEnter = () => { env.zenEnters++; };
  global.cmZenWasRun = !!opts.wasRun;
  global.cmChDailyN = 1;
  global.CMCH_DAILY_GOAL = 2;
  eval(fn('cmChRenderReward'));
  env.render = () => cmChRenderReward(stubEl());
  return env;
}

// 1) Live 완주 transition: the page just watched the session run → fold once.
let env = boot({ wasRun: true });
env.render();
check('live completion folds the board once', env.zenEnters, 1);
check('transition flag consumed', global.cmZenWasRun, false);

// 2) Orb still pending, user may have revealed via 둘러보기 → later renders never re-fold.
env.render(); env.render();
check('pending-orb re-renders never re-fold', env.zenEnters, 1);

// 3) Fresh page load mid-reward (no live transition on this page) → never folds.
env = boot({ wasRun: false });
env.render(); env.render();
check('fresh load mid-reward never folds', env.zenEnters, 0);

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
