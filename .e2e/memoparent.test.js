// E2E for 메모장 부모 칸의 후보 드롭다운 — "칸에 들어오면 최근에 확정한 부모 번호가
// 맨 위(최신 먼저), 그 아래 이 줄 제목에 대한 AI 추천(서버 ParentSuggest)이 뜬다".
// REAL source 에 묶는다: MemoPad.swift(패드 JS), AppDelegate.swift(라우팅+핸들러),
// Settings.swift(MRU), ParentSuggest.swift(rank), DashboardServer.swift(GET 화이트리스트).
//
// 여기서 지키는 계약:
//   - 부모 칸(pno)만 wireParent 로 연결된다
//   - 칸에 들어오면 기다리지 않고 바로 찾는다(늦게 온 응답은 버린다)
//   - 섹션 순서 = 최근(최신이 맨 위) -> AI 추천, 겹치는 번호는 최근 쪽만
//   - 타이핑 필터는 받아 둔 목록을 로컬에서 거른다(재요청 없음)
//   - 고르면 번호가 칸에 들어가고 POST /api/memo/parent-used 로 사용 기록이 남는다
//   - 손으로 적은 번호도 blur 에서 기록된다 — 단, 이번 포커스에서 값이 바뀌었을 때만
//   - 후보 클릭은 mousedown+preventDefault (blur 로 먼저 닫히지 않게)
//   - 서버 MRU = 최신이 맨 앞, 8개 상한, 보드 부모# 와 같은 목록(noteParentUse)
//   - /api/memo/parent-suggest 라우트가 /api/memo 보다 먼저 (접두어가 겹친다)
//   - 자기 자신(이 줄의 골번호)은 최근/추천 어느 목록에도 나오지 않는다
//   - 추천은 ParentSuggest.rank — 드롭다운 전용이라 compute 의 침묵 게이트가 없다
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionMate/Dashboard/MemoPad.swift');
const APP = R('Sources/ConditionMate/AppDelegate.swift');
const SET = R('Sources/ConditionMate/Core/Settings.swift');
const PS = R('Sources/ConditionMate/Core/ParentSuggest.swift');
const SERVER = R('Sources/ConditionMate/Dashboard/DashboardServer.swift');

let pass = 0, fail = 0;
function eq(name, got, want) {
  if (got === want) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + JSON.stringify(got) + '\n      want=' + JSON.stringify(want)); }
}

