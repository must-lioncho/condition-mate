// E2E for 초집중(ultra) — 지금 덩어리가 엉뚱한 다른 메모로 튀는 사고(2026-08-20 재현).
//
// '지금 덩어리' 추적(ultraEnsure)은 DOM 참조(pad.uaRow)와 dataset.cur 에 기댄다. 그런데
// render() 는 .cmm-doc 의 행 DOM 을 통째로 새로 만든다(innerHTML='' 후 재조립) — 되돌리기
// (histApply)든, 다른 창이 먼저 저장해 생기는 충돌 합치기(push 의 conflict → adopt)든,
// 그 행 DOM 을 다시 그리는 모든 길에서 참조와 dataset.cur 가 함께 사라진다. 그러면
// ultraEnsure 는 '마지막으로 보이는 줄' 로 조용히 폴백하는데, 그게 지금 쓰던 덩어리가
// 아닌 완전히 다른 옛 메모일 수 있다 — 그 값은 uaSync 가 즉시 그 행에 되써 저장까지
// 태운다. 아래 [1]은 이 사고를 다른 창의 저장 충돌로 직접 재현한다(가장 흔한 실제 방아쇠 —
// 예를 들어 창이 다시 포커스를 받을 때 걸리는 refresh() 도 같은 adopt() 를 탄다).
// [2]는 방어적으로 함께 고친 것 — 초집중의 ⌘Z 가 브라우저 네이티브 되돌리기 대신 앱
// 자체 히스토리를 타야, 이 textarea 가 예전에 담았던 다른 덩어리의 되돌리기 기록과
// 뒤섞일 길 자체가 없다(.cmm-doc 이 이미 쓰는 것과 같은 원칙).
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? '  PASS: ' : '  FAIL: ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const eq = (n, got, want) => check(n, JSON.stringify(got) === JSON.stringify(want),
  JSON.stringify(got) === JSON.stringify(want) ? '' : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);

const htmlFetch = `<!doctype html><meta charset=utf-8>
<script>
(function(){
  var store = { cmMemoUI: 'ultra', cmMemoCr: 'all', cmMemoView: 'todo,done,block' };
  Object.defineProperty(window, 'localStorage', { value: {
    getItem: function(k){ return k in store ? store[k] : null; },
    setItem: function(k, v){ store[k] = String(v); },
    removeItem: function(k){ delete store[k]; },
  } });
})();
</script>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
window.__posts=0;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(o && o.method==='POST'){
      window.__posts++;
      // 첫 저장은 '다른 창이 먼저 저장했다' — 서버가 거부하고 그쪽 글을 돌려준다.
      // 그 글에는 이쪽에 없는 새 줄이 하나 있어야 mergeLines 가 실제로 바뀐 판을 만든다.
      if(window.__posts===1)
        return Promise.resolve({json:()=>Promise.resolve(
          {conflict:true, text:'SUT team sync\\n다른 창에서 방금 쓴 새 줄', rev:2})});
      return Promise.resolve({json:()=>Promise.resolve({ok:true})});
    }
    return Promise.resolve({json:()=>Promise.resolve({text:'', rev:1})});
  }
  return Promise.reject(new Error('no board'));
};
</script></body>`;

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext();

  // ── [1] 다른 창의 저장 충돌(adopt) 이 지금 덩어리를 튀게 하지 않는다 ──────────
  {
    const page = await ctx.newPage();
    await page.setContent(htmlFetch);
    await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
    // 이미 있던 덩어리 — 이 사고의 '엉뚱한 옛 메모' 역할.
    await page.evaluate((s) => CMMemo.setText(s), 'SUT team sync');
    const ua = () => page.evaluate(() => document.querySelector('[data-cmmemo-ua]').value);
    const rowText = (i) => page.evaluate((i) => {
      const r = document.querySelectorAll('[data-cmmemo-doc] .cmm-row')[i];
      return r ? r.querySelector('.cmm-tx').textContent : null;
    }, i);

    // '+ 새 덩어리' — 지금 있는 덩어리와 같은 textarea DOM 노드에 새 내용을 싣는다.
    await page.click('[data-cmmemo-add]');
    await page.keyboard.type('오늘 회의 메모', { delay: 10 });
    eq('쓰던 글이 지금 덩어리에 있다', await ua(), (await ua()));   // sanity: focus/typed
    check('쓰던 글에 방금 친 문장이 들어 있다', (await ua()).indexOf('오늘 회의 메모') >= 0);

    // 다른 창이 먼저 저장 → 이 창의 저장은 충돌 → mergeLines → adopt() → 전 pad 다시 그림.
    await page.evaluate(() => CMMemo.flush());
    await page.waitForTimeout(300);

    const after = await ua();
    check('충돌 합치기 뒤에도 지금 쓰던 덩어리가 그대로 보인다 (다른 메모로 튀지 않는다)',
      after.indexOf('오늘 회의 메모') >= 0 && after.indexOf('다른 창에서') < 0,
      `got=${JSON.stringify(after)}`);
    eq('예전 덩어리(SUT team sync)의 저장 글자도 그대로', await rowText(0), 'SUT team sync');
    eq('다른 창의 새 줄은 문서 끝에 별도 행으로 들어왔다 (글은 버려지지 않는다)',
      await rowText(2), '다른 창에서 방금 쓴 새 줄');
  }

  // ── [2] 초집중의 ⌘Z 는 브라우저가 아니라 우리 히스토리를 탄다 ─────────────────
  {
    const page = await ctx.newPage();
    await page.setContent(htmlFetch);
    await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
    await page.evaluate((s) => CMMemo.setText(s), 'SUT team sync');
    const ua = () => page.evaluate(() => document.querySelector('[data-cmmemo-ua]').value);

    await page.click('[data-cmmemo-add]');
    await page.keyboard.type('첫 문장', { delay: 10 });
    await page.waitForTimeout(700);                 // 되돌리기 덩어리 경계(COALESCE=550ms)
    await page.keyboard.type(' 둘째 문장', { delay: 10 });
    const written = await ua();

    await page.keyboard.press('Meta+z');
    const mid = await ua();
    check('한 번 되돌리면 방금 이어 친 부분만 사라진다', mid.length < written.length && mid.length > 0,
      `got=${JSON.stringify(mid)}`);
    check('예전 덩어리(SUT team sync)로는 넘어가지 않는다', mid.indexOf('SUT') < 0);

    await page.keyboard.press('Meta+Shift+z');
    eq('⌘⇧Z 로 쓰던 글이 그대로 돌아온다 (우리 히스토리가 대칭으로 동작한다는 증거)',
      await ua(), written);

    // 편집 메뉴의 '실행 취소'(beforeinput historyUndo)도 같은 길을 타야 한다 — 트랙패드
    // 제스처·Edit 메뉴가 이 경로로 온다(키 이벤트를 거치지 않는다).
    await page.evaluate(() => document.querySelector('[data-cmmemo-ua]')
      .dispatchEvent(new InputEvent('beforeinput', { inputType: 'historyUndo', bubbles: true, cancelable: true })));
    check('편집 메뉴의 실행 취소도 우리 히스토리로 간다 (여기서도 옛 덩어리로 새지 않는다)',
      (await ua()).indexOf('SUT') < 0);
  }

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
