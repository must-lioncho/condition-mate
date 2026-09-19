// E2E for 레일 ⊞ 3단계 — 1 메모장만(문서형) / 2 메모+AI 컴포저 / 3 작업+대화 분할,
// 그리고 메모장이 없는 페이지에만 남는 0 레일 접힘.
// REAL source(Sources/ConditionMate/Dashboard/SessionRail.swift)에 묶는다.
//
// ── 이 파일이 통째로 다시 쓰인 이유 (뿌리 A, 2026-08-09 커밋 ac14716) ──────────────
// 2026-07-21 판은 레일의 '메모장' 단축키를 지켰다: cmNav('memo') 가 sessionStorage 에
// cmGaFocus 한 방 힌트를 넣고 /goal-add 로 가고, 이미 /goal-add 면 그 자리에서 레일을
// 접는다. 그 기구는 ac14716 에서 통째로 걷혔다 — 지금 소스에 cmNav('memo') 도 cmGaFocus 도
// 없고, data-nav 목록에 memo 가 없다. 같은 자리(레일을 접고 메모만 크게)를 레일 ⊞ 3단계의
// 1단계가 대신한다. 시험이 20일 동안 그 교체를 따라오지 않아 7건이 붉은 채였고, 그동안
// 후속 기구인 3단계 자체를 지키는 시험은 하나도 없었다. 그래서 지우지 않고 다시 쓴다.
//
// 옛 판의 '통과' 2건("collapse pref 를 쓰지 않는다", "이동하지 않는다")은 아무 일도
// 일어나지 않아서 참이 된 공허한 통과였다. 여기서는 없는 것을 확인하지 않는다 —
// 전부 실제로 단계를 굴려서 나온 body 클래스·저장값·툴팁·네이티브 신호를 본다.
//
// 여기서 지키는 계약:
//   - ⊞ 와 3점 표시기는 레일 안과 접힘용 떠 있는 자리, 두 곳에 같이 있다
//   - 페이지가 가진 것(메모장·보드)이 단계 목록을 정한다: [1,2,3] / [1,2] / [3,0]
//   - 저장된 단계가 이 페이지에 없으면 '전부 보이는' 쪽으로 떨어진다 (빈 화면 방지)
//   - 단계마다 body 클래스 조합이 정해져 있고, 1단계가 곧 옛 '메모장'(레일 접힘+메모만)
//   - ⊞ 는 앞으로 순환, ⌥+⊞ 는 역방향, Esc 는 1단계에서 3단계로, ⌃⌘N 은 ⊞ 와 같다
//   - 선택은 localStorage(cmStage)에 남고, persist=false 와 좁은 창 강제는 저장값을 안 건드린다
//   - 부팅은 새 키 → 구 키 이관 → ?stage= 순으로 단계를 정한다
//   - 1단계 출입은 네이티브에 창 크기 신호(memo / memoExit:N)를 보낸다
const fs = require('fs');
const vm = require('vm');
const SR = fs.readFileSync(__dirname + '/../Sources/ConditionMate/Dashboard/SessionRail.swift', 'utf8');

let pass = 0, fail = 0;
function eq(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? 'PASS ' : 'FAIL ') + name);
  if (!ok) { console.log('       got =' + JSON.stringify(got) + '\n       want=' + JSON.stringify(want)); fail++; }
  else pass++;
}

// ---- 0) 소스에서 3단계 상태 머신만 잘라 온다 --------------------------------
// CMRAIL_TIPS(단계 이름표)부터 부팅 배선까지가 한 덩어리다. 소스 문자열을 정규식으로
// 통째 고정하지 않고 실제로 굴리기 위해 잘라서 vm 에 올린다.
const START = 'var CMRAIL_TIPS={';
const END = "if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', cmRailStageBoot); else cmRailStageBoot();";
const s0 = SR.indexOf(START), s1 = SR.indexOf(END);
if (s0 < 0 || s1 < 0) { console.log('FAIL 3단계 상태 머신을 소스에서 못 찾았다'); process.exit(1); }
const STAGE_JS = SR.slice(s0, s1 + END.length);

