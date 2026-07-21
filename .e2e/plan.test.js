// E2E for the rail nav AFTER the 계획(plan) menu removal (2026-07-19), bound to the REAL
// sources (SessionRail.swift, AppDelegate.swift). Asserts:
//   1) the rail nav is a 3×3 set in flow order 대화→스킬→크론→위임→팀위임→작업→메모장→미정×2 —
//      the plan item, its overlay (#cmPlanOverlay) and cmNav/cmNavReflect plan branches are
//      GONE; the two 미정 slots are inert (class "off", no onclick). (메모장 filled the
//      first reserved slot 2026-07-21 — see memo.test.js for its own coverage.)
//   2) the goal page's sendTeamKick still consumes a stashed cmPlanKick with preset:'plan'
//      (legacy "계획:" goals keep working) — and team kick wins over a stale plan kick
//   3) server contract stays for legacy sessions: /api/plan/delegate mints a "계획:" goal;
//      chat2Say routes preset "plan" to planChatPreamble (plan-first, no implementation)
const fs = require('fs');
const SR = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/SessionRail.swift', 'utf8');
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
// window.name=function(){...} extractor (rail functions are assigned, not declared).
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
const tick = () => new Promise(r => setTimeout(r, 0));

async function run() {
  // 1) nav grid: nine items, NO plan item, 미정×3 inert.
  const nav = (SR.match(/<nav class="cmrail-nav"[\s\S]*?<\/nav>/) || [''])[0];
  const items = [...nav.matchAll(/<a class="(cmrail-item[^"]*)" data-nav="([^"]+)"([^>]*)>[\s\S]*?<span class="cmr-lbl">([^<]+)<\/span><\/a>/g)]
    .map(m => ({ cls: m[1], nav: m[2], attrs: m[3], lbl: m[4] }));
  check('nav has 9 items', items.length, 9);
  check('nav flow order (plan removed)', items.map(x => x.nav),
        ['chat', 'skills', 'cron', 'delegate', 'team', 'work', 'memo', 'tbd2', 'tbd3']);
  check('nav labels', items.map(x => x.lbl),
        ['대화', '스킬', '크론', '위임', '팀위임', '작업', '메모장', '미정', '미정']);
  check('미정 slots are inert (off, no onclick)',
        items.slice(7).every(x => x.cls.includes('off') && !x.attrs.includes('onclick')), true);
  check('active items are clickable', items.slice(0, 7).every(x => x.attrs.includes("cmNav('" + x.nav + "')")), true);
  check('.off style exists', SR.includes('.cmrail-item.off{'), true);

  // plan UI is gone: no overlay markup, no open/submit wiring, no nav branches.
  check('plan overlay markup removed', SR.includes('id="cmPlanOverlay"'), false);
  check('plan overlay wiring removed',
        SR.includes('cmPlanOpen=') || SR.includes('cmPlanSubmit=') || SR.includes('cmPlanClose='), false);
  const cmNav = fnExpr(SR, 'window.cmNav=function');
  check('cmNav has no plan branch', cmNav.includes("'plan'") || cmNav.includes('cmPlanOpen'), false);
  const reflect = fnExpr(SR, 'window.cmNavReflect=function');
  check('cmNavReflect has no plan branch', reflect.includes('cmPlanOverlay'), false);

  // 2) goal page still consumes a stashed cmPlanKick with preset:'plan' (legacy 계획 goals).
  const kenv = { session: { 'cmPlanKick:42': '주간 리포트 탭 만들기' }, fetches: [] };
  global.window = global;
  global.TASK = ''; global.SEQ = 42; global.streaming = false;
  global.sessionStorage = { getItem: k => kenv.session[k] ?? null,
                            removeItem: k => { delete kenv.session[k]; },
                            setItem: (k, v) => { kenv.session[k] = v; } };
  global.document = { getElementById: () => ({ querySelector: () => null,
    appendChild() {}, scrollTop: 0, scrollHeight: 0 }) };
  global.bubble = () => ({}); global.openStream = () => {};
  global.persistedAllow = () => [];
  global.fetch = (url, opts) => { kenv.fetches.push({ url, body: JSON.parse(opts.body) });
    return Promise.resolve({ json: () => Promise.resolve({ ok: true }) }); };
  eval.call(global, 'global.sendTeamKick = ' + fn(AD, 'sendTeamKick'));
  global.sendTeamKick();
  await tick();
  check('plan kick fires one chat2 turn', kenv.fetches.map(f => f.url), ['/api/goal/chat2/say']);
  check('plan kick uses the plan preamble', kenv.fetches[0].body.preset, 'plan');
  check('plan kick text = the composer input', kenv.fetches[0].body.text, '주간 리포트 탭 만들기');
  check('plan kick consumed (one-shot)', kenv.session['cmPlanKick:42'] === undefined, true);
  // team kick still wins over a (stale) plan kick — team is checked first.
  const kick = fn(AD, 'sendTeamKick');
  check('team kick checked before plan kick', kick.indexOf('cmTeamKick') < kick.indexOf('cmPlanKick'), true);

  // 3) server contract stays for legacy sessions: endpoint + preamble routing.
  check('/api/plan/delegate mints a 계획 goal',
        AD.includes('path == "/api/plan/delegate"') && AD.includes('let title = "계획: "'), true);
  check('chat2Say routes preset plan to planChatPreamble',
        AD.includes('case "plan": preamble = planChatPreamble(scope)'), true);
  const pre = (AD.match(/func planChatPreamble[\s\S]*?\n    \}/) || [''])[0];
  check('plan preamble is plan-first (no implementation)',
        pre.includes('실제 구현·실행을 시작하지 않습니다'), true);
  check('plan preamble hands off to GUI시작', pre.includes('GUI시작'), true);
  check('plan preamble keeps the cm-question contract', pre.includes('cm-question'), true);

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
}
run();
