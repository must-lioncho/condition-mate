// E2E for 메모장 골번호 + 골부모 트리 (2026-08-06). REAL source 에 묶는다.
// 계약:
//   - 체크리스트 줄, 그리고 상세·칸을 단 줄(2026-08-08)은 보드와 같은 골 번호 공간에서
//     유일 번호를 받는다
//     (POST /api/memo/seq → ReviewStore.reserveSeqs, 번호만 예약 — Goal 은 안 만든다)
//   - 평문 줄도 골번호가 있으면 원 호버로 드러나고, 칸 패널 맨 앞의 '번호' 표찰에도 보인다
//   - 저장은 '@골: N' 들여쓴 줄 — 텍스트로 열어도 읽히고, 왕복(파싱→재직렬화)이 항등
//   - '@부모: M' 칸에 골번호를 적으면 부모 기반 표시(UI 콤보 구조)가 자식을 부모
//     아래로 모은다(표시만)
//   - 채번 전(스텁·오프라인)에는 위치 번호 1,2,3… 폴백, 실패는 조용히
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionManager/Dashboard/MemoPad.swift');
const APP = R('Sources/ConditionManager/AppDelegate.swift');
const REV = R('Sources/ConditionManager/Core/ReviewStore.swift');

let pass = 0, fail = 0;
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + g + '\n      want=' + w); }
}

// ── 칸 정의 ────────────────────────────────────────────────────────────────
const fields = PAD.match(/var FIELDS=\[([\s\S]*?)\];/)[1];
eq('부모 칸이 FIELDS 에 있다 (저장·CSV·병합이 공짜로 따라온다)',
  /\{k:'부모'[^}]*pno:true/.test(fields), true);
eq('부모 칸에는 태그 사전이 없다 (번호 칸이다)',
  /\{k:'부모'[^}]*tag:true/.test(fields), false);
eq("FRE 에 '골' 이 별칭으로 있다 (칸이 아니라 행의 번호로 읽는다)",
  /\|링크\|골[|)]/.test(PAD), true);
