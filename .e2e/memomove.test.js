// E2E for 메모장 우클릭 '위로/아래로 이동' (우선순위 정렬). Bound to REAL source:
// mounts the SHIPPING MemoPad module (MemoPad.swift, via memosrc) in a real Chromium
// and drives a REAL contextmenu — the rule under test is "같은 상태값 안에서만 이동":
// 완료는 완료끼리, 바틀넥은 바틀넥끼리 오르내린다. 사이에 다른 상태가 끼어 있으면
// 건너뛰어 같은 상태의 가장 가까운 행 곁으로 간다(정렬 화면의 시각적 이웃과 일치).
// 그 방향에 같은 상태가 더 없으면 막힌다.
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
// /api/memo 를 메모리로 — 저장이 화면 동작에 영향을 주지 않도록 조용히 성공시킨다.
const _f=window.fetch;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(o && o.method==='POST') return Promise.resolve({json:()=>Promise.resolve({ok:true})});
    return Promise.resolve({json:()=>Promise.resolve({text:''})});
  }
  return _f.apply(this,arguments);
};
</script></body>`;

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const eq = (n, got, want) => check(n, JSON.stringify(got) === JSON.stringify(want),
  JSON.stringify(got) === JSON.stringify(want) ? '' : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(html);
  await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
  // 기본 보기는 완료를 숨긴다 — 이 테스트는 순서가 주제이므로 전 상태를 펼쳐 놓고 본다.
  await page.evaluate(() => {
    document.querySelectorAll('[data-cmmemo]').forEach((el) => el.setAttribute('data-hide', ''));
  });

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  // 생성 스탬프(2026-08-10, '    @생성: …')는 줄마다 붙는 메타다. 이 파일이 보는 것은
  // 글의 '모양' 이라 스탬프는 걷어 내고 읽는다 — 스탬프 계약은 memocreated.test.js 가 지킨다.
  const noCr = (s) => String(s).split('\n').filter((l) => !/^\s+@생성:/.test(l)).join('\n');
  const text = () => page.evaluate(() => CMMemo.text()).then(noCr);
  // 남아 있는 메뉴를 닫는다 — 막힌 항목을 누른 뒤에는 메뉴가 열린 채라, 다음
  // 우클릭 좌표를 덮어 클릭이 메뉴를 때리는 사고를 막는다.
  const closeAll = () => page.evaluate(() =>
    document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })));
  // i 번째 행 제목에 진짜 우클릭 — 앱과 같은 길(contextmenu 리스너)로 메뉴를 연다.
  const rclick = async (i) => {
    await closeAll();
    await page.click(`[data-cmmemo-doc] .cmm-row:nth-child(${i + 1}) .cmm-tx`, { button: 'right' });
  };
  // 열린 메뉴의 항목들 [{t:라벨, d:disabled}] — 없으면 [].
  const menu = () => page.evaluate(() =>
    Array.prototype.map.call(document.querySelectorAll('.cmmemo-menu button'),
      (b) => ({ t: b.textContent, d: !!b.disabled })));
  // 라벨로 항목을 눌러 실행한다(메뉴 항목은 mousedown 에 산다).
  const pick = (label) => page.evaluate((label) => {
    const b = Array.prototype.find.call(document.querySelectorAll('.cmmemo-menu button'),
      (x) => x.textContent === label);
    if (b) b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    return !!b;
  }, label);

  const MIX = '- [ ] a\n- [ ] b\n- [x] c\n- [x] d\n- [!] e';

  // ── 같은 상태 안에서의 이동 ──────────────────────────────────────────────
  await set(MIX);
  await rclick(1);                                     // b (미완료)
  let m = await menu();
  eq('우클릭 메뉴에 이동 항목이 뜬다', m.slice(0, 2).map(x => x.t), ['위로 이동', '아래로 이동']);
  eq('위 이웃(a)이 같은 상태 — 위로 이동 가능', m[0].d, false);
  await pick('위로 이동');
  eq('미완료끼리 자리가 바뀐다', await text(), '- [ ] b\n- [ ] a\n- [x] c\n- [x] d\n- [!] e');

  await rclick(2);                                     // c (완료)
  await pick('아래로 이동');
  eq('완료끼리도 내려간다', await text(), '- [ ] b\n- [ ] a\n- [x] d\n- [x] c\n- [!] e');

  // ── 같은 상태가 더 없는 방향은 막힌다 ────────────────────────────────────
  await set(MIX);
  await rclick(2);                                     // c (완료) — 위에는 완료가 없다
  m = await menu();
  eq('그 방향에 같은 상태가 없으면 막힌다 (항목은 흐려진 채 남는다)', m[0].d, true);
  eq('아래 이웃(d)은 같은 완료 — 열려 있다', m[1].d, false);
  await pick('위로 이동');                              // 눌러도 아무 일 없어야 한다
  eq('막힌 방향은 눌러도 순서가 그대로다', await text(), MIX);

  await rclick(4);                                     // e (바틀넥) — 유일한 바틀넥
  m = await menu();
  eq('같은 상태 이웃이 없으면 양쪽 다 막힌다', [m[0].d, m[1].d], [true, true]);

  // 맨 위·맨 아래 끝에서도 막힌다.
  await rclick(0);                                     // a — 맨 위
  m = await menu();
  eq('맨 위 행은 위로 이동이 막힌다', m[0].d, true);

  // ── 사이에 다른 상태가 끼면 건너뛴다 ─────────────────────────────────────
  // 정렬(미완료↑ 완료↓)을 켠 화면에서는 같은 상태끼리 붙어 보인다 — 그 화면의
  // '한 칸 이동' 이 텍스트에서는 다른 상태를 건너뛴 자리로 내려앉는다.
  await set('- [x] c\n- [ ] a\n- [x] d');
  await rclick(0);                                     // c (완료) — 아래 완료는 a 건너 d
  m = await menu();
  eq('끼어 있는 미완료를 건너 같은 상태를 찾는다', m[1].d, false);
  await pick('아래로 이동');
  eq('완료는 미완료를 건너뛰어 다음 완료 뒤로 간다', await text(), '- [ ] a\n- [x] d\n- [x] c');

  await set('- [x] c\n- [ ] a\n- [x] d');
  await rclick(2);                                     // d (완료) — 위 완료는 a 건너 c
  await pick('위로 이동');
  eq('위로도 건너뛰어 같은 상태 바로 앞에 선다', await text(), '- [x] d\n- [x] c\n- [ ] a');

  // ── 평문 줄도 평문끼리 ──────────────────────────────────────────────────
  await set('평문 하나\n평문 둘\n- [ ] a');
  await rclick(1);                                     // 평문 둘
  m = await menu();
  eq('평문 줄은 평문 이웃과만 움직인다', [m[0].d, m[1].d], [false, true]);
  await pick('위로 이동');
  eq('평문끼리 자리가 바뀐다', await text(), '평문 둘\n평문 하나\n- [ ] a');

  // ── 이동도 되돌리기 한 단계 ──────────────────────────────────────────────
  await set(MIX);
  await rclick(3);                                     // d (완료)
  await pick('위로 이동');
  eq('이동이 반영됐다', await text(), '- [ ] a\n- [ ] b\n- [x] d\n- [x] c\n- [!] e');
  await page.click('[data-cmmemo-doc]');
  await page.keyboard.press('Meta+z');
  eq('⌘Z 한 번으로 이동이 원상 복귀된다', await text(), MIX);

  // ── 이동은 상세·필드를 함께 데려간다 ─────────────────────────────────────
  await set('- [ ] a\n    a 상세\n- [ ] b');
  await rclick(1);                                     // b
  await pick('위로 이동');
  eq('상세 달린 행 위로 올라가도 상세는 제 행에 붙어 있다',
    await text(), '- [ ] b\n- [ ] a\n    a 상세');

  // ── 행 밖(빈 자리) 우클릭은 예전 그대로 복사 메뉴만 ──────────────────────
  await set('- [ ] a');
  await page.evaluate(() => {
    const doc = document.querySelector('[data-cmmemo-doc]');
    doc.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 8, clientY: 8 }));
  });
  m = await menu();
  eq('행이 아닌 곳의 메뉴에는 이동 항목이 없다', m[0].t.indexOf('복사') === 0, true);

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