// ── 배선 ───────────────────────────────────────────────────────────────────
eq('부모 칸(pno)만 wireParent 로 연결된다', /if\(d\.pno\)\{ wireParent\(pad, row, inp\); \}/.test(PAD), true);
eq('focus 는 기다리지 않고 바로 찾는다', /addEventListener\('focus', function\(\)\{ v0=inp\.value; psugFetch\(pad, inp, row\); \}\)/.test(PAD), true);
eq('늦게 온 응답은 버린다', /if\(my!==sugSeq \|\| document\.activeElement!==inp\) return;\s*\n\s*inp\._psug=j;/.test(PAD), true);
eq('타이핑 필터는 로컬 — 재요청 없음', /addEventListener\('input', function\(\)\{\s*\n\s*if\(inp\._psug\) psugRender\(pad, inp, row, inp\._psug\);/.test(PAD), true);
eq('후보 클릭은 mousedown+preventDefault', /addEventListener\('mousedown', function\(e\)\{ e\.preventDefault\(\); psugPick\(it\.n\); \}\)/.test(PAD), true);
eq('손 입력도 blur 에서 기록 — 값이 바뀌었을 때만', /if\(n && inp\.value!==v0\)/.test(PAD), true);
eq('섹션 순서 = 최근이 먼저, AI 추천이 다음',
  PAD.indexOf("h1.textContent='최근 — 방금 쓴 것이 맨 위'") >= 0
  && PAD.indexOf("h1.textContent='최근 — 방금 쓴 것이 맨 위'") < PAD.indexOf("h2.textContent='AI 추천 — 이 줄 제목으로'"), true);

// ── 라우팅 · 서버 ──────────────────────────────────────────────────────────
eq('/api/memo/parent-suggest 가 /api/memo 보다 먼저다',
  APP.indexOf('path.hasPrefix("/api/memo/parent-suggest")') >= 0
  && APP.indexOf('path.hasPrefix("/api/memo/parent-suggest")') < APP.indexOf('if path.hasPrefix("/api/memo") {'), true);
eq('POST /api/memo/parent-used 는 noteParentUse 로 기록한다',
  /if path == "\/api\/memo\/parent-used" \{\s*\n\s*Settings\.shared\.noteParentUse/.test(APP), true);
eq('추천은 ParentSuggest.rank 를 쓴다', /ParentSuggest\.rank\(title: t, goals: input, recentParentSeqs: recent\)/.test(APP), true);
eq('자기 자신은 최근 목록에서 뺀다', /recentParentSeqs\.filter \{ \$0 != no \}/.test(APP), true);
eq('자기 자신은 추천 목록에서도 뺀다', /\.filter \{ \$0\.parentSeq != no \}/.test(APP), true);
eq('GET 화이트리스트가 /api/memo 접두어를 허용한다', /path\.hasPrefix\("\/api\/memo"\)/.test(SERVER), true);
eq('rank 는 침묵 게이트(minScore·minMargin·minCoverage)를 걸지 않는다',
  (() => {
    const a = PS.indexOf('static func rank(');
    const b = PS.indexOf('static func compute(');
    if (a < 0) return 'no rank';
    // rank 본문(다음 static/private 선언 전까지)에 게이트 상수 참조가 없어야 한다.
    const body = PS.slice(a, PS.indexOf('private static func evidenceUnits'));
    return b >= 0 && !/minScore|minMargin|minCoverage/.test(body);
  })(), true);

// ── 서버 MRU (보드 부모# 와 같은 목록) ─────────────────────────────────────
eq('MRU 는 최신이 맨 앞이다', /list\.insert\(seq, at: 0\)/.test(SET), true);
eq('MRU 상한은 8개다', /if list\.count > 8 \{ list = Array\(list\.prefix\(8\)\) \}/.test(SET), true);

// ── 동작: psugRender 를 실 소스에서 뽑아 스텁 DOM 으로 돌린다 ───────────────
function fn(name) {
  const start = PAD.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = PAD.indexOf('{', start); k < PAD.length; k++) {
    if (PAD[k] === '{') depth++;
    else if (PAD[k] === '}') { depth--; if (depth === 0) return PAD.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
}
function el(tag) {
  return { tag, children: [], style: {}, listeners: {}, type: '', title: '', textContent: '', className: '',
    appendChild(c) { this.children.push(c); },
    addEventListener(t, f) { this.listeners[t] = f; },
    querySelectorAll() { return []; } };
}
const POSTS = [];
global.document = {
  createElement: el,
  body: el('body'),
  documentElement: {},
  activeElement: null
};
global.window = { innerWidth: 0, innerHeight: 0 };
global.fetch = (url, opt) => { POSTS.push({ url, opt }); return Promise.resolve({ json: () => Promise.resolve({}) }); };

var painted = 0, edited = 0;
var sandbox = [
  'var sugEl=null,sugInp=null,sugPad=null,sugRow=null,sugAt=-1,sugSeq=0;',
  'function sugClose(){ sugEl=null; sugInp=null; }',
  'function rows(){ return []; }',
  'function goalTitle(){ return null; }',
  'function paint(){ painted++; }',
  'function onEdit(){ edited++; }',
  fn('pnum'), fn('sugPlace'), fn('psugTitleOf'), fn('psugItem'), fn('psugPick'), fn('psugRender'),
  // 검사용 손잡이
  'global._t={render:psugRender, open:function(){return sugEl;}};'
].join('\n');
eval(sandbox);
const T = global._t;

const DATA = {
  recent: [{ n: 784, t: 'MPC Listing' }, { n: 12, t: '베타 정리' }],
  sug: [{ n: 784, t: 'MPC Listing', why: '제목 키워드 일치: mpc' },
        { n: 99, t: '큐 파이프라인', why: '제목 키워드 일치: 큐' }]
};
const pad = {}, row = { dataset: {}, querySelector: () => null };
const inp = { value: '', focus() {} };

// 열림 + 섹션/순서/겹침 제거
T.render(pad, inp, row, DATA);
let dd = T.open();
const heads = dd.children.filter(c => c.className === 'cmm-sh').map(c => c.textContent);
const txt = (b) => b.children.map(c => c.textContent).join('');
const items = dd.children.filter(c => c.tag === 'button').map(txt);
eq('최근 섹션이 먼저 열린다', heads[0], '최근 — 방금 쓴 것이 맨 위');
eq('AI 추천 섹션이 그 아래다', heads[1], 'AI 추천 — 이 줄 제목으로');
eq('최근은 서버 MRU 순서 그대로(최신이 맨 위)', items[0].indexOf('#784') === 0 && items[1].indexOf('#12') === 0, true);
eq('최근과 겹치는 추천(#784)은 한 번만 나온다', items.filter(t => t.indexOf('#784') === 0).length, 1);
eq('겹치지 않는 추천(#99)은 제목과 함께 나온다', items[2], '#99 · 큐 파이프라인');

// 타이핑 필터 — 번호 앞자리/제목 포함
inp.value = '7';
T.render(pad, inp, row, DATA);
dd = T.open();
eq('숫자를 치면 번호 앞자리로 걸러진다',
  dd.children.filter(c => c.tag === 'button').map(txt).join('|'), '#784 · MPC Listing');
inp.value = '큐';
T.render(pad, inp, row, DATA);
dd = T.open();
eq('글자를 치면 제목 포함으로 걸러진다',
  dd.children.filter(c => c.tag === 'button').map(txt).join('|'), '#99 · 큐 파이프라인');
inp.value = '없는후보';
T.render(pad, inp, row, DATA);
eq('맞는 후보가 없으면 목록을 열지 않는다', T.open(), null);

// 고르기 — 번호 확정 + 사용 기록
inp.value = '';
T.render(pad, inp, row, DATA);
dd = T.open();
const first = dd.children.filter(c => c.tag === 'button')[0];
let prevented = false;
first.listeners.mousedown({ preventDefault() { prevented = true; } });
eq('클릭은 preventDefault 로 blur 를 막는다', prevented, true);
eq('고르면 번호가 칸에 들어간다', inp.value, '784');
eq('고르면 사용 기록이 남는다(POST parent-used)',
  POSTS.length === 1 && POSTS[0].url === '/api/memo/parent-used' && JSON.parse(POSTS[0].opt.body).n, 784);
eq('고른 뒤 목록은 닫힌다', T.open(), null);
eq('고르면 다시 그리고 저장한다(paint+onEdit)', painted >= 1 && edited >= 1, true);

console.log('\n' + pass + ' pass, ' + fail + ' fail');
process.exit(fail ? 1 : 0);