function classList(set) {
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    contains: (c) => set.has(c),
    toggle: (c, on) => { const v = (on === undefined) ? !set.has(c) : !!on; if (v) set.add(c); else set.delete(c); return v; },
  };
}
// 단계가 칠하는 body 클래스만 정해진 순서로 뽑는다 (Set 순서에 흔들리지 않게).
const LAYOUT = ['cmrail-collapsed', 'cmmemo-only', 'cmboard-off', 'cmchat-full', 'cmchat-side'];

// 레일 한 벌을 실제로 띄운다. memo/board = 그 페이지가 가진 것, store = localStorage 초기값.
function rail(opt) {
  opt = opt || {};
  const bodyCls = new Set(opt.zen ? ['cm-zen'] : []);
  const store = Object.assign({}, opt.store);
  const msgs = [];
  const keydown = [];
  const mkEl = () => ({ title: '', classList: classList(new Set()) });
  const tgs = [mkEl(), mkEl()];
  const dotSets = [new Set(), new Set(), new Set()];
  const dotBox = { classList: classList(new Set()), children: dotSets.map((s) => ({ classList: classList(s) })) };
  const sandbox = {
    console, URLSearchParams, setTimeout, clearTimeout,
    location: { search: opt.search || '', pathname: '/' },
    localStorage: {
      getItem: (k) => (k in store ? store[k] : null),
      setItem: (k, v) => { store[k] = String(v); },
      removeItem: (k) => { delete store[k]; },
    },
    matchMedia: () => ({ matches: !!opt.narrow, addEventListener: () => {}, addListener: () => {} }),
    addEventListener: () => {},
    webkit: { messageHandlers: { cmzen: { postMessage: (m) => msgs.push(m) } } },
    document: {
      readyState: 'complete',
      body: { classList: classList(bodyCls) },
      addEventListener: (t, fn) => { if (t === 'keydown') keydown.push(fn); },
      querySelector: (s) => (s === '[data-cmmemo]' ? (opt.memo ? {} : null)
                           : s === '[data-cmboard]' ? (opt.board ? {} : null) : null),
      querySelectorAll: (s) => (s === '[data-cmrail-tg]' ? tgs
                              : s === '[data-cmrail-dots]' ? [dotBox] : []),
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext('var window=this;', ctx);
  vm.runInContext(STAGE_JS, ctx);
  return {
    ctx, store, msgs,
    stage: () => ctx.cmRailStageNow,
    layout: () => LAYOUT.filter((c) => bodyCls.has(c)),
    tip: () => tgs[0].title,
    tips: () => tgs.map((t) => t.title),
    dotsOn: () => dotBox.classList.contains('on'),
    dotAt: () => dotSets.map((s) => s.has('at')),
    stages: () => ctx.cmRailStages(),
    fit: (n) => ctx.cmRailFit(n),
    set: (n, p) => ctx.cmRailStage(n, p),
    toggle: (ev) => ctx.cmRailToggle(ev),
    // 키는 등록된 핸들러 전부에 흘려 보낸다 — 실제 document 처럼.
    key: (ev) => { let n = 0; const e = Object.assign({ preventDefault: () => { n++; } }, ev);
                   keydown.forEach((fn) => fn(e)); return n; },
  };
}

// ---- 1) 마크업: ⊞ 와 3점 표시기 --------------------------------------------
const tgBtns = SR.match(/<button class="cmrail-sbtoggle" data-cmrail-tg[^>]*>/g) || [];
eq('⊞ 는 두 자리에 있다 (레일 안 · 접힘용 떠 있는 자리)', tgBtns.length, 2);
eq('두 자리 모두 같은 단계 순환을 부른다',
   tgBtns.every((t) => /onclick="cmRailToggle\(event\)"/.test(t)), true);
const dotSpans = SR.match(/<span class="cmrail-dots" data-cmrail-dots>[\s\S]*?<\/span>/g) || [];
eq('3점 표시기도 두 자리에 (세 번째 단계가 있다는 유일한 눈 신호)', dotSpans.length, 2);
eq('점은 단계 수만큼 셋', dotSpans.map((d) => (d.match(/<i>/g) || []).length), [3, 3]);
eq('1단계 CSS: main 안에서 메모 패드만 남는다',
   /body\.cmmemo-only\s+main\s*>\s*\*:not\(\.cmmemo\)\{\s*display:none/.test(SR), true);
eq('접힘일 때만 떠 있는 ⊞ 가 나타난다',
   /body\.cmrail-collapsed\s+\.cmrail-toggle\{\s*display:inline-flex\s*\}/.test(SR), true);

// ---- 2) 페이지가 가진 것이 단계 목록을 정한다 --------------------------------
// 대시보드(메모장+보드)만 3단계 전부를 갖는다. 메모장만 있는 페이지는 3단계(분할)가 없고,
// 메모장이 아예 없는 페이지는 1·2 로 들어가면 빈 화면이 되므로 예전처럼 보임↔접힘뿐이다.
eq('대시보드(메모+보드)는 1·2·3 전부', rail({ memo: true, board: true }).stages(), [1, 2, 3]);
eq('메모장만 있는 페이지는 1·2', rail({ memo: true }).stages(), [1, 2]);
eq('메모장이 없는 페이지는 보임(3)↔접힘(0) 둘뿐', rail({}).stages(), [3, 0]);
eq('없는 단계를 고르면 그 페이지의 마지막 단계로 떨어진다 (빈 화면 방지)',
   rail({ memo: true }).fit(3), 2);
eq('메모장이 없는 페이지에서 1단계를 고르면 3단계로 떨어진다', rail({}).fit(1), 3);

// ---- 3) 단계마다 정해진 body 클래스 -----------------------------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '3' } });
  r.set(1);
  eq('1단계 = 옛 메모장: 레일 접힘 + 메모만 + 보드 걷힘', r.layout(), ['cmrail-collapsed', 'cmmemo-only', 'cmboard-off']);
  r.set(2);
  eq('2단계 = 레일 + 메모 + 대화 전체폭 (보드는 아직 걷힌 채)', r.layout(), ['cmboard-off', 'cmchat-full']);
  r.set(3);
  eq('3단계 = 보드 + 오른쪽 대화 분할 (감추는 것이 없다)', r.layout(), ['cmchat-side']);
  eq('3단계에서는 레일이 펴져 있다', r.layout().includes('cmrail-collapsed'), false);
}
{
  const r = rail({ store: { cmStage: '0' } });   // 메모장이 없는 페이지
  eq('0단계는 레일만 접는다 (본문은 그대로)', r.layout(), ['cmrail-collapsed']);
}

// ---- 4) 표시기와 툴팁은 '다음에 누르면 뭐가 되는지' 를 말한다 ----------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  eq('1단계에서 툴팁은 다음 단계(2) 를 말한다', r.tip(), '메모 + AI 컴포저 · ⌃⌘N');
  eq('두 자리의 ⊞ 가 같은 말을 한다', r.tips()[0] === r.tips()[1], true);
  eq('첫 점에 불이 들어온다', r.dotAt(), [true, false, false]);
  eq('3단계 페이지에서는 점이 보인다', r.dotsOn(), true);
  r.set(3);
  eq('3단계에서는 툴팁이 한 바퀴 돌아 1단계를 말한다', r.tip(), '메모장만 보기 (Esc로 복귀) · ⌃⌘N');
  eq('셋째 점으로 불이 옮겨 간다', r.dotAt(), [false, false, true]);
  const r2 = rail({ memo: true, store: { cmStage: '1' } });
  eq('단계가 둘뿐인 페이지에서는 점을 감춘다', r2.dotsOn(), false);
}

// ---- 5) ⊞ 순환 · ⌥ 역방향 ---------------------------------------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  const seen = [r.stage()];
  r.toggle(); seen.push(r.stage());
  r.toggle(); seen.push(r.stage());
  r.toggle(); seen.push(r.stage());
  eq('⊞ 를 계속 누르면 1→2→3→1 로 돈다', seen, [1, 2, 3, 1]);
  r.toggle({ altKey: true });
  eq('⌥+⊞ 는 역방향', r.stage(), 3);
  const r2 = rail({ store: { cmStage: '3' } });
  r2.toggle();
  eq('메모장 없는 페이지의 ⊞ 는 접힘(0) 으로', r2.stage(), 0);
  r2.toggle();
  eq('한 번 더 누르면 다시 보임(3)', r2.stage(), 3);
}

