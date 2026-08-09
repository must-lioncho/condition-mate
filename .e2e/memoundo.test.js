// E2E for 메모장 되돌리기(⌘Z) + 줄 합치기. Bound to REAL source: mounts the SHIPPING
// MemoPad module (MemoPad.swift, via memosrc) in a real Chromium and drives REAL key events.
//
// 왜 실제 브라우저인가: 두 버그 모두 WebKit/Blink 의 contenteditable 기본 동작과 우리 행
// 편집기가 부딪히는 지점에서 났다. 정규식으로 소스를 훑는 검사로는 재현되지 않는다.
//   [1] ⌘Z 가 원상 복귀하지 않는다 — 행을 코드로 조립·삭제해 네이티브 undo 스택이 끊긴다.
//   [2] 줄 맨 앞 Backspace 로 합치면 글자가 제목이 아니라 회색 상세 칸 끝에 들러붙는다.
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
// /api/memo 를 메모리로 — 저장이 화면 동작에 영향을 주지 않도록 조용히 성공시킨다.
window.__saved=[];
const _f=window.fetch;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(o && o.method==='POST'){ window.__saved.push(JSON.parse(o.body).text); return Promise.resolve({json:()=>Promise.resolve({ok:true})}); }
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

  // 캐럿을 n 번째 행 제목의 off 글자째에 놓는다(테스트가 손을 흉내 내는 유일한 지점).
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
  const text = () => page.evaluate(() => CMMemo.text());
  const caretAt = () => page.evaluate(() => {
    const doc = document.querySelector('[data-cmmemo-doc]');
    const s = getSelection();
    let n = s.anchorNode; if (n && n.nodeType === 3) n = n.parentElement;
    let row = n; while (row && !row.classList.contains('cmm-row')) row = row.parentElement;
    return { row: Array.prototype.indexOf.call(doc.children, row), cell: n && n.className, off: s.anchorOffset };
  });

  // ── [2] 줄 합치기 ────────────────────────────────────────────────────────
  // 윗줄에 상세가 달려 있어도 글자는 '제목' 으로 간다. 이것이 회귀의 핵심이다.
  const WITH_DETAIL = '1. 우리의 경쟁력\n    컴퍼니 에이전트\n목표일담당팀프로젝트';
  await set(WITH_DETAIL);
  await caret(1, 0);
  await page.keyboard.press('Backspace');
  eq('윗줄에 상세가 있어도 제목끼리 합쳐진다 (상세 칸에 들러붙지 않는다)',
    await text(), '1. 우리의 경쟁력목표일담당팀프로젝트\n    컴퍼니 에이전트');
  eq('캐럿은 두 글이 만나는 이음매에 남는다 (맨 아래로 튀지 않는다)',
    (await caretAt()).row, 0);

  // 아랫줄이 감추고 있던 상세·상태는 버리지 않고 윗줄로 옮겨 탄다.
  await set('윗줄\n- [x] 아랫줄\n    아랫줄 상세');
  await caret(1, 0);
  await page.keyboard.press('Backspace');
  eq('합칠 때 아랫줄의 상세와 상태가 사라지지 않는다',
    await text(), '- [x] 윗줄아랫줄\n    아랫줄 상세');

  // Delete(앞으로 지우기)도 대칭이다 — 줄 끝에서 누르면 아랫줄이 올라온다.
  await set('가나다\n라마바');
  await caret(0, -1);
  await page.keyboard.press('Delete');
  eq('줄 끝의 Delete 는 아랫줄을 끌어올린다', await text(), '가나다라마바');

  // 빈 체크리스트 줄은 한 번 더 눌러야 지워진다(예전 감각 유지).
  await set('윗줄\n- [ ] ');
  await caret(1, 0);
  await page.keyboard.press('Backspace');
  eq('빈 체크리스트는 먼저 상태만 벗는다', await text(), '윗줄\n');
  await page.keyboard.press('Backspace');
  eq('한 번 더 누르면 그때 합쳐진다', await text(), '윗줄');

  // ── [1] 되돌리기 ─────────────────────────────────────────────────────────
  await set(WITH_DETAIL);
  await caret(1, 0);
  await page.keyboard.press('Backspace');
  await page.keyboard.press('Meta+z');
  eq('⌘Z 가 합치기를 원상 복귀시킨다', await text(), WITH_DETAIL);
  eq('되돌린 뒤 캐럿도 원래 줄로 돌아온다', (await caretAt()).row, 1);
  await page.keyboard.press('Meta+Shift+z');
  eq('⌘⇧Z 로 다시 실행된다', await text(), '1. 우리의 경쟁력목표일담당팀프로젝트\n    컴퍼니 에이전트');

  // 상태 토글도 한 단계다 — 실수로 누른 체크가 ⌘Z 로 풀려야 한다.
  await set('가나다');
  await page.evaluate(() => document.querySelector('.cmm-ck').click());
  eq('체크리스트 승격', await text(), '- [ ] 가나다');
  await caret(0, 0);
  await page.keyboard.press('Meta+z');
  eq('⌘Z 가 상태 토글도 되돌린다', await text(), '가나다');

  // 타이핑은 글자마다가 아니라 덩어리로 되돌아간다(0.55초 안에 이어진 입력은 한 단계).
  await set('');
  await caret(0, 0);
  await page.keyboard.type('가나다라');
  eq('타이핑이 들어갔다', await text(), '가나다라');
  await page.keyboard.press('Meta+z');
  eq('한 번의 ⌘Z 로 이어 친 글이 통째로 되돌아간다', await text(), '');

  // 여러 단계를 거슬러 올라간다.
  await set('처음');
  await caret(0, -1);
  await page.keyboard.press('Enter');
  await page.keyboard.type('둘째');
  await page.waitForTimeout(700);          // 덩어리 경계
  await page.keyboard.press('Enter');
  await page.keyboard.type('셋째');
  eq('세 줄이 됐다', await text(), '처음\n둘째\n셋째');
  await page.keyboard.press('Meta+z');
  await page.keyboard.press('Meta+z');
  eq('두 번 거슬러 올라간다', await text(), '처음\n둘째');

  // 편집 메뉴의 '실행 취소'(beforeinput historyUndo)도 같은 히스토리를 쓴다.
  await set('메뉴 경로');
  await caret(0, -1);
  await page.keyboard.type('!');
  await page.evaluate(() => document.querySelector('[data-cmmemo-doc]')
    .dispatchEvent(new InputEvent('beforeinput', { inputType: 'historyUndo', bubbles: true, cancelable: true })));
  eq('편집 메뉴의 실행 취소도 우리 히스토리로 간다', await text(), '메뉴 경로');

  // 브라우저의 네이티브 undo 가 새어 나가 행 구조를 부수지 않는다.
  eq('되돌린 뒤에도 행 구조가 온전하다',
    await page.evaluate(() => {
      const doc = document.querySelector('[data-cmmemo-doc]');
      return Array.prototype.every.call(doc.children,
        (n) => n.classList.contains('cmm-row') && n.querySelector('.cmm-tx') && n.querySelector('.cmm-dt'));
    }), true);

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
