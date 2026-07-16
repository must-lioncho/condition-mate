// Node stub render test for the 시스템 로그 (view-trace) tab, bound to the REAL source.
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/BGMPlayerContent.swift', 'utf8');
function slice(from, to) { const a = SRC.indexOf(from); const b = SRC.indexOf(to, a); if (a < 0 || b < 0) throw new Error('extract fail: ' + from); return SRC.slice(a, b); }
const JS = slice('let _vtEvents=null;', 'let _scList=null');   // ends where the 화면 카탈로그 block begins (screens.test.js owns that slice)

// --- stubs ---
const els = {};
function el(id){ return els[id] || (els[id] = { innerHTML:'', checked:false, style:{} }); }
global.$ = el;
global.esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
global.actPad = n => (n < 10 ? '0' : '') + n;
global.CMTimeFilter = { parts: ms => { const d = new Date(ms); return { y:d.getFullYear(), mo:d.getMonth()+1, d:d.getDate(), h:d.getHours(), mi:d.getMinutes(), s:d.getSeconds(), wd:d.getDay() }; } };
global.fetch = () => new Promise(() => {});   // loadViewTrace untested (network)
eval(JS.replace('let _vtEvents=null;', 'var _vtEvents=null;'));  // let은 eval 스코프에 갇힘 — 테스트에서 주입 가능하게 var로
el('vtTicks'); el('vtLaunch'); el('vtList');

let pass = 0, fail = 0;
function check(name, ok, got) {
  console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  got=' + JSON.stringify(got).slice(0, 300)));
  ok ? pass++ : fail++;
}

// Real-shaped launch sequence (from the actual isolated run) + tick run + error event.
const T = 1783788961000;
_vtEvents = [
  { t:T,      src:'native', k:'ev', note:'appLaunch', detail:'pid=1 bundle=nil' },
  { t:T+188,  src:'native', k:'ev', note:'loadStart', page:'/bgm-player' },
  { t:T+269,  src:'native', k:'ev', note:'windowOpen', detail:'mode=dashboard firstOpen=true' },
  { t:T+338,  src:'native', k:'ev', note:'navCommit', page:'/' },
  { t:T+339,  src:'js', k:'ev', note:'boot', page:'/', view:'input', painted:false, hidden:false },
  { t:T+3400, src:'js', k:'ev', note:'firstPaint +3061ms', page:'/', view:'input', painted:true },
  { t:T+3500, src:'js', k:'tick', page:'/', view:'input', painted:true, hidden:false },
  { t:T+4000, src:'js', k:'tick', page:'/', view:'input', painted:true, hidden:false },
  { t:T+4500, src:'js', k:'tick', page:'/', view:'input', painted:true, hidden:false },
  { t:T+5000, src:'js', k:'tick', page:'/bgm-player', view:'map', painted:true, hidden:false },
  { t:T+5500, src:'js', k:'ev', note:'jsError: boom @app.js:3', page:'/', view:'input' },
];
renderViewTrace();

const launch = els['vtLaunch'].innerHTML, list = els['vtList'].innerHTML;
check('launch: 창 표시 offset', launch.includes('창 표시 <b>+269ms</b>'), launch);
check('launch: 첫 페인트 offset', launch.includes('첫 페인트 <b>+3400ms</b>'), launch);
check('launch: 빈 화면 구간 = paint-open', launch.includes('빈 화면 구간 3131ms'), launch);
check('launch: >800ms → amber highlight', launch.includes('#e0a13a'), launch);
check('list: 연속 동일-화면 틱 3개가 세그먼트 1줄로 압축', (list.match(/보는 중/g) || []).length === 2, list.match(/보는 중/g));
check('list: 세그먼트 틱 카운트', list.includes('(3틱)'), list);
check('list: 페이지 라벨 한국어 매핑', list.includes('대시보드') && list.includes('컨디션 관리'), list);
check('list: jsError 이벤트 표시', list.includes('jsError: boom'), list);
check('list: native 이벤트 badge', list.includes('네이티브'), list);

// 틱 펼치기: 세그먼트 없이 원본 그대로
els['vtTicks'].checked = true;
renderViewTrace();
check('ticks expanded: 세그먼트 없음', !els['vtList'].innerHTML.includes('보는 중'), null);

// 빈 데이터
els['vtTicks'].checked = false;
_vtEvents = [];
renderViewTrace();
check('empty state', els['vtList'].innerHTML.includes('아직 기록이 없습니다'), els['vtList'].innerHTML);

// firstPaint가 아예 없는 실행(흰 화면에서 멈춘 케이스)도 요약이 드러내야 한다
_vtEvents = [
  { t:T, src:'native', k:'ev', note:'appLaunch' },
  { t:T+300, src:'native', k:'ev', note:'windowOpen' },
];
renderViewTrace();
check('paint 없음 → 경고 문구', els['vtLaunch'].innerHTML.includes('첫 페인트 기록 없음'), els['vtLaunch'].innerHTML);

// ── 인페이지 사용자 액션 계측: 하트비트가 window.cmVT.ev 를 노출하고, 채팅/CLI/사진
//    첨부가 그 훅을 실제로 호출하는지 — 소스 문자열에 바인딩해 회귀를 잡는다.
//    (배경: 채팅 열기·사진 첨부·CLI 세션 시작이 시스템 로그에 전혀 안 남던 문제)
const GB = fs.readFileSync(__dirname + '/../Sources/ConditionManager/UI/GUIBridge.swift', 'utf8');
const GA = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/GoalAddContent.swift', 'utf8');
const AD = fs.readFileSync(__dirname + '/../Sources/ConditionManager/AppDelegate.swift', 'utf8');
check('heartbeat: window.cmVT.ev 노출', GB.includes('window.cmVT = { ev: ev }'), null);
check('goal-add: CLI 열기 스탬프 + cmView', /vtev\('cliOpen goal-'\+pad2\(seq\)\); window\.cmView='cli'/.test(GA), null);
check('goal-add: 세션 뷰 열기/이어가기 스탬프', GA.includes("vtev('sessOpen goal-'") && GA.includes("vtev('sessResume goal-'"), null);
check('goal-add: 사진 첨부/제거 스탬프 (컴포저+세션)', (GA.match(/vtev\('imageAttach /g) || []).length === 2 && (GA.match(/vtev\('imageRemove /g) || []).length === 2, GA.match(/vtev\('image/g));
check('goal page: 채팅 열기/닫기 스탬프', AD.includes("cmVT.ev(open?'chatOpen':'chatClose')"), null);
check('goal page: CLI 오버레이 열기/닫기 스탬프', AD.includes("cmVT.ev('cliOpen goal '+SEQ)") && AD.includes("cmVT.ev('cliClose goal '+SEQ)"), null);

console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
