// E2E for the 부모# 칸 자동 부모 추천 (ghost number · status dot · 최근/추천 드롭다운).
// Bound to REAL source: extracts the cell/ghost/dropdown functions out of
// DashboardContent.swift and runs them against a stub DOM + a stub /data.json review
// object carrying the server's new `psug` / `recentParents` fields. Asserts:
//   - 부모 없음 + 추천 있음 -> 회색 고스트(<a class="pghost">)가 렌더된다
//   - 고스트는 input value 를 절대 채우지 않는다 (확정은 사용자가 번호를 직접 입력할 때만)
//   - 고스트는 추천 부모 goal 페이지(/goal?n=NN)로 가는 링크다
//   - 점 클래스가 추천 부모의 실효 상태를 따른다(자식 롤업 포함), 계산 중이면 보라 calc
//   - 이미 부모가 있는 행에는 고스트가 없다
//   - 드롭다운 섹션 순서 = 추천 -> 최근 사용 -> 후보, 항목 클릭은 즉시 확정(POST)
//   - 타이핑하면 목록이 실시간으로 걸러진다 (포커스는 입력칸에 그대로)
//   - 최근 사용 목록이 서버 MRU(recentParents)를 따른다 (localStorage 아님)
const fs = require('fs');
const SRC = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/DashboardContent.swift', 'utf8');
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
const constLine = name => {
  const m = SRC.match(new RegExp('^const ' + name + '=.*$', 'm'));
  if (!m) throw new Error('no const ' + name);
  return 'var ' + m[0].slice('const '.length);
};

// ---- stub DOM: only what the dropdown touches ----
const pinListEl = { innerHTML: '' };
let _popup = null;   // {x,y,html} — showPopup/hidePopup are stubbed, not extracted
global.$ = id => (id === 'pinList' ? pinListEl : null);
global.showPopup = (x, y, html) => { _popup = { x, y, html }; };
global.hidePopup = () => { _popup = null; };
const POSTS = [];
global.post = (path, obj) => { POSTS.push({ path, obj }); };

var _goals = [], _review = null, _fill = null, _pinId = null;
eval([
  constLine('PIN_TIP'),
  fn('esc'), fn('escAttr'), fn('pad2'), fn('byId'),
  fn('statLabel'), fn('statLabel2'), fn('goalKids'), fn('derivedStatus'),
  fn('recentParentSeqs'), fn('recentParentIds'),
  fn('psugItems'), fn('psugRunning'), fn('psugFor'), fn('bySeq'),
  fn('psugStatusOf'), fn('psugStatusLabel'), fn('psugGhostHTML'),
  fn('parentCellHTML'), fn('setParentById'), fn('pinPick'), fn('pinItemHTML'), fn('renderPinList')
].join('\n'));

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

// ---- fixture: a small tracker ----
//   #1 슬랙 번역 파이프라인   — 부모, 자식 #4 가 진행 중 -> 롤업 on_track (자체 상태 backlog 가 아니라)
//   #2 장비 페이지            — 부모, 자식 #11 보유
//   #7 포모도로 통계          — 부모 없음, 잎, 자체 상태 waiting
//   #3 네트워크 진단 프로브    — 부모 없음, 잎 (최근/추천 어디에도 없는 순수 후보)
//   #10 슬랙 번역 데몬 재시작 — 미연결 고아 (추천 대상)
//   #11 늑대 스프라이트 추가  — 이미 #2 의 자식
const G = [
  { id: 'g1', seq: 1, text: '슬랙 번역 파이프라인', parent: '', status: 'backlog' },
  { id: 'g4', seq: 4, text: '데몬 로그 회전', parent: 'g1', status: 'in_progress' },
  { id: 'g2', seq: 2, text: '장비 페이지 픽셀아트', parent: '', status: 'backlog' },
  { id: 'g3', seq: 3, text: '네트워크 진단 프로브', parent: '', status: 'backlog' },
  { id: 'g7', seq: 7, text: '포모도로 통계 영속화', parent: '', status: 'waiting' },
  { id: 'g10', seq: 10, text: '슬랙 번역 데몬 재시작 처리', parent: '', status: 'backlog' },
  { id: 'g11', seq: 11, text: '늑대 스프라이트 추가', parent: 'g2', status: 'backlog' }
];
const byid = id => G.find(g => g.id === id);
function setReview(psugState, items, recent) {
  _goals = G;
  _review = { goals: G, psug: { state: psugState, at: 0, items: items || [] }, recentParents: recent || [] };
}
const SUG = [{ seq: 10, p: 1, score: 0.82, why: '제목 키워드 일치: 슬랙, 번역' }];

