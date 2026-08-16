// E2E for 메모장 UI 모드 — "공유·발표할 때는 쓰고 있는 줄만 잘 보이면 된다."
// REAL source(MemoPad.swift)에 묶는다. 여기서 지키는 계약:
//   - UI 모드는 CSS(data-ui)만 바꾼다 — 저장 텍스트·번호·⌘Z 히스토리는 그대로
//   - 기본값은 현재 모습(localStorage 에 아무것도 없을 때 data-ui 미부착)
//   - 선택은 cmMemoUI 로 저장되어 다음에 열 때도 유지
//   - 집중 모드: 캐럿/호버 밖의 줄은 회색으로 가라앉고, 쓰는 줄만 색·바탕이 남는다
//   - 집중 모드: 글자가 한 단계 커진다(본문 16px, 상세 14px)
//   - 구조 섹션(2026-08-08): 리스트(기본) / 부모 기반 — 부모 아래 자식 계층(표시만),
//     선택은 cmMemoGrp, 예전 정렬 트리(cmMemoSort='tree') 선택은 이어받는다
//   - 상세 칸 가독성: 안내문은 읽히는 농도(opacity .8), 선택 배경은 앱 색으로 고정
const fs = require('fs');
const R = (p) => fs.readFileSync(__dirname + '/../' + p, 'utf8');
const PAD = R('Sources/ConditionMate/Dashboard/MemoPad.swift');

let pass = 0, fail = 0;
function eq(name, got, want) {
  if (got === want) { pass++; console.log('PASS ' + name); }
  else { fail++; console.log('FAIL ' + name + '\n       got=' + JSON.stringify(got) + '\n      want=' + JSON.stringify(want)); }
}

// ── 표시만 바꾼다 (CSS data-ui) ────────────────────────────────────────────
eq('집중 모드에서 본문 글자가 한 단계 커진다 (16px)',
  /\.cmmemo\[data-ui="focus"\] \.cmm-doc\{ font-size:16px \}/.test(PAD), true);
eq('문서형(3단계)에서도 한 단계 커진다 (15px 기본 → 17px)',
  /body\.cmmemo-only \.cmmemo\[data-ui="focus"\] \.cmm-doc\{ font-size:17px \}/.test(PAD), true);
eq('상세 글자도 커진다 (14px)',
  /\.cmmemo\[data-ui="focus"\] \.cmm-dt\{ font-size:14px \}/.test(PAD), true);
eq('캐럿·호버 밖의 줄은 회색으로 가라앉는다',
  /\.cmmemo\[data-ui="focus"\] \.cmm-row:not\(:focus-within\):not\(:hover\)\{\s*filter:grayscale\(1\); opacity:\.4 \}/.test(PAD), true);
eq('쓰고 있는 줄만 은은한 앱색 바탕',
  /\.cmmemo\[data-ui="focus"\] \.cmm-row:focus-within\{\s*background:rgba\(91,140,255,\.10\) \}/.test(PAD), true);
