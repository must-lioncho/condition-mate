// E2E for the rail 메모장 focus shortcut (2026-07-21), bound to the REAL source
// (SessionRail.swift). 메모장 is NOT a separate notepad — it opens the existing
// 목표 추가 page (/goal-add) with the rail collapsed for that load only, so the
// composer fills the screen for brain-dumping (머릿속 비워내기). Asserts:
//   1) grid: the memo item fills the first reserved slot (clickable, label 메모장)
//   2) cmNav('memo') behavior (stubbed DOM):
//      - from any other page: stashes the one-shot cmGaFocus hint + navigates to /goal-add
//      - already on /goal-add: collapses the rail in place (다시 누르면 크게), no navigation
//   3) boot: the hint is consumed on /goal-add load (collapse once, then removed), and the
//      persisted cmRailCollapsed preference is never written by this path
const fs = require('fs');
const SR = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');

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

// ---- 1) grid ---------------------------------------------------------------
const nav = (SR.match(/<nav class="cmrail-nav"[\s\S]*?<\/nav>/) || [''])[0];
const memoItem = (nav.match(/<a class="([^"]*)" data-nav="memo"([^>]*)>[\s\S]*?<span class="cmr-lbl">([^<]+)<\/span><\/a>/) || []);
check('memo nav item exists + clickable (not off)',
      !!memoItem[0] && !memoItem[1].includes('off') && memoItem[2].includes("cmNav('memo')"), true);
check('memo nav label', memoItem[3], '메모장');
check('no leftover notepad overlay', SR.includes('cmMemoOverlay') || SR.includes('cmmemo'), false);

// ---- 2) cmNav('memo') behavior ----------------------------------------------
function makeEnv(pathname) {
  const env = {
    session: {}, local: {}, hrefs: [], bodyCls: new Set(),
  };
  global.window = global;
  global.location = { pathname, get href() { return pathname; }, set href(v) { env.hrefs.push(v); } };
  global.sessionStorage = { setItem: (k, v) => { env.session[k] = v; }, getItem: k => env.session[k] ?? null,
                            removeItem: k => { delete env.session[k]; } };
  global.localStorage = { setItem: (k, v) => { env.local[k] = v; }, getItem: k => env.local[k] ?? null };
  global.document = {
    body: { classList: { add: c => env.bodyCls.add(c), toggle: c => env.bodyCls.add(c) } },
    querySelectorAll: () => [],
    getElementById: () => null,
  };
  global.navigator = { sendBeacon: () => true };
  global.Blob = function () {};
  global.fetch = () => Promise.resolve({ json: () => Promise.resolve({}) });
  // overlay helpers cmNav probes with typeof — leave undefined except a no-op setActive path
  delete global.cmTeamHide; delete global.cmSkClose; delete global.cmAgClose;
  delete global.cmComposeAi; delete global.cmTeamOpen; delete global.cmAgentsOpen; delete global.cmSkillsOpen;
  return env;
}

// from the dashboard: stash hint + navigate
let env = makeEnv('/');
global.setActive = () => {};
eval.call(global, 'global.cmNav = ' + fnExpr(SR, 'window.cmNav=function'));
global.cmNav('memo');
check('memo from dashboard stashes one-shot hint', env.session.cmGaFocus, '1');
check('memo from dashboard navigates to /goal-add', env.hrefs, ['/goal-add']);
check('memo never writes the persisted collapse pref', env.local.cmRailCollapsed === undefined, true);

// already on /goal-add: collapse in place, no navigation
env = makeEnv('/goal-add');
global.setActive = () => {};
eval.call(global, 'global.cmNav = ' + fnExpr(SR, 'window.cmNav=function'));
global.cmNav('memo');
check('memo on /goal-add collapses the rail in place', env.bodyCls.has('cmrail-collapsed'), true);
check('memo on /goal-add does not navigate', env.hrefs, []);

// ---- 3) boot hint consumption -----------------------------------------------
const boot = SR.slice(SR.indexOf("sessionStorage.getItem('cmGaFocus')") - 400,
                      SR.indexOf("sessionStorage.getItem('cmGaFocus')") + 400);
check('boot consumes the hint on /goal-add only',
      boot.includes("location.pathname.indexOf('/goal-add')===0")
      && boot.includes("sessionStorage.removeItem('cmGaFocus')")
      && boot.includes("classList.add('cmrail-collapsed')"), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
