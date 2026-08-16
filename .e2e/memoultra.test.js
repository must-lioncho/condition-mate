// E2E for 메모장 초집중(ultra) — 2026-08-13 구조 교체.
//
// 예전 초집중은 행 편집기를 그대로 두고 '지금 줄' 하나만 CSS 로 남겼다. 그 화면에도
// 원·제목·접힌 상세·칸이 그대로 있어서 "적었는데 사라졌다" 가 되풀이됐다 — 접힌 상세는
// 화면에 없는 글이고, 화면에 없는 글은 언제든 구조가 삼킬 수 있다. 그래서 초집중에서는
// 편집면 자체를 바꾼다: 지금 덩어리 하나만 담는 순수 textarea.
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 여기서 지키는 계약:
//   - 초집중: 행 편집기(.cmm-doc)는 화면에서 내려가고 textarea(.cmm-ua) 하나만 남는다
//   - 그 칸에는 '지금 덩어리' 하나 — 첫 줄=제목, 나머지=상세. 보이는 글자가 곧 저장 글자
//   - 타이핑은 즉시 행에 반영된다(나갈 때 몰아 저장하지 않는다)
//   - 제목 칸이 없으므로 빈 덩어리에 쓰기 시작하면 날짜·시각 머리글이 자동으로 붙고,
//     이어 쓰는 동안에는 다시 붙지 않는다
//   - 한글 조합 중에는 절대 끼어들지 않는다(조합이 끝난 뒤에 붙고 글자가 안 깨진다)
//   - ↑↓ 는 글 안에서는 평소대로, 첫 줄/마지막 줄에서만 앞뒤 덩어리로 넘어간다.
//     마지막 덩어리에서 ↓ 는 새 덩어리를 만든다
//   - 초집중을 나가면 행 편집기가 그대로 돌아오고, 쓴 글은 제목/상세로 행에 남아 있다
//   - 기본 모드는 하나도 바뀌지 않는다(빈 자리 클릭·버튼 규칙 그대로)
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const TZ = 'Asia/Seoul';
process.env.TZ = TZ;

// 날짜 축(생성 날짜)은 이 시험의 관심사가 아니다 — '전체' 로 열어 두고 UI 모드만 본다.
const html = (ui) => `<!doctype html><meta charset=utf-8>
<script>
(function(){
  var store = { cmMemoUI: ${JSON.stringify(ui || '')}, cmMemoCr: 'all', cmMemoView: 'todo,done,block' };
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
window.__saved=[];
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(o && o.method==='POST'){ window.__saved.push(JSON.parse(o.body).text); return Promise.resolve({json:()=>Promise.resolve({ok:true})}); }
    return Promise.resolve({json:()=>Promise.resolve({text:'', rev:1})});
  }
  return Promise.reject(new Error('no board'));
};
</script></body>`;

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? '  PASS: ' : '  FAIL: ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };
const eq = (n, got, want) => check(n, JSON.stringify(got) === JSON.stringify(want),
  JSON.stringify(got) === JSON.stringify(want) ? '' : `got=${JSON.stringify(got)} want=${JSON.stringify(want)}`);

const STAMP = /^\d{4}-\d{2}-\d{2} \([일월화수목금토]\) \d{2}:\d{2}$/;

