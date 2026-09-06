// E2E for 메모장 칸(담당·팀·프로젝트)의 태그 자동완성 — "같은 사람/팀/프로젝트가 철자만
// 다르게 여러 벌 쌓이지 않게, 슬랙처럼 몇 글자 치면 쓰던 이름이 뜨고 그걸 고른다".
// REAL source 에 묶는다: MemoPad.swift(패드 JS), MemoTagStore.swift(사전),
// AppDelegate.swift(라우팅), DashboardServer.swift(GET 화이트리스트).
//
// 여기서 지키는 계약:
//   - 목표일은 사전이 없고 담당·팀·프로젝트만 tag:true (날짜에 사전은 의미가 없다)
//   - 검색은 타이핑이 2초 멎었을 때 한 번, 칸에 처음 들어왔을 때는 기다리지 않는다
//   - 고르든 만들든 같은 길(POST /api/memo/tags)로 사용 기록이 남는다
//   - 만들기는 canCreate 일 때만 — 이미 있는 이름을 또 만들 길은 없다
//   - /api/memo/tags 라우트가 /api/memo 보다 먼저 (접두어가 겹친다)
//   - 사전은 memo.json 이 아니라 자기 파일에, atomic 으로 쓴다
//   - 후보 목록의 매칭/정렬 규칙(앞글자 → 단어 앞글자 → 포함, 많이 쓴 순)
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionMate/Dashboard/MemoPad.swift');
const STORE = R('Sources/ConditionMate/Core/MemoTagStore.swift');
const APP = R('Sources/ConditionMate/AppDelegate.swift');
const SERVER = R('Sources/ConditionMate/Dashboard/DashboardServer.swift');
const STUB = R('.e2e/memostub.js');

let pass = 0, fail = 0;
function eq(name, got, want) {
  if (got === want) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + JSON.stringify(got) + '\n      want=' + JSON.stringify(want)); }
}

// ── 어떤 칸이 사전을 갖는가 ────────────────────────────────────────────────
const fields = PAD.match(/var FIELDS=\[([\s\S]*?)\];/)[1];
eq('목표일에는 사전을 붙이지 않는다', /\{k:'목표일'[^}]*tag:true/.test(fields), false);
['담당', '팀', '프로젝트'].forEach((k) => {
  eq(k + ' 칸은 사전에서 고른다', new RegExp("\\{k:'" + k + "'[^}]*tag:true").test(fields), true);
  eq(k + ' 은 서버 사전의 kind 이다', new RegExp('"' + k + '"').test(STORE.match(/static let kinds = \[(.*)\]/)[1]), true);
});
eq('tag 칸만 wireTag 로 연결된다', /if\(d\.tag\)\{[^}]*wireTag\(pad, row, inp\)/.test(PAD), true);