// ---- 6) 선택은 남는다 (그리고 남기지 말라면 안 남는다) ----------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  r.set(2);
  eq('고른 단계는 cmStage 에 남는다', r.store.cmStage, '2');
  r.set(3, false);
  eq('persist=false 도 화면은 3단계로 간다', r.stage(), 3);
  eq('그런데 저장값은 방금 고른 2 그대로다', r.store.cmStage, '2');
}

// ---- 7) Esc — 1단계에서 한 번에 작업 화면으로 --------------------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  const stopped = r.key({ key: 'Escape' });
  eq('1단계에서 Esc 는 3단계로 빠져나온다', r.stage(), 3);
  eq('Esc 를 삼킨다 (메모 textarea 안에서도 이 길로 온다)', stopped, 1);
  r.set(2);
  r.key({ key: 'Escape' });
  eq('1단계가 아닐 때 Esc 는 단계를 건드리지 않는다', r.stage(), 2);
}

// ---- 8) ⌃⌘N — ⊞ 와 같은 순환 (마우스를 쓰지 않는 길) -----------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  r.key({ metaKey: true, ctrlKey: true, code: 'KeyN', key: 'n' });
  eq('⌃⌘N 은 다음 단계로', r.stage(), 2);
  // 한글 입력원에서는 e.key 가 'ㅜ' 로 온다 — 물리 키로도 받는다.
  r.key({ metaKey: true, ctrlKey: true, code: '', key: 'ㅜ' });
  eq('한글 입력원(ㅜ)에서도 같은 순환', r.stage(), 3);
}