// ===== 1. 고스트 렌더 =====
setReview('ready', SUG, [7, 2]);
const cell10 = parentCellHTML(byid('g10'), true);
check('추천 있는 고아: 고스트 렌더', cell10.indexOf('class="pghost"') >= 0);
check('고스트는 추천 부모 goal 페이지 링크', cell10.indexOf('href="/goal?n=1"') >= 0, cell10);
check('고스트에 회색 번호 01 표시', /<\/i>01<\/a>/.test(cell10), cell10);
// 요구사항 2: 확정은 사용자가 직접 입력할 때만 — 고스트가 있어도 input 은 비어 있어야 한다.
check('고스트가 input value 를 채우지 않음', /class="pin"[^>]*value=""/.test(cell10), cell10.slice(0, 160));
check('고스트 있으면 placeholder 를 비워 겹침 방지', cell10.indexOf('placeholder=""') >= 0);
check('툴팁: 부모 번호 · 상태 · 근거 · 확정 안내', (function () {
  const m = cell10.match(/<a class="pghost"[^>]*title="([^"]*)"/);
  return !!m && m[1].indexOf('추천 부모 goal-01') >= 0 && m[1].indexOf('슬랙') >= 0
    && m[1].indexOf('확정은 번호를 직접 입력') >= 0;
})(), (cell10.match(/<a class="pghost"[^>]*title="([^"]*)"/) || [])[1]);

// ===== 2. 점 색 = 추천 부모의 실효 상태 =====
// #1 은 자식 #4 가 진행 중이라 롤업 on_track (수동 상태 backlog 가 아니라).
check('점 클래스 = 롤업 상태 on_track', cell10.indexOf('psdot on_track') >= 0, cell10);
// 잎 부모는 롤업이 없으니 자체 상태가 그대로 점 색이 된다.
setReview('ready', [{ seq: 10, p: 7, score: 0.7, why: '제목 키워드 일치: 포모도로' }], []);
check('점 클래스 = 부모의 자체 상태(waiting)', parentCellHTML(byid('g10'), true).indexOf('psdot waiting') >= 0,
  parentCellHTML(byid('g10'), true).match(/psdot [a-z_]*/));
// 계산 중에는 상태색 대신 보라 pulse
setReview('running', SUG, []);
check('계산 중: 보라 calc 점', parentCellHTML(byid('g10'), true).indexOf('psdot calc') >= 0);
check('계산 중 툴팁 문구', parentCellHTML(byid('g10'), true).indexOf('다시 계산 중') >= 0);
setReview('running', [], []);
const calcOnly = parentCellHTML(byid('g10'), true);
check('추천 없이 계산만 진행 중: 점만', calcOnly.indexOf('psdot calc') >= 0 && calcOnly.indexOf('href=') < 0, calcOnly);

// ===== 3. 고스트가 뜨지 않아야 하는 경우 =====
setReview('ready', SUG, []);
check('이미 부모가 있는 행: 고스트 없음', parentCellHTML(byid('g11'), true).indexOf('pghost') < 0);
check('이미 부모가 있는 행: 부모 번호가 값으로', parentCellHTML(byid('g11'), true).indexOf('value="02"') >= 0);
setReview('ready', [], []);
check('추천도 계산도 없음: 고스트 없음', parentCellHTML(byid('g10'), true).indexOf('pghost') < 0);
check('고스트 없으면 placeholder 부모#', parentCellHTML(byid('g10'), true).indexOf('placeholder="부모#"') >= 0);

// ===== 4. 뷰별 차이: Cmd+드래그 채우기는 보드에서만 =====
setReview('ready', SUG, []);
check('보드 셀: pinDown 배선', parentCellHTML(byid('g10'), true).indexOf('pinDown(event') >= 0);
check('목록 셀: pinDown 없음', parentCellHTML(byid('g10'), false).indexOf('pinDown(event') < 0);
check('두 뷰 모두 같은 고스트를 쓴다', parentCellHTML(byid('g10'), false).indexOf('class="pghost"') >= 0);

// ===== 5. 드롭다운: 섹션 순서 · 즉시 확정 · 실시간 필터 =====
setReview('ready', SUG, [7, 2]);
_pinId = 'g10';
renderPinList('');
const H = pinListEl.innerHTML;
const iSug = H.indexOf('>추천<'), iRec = H.indexOf('>최근 사용<'), iCand = H.indexOf('>후보<');
check('섹션 순서: 추천 -> 최근 사용 -> 후보', iSug >= 0 && iRec > iSug && iCand > iRec, iSug + '/' + iRec + '/' + iCand);
check('추천 섹션에 goal-01', H.slice(iSug, iRec).indexOf('goal-01') >= 0);
check('추천 근거를 함께 보여줌', H.indexOf('제목 키워드 일치: 슬랙, 번역') >= 0);
check('최근 사용 = 서버 MRU 순서(07 먼저, 그다음 02)',
  H.slice(iRec, iCand).indexOf('goal-07') < H.slice(iRec, iCand).indexOf('goal-02'));
check('추천 부모는 최근/후보에서 중복되지 않음', (H.match(/goal-01/g) || []).length === 1);
check('자기 자신은 후보가 아님', H.indexOf('goal-10') < 0);
check('자식이 있는 목표도 부모 후보 (goal-02)', H.indexOf('goal-02') >= 0);
check('이미 자식인 목표는 후보 아님 (goal-11)', H.indexOf('goal-11') < 0);
check('부모 없는 행에는 Unlink 없음', H.indexOf('Unlink') < 0);

