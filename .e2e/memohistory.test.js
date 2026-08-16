// E2E for 메모장 저장 신뢰 — "장문을 썼는데 ⌘Z 하다가 다 사라졌다" 사고(2026-08-06)의 회귀.
// Bound to REAL source: mounts the SHIPPING MemoPad module (MemoPad.swift, via memosrc) in a
// real Chromium and drives REAL key events. 세 가지를 지킨다:
//   [1] 덩어리 3초 상한 — 쉼 없이 이어 친 장문이 ⌘Z 한 번에 통째로 사라지지 않는다.
//   [2] 다시 실행 보존 — ⌘Z 직후 백그라운드 병합(포커스 새로고침)이 끼어들어도 ⌘⇧Z 가 산다.
//   [3] 히스토리 메뉴 — 서버 저널의 지난 판을 열어 보고 복원/합치기로 되살린다(복원도 ⌘Z 한 단계).
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
// 판번호 게이트까지 흉내 낸 in-memory /api/memo — 다른 화면의 저장(rev 증가)을 테스트가
// window.__srv 로 직접 일으킬 수 있다. /api/memo/history 는 window.__hist 를 그대로 준다.
window.__srv={text:'', rev:1};
window.__hist={items:[]};
const _f=window.fetch;
window.fetch=function(u,o){
  u=String(u);
  const json=(x)=>Promise.resolve({json:()=>Promise.resolve(x)});
  if(u.indexOf('/api/memo/history')>=0) return json(window.__hist);
  if(u.indexOf('/api/memo/seq')>=0) return json({ok:true,seqs:[]});
  if(u.indexOf('/api/memo/tags')>=0) return json({tags:[],canCreate:false});
  if(u.indexOf('/api/memo')>=0){
    if(o && o.method==='POST'){
      const b=JSON.parse(o.body);
      if(typeof b.base==='number' && b.base!==__srv.rev)
        return json({ok:true,conflict:true,text:__srv.text,rev:__srv.rev,updatedAt:1});
      if(b.text!==__srv.text) __srv={text:b.text, rev:__srv.rev+1};
      return json({ok:true,rev:__srv.rev,updatedAt:1,chars:__srv.text.length});
    }
    return json({text:__srv.text,rev:__srv.rev,updatedAt:1,chars:__srv.text.length});
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
  await page.waitForTimeout(150);            // load() 의 첫 GET 이 돌아올 시간

  const caret = (i, off) => page.evaluate(([i, off]) => {
    const doc = document.querySelector('[data-cmmemo-doc]');
    const tx = doc.children[i].querySelector('.cmm-tx');
    const r = document.createRange();
    const t = tx.firstChild;
    if (t && t.nodeType === 3) r.setStart(t, Math.min(off < 0 ? t.nodeValue.length : off, t.nodeValue.length));
    else { r.selectNodeContents(tx); r.collapse(true); }
    r.collapse(true);
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    doc.focus();
  }, [i, off]);
  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  // 생성 스탬프(2026-08-10, '    @생성: …')는 줄마다 붙는 메타다. 이 파일이 보는 것은
  // 글의 '모양' 이라 스탬프는 걷어 내고 읽는다 — 스탬프 계약은 memocreated.test.js 가 지킨다.
  const noCr = (s) => String(s).split('\n').filter((l) => !/^\s+@생성:/.test(l)).join('\n');
  const text = () => page.evaluate(() => CMMemo.text()).then(noCr);

  // ── [1] 덩어리 3초 상한 ──────────────────────────────────────────────────
  // 70자를 쉼 없이(60ms 간격 ≈ 4.2초) 이어 친다 — 상한이 없으면 전부 한 덩어리가 되어
  // ⌘Z 한 번에 빈 메모로 돌아간다(그 사고). 상한이 있으면 마지막 덩어리만 벗겨진다.
  const LONG = 'm'.repeat(70);
  await set('');
  await caret(0, 0);
  await page.keyboard.type(LONG, { delay: 60 });
  eq('장문이 다 들어갔다', await text(), LONG);
  await page.keyboard.press('Meta+z');
  const after = await text();
  check('⌘Z 한 번에 장문 전체가 사라지지 않는다 (마지막 덩어리만)',
    after.length > 0 && after.length < LONG.length, `남은 길이=${after.length}/${LONG.length}`);
  check('되돌린 결과는 친 글의 앞부분 그대로다', LONG.indexOf(after) === 0);

  // 짧게 이어 친 글은 예전 그대로 한 덩어리다(0.55초 묶음 감각 유지 — memoundo 와 동일).
  await set('');
  await caret(0, 0);
  await page.keyboard.type('가나다라');
  await page.keyboard.press('Meta+z');
  eq('짧은 타이핑은 여전히 한 번의 ⌘Z 로 통째로 되돌아간다', await text(), '');

  // ── [2] ⌘Z 직후의 백그라운드 병합이 '다시 실행' 을 끊지 않는다 ─────────────
  // 사고의 실제 경로: ⌘Z 로 돌아간 순간 저장이 나가고, 포커스 새로고침(다른 화면의 새 판
  // 병합)이 프로그램적으로 히스토리에 기록되며 redo 갈래를 지워 — 글을 되찾을 길이 없었다.
  await set('처음 줄');
  await page.waitForTimeout(600);            // 저장 확정(dirty=false)
  await caret(0, -1);
  await page.keyboard.type(' 이어 쓴 장문입니다');
  await page.waitForTimeout(600);
  await page.keyboard.press('Meta+z');       // 타이핑 덩어리가 벗겨진다
  eq('⌘Z 로 이어 쓴 글이 빠졌다', await text(), '처음 줄');
  await page.waitForTimeout(600);            // 되돌린 판이 저장 확정될 시간
  // 다른 화면이 그 사이 새 판을 저장했다 → 포커스 새로고침이 병합(adopt)을 일으킨다.
  await page.evaluate(() => { window.__srv = { text: '처음 줄\n다른 화면의 줄', rev: window.__srv.rev + 1 }; });
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await page.waitForTimeout(300);
  eq('다른 화면의 줄이 병합돼 들어왔다', await text(), '처음 줄\n다른 화면의 줄');
  await page.keyboard.press('Meta+Shift+z');
  check('병합이 끼어들어도 ⌘⇧Z 가 지운 글을 되찾는다',
    (await text()).indexOf('이어 쓴 장문입니다') >= 0, `text=${JSON.stringify(await text())}`);

  // ── [3] 히스토리 메뉴 ────────────────────────────────────────────────────
  const OLD1 = '어제 쓴 장문 초안\n    상세까지 있던 판';
  const OLD2 = '오늘 아침의 판';
  await page.evaluate(([a, b]) => {
    window.__hist = { items: [
      { t: Math.floor(Date.now() / 1000) - 120, rev: 8, kind: 'replaced', chars: b.length, text: b },
      { t: Math.floor(Date.now() / 1000) - 86400 * 2, rev: 3, kind: 'replaced', chars: a.length, text: a },
    ] };
  }, [OLD1, OLD2]);
  await set('지금 판');
  await page.waitForTimeout(600);

  const openHist = async () => {
    await page.dispatchEvent('[data-cmmemo-hist]', 'mousedown');
    await page.waitForFunction(() => {
      const m = document.querySelector('.cmmemo-menu.cmm-hm');
      return m && m.querySelectorAll('.cmm-ho').length > 0;
    });
  };
  await openHist();
  eq('히스토리 메뉴에 지난 판이 최신순으로 뜬다',
    await page.evaluate(() => Array.from(document.querySelectorAll('.cmm-ho b')).map((n) => n.textContent)),
    ['오늘 아침의 판', '어제 쓴 장문 초안']);

  // 판을 고르면 전문 미리보기가 펼쳐진다.
  await page.dispatchEvent('.cmm-ho:nth-of-type(2)', 'mousedown');
  eq('고른 판의 전문이 미리보기로 보인다',
    await page.evaluate(() => document.querySelector('.cmm-hp pre').textContent), OLD1);

  // '이 판으로 복원' — 통째 교체, 그리고 복원 자체가 ⌘Z 한 단계다.
  await page.evaluate(() => {
    const btns = Array.from(document.querySelectorAll('.cmm-ha button'));
    btns.find((b) => b.textContent === '이 판으로 복원')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
  });
  eq('지난 판이 통째로 복원된다', await text(), OLD1);
  check('메뉴는 복원 후 닫힌다', await page.evaluate(() => !document.querySelector('.cmmemo-menu')));
  await caret(0, 0);
  await page.keyboard.press('Meta+z');
  eq('잘못 복원했으면 ⌘Z 한 번으로 돌아온다', await text(), '지금 판');

  // '현재 글과 합치기' — 합집합 병합: 현재 글을 한 줄도 버리지 않는다.
  await page.waitForTimeout(600);
  await openHist();
  await page.dispatchEvent('.cmm-ho:nth-of-type(1)', 'mousedown');
  await page.evaluate(() => {
    const btns = Array.from(document.querySelectorAll('.cmm-ha button'));
    btns.find((b) => b.textContent === '현재 글과 합치기')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
  });
  eq('합치기는 현재 글 아래에 지난 판의 줄을 덧붙인다', await text(), '지금 판\n오늘 아침의 판');

  // 히스토리가 비어 있으면 조용한 안내만 — 실패 배너 금지(앱 규칙).
  await page.evaluate(() => { window.__hist = { items: [] }; });
  await page.dispatchEvent('[data-cmmemo-hist]', 'mousedown');   // 닫고
  await page.dispatchEvent('[data-cmmemo-hist]', 'mousedown');   // 다시 연다
  await page.waitForTimeout(100);
  check('빈 히스토리는 안내 문구만 보여 준다',
    (await page.evaluate(() => document.querySelector('.cmmemo-menu.cmm-hm .cmm-hl').textContent))
      .indexOf('아직 없습니다') >= 0);

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