// ---- 9) 부팅이 단계를 정하는 순서 --------------------------------------------
eq('저장된 단계로 연다', rail({ memo: true, board: true, store: { cmStage: '2' } }).stage(), 2);
eq('처음 여는 사람은 메모장만(1)', rail({ memo: true, board: true }).stage(), 1);
{
  const r = rail({ memo: true, board: true, store: { cmRailStage: '2' } });
  eq('옛 키의 메모장만(2)은 새 1단계로 이관된다', r.stage(), 1);
  eq('이관 결과는 새 키에 적힌다', r.store.cmStage, '1');
  eq('옛 키의 나머지 값은 작업 화면(3)으로', rail({ memo: true, board: true, store: { cmRailStage: '0' } }).stage(), 3);
}
eq('?stage= 는 저장값을 이긴다 (다른 페이지가 목적지 단계를 지정한다)',
   rail({ memo: true, board: true, store: { cmStage: '1' }, search: '?stage=3' }).stage(), 3);
eq('zen(레일 폭 창)에서는 단계가 의미 없다 — 늘 3', rail({ memo: true, board: true, zen: true, store: { cmStage: '1' } }).stage(), 3);

// ---- 10) 좁은 창(포스트잇)이 강제한 메모장은 '일시' 다 -----------------------
{
  const r = rail({ memo: true, board: true, narrow: true, store: { cmStage: '3' } });
  eq('창이 360px 이하면 메모장만 남는다', r.stage(), 1);
  eq('그래도 저장값은 원래 단계 그대로 (넓히면 돌아온다)', r.store.cmStage, '3');
  const r2 = rail({ narrow: true, store: { cmStage: '3' } });
  eq('메모장이 없는 페이지는 좁아져도 강제하지 않는다', r2.stage(), 3);
}

// ---- 11) 네이티브 창 크기 신호 ------------------------------------------------
{
  const r = rail({ memo: true, board: true, store: { cmStage: '1' } });
  eq('첫 페인트는 창을 건드리지 않는다 (부팅이 창을 흔들지 않게)', r.msgs, []);
  r.set(2);
  eq('1단계에서 나갈 때는 가려는 단계를 같이 보낸다', r.msgs, ['memoExit:2']);
  r.set(1);
  eq('1단계로 들어갈 때는 포스트잇 크기로', r.msgs, ['memoExit:2', 'memo']);
  const r2 = rail({ memo: true, board: true, narrow: true, store: { cmStage: '3' } });
  eq('좁은 창이 강제한 메모장은 창 크기를 건드리지 않는다 (이미 유저가 줄여 둔 창이다)', r2.msgs, []);
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