// 맨 뒤에 빈 줄을 두지 않는다 — 빈 줄이 있으면 '빈 자리 클릭' 이 그 줄로 캐럿만
// 옮기고 끝나서, 줄이 생기는지 아닌지를 가릴 수 없다.
const MEMO = ['- [ ] 첫 줄', '- [ ] 둘째 줄', '- [ ] 셋째 줄'].join('\n');

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ timezoneId: TZ });
  let page = null;
  // 단계마다 새 탭 — setContent 는 JS 컨텍스트를 재사용해 CMMemo 싱글턴이 살아남는다.
  const mount = async (ui, memo) => {
    if (page) await page.close();
    page = await ctx.newPage();
    await page.setContent(html(ui));
    await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
    await page.evaluate((s) => CMMemo.setText(s), memo === undefined ? MEMO : memo);
  };
  const rows = () => page.evaluate(() =>
    document.querySelectorAll('[data-cmmemo-doc] .cmm-row').length);
  const cur = () => page.evaluate(() => {
    const r = document.querySelector('[data-cmmemo-doc] .cmm-row[data-cur="1"]');
    return r ? (r.querySelector('.cmm-tx').textContent || '(빈 줄)') : null;
  });
  const ua = () => page.evaluate(() => document.querySelector('[data-cmmemo-ua]').value);
  const focusUa = () => page.evaluate(() => {
    const t = document.querySelector('[data-cmmemo-ua]');
    t.focus(); t.setSelectionRange(t.value.length, t.value.length);
  });
  // 편집면 자체를 누른다 — target 이 doc 인, 즉 '행이 아닌 빈 자리' 클릭.
  const blankDown = (button) => page.evaluate((button) =>
    document.querySelector('[data-cmmemo-doc]').dispatchEvent(
      new MouseEvent('mousedown', { bubbles: true, cancelable: true, button })), button || 0);

  // ── 1. 초집중 = textarea 하나 ─────────────────────────────────────────
  await mount('ultra');
  eq('초집중이 켜져 있다', await page.evaluate(() =>
    document.querySelector('[data-cmmemo]').getAttribute('data-ui')), 'ultra');
  eq('행 편집기는 화면에서 내려간다', await page.evaluate(() =>
    getComputedStyle(document.querySelector('[data-cmmemo-doc]')).display), 'none');
  eq('편집면은 textarea 하나', await page.evaluate(() => {
    const t = document.querySelector('[data-cmmemo-ua]');
    return [t.tagName, getComputedStyle(t).display];
  }), ['TEXTAREA', 'block']);
  eq('그 칸에는 지금 덩어리 하나만', await ua(), '셋째 줄');
  eq('행은 그대로 살아 있다 (감췄을 뿐)', await rows(), 3);

  // ── 2. 쓰는 즉시 행에 반영된다 ────────────────────────────────────────
  await focusUa();
  await page.keyboard.type(' 이어서', { delay: 10 });
  eq('제목이 바로 따라온다', await cur(), '셋째 줄 이어서');
  await page.keyboard.press('Enter');
  await page.keyboard.type('내용 한 줄', { delay: 10 });
  eq('둘째 줄부터는 상세로 들어간다', await page.evaluate(() =>
    document.querySelector('.cmm-row[data-cur="1"] .cmm-dt').textContent), '내용 한 줄');
  // 생성 스탬프('    @생성: …')는 줄마다 붙는 메타라 '모양' 비교에서는 걷어 낸다.
  eq('저장 텍스트도 같은 모양 (제목 + 4칸 들여쓴 상세)',
    (await page.evaluate(() => CMMemo.text())).split('\n')
      .filter((l) => !/^\s+@생성:/.test(l)).slice(-2),
    ['- [ ] 셋째 줄 이어서', '    내용 한 줄']);
  eq('보이는 글자가 곧 저장 글자', await ua(), '셋째 줄 이어서\n내용 한 줄');

  // ── 3. ↑↓ = 앞뒤 덩어리 (글 안에서는 평소대로) ────────────────────────
  await page.keyboard.press('ArrowUp');
  eq('글 안에서의 ↑ 는 덩어리를 넘기지 않는다', await ua(), '셋째 줄 이어서\n내용 한 줄');
  await page.keyboard.press('ArrowUp');
  eq('첫 줄에서 한 번 더 ↑ 하면 앞 덩어리', await ua(), '둘째 줄');
  await page.keyboard.press('ArrowDown');
  eq('마지막 줄에서 ↓ 하면 뒤 덩어리', await ua(), '셋째 줄 이어서\n내용 한 줄');

  // ── 4. 마지막에서 ↓ = 새 덩어리 + 날짜·시각 머리글 ────────────────────
  await focusUa();
  await page.keyboard.press('ArrowDown');
  eq('마지막 덩어리에서 ↓ 는 새 덩어리를 만든다', await rows(), 4);
  eq('새 덩어리는 비어 있다', await ua(), '');
  await page.keyboard.type('새로 적는 글', { delay: 10 });
  const ls = (await ua()).split('\n');
  check('빈 덩어리에 쓰기 시작하면 날짜·시각이 머리에 붙는다', STAMP.test(ls[0]), `머리=${JSON.stringify(ls[0])}`);
  eq('내가 친 글은 그 아래 그대로', ls[1], '새로 적는 글');
  eq('머리글이 그 행의 제목이 된다', await cur(), ls[0]);
  await page.keyboard.type(' 계속', { delay: 10 });
  eq('이어 쓰는 동안에는 머리글이 다시 붙지 않는다',
    (await ua()).split('\n').filter((l) => STAMP.test(l)).length, 1);

  // ── 5. 한글(IME) 조합 — 조합 중에는 끼어들지 않는다 ───────────────────
  // macOS 2벌식이 내는 순서를 그대로 흉내 낸다: keydown(229) → compositionstart →
  // 조합 중 input(isComposing) → compositionend. 조합 중에 value 를 건드리면 글자가 깨진다.
  await focusUa();
  await page.keyboard.press('ArrowDown');                 // 새 빈 덩어리
  const mid = await page.evaluate(() => {
    const t = document.querySelector('[data-cmmemo-ua]');
    t.focus(); t.value = ''; t.setSelectionRange(0, 0);
    t.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Process', keyCode: 229 }));
    t.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    t.value = '안'; t.setSelectionRange(1, 1);
    t.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: '안' }));
    t.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true }));
    return t.value;
  });
  eq('조합 중에는 끼어들지 않는다 (글자 그대로)', mid, '안');
  await page.evaluate(() => {
    const t = document.querySelector('[data-cmmemo-ua]');
    t.value = '안녕'; t.setSelectionRange(2, 2);
    t.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '녕' }));
    t.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: false }));
  });
  await page.waitForFunction(() => document.querySelector('[data-cmmemo-ua]').value.split('\n').length === 2);
  const kls = (await ua()).split('\n');
  check('조합이 끝난 뒤에 머리글이 붙는다', STAMP.test(kls[0]), JSON.stringify(kls));
  eq('한글은 깨지지 않는다', kls[1], '안녕');

  // ── 6. 초집중을 나가면 행 편집기가 그대로 돌아온다 ────────────────────
  const wrote = await ua();
  await page.evaluate(() => {
    // UI 콤보의 '기본' 을 고른 것과 같은 길(uiSet → uiPaint).
    document.querySelector('[data-cmmemo-ui]').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    const opt = Array.from(document.querySelectorAll('.cmmemo-menu button')).filter((b) => /기본/.test(b.textContent))[0];
    opt.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
  });
  eq('행 편집기가 다시 보인다', await page.evaluate(() =>
    [document.querySelector('[data-cmmemo]').getAttribute('data-ui'),
     getComputedStyle(document.querySelector('[data-cmmemo-doc]')).display,
     getComputedStyle(document.querySelector('[data-cmmemo-ua]')).display]), [null, 'block', 'none']);
  eq('초집중에서 쓴 글이 제목+상세로 남아 있다', await page.evaluate(() => {
    const r = document.querySelector('[data-cmmemo-doc]').lastElementChild;
    return [r.querySelector('.cmm-tx').textContent, r.querySelector('.cmm-dt').textContent];
  }), wrote.split('\n'));

  // ── 7. 기본 모드는 하나도 바뀌지 않는다 ───────────────────────────────
  await mount('');
  const base = await rows();
  await blankDown(2);
  eq('오른쪽 버튼(내보내기 메뉴)으로는 줄이 생기지 않는다', await rows(), base);
  await blankDown(1);
  eq('가운데 버튼으로도 줄이 생기지 않는다', await rows(), base);
  await blankDown(0);
  eq('기본 모드: 왼쪽 버튼 빈 자리 클릭은 이어 쓸 줄을 만든다', await rows(), base + 1);
  eq('기본 모드에서는 초집중 칸이 화면에 없다', await page.evaluate(() =>
    getComputedStyle(document.querySelector('[data-cmmemo-ua]')).display), 'none');

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
