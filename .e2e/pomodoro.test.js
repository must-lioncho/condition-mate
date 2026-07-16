// E2E for the wall-clock pomodoro tracker (server-owned completion), bound to the REAL source.
// Extracts the challenge-dial state block from SessionRail.swift and asserts:
//   1) the pomodoro dial counts down WALL seconds (cmChWall), not activity seconds (cmChSecs)
//   2) the idle/running sub-label always carries the daily N/2 tracker
//   3) the state-poll contract: d.wall/d.pomoToday/d.reward drive the local mirrors,
//      and the local post-harvest chooser (cmChDone) shields against a lagging reward poll
// Server-side completion itself (heartbeat -> pomodoro.complete -> PomodoroStats) is covered
// by the live isolated-instance check (CM_POMODORO_SECS), not here.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/SessionRail.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }

// Stubs for the browser globals the block touches.
global.localStorage = { getItem: () => null, setItem: () => {} };
global.window = global;
global.document = { getElementById: () => null };

// State vars + formatters + label/view functions form one contiguous run.
eval(slice('var cmChRun=false', 'function cmChClearCd'));

let pass = 0, fail = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name + '  got=' + JSON.stringify(got));
  if (!ok) { console.log('       want=' + JSON.stringify(want)); fail++; } else pass++;
}

// 1) Wall-clock countdown: activity seconds frozen (idle) must NOT stall the dial.
cmChMode = 'pomodoro'; cmChRun = true;
cmChSecs = 1;            // activity-gated count frozen at 1 (user idle/reading)
cmChWall = 10 * 60;      // 10 real minutes elapsed
check('dial counts wall clock', cmChView(), { text: '15:00', frac: (10 * 60) / (25 * 60) });

// 2) Wall past 25:00 clamps at 0:00 / full ring (server flips to reward on next poll).
cmChWall = 26 * 60;
check('dial clamps at 0:00', cmChView(), { text: '0:00', frac: 1 });

// 3) The N/2 tracker is always on the pomodoro label, not only in reward/done states.
//    The count rides in its own .cmch-day nowrap chunk so a wrap can't split "오늘 2/2".
cmChDailyN = 2;
const modeLabel = cmChModeLabel();
check('label carries daily N/2', modeLabel.replace(/<[^>]*>/g, ''), '포모도로 25분 · 오늘 2/2');
check('daily chunk is nowrap-wrapped', /<span class="cmch-day">· 오늘 2\/2<\/span>$/.test(modeLabel), true);

// 4) State-poll contract on the live source: the sync handler must consume the
//    server fields and shield the local post-harvest chooser from a lagging poll.
const sync = slice('function cmChSync', 'cmChRender();            // reflect');
check('poll consumes d.wall', /typeof d\.wall==='number'.*cmChWall=d\.wall/.test(sync), true);
check('poll consumes d.pomoToday', /typeof d\.pomoToday==='number'.*cmChDailyN=d\.pomoToday/.test(sync), true);
check('reward mirrored unless chooser is up', sync.includes("if(!cmChDone) cmChReward=!!d.reward;"), true);
check('client-side completion judge removed', SRC.includes('cmChCheckComplete'), false);
check('harvest acks the server', slice('window.cmChHarvest', '};').includes("action:'harvest'"), true);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
