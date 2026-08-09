// E2E for 메모장 줄 합치기(Backspace/Delete)의 필드 보존. Bound to REAL source:
// mounts the SHIPPING MemoPad module (MemoPad.swift, via memosrc) in a real Chromium
// and drives REAL keystrokes. 규칙: 아랫줄의 필드는 윗줄의 빈 칸으로 옮겨 타고(시각
// 칸도 증발 없이), 같은 칸을 서로 다른 값으로 채운 채 합치면 — 그 값은 옮겨 탈 자리가
// 없으므로 — confirm 팝업으로 묻는다. 취소하면 합치기 자체가 일어나지 않는다.
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

  // confirm 팝업은 노드 쪽에서 받아 적는다 — 케이스마다 수락/취소를 갈아 끼운다.
  const dlg = { mode: 'dismiss', msgs: [] };
  page.on('dialog', (d) => { dlg.msgs.push(d.message()); (dlg.mode === 'accept' ? d.accept() : d.dismiss()); });

  await page.setContent(html);
  await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  const text = () => page.evaluate(() => CMMemo.text());
  // i 번째 행 제목의 맨 앞/맨 뒤에 캐럿 — 앱과 같은 길(선택 영역)로 놓고 실제 키를 친다.
  const caret = (i, atEnd) => page.evaluate(({ i, atEnd }) => {
    const tx = document.querySelectorAll('[data-cmmemo-doc] .cmm-row')[i].querySelector('.cmm-tx');
    document.querySelector('[data-cmmemo-doc]').focus();
    const r = document.createRange();
    r.selectNodeContents(tx); r.collapse(!atEnd);
    const s = getSelection(); s.removeAllRanges(); s.addRange(r);
  }, { i, atEnd });

  // ── 아랫줄 필드는 윗줄의 빈 칸으로 옮겨 탄다 — 시각(목표일) 칸도 증발 없이 ────────
  await set('윗줄\n아랫줄\n    @목표일: 2026-08-07T09:00Z\n    @담당: ismail');
  await caret(1, false);
  await page.keyboard.press('Backspace');
  eq('빈 칸으로는 안 묻고 옮겨 탄다 (팝업 없음)', dlg.msgs.length, 0);
  eq('목표일·담당이 합쳐진 줄에 그대로 남는다', await text(),
    '윗줄아랫줄\n    @목표일: 2026-08-07T09:00Z\n    @담당: ismail');

  // 서로 다른 칸끼리도 잃는 것이 없다 — 조용히 둘 다 남는다.
  await set('윗줄\n    @팀: infra\n아랫줄\n    @담당: ismail');
  await caret(1, false);
  await page.keyboard.press('Backspace');
  eq('다른 칸끼리는 팝업 없이 둘 다 남는다', await text(),
    '윗줄아랫줄\n    @담당: ismail\n    @팀: infra');

  // ── 같은 칸이 다른 값으로 충돌하면 묻는다 ─────────────────────────────────────
  const CONFLICT = '윗줄\n    @담당: kim\n아랫줄\n    @담당: lee';
  await set(CONFLICT);
  dlg.mode = 'dismiss'; dlg.msgs.length = 0;
  await caret(1, false);
  await page.keyboard.press('Backspace');
  eq('충돌하는 필드가 있으면 confirm 이 뜬다', dlg.msgs.length, 1);
  check('팝업 문구가 어떤 필드가 지워지는지 알린다',
    dlg.msgs[0] && dlg.msgs[0].indexOf('담당') >= 0 && dlg.msgs[0].indexOf('삭제') >= 0, dlg.msgs[0]);
  eq('취소하면 합치기 자체가 일어나지 않는다', await text(), CONFLICT);

  // 확인하면 합쳐지고 — 윗줄 값이 남고 아랫줄 값이 비워진다.
  await set(CONFLICT);
  dlg.mode = 'accept'; dlg.msgs.length = 0;
  await caret(1, false);
  await page.keyboard.press('Backspace');
  eq('확인하면 윗줄 값으로 합쳐진다', await text(), '윗줄아랫줄\n    @담당: kim');

  // 값이 같은 칸은 잃는 게 없다 — 묻지 않는다.
  await set('윗줄\n    @담당: kim\n아랫줄\n    @담당: kim');
  dlg.mode = 'dismiss'; dlg.msgs.length = 0;
  await caret(1, false);
  await page.keyboard.press('Backspace');
  eq('같은 값은 안 묻는다', dlg.msgs.length, 0);
  eq('같은 값은 하나로 합쳐진다', await text(), '윗줄아랫줄\n    @담당: kim');

  // ── Delete(앞으로 지우기) 병합도 같은 보호를 받는다 ──────────────────────────
  await set(CONFLICT);
  dlg.mode = 'dismiss'; dlg.msgs.length = 0;
  await caret(0, true);
  await page.keyboard.press('Delete');
  eq('Delete 병합도 충돌이면 묻는다', dlg.msgs.length, 1);
  eq('Delete 병합도 취소하면 그대로다', await text(), CONFLICT);

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