eq('쓰고 있는 줄의 상세는 밝게',
  /\.cmmemo\[data-ui="focus"\] \.cmm-row:focus-within \.cmm-dt\{ color:#c3cbd8 \}/.test(PAD), true);
eq('UI 전환은 히스토리에 남지 않는다 (uiSet 이 onEdit 을 부르지 않는다)',
  /function uiSet\(m\)\{[^}]*onEdit/.test(PAD), false);

// ── 기본값 · 저장 ──────────────────────────────────────────────────────────
eq('기본은 현재 모습 (아는 모드 focus 외에는 전부 기본)',
  /v==='focus' \? v : ''/.test(PAD), true);
eq('선택은 cmMemoUI 로 저장된다', /localStorage\.setItem\('cmMemoUI', m\)/.test(PAD), true);
eq('기본 모드에서는 data-ui 를 떼어낸다 (CSS 흔적 없음)',
  /else p\.el\.removeAttribute\('data-ui'\)/.test(PAD), true);
eq('마운트마다 저장된 UI 모드를 다시 칠한다', /sortPaint\(\);\s*uiPaint\(\);/.test(PAD), true);

// ── 헤더 버튼 위치 · 라벨 ──────────────────────────────────────────────────
eq('UI 버튼은 메뉴 묶음 맨 앞 (필터 왼쪽)',
  PAD.indexOf('data-cmmemo-ui ') < PAD.indexOf('data-cmmemo-flt ') &&
  PAD.indexOf('data-cmmemo-meta') < PAD.indexOf('data-cmmemo-ui '), true);
eq('활성 시 버튼 라벨이 모드를 말해 준다 (집중·부모 합성)',
  /p\.ui\.textContent = 'UI'\+\(m\?' 집중':''\)\+\(g\?' 부모':''\)\+' ▾'/.test(PAD), true);

// ── 콤보 (라디오) ─────────────────────────────────────────────────────────
const uis = PAD.match(/var UIS=\[([\s\S]*?)\];/)[1];
eq('옵션 1 = 기본(현재 모습)', /\{s:'',n:'기본',d:'현재 모습'\}/.test(uis), true);
eq('옵션 2 = 집중(공유·발표)', /\{s:'focus',n:'집중',d:'공유·발표'\}/.test(uis), true);
eq('고르면 즉시 적용되고 콤보가 닫힌다 (라디오)',
  /ev\.preventDefault\(\); uiSet\(o\.s\); closeMenu\(\);/.test(PAD), true);
eq('체크 표시는 현재 모드 하나만',
  /x\.b\.setAttribute\('aria-checked', x\.o\.s===m \? 'true' : 'false'\)/.test(PAD), true);
eq('같은 버튼을 다시 누르면 닫는다',
  /var was = menuEl && menuEl\.dataset\.ui==='1';\s*closeMenu\(\);\s*if\(was\) return;/.test(PAD), true);
eq('콤보를 닫으면 UI 버튼의 aria 도 풀린다',
  /if\(p\.ui\) p\.ui\.setAttribute\('aria-expanded','false'\)/.test(PAD), true);

// ── 구조 섹션 (리스트 / 부모 기반) ─────────────────────────────────────────
const grps = PAD.match(/var GRPS=\[([\s\S]*?)\];/)[1];
eq('구조 옵션 1 = 리스트(지금처럼)', /\{s:'',n:'리스트',d:'지금처럼'\}/.test(grps), true);
eq('구조 옵션 2 = 부모 기반(부모 아래 자식)',
  /\{s:'tree',n:'부모 기반',d:'부모 아래 자식'\}/.test(grps), true);
eq('같은 콤보 안의 별도 섹션 (구분선 + 구조 표제)',
  /gtt\.className='cmm-vt'; gtt\.textContent='구조';/.test(PAD), true);
eq('고르면 즉시 적용되고 콤보가 닫힌다 (라디오)',
  /ev\.preventDefault\(\); grpSet\(o\.s\); closeMenu\(\);/.test(PAD), true);
eq('체크 표시는 두 축이 따로 (UI 모드·구조 각각 하나씩)',
  /gopts\.forEach\(function\(x\)\{\s*x\.b\.setAttribute\('aria-checked', x\.o\.s===g \? 'true' : 'false'\); \}\);/.test(PAD), true);
eq('선택은 cmMemoGrp 로 저장된다', /localStorage\.setItem\('cmMemoGrp', m\)/.test(PAD), true);
eq('예전 정렬 트리 선택을 이어받는다 (cmMemoGrp 미설정 + cmMemoSort=tree)',
  /if\(v==null\) return localStorage\.getItem\('cmMemoSort'\)==='tree' \? 'tree' : '';/.test(PAD), true);
eq('리스트(기본)에서는 data-grp 를 떼어낸다 (CSS 흔적 없음)',
  /else p\.el\.removeAttribute\('data-grp'\)/.test(PAD), true);
eq('부모 기반은 treePaint 가 order·들여쓰기를 얹는다 (data-grp 판정)',
  /var list=rows\(pad\), on=pad\.el\.getAttribute\('data-grp'\)==='tree';/.test(PAD), true);
eq('들여쓰기 CSS 는 data-grp 에 걸린다',
  /\.cmmemo\[data-grp="tree"\] \.cmm-row\[data-tdep="1"\]\{ margin-left:24px \}/.test(PAD), true);
eq('구조 전환은 히스토리에 남지 않는다 (grpSet 이 onEdit 을 부르지 않는다)',
  /function grpSet\(m\)\{[\s\S]{0,200}?onEdit/.test(PAD), false);

// ── 상세 칸 가독성 (같은 요청에서 함께 고침) ──────────────────────────────
eq('상세 안내문은 읽히는 농도 (opacity .8, ::before 판)',
  /content:'상세 내용 — Esc 로 접기';\s*color:var\(--mut,var\(--dim,#8a93a3\)\); opacity:\.8 \}/.test(PAD), true);
eq('폼 안 상세(::after 판)도 같은 농도',
  (PAD.match(/상세 내용 — Esc 로 접기';\s*color:var\(--mut,var\(--dim,#8a93a3\)\); opacity:\.8 \}/g) || []).length, 2);
eq('상세 본문 글자색은 회색보다 밝게',
  /\.cmmemo \.cmm-dt\{ display:none; margin:0 0 2px 28px; padding:0;\s*color:#a8b1c0/.test(PAD), true);
eq('선택(하이라이트) 배경은 흰색 기본값 대신 앱 색',
  /\.cmmemo \.cmm-doc ::selection, \.cmmemo \.cmm-doc::selection\{\s*background:rgba\(91,140,255,\.35\) \}/.test(PAD), true);

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