// ── 언제 찾는가 ────────────────────────────────────────────────────────────
eq('타이핑이 2초 멎으면 찾는다', /var SUG_WAIT=2000;/.test(PAD), true);
eq('input 은 기다렸다 찾는다', /addEventListener\('input',\s*function\(\)\{ sugSchedule\(pad, inp, row, false\)/.test(PAD), true);
eq('focus 는 기다리지 않고 바로 연다', /addEventListener\('focus',\s*function\(\)\{ sugSchedule\(pad, inp, row, true\)/.test(PAD), true);
eq('예약이 겹치면 앞의 것을 버린다 (글자마다 요청이 쌓이지 않는다)',
  /function sugSchedule\([^)]*\)\{\s*if\(sugTimer\)\{ clearTimeout\(sugTimer\)/.test(PAD), true);
eq('늦게 온 응답은 버린다', /if\(my!==sugSeq \|\| document\.activeElement!==inp\) return;/.test(PAD), true);

// ── 고르기 · 만들기 ────────────────────────────────────────────────────────
eq('고르기도 만들기도 같은 길로 기록된다',
  (PAD.match(/sugPick\(/g) || []).length >= 3 && /function sugPick\(name\)\{[\s\S]*?fetch\('\/api\/memo\/tags',\{method:'POST'/.test(PAD), true);
eq('만들기는 canCreate 일 때만 나온다', /if\(canNew\)\{[\s\S]*?cmm-snew/.test(PAD), true);
eq('사전의 표기로 칸을 맞춘다 (대소문자 두 벌 방지)',
  /if\(j && j\.ok && j\.name && j\.name!==inp\.value/.test(PAD), true);
eq('보여 줄 게 없으면 목록을 열지 않는다', /if\(!tags\.length && !canNew\) return;/.test(PAD), true);
eq('후보 클릭은 mousedown+preventDefault (blur 로 먼저 닫히지 않게)',
  /addEventListener\('mousedown', function\(e\)\{ e\.preventDefault\(\); sugPick/.test(PAD), true);

// ── 키 · 닫힘 ──────────────────────────────────────────────────────────────
eq('목록이 열려 있을 때만 키를 가로챈다', /if\(!sugOpen\(\) \|\| ev\.target!==sugInp\) return false;/.test(PAD), true);
eq('Esc 는 칸이 아니라 목록만 닫는다', /if\(ev\.key==='Escape'\)\{ ev\.preventDefault\(\); ev\.stopPropagation\(\); sugClose\(\); return true; \}/.test(PAD), true);
// 칸의 Esc/⌘Enter(칸 접기)는 목록이 없을 때만 — 목록이 떠 있는데 칸까지 접히면 한 번에 두 단계가 사라진다.
eq('칸 키 처리보다 목록이 먼저다',
  PAD.indexOf('if(sugKey(ev)) return;') <
  PAD.indexOf("if(((ev.metaKey||ev.ctrlKey) && ev.key==='Enter') || ev.key==='Escape')"), true);
eq('칸이 접히면 목록도 닫힌다', /if\(sugRow===row\) sugClose\(\);/.test(PAD), true);
// 뿌리 D — 이 단정은 핸들러 '본문 전체' 를 정규식으로 고정하고 있었다. 2026-08 에 같은
// 핸들러에 tipHide() 한 줄이 더해지자(툴팁도 같이 닫는다) 약속한 행동은 그대로 지켜지는데
// 시험만 붉어졌다. 소스 문자열을 통째로 고정하면 기능 추가가 곧 시험 실패가 된다.
// 여기서 지킬 것은 "스크롤·리사이즈에 후보 목록과 메뉴를 닫는다" 뿐이니 그것만 본다.
const handlerBody = (evt) => {
  const m = PAD.match(new RegExp("addEventListener\\('" + evt + "', function\\(\\)\\{([^{}]*)\\}"));
  return m ? m[1] : '';
};
['scroll', 'resize'].forEach((evt) => {
  const body = handlerBody(evt);
  eq(evt + ' 에 후보 목록이 따라 떠 있지 않는다', /sugClose\(\);/.test(body), true);
  eq(evt + ' 에 메뉴도 같이 닫힌다', /closeMenu\(\);/.test(body), true);
});
eq('바깥 클릭은 닫되 자기 칸 클릭은 살려 둔다',
  /if\(sugEl && ev\.target!==sugInp && !sugEl\.contains\(ev\.target\)\) sugClose\(\);/.test(PAD), true);

// ── 서버 배선 ──────────────────────────────────────────────────────────────
eq('GET /api/memo/tags 가 /api/memo 보다 먼저 걸린다',
  APP.indexOf('path.hasPrefix("/api/memo/tags")') < APP.indexOf('path.hasPrefix("/api/memo") {'), true);
eq('POST /api/memo/tags 도 /api/memo 보다 먼저',
  APP.indexOf('path == "/api/memo/tags"') < APP.indexOf('path == "/api/memo" {'), true);
eq('GET 화이트리스트가 /api/memo 접두어로 tags 까지 덮는다',
  /path\.hasPrefix\("\/api\/memo"\)/.test(SERVER), true);
eq('모르는 칸 이름은 빈 목록으로 조용히 돌려보낸다 (실패 배너 없음)',
  /guard MemoTagStore\.isKind\(kind\) else \{ return "\{\\"tags\\":\[\],\\"canCreate\\":false\}" \}/.test(APP), true);
eq('canCreate 는 "그 글자로 만들 태그가 없다" 는 뜻',
  /let canCreate = !q\.isEmpty && !MemoTagStore\.shared\.exists\(kind: kind, name: q\)/.test(APP), true);
eq('kind 는 자유 입력이 아니다 (오타 하나가 새 사전을 만들지 않게)',
  /guard MemoTagStore\.isKind\(kind\) else \{ return nil \}/.test(STORE), true);

// ── 사전 저장 ──────────────────────────────────────────────────────────────
eq('사전은 memo.json 이 아니라 자기 파일', /memo-tags\.json/.test(STORE) && !/memo-tags/.test(R('Sources/ConditionMate/Core/MemoStore.swift')), true);
eq('atomic 으로 쓴다 (반쪽 사전이 남지 않게)', /options: \.atomic/.test(STORE), true);
eq('이름 수·길이에 상한이 있다', /maxPerKind/.test(STORE) && /maxNameChars/.test(STORE), true);
eq('있는 이름은 새로 만들지 않고 횟수만 오른다', /list\[i\]\.count \+= 1/.test(STORE), true);

// ── 매칭·정렬 규칙 (stub 이 서버 규칙을 그대로 흉내 내는지) ────────────────
// searchTags 는 memostub.js 안의 in-memory 판. Swift 와 같은 3단계 점수를 쓰는지 실제로 돌려본다.
const searchTags = (() => {
  const body = STUB.slice(STUB.indexOf('const fold ='), STUB.indexOf('http.createServer'));
  const mod = {};
  new Function('tags', 'module', body + ';module.exports={fold,searchTags}')(
    {
      담당: [{ name: 'ismail', count: 4 }, { name: 'ismail.k', count: 1 },
             { name: 'Kim ismet', count: 9 }, { name: '김지훈', count: 3 },
             { name: 'prismail', count: 99 }],
    }, mod);
  return mod.exports.searchTags;
})();
const names = (q) => searchTags('담당', q).map((t) => t.name);
eq('앞글자 일치가 먼저, 그 안에서 많이 쓴 순', names('ism').slice(0, 2).join(','), 'ismail,ismail.k');
eq('단어 앞글자도 잡는다 ("Kim ismet" 의 ismet)', names('ism').indexOf('Kim ismet'), 2);
eq('아무데나 포함은 맨 뒤 (횟수가 99여도)', names('ism').pop(), 'prismail');
eq('대소문자는 같은 것으로 본다', names('ISM').length, 4);
eq('빈 질의는 자주 쓰는 순 목록', names('')[0], 'prismail');
eq('없는 글자는 빈 목록', names('zzz').length, 0);
eq('모르는 칸은 빈 목록', searchTags('없는칸', 'a').length, 0);

console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
