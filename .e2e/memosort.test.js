// E2E for 메모장 정렬 — "처리 관점: 미완료는 맨 위, 바틀넥은 완료 바로 위, 완료는 맨 아래. 기본은 입력 순서."
// REAL source(MemoPad.swift)에 묶는다. 여기서 지키는 계약:
//   - 정렬은 CSS(order)만 바꾼다 — 저장 텍스트의 줄 순서·일련번호·⌘Z 히스토리는 그대로
//   - 기본값은 입력 순서(localStorage 에 아무것도 없을 때 data-sort 미부착)
//   - 선택은 cmMemoSort 로 저장되어 다음에 열 때도 유지
//   - 헤더 버튼은 보기 와 ＋체크리스트 사이, 활성 시 라벨이 모드를 말해 준다
//   - 콤보는 단일 선택(라디오) — 입력 순서 / 미완료 위 · 완료 아래 두 옵션
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionManager/Dashboard/MemoPad.swift');

let pass = 0, fail = 0;
function eq(name, got, want) {
  if (got === want) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + JSON.stringify(got) + '\n      want=' + JSON.stringify(want)); }
}

// ── 표시만 바꾼다 (CSS order) ──────────────────────────────────────────────
eq('정렬은 flex order 로만 — 바틀넥은 완료 바로 위로',
  /\.cmmemo\[data-sort="st"\] \.cmm-row\[data-st="block"\]\{ order:1 \}/.test(PAD), true);
eq('완료는 맨 아래로',
  /\.cmmemo\[data-sort="st"\] \.cmm-row\[data-st="done"\]\{ order:2 \}/.test(PAD), true);
eq('정렬 중에만 편집면이 flex 컨테이너가 된다',
  /\.cmmemo\[data-sort="st"\] \.cmm-doc\{ display:flex; flex-direction:column \}/.test(PAD), true);
eq('미완료·평문 줄은 order:0 — 맨 위 (입력 순서 유지)',
  /\.cmmemo\[data-sort="st"\] \.cmm-row\{ order:0 \}/.test(PAD), true);
// 저장 경로는 DOM 순서(=텍스트 순서)를 그대로 읽는다 — 정렬이 저장을 건드릴 길이 없다.
eq('serialize 는 DOM 순서 그대로 (order 를 보지 않는다)',
  /function rows\(pad\)\{ return Array\.prototype\.slice\.call\(pad\.doc\.children\); \}/.test(PAD), true);
eq('정렬 전환은 히스토리에 남지 않는다 (sortSet 이 onEdit 을 부르지 않는다)',
  /function sortSet\(m\)\{[^}]*onEdit/.test(PAD), false);

// ── 기본값 · 저장 ──────────────────────────────────────────────────────────
eq('기본은 입력 순서 (아는 모드 st 외에는 전부 기본 — 트리는 UI 콤보 구조로 이주)',
  /return v==='st' \? v : ''/.test(PAD), true);
eq('선택은 cmMemoSort 로 저장된다', /localStorage\.setItem\('cmMemoSort', m\)/.test(PAD), true);
eq('기본 모드에서는 data-sort 를 떼어낸다 (CSS 흔적 없음)',
  /else p\.el\.removeAttribute\('data-sort'\)/.test(PAD), true);
eq('마운트마다 저장된 정렬을 다시 칠한다', /viewPaint\(\);[\s\S]{0,80}?sortPaint\(\);/.test(PAD), true);

// ── 헤더 버튼 위치 · 라벨 ──────────────────────────────────────────────────
eq('정렬 버튼은 보기 와 ＋체크리스트 사이',
  PAD.indexOf('data-cmmemo-view ') < PAD.indexOf('data-cmmemo-sort') &&
  PAD.indexOf('data-cmmemo-sort') < PAD.indexOf('data-cmmemo-add'), true);
eq('활성 시 버튼 라벨이 모드를 말해 준다',
  /p\.sort\.textContent = m \? '미완료↑ 완료↓ ▾' : '정렬 ▾'/.test(PAD), true);

// ── 콤보 (라디오) ─────────────────────────────────────────────────────────
const sorts = PAD.match(/var SORTS=\[([\s\S]*?)\];/)[1];
eq('옵션 1 = 입력 순서(기본)', /\{s:'',n:'입력 순서',d:'기본'\}/.test(sorts), true);
eq('옵션 2 = 미완료 위 · 완료 아래', /\{s:'st',n:'미완료 위 · 완료 아래'/.test(sorts), true);
eq('트리는 더 이상 정렬 옵션이 아니다 (UI 콤보 구조 섹션으로 이주)',
  /tree/.test(sorts), false);
eq('고르면 즉시 적용되고 콤보가 닫힌다 (라디오)',
  /ev\.preventDefault\(\); sortSet\(o\.s\); closeMenu\(\);/.test(PAD), true);
eq('체크 표시는 현재 모드 하나만',
  /x\.b\.setAttribute\('aria-checked', x\.o\.s===m \? 'true' : 'false'\)/.test(PAD), true);
eq('같은 버튼을 다시 누르면 닫는다',
  /var was = menuEl && menuEl\.dataset\.sort==='1';\s*closeMenu\(\);\s*if\(was\) return;/.test(PAD), true);
eq('콤보를 닫으면 정렬 버튼의 aria 도 풀린다',
  /if\(p\.sort\) p\.sort\.setAttribute\('aria-expanded','false'\)/.test(PAD), true);

console.log('---');
console.log(pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