eq('골 칸은 FIELDS 에 없다 (편집 칸이 아니다 — 정체성이다)',
  /\{k:'골'/.test(fields), false);

// ── 순수 함수를 실제로 돌려본다 ────────────────────────────────────────────
const slice = (from, to) => {
  const a = PAD.indexOf(from), b = PAD.indexOf(to, a);
  if (a < 0 || b < 0) throw new Error('cannot extract ' + from);
  return PAD.slice(a, b + to.length);
};
const fn = (name) => {
  const start = PAD.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('no fn ' + name);
  let depth = 0;
  for (let k = PAD.indexOf('{', start); k < PAD.length; k++) {
    if (PAD[k] === '{') depth++;
    else if (PAD[k] === '}') { depth--; if (depth === 0) return PAD.slice(start, k + 1); }
  }
  throw new Error('unbalanced ' + name);
};
const env = [
  slice('var FIELDS=', '];'),
  slice("var FRE=new RegExp(", ');'),
  fn('pnum'),
  slice('var LINKS=', '];'),
  slice('var LK2F=', ';'),
  fn('linkKind'),
  fn('parse'),
].join('\n');
const { parse, pnum } = new Function(env + '\nreturn {parse:parse, pnum:pnum};')();

eq("pnum('12') = 12", pnum('12'), 12);
eq("pnum('#12') = 12 (＃를 붙여 적어도 된다)", pnum('#12'), 12);
eq("pnum(' #7 ') = 7 (여백 허용)", pnum(' #7 '), 7);
eq("pnum('x7') = 0 (번호가 아니다)", pnum('x7'), 0);
eq('pnum 빈 값 = 0', pnum(''), 0);

const one = parse('- [ ] certik\n    @골: 599\n    @부모: 12\n    상세 한 줄')[0];
eq('@골: 줄이 행의 골번호로 실린다', one.gno, 599);
eq('@부모: 는 칸으로 (FIELDS 자동 커버)', one.fields['부모'], '12');
eq('상세 줄은 그대로 상세로', one.detail, ['상세 한 줄']);
eq('상태도 그대로', one.st, 'todo');

const dup = parse('- [x] 줄\n    @골: 5\n    @골: 6')[0];
eq('두 번째 @골: 은 상세로 남는다 (첫 번호만 정체성)', dup.gno, 5);
eq('버리지 않는다 — 애매하면 글로 보존', dup.detail, ['@골: 6']);
eq('이상한 @골: 값도 상세로 보존', parse('- [ ] a\n    @골: abc')[0].detail, ['@골: abc']);
eq('골번호 없는 줄은 gno 0', parse('- [ ] 새 줄')[0].gno, 0);

// ── 저장 왕복 ──────────────────────────────────────────────────────────────
eq('lineOf 가 @골: 을 칸보다 먼저 쓴다 (행 정체성이 맨 위)',
  /if\(row\.dataset\.gno\) out\.push\(IND\+'@골: '\+row\.dataset\.gno\);/.test(PAD), true);
eq('render 가 파싱된 골번호를 행에 되돌린다',
  /makeRow\(pad, it\.text, it\.st, it\.detail\.join\('\\n'\), it\.fields, it\.gno[,)]/.test(PAD), true);

// ── 채번 ───────────────────────────────────────────────────────────────────
eq('번호 없는 자격 줄 수만큼 묶어 청한다 (POST /api/memo/seq)',
  /fetch\('\/api\/memo\/seq',\{method:'POST'/.test(PAD)
  && /JSON\.stringify\(\{count:need\.length\}\)/.test(PAD), true);
eq('자격 = 체크리스트 또는 상세·칸을 단 줄 (2026-08-08 확대)',
  /function wantsGno\(r\)\{ return !!\(r\.dataset\.st \|\| r\.dataset\.has==='1'\); \}/.test(PAD)
  && /return wantsGno\(r\) && !r\.dataset\.gno;/.test(PAD), true);
eq('그 사이 지워지거나 자격이 풀리거나 이미 받은 줄은 건너뛴다',
  /if\(!p\.doc\.contains\(r\) \|\| !wantsGno\(r\) \|\| r\.dataset\.gno\) return;/.test(PAD), true);
eq('채번 실패는 조용히 (배너 없음 — 앱 규칙)',
  /\.catch\(function\(\)\{ allocBusy=false; \}\)/.test(PAD), true);
eq('원에는 골번호가 먼저, 채번 전에만 위치 번호',
  /row\.querySelector\('\.cmm-no'\)\.textContent=row\.dataset\.gno\|\|n;/.test(PAD), true);
eq('평문 줄도 골번호가 있으면 원 호버로 드러난다',
  /row\.querySelector\('\.cmm-no'\)\.textContent=row\.dataset\.gno\|\|'';/.test(PAD), true);
eq('번호 없는 줄은 호버해도 빈 알약이 안 뜬다 (:empty 감춤)',
  /\.cmmemo \.cmm-ck:hover \.cmm-no:empty\{ display:none \}/.test(PAD), true);
eq('CSV 번호 열도 골번호가 먼저 — 메모 줄 포함',
  /\(row\.dataset\.gno\|\|\(st\?row\.dataset\.no:''\)\|\|''\)/.test(PAD), true);

// ── 칸 패널의 번호 표찰 ────────────────────────────────────────────────────
eq("칸 패널 맨 앞에 '번호' 표찰이 있다 (편집 칸 아님 — FIELDS 밖)",
  /gcap\.textContent='번호'/.test(PAD)
  && /gv\.className='cmm-gno'/.test(PAD), true);
eq('표찰 값은 paint 가 채운다 — 골번호는 #N, 채번 전에는 —',
  /gEl\.textContent = row\.dataset\.gno \? '#'\+row\.dataset\.gno : '—';/.test(PAD), true);
eq('번호 칸은 FIELDS 에 없다 (저장은 @골: 행 정체성으로만)',
  /\{k:'번호'/.test(fields), false);

// ── 부모 기반 표시 (UI 콤보 구조 섹션, 2026-08-08 정렬→UI 이주) ─────────────
eq('부모 기반 옵션이 있다 (UI 콤보 구조)', /\{s:'tree',n:'부모 기반',d:'부모 아래 자식'\}/.test(PAD), true);
eq('자식은 부모 바로 아래로 (kids 맵 → DFS walk)',
  /if\(g && kids\[g\]\) kids\[g\]\.forEach\(function\(c\)\{ walk\(c, d\+1\); \}\);/.test(PAD), true);
eq('들여쓰기는 3단까지', /r\.setAttribute\('data-tdep', Math\.min\(d,3\)\)/.test(PAD), true);
eq('리스트로 돌리면 흔적을 지운다 (order·data-tdep)',
  /r\.style\.order=''; r\.removeAttribute\('data-tdep'\);/.test(PAD), true);
eq('부모 기반 들여쓰기 CSS', /\.cmmemo\[data-grp="tree"\] \.cmm-row\[data-tdep="1"\]\{ margin-left:24px \}/.test(PAD), true);
eq('부모 칸 꼬리표 — 번호의 제목을 보여 주고 모르면 번호 확인',
  /pkEl\.textContent='번호 확인'/.test(PAD), true);

// ── 서버 ───────────────────────────────────────────────────────────────────
eq('POST /api/memo/seq 핸들러가 있다', /if path == "\/api\/memo\/seq" \{/.test(APP), true);
eq('채번은 액션 로그에 남기지 않는다 (자동 동작)', /"\/api\/memo\/seq",/.test(APP), true);
eq('메모 저장도 액션 로그 제외 (내용 유출 방지)', /^\s*"\/api\/memo",/m.test(APP), true);
eq('ReviewStore 가 같은 시퀀스에서 예약한다 (reserveSeqs)',
  /func reserveSeqs\(_ count: Int\) -> \[Int\]/.test(REV), true);
eq('예약 최고 번호는 floor 로 영속 — 보드 골에 재발급되지 않는다',
  /seq-floor\.json/.test(REV)
  && /max\(goals\.map \{ \$0\.seq \}\.max\(\) \?\? 0, seqFloor\) \+ 1/.test(REV), true);

console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
