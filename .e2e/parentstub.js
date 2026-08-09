// Visual/interaction stub for the 부모# 셀 (고스트 추천 번호 · 상태 점 · 최근/추천 드롭다운).
//
// WHY: the dashboard is served by the Swift app, and the app cannot be launched from a
// sandboxed shell (LaunchServices/WindowServer are unavailable), so the real page is not
// reachable here. This serves the SHIPPING CSS and the SHIPPING cell/dropdown functions —
// pulled straight out of DashboardContent.swift, same convention as memostub.js — over a
// stub /data.json, so what the browser renders is the real markup at the real widths.
//
//   node .e2e/parentstub.js   ->  http://127.0.0.1:8934
const fs = require('fs');
const http = require('http');
const path = require('path');

const SRC = fs.readFileSync(path.join(__dirname, '..',
  'Sources/ConditionManager/Dashboard/DashboardContent.swift'), 'utf8');

function slice(from, to, what) {
  const a = SRC.indexOf(from), b = SRC.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('cannot extract ' + what);
  return SRC.slice(a, b + to.length);
}
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
const constLine = name => 'var ' + SRC.match(new RegExp('^const ' + name + '=.*$', 'm'))[0].slice(6);

// The whole dashboard stylesheet, so widths/colors are exactly what ships.
// Swift interpolations (\#(...)) are inert here — strip them to a neutral value.
const CSS = slice('<style>', '</style>', 'dashboard CSS').replace(/\\#\([^)]*\)/g, '0');

const JS = [
  'const $ = id => document.getElementById(id);',   // 대시보드 공용 헬퍼 (DashboardContent.swift:1000)
  constLine('PIN_TIP'),
  fn('esc'), fn('escAttr'), fn('pad2'), fn('byId'),
  fn('statLabel'), fn('statLabel2'), fn('goalKids'), fn('derivedStatus'),
  fn('recentParentSeqs'), fn('recentParentIds'),
  fn('psugItems'), fn('psugRunning'), fn('psugFor'), fn('bySeq'),
  fn('psugStatusOf'), fn('psugStatusLabel'), fn('psugGhostHTML'), fn('parentCellHTML'),
  fn('pinFocus'), fn('pinBlur'), fn('pinPick'), fn('pinItemHTML'), fn('renderPinList'),
  fn('showPopup'), fn('popupOutside'), fn('hidePopup')
].join('\n');

// A tracker slice with one of each case the feature has to render.
const GOALS = [
  { id: 'g1', seq: 1, text: '슬랙 이모지 번역 파이프라인', parent: '', status: 'backlog', priority: 'high' },
  { id: 'g4', seq: 4, text: '번역 데몬 로그 회전', parent: 'g1', status: 'in_progress', priority: 'medium' },
  { id: 'g2', seq: 2, text: '장비 페이지 픽셀아트 씬', parent: '', status: 'waiting', priority: 'medium' },
  { id: 'g3', seq: 3, text: '네트워크 진단 프로브', parent: '', status: 'backlog', priority: 'low' },
  { id: 'g7', seq: 7, text: '포모도로 통계 영속화', parent: '', status: 'done', priority: 'medium' },
  { id: 'g10', seq: 10, text: '슬랙 번역 데몬 재시작 처리', parent: '', status: 'backlog', priority: 'high' },
  { id: 'g12', seq: 12, text: '장비 픽셀아트 늑대 스프라이트 추가', parent: '', status: 'backlog', priority: 'medium' },
  { id: 'g13', seq: 13, text: '포모도로 완주음 교체', parent: 'g7', status: 'backlog', priority: 'low' },
  { id: 'g14', seq: 14, text: '아직 아무 데도 안 붙은 잡다한 메모 정리', parent: '', status: 'backlog', priority: 'low' },
  // 세 자리 부모 번호 — 추천 폭이 가장 넓어지는 최악의 경우(트래커는 이미 goal-685까지 갔다).
  { id: 'g680', seq: 680, text: '주간 개런티 정산 파이프라인', parent: '', status: 'in_progress', priority: 'high' },
  { id: 'g681', seq: 681, text: '주간 개런티 온체인 재조회', parent: '', status: 'backlog', priority: 'medium' }
];
const REVIEW = {
  goals: GOALS,
  recentParents: [7, 2],
  psug: {
    state: 'ready', at: 0,
    items: [
      { seq: 10, p: 1, score: 0.86, why: '제목 키워드 일치: 슬랙, 번역, 데몬' },
      { seq: 12, p: 2, score: 0.61, why: '제목 키워드 일치: 픽셀아트, 장비' },
      { seq: 681, p: 680, score: 0.74, why: '제목 키워드 일치: 주간, 개런티' }
    ]
  }
};

const PAGE = `<!doctype html><html lang="ko"><head><meta charset="utf-8">
<title>부모# 셀 스텁</title>
${CSS}
<style>
  body{padding:24px;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
  .stubnote{color:var(--mut);font-size:12px;margin:0 0 14px}
  .board{max-width:760px}
</style></head><body>
<p class="stubnote">스텁: 실제 DashboardContent.swift 의 CSS + 셀/드롭다운 함수를 그대로 실행합니다.
goal-10 · goal-12 에 추천이 있고, goal-14 는 추천 없음 · goal-04/13 은 이미 부모가 있습니다.</p>
<div class="board" id="board"></div>
<div id="popup" class="popup" style="display:none"></div>
<script>
var _goals=[], _review=null, _fill=null, _pinId=null;
${JS}
// 스텁 배선: 확정 POST 대신 화면 갱신만 (실제 앱에서는 post() -> load()).
function post(p,o){ document.title='POST '+p+' '+JSON.stringify(o);
  var g=byId(_goals,o.id); if(g){ g.parent=o.parent; render(); } }
function setParentById(id,pid){ post('/api/goal/parent',{id:id,parent:pid}); }
function setParentByNumber(id,v){ var n=parseInt(String(v).replace(/[^0-9]/g,''),10);
  var p=n?bySeq(n):null; setParentById(id, p?p.id:''); }
function pinDown(e){ /* Cmd+드래그 채우기는 보드 지오메트리가 필요해 스텁에서는 생략 */ }
function statSelBoard(g){ return '<span class="ot '+(g.status||'backlog')+'">'+statLabel2(g.status||'backlog')+'</span>'; }
function gpill(g){ return '<span class="gn">goal-'+pad2(g.seq)+'</span>'; }
function linkDot(){ return ''; }
function priLabel(p){ return p; }
function priSvg(){ return '<span style="width:9px;height:9px;border-radius:50%;background:currentColor;display:inline-block"></span>'; }
function row(g){
  var kids=goalKids(_goals,g), hasKids=kids.length>0, ds=derivedStatus(_goals,g);
  var statCell=(ds!==null)?'<span class="ot '+ds+'" title="자식 태스크 상태에서 자동 계산">'+statLabel(ds)+'</span>':statSelBoard(g);
  var pcell=hasKids?'<span class="pin-sp"></span>':parentCellHTML(g,true);
  return '<div class="bgoal'+(g.parent?' child':'')+'" data-id="'+g.id+'">'
    +'<span class="bgsp"></span><span class="grip">⠿</span>'
    +'<span class="pri pri-'+(g.priority||'medium')+'">'+priSvg()+'</span>'+gpill(g)
    +'<span class="t gt">'+esc(g.text)+'</span>'+pcell+statCell+'</div>';
}
function render(){ document.getElementById('board').innerHTML=_goals.map(row).join(''); }
fetch('/data.json').then(r=>r.json()).then(function(d){ _review=d; _goals=d.goals; render(); });
</script></body></html>`;

const server = http.createServer((req, res) => {
  if (req.url.startsWith('/data.json')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(REVIEW));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(PAGE);
});
server.listen(8934, '127.0.0.1', () => console.log('parent stub on http://127.0.0.1:8934'));
