// E2E for the 액션로그 category axis (분류 필터) — all-user-action logging.
// Extracts actCat + renderActions (and their const tables) from the REAL
// BGMPlayerContent.swift (액션로그 뷰가 대시보드에서 컨디션 관리 페이지로 이동)
// and asserts: (1) cat passthrough + legacy derivation
// (sessionStart→pomodoro, dislike→bgm, updateRun→settings — must mirror
// ActionLog.defaultCategory on the Swift side), (2) the 분류 filter hides other
// categories, (3) path-derived action names get Korean labels and a category
// pill, (4) the summary line counts 포모도로/목표 events.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/BGMPlayerContent.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract ' + from); return SRC.slice(a, b); }

// Globals the extracted functions reference. _actRange=null → 기간 필터 통과(자동과 동일).
let _actEvents = null, _actKind = '', _actCat = '', _actRenderedSig = '', _actRange = null;
const els = {};
function $(id) { if (!els[id]) els[id] = { innerHTML: '', textContent: '', firstChild: null, classList: { toggle() {} } }; return els[id]; }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }
const CMTimeFilter = { parts(ms) { const d = new Date(ms); return { y: d.getUTCFullYear(), mo: d.getUTCMonth() + 1, d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds() }; } };

eval(slice('const ACT_LABEL', 'function setActKind')
   + '\n' + slice('function actPad', '// 컨디션맵 → 액션로그 드릴다운'));

let pass = 0, fail = 0;
function check(name, ok, extra) {
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (extra ? '  ' + extra : ''));
  ok ? pass++ : fail++;
}

// 1) category derivation: explicit cat wins; legacy lines fall back by action name
check('cat passthrough', actCat({ cat: 'goal', action: 'trackChange' }) === 'goal');
check('legacy sessionStart→pomodoro', actCat({ action: 'sessionStart' }) === 'pomodoro');
check('legacy dislike→bgm', actCat({ action: 'dislike' }) === 'bgm');
check('legacy updateRun→settings', actCat({ action: 'updateRun' }) === 'settings');

// 2+3+4) render a mixed timeline
const T = 1783600000;
_actEvents = [
  { t: T, kind: 'user', action: 'sessionStart', detail: '세션 시작 (pomodoro)', mode: 'pomodoro' },
  { t: T + 60, kind: 'user', action: 'goal.add', cat: 'goal', detail: '테스트 목표 텍스트' },
  { t: T + 120, kind: 'user', action: 'pomodoro.complete', cat: 'pomodoro', detail: '포모도로 25분 완주 — 장비 EXP 반영' },
  { t: T + 180, kind: 'bgm', action: 'trackChange', cat: 'bgm', track: '곡A', pool: '모드 · pomodoro' },
];

_actCat = ''; _actRenderedSig = '';
renderActions();
const allHtml = els.actList.innerHTML;
check('all: goal label rendered', allHtml.indexOf('목표 추가') >= 0);
check('all: pomodoro.complete label rendered', allHtml.indexOf('포모도로 완주') >= 0);
check('all: category pill present', allHtml.indexOf('목표설정') >= 0 && allHtml.indexOf('포모도로</span>') >= 0);
check('summary counts categories', els.actSummary.textContent.indexOf('포모도로 2') >= 0 && els.actSummary.textContent.indexOf('목표 1') >= 0, 'got=' + els.actSummary.textContent);

_actCat = 'goal'; _actRenderedSig = ''; els.actList.firstChild = null;
renderActions();
const goalHtml = els.actList.innerHTML;
check('goal filter: keeps goal.add', goalHtml.indexOf('목표 추가') >= 0);
check('goal filter: hides sessionStart', goalHtml.indexOf('세션 시작</b>') < 0);
check('goal filter: hides trackChange', goalHtml.indexOf('곡 전환') < 0);

_actCat = 'pomodoro'; _actRenderedSig = ''; els.actList.firstChild = null;
renderActions();
const pomHtml = els.actList.innerHTML;
check('pomodoro filter: keeps sessionStart (legacy derive)', pomHtml.indexOf('세션 시작</b>') >= 0);
check('pomodoro filter: keeps pomodoro.complete', pomHtml.indexOf('포모도로 완주') >= 0);
check('pomodoro filter: hides goal.add', pomHtml.indexOf('목표 추가') < 0);

console.log('\n' + pass + ' pass, ' + fail + ' fail');
process.exit(fail ? 1 : 0);