// 타이핑 필터 — 포커스를 뺏지 않으려고 항목은 mousedown 에서 preventDefault 한다.
renderPinList('포모');
check('타이핑 필터링', pinListEl.innerHTML.indexOf('goal-07') >= 0 && pinListEl.innerHTML.indexOf('goal-01') < 0);
check('항목은 mousedown+preventDefault (입력 포커스 유지)',
  pinListEl.innerHTML.indexOf('onmousedown="event.preventDefault()') >= 0);
renderPinList('없는검색어');
check('결과 없음 안내', pinListEl.innerHTML.indexOf('결과 없음') >= 0);

// 항목 클릭 = 즉시 확정
POSTS.length = 0; _pinId = 'g10'; _popup = { x: 0, y: 0, html: '' };
pinPick('g1');
check('항목 클릭은 즉시 확정(POST /api/goal/parent)',
  POSTS.length === 1 && POSTS[0].path === '/api/goal/parent' && POSTS[0].obj.parent === 'g1', JSON.stringify(POSTS));
check('확정 후 드롭다운 닫힘', _popup === null);

// 부모가 있는 행이면 Unlink 가 맨 위에
_pinId = 'g11';
renderPinList('');
check('부모 있는 행: Unlink 최상단', pinListEl.innerHTML.indexOf('Unlink') === 0 || pinListEl.innerHTML.indexOf('unlink') < pinListEl.innerHTML.indexOf('pophdr'));
POSTS.length = 0; _pinId = 'g11';
pinPick('');
check('Unlink 는 빈 부모로 확정', POSTS.length === 1 && POSTS[0].obj.parent === '');

// ===== 6. 최근 사용은 서버 MRU 만 본다 (localStorage 흔적 없음) =====
check('setParentById 가 localStorage 를 쓰지 않음', fn('setParentById').indexOf('localStorage') < 0);
check('부모 선택기도 서버 MRU 사용', fn('renderParentList').indexOf('recentParentIds') >= 0);
check('cm.lastParent 잔재 없음', SRC.indexOf('cm.lastParent') < 0);

// ===== 7. 점 색은 신호등이 아니라 기존 상태 팔레트를 재사용한다 =====
const cssStart = SRC.indexOf('.psdot{'), cssEnd = SRC.indexOf('@keyframes psblink');
const css = SRC.slice(cssStart, cssEnd);
check('psdot CSS 추출', cssStart > 0 && css.length > 0);
check('계산 중 = 보라 (#9b7bff)', css.indexOf('#9b7bff') >= 0);
check('진행/대기 색이 상태 팔레트와 동일', css.indexOf('#5b8cff') >= 0 && css.indexOf('#e8a33d') >= 0 && css.indexOf('#4cc9f0') >= 0);

// ===== 8. 추천과 입력칸은 히트 영역이 겹치지 않는다 =====
// 한때 고스트를 입력칸 위에 절대배치했더니, 세 자리 부모 번호(goal-680)에서 겹친 폭이 칸의
// 절반을 넘어 "가운데를 눌러 타이핑" 하려던 클릭까지 링크가 삼켜 페이지를 이동시켰다.
// 이제 둘은 .pinwrap 안의 나란한 flex 형제다 — 이 구조가 깨지면 그 버그가 돌아온다.
const wrapCss = SRC.slice(SRC.indexOf('.pinwrap{'), SRC.indexOf('.psdot{'));
check('칸 겉모양(폭/테두리)은 .pinwrap 이 갖는다',
  /\.pinwrap\{[^}]*width:84px[^}]*border:1px solid var\(--line\)/.test(wrapCss), wrapCss.slice(0, 120));
check('고스트는 absolute 배치가 아니다', !/\.pghost\{[^}]*position:absolute/.test(wrapCss));
check('고스트는 줄어들지 않는 flex 형제', /\.pghost\{[^}]*flex:0 0 auto/.test(wrapCss));
check('입력칸이 남는 폭을 차지한다', /\.pinwrap \.pin\{[^}]*flex:1 1 auto/.test(wrapCss));
check('입력칸 테두리는 전역 input 규칙까지 벗겨낸다',
  /\.pinwrap \.pin\{[^}]*background:transparent[^}]*border:0/.test(wrapCss.replace(/\n\s*/g, '')));
const shape = parentCellHTML(byid('g10'), true);
check('마크업 순서: 고스트 -> 입력칸', shape.indexOf('pghost') < shape.indexOf('class="pin"'), shape.slice(0, 80));
check('입력칸에 고정 폭 인라인 스타일이 없다(칸 폭은 wrap 소유)',
  parentCellHTML(byid('g10'), false).indexOf('style="width:') < 0);
check('타이핑 중에는 고스트가 비켜난다', /\.pinwrap\.focus \.pghost\{display:none\}/.test(wrapCss));

console.log('\n' + (fail ? 'FAILED ' + fail + ' / ' : 'ALL PASS ') + (pass + fail) + ' checks');
process.exit(fail ? 1 : 0);
