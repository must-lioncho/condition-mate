// E2E for 메모장 — 루프 컷 직후에 적는 줄. SHIPPING 소스(MemoPad.swift, via memosrc)를
// 실제 Chromium 에 mount 해 굴린다.
//
// 왜 이 시험이 있나 (2026-08-30 관측):
//   'Complete loop' 를 누른 직후 메모가 비고(수확) 루프 번호가 올라가는 것까지는 맞았는데,
//   그 자리에서 새 줄을 적으면 글자가 그대로 사라졌다. 1분쯤 지나면 다시 적을 수 있었다.
//   원인은 동기화 지연이 아니라 **두 시계의 눈금이 다른 것**이다:
//     - 줄의 '@생성' 스탬프는 분 단위다 (crNow: …THH:MMZ — 초가 없다)
//     - 컷(릴리즈)의 경계는 초 단위다 (releasedAt)
//   그래서 21:53:40 에 컷이 나고 21:53:50 에 적은 줄은 스탬프가 21:53:00 으로 내려앉아
//   '컷 이전' 으로 판정되고(loopOf), 지난 루프의 줄이라 CSS(data-lold)가 감춰 버린다.
//   분이 넘어가면(21:54) 저절로 나아지는 것이 '1분 뒤부터 된다' 의 정체다.
//
// 여기서 지키는 계약:
//   - 컷과 같은 분에 적은 줄은 감춰지지 않는다. 스탬프가 컷보다 이르게 보이더라도, 분
//     단위 스탬프로는 그 줄이 컷 앞인지 뒤인지 알 수 없다 — 알 수 없는 것을 과거로 미는
//     것은 지어내는 일이고, 그 결과가 '적었는데 사라졌다' 다. 모호하면 보이는 쪽으로 튼다
//   - 컷보다 확실히 이른 줄(지난 분·지난 날)은 그대로 묻힌다 — 이 시험은 감춤 기능을
//     되돌리는 것이 아니라 경계 한 칸만 고친다
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const DAY = 86400;
const p2 = (n) => (n < 10 ? '0' : '') + n;
const stamp = (sec) => { const d = new Date(sec * 1000);
  return d.getUTCFullYear() + '-' + p2(d.getUTCMonth() + 1) + '-' + p2(d.getUTCDate())
       + 'T' + p2(d.getUTCHours()) + ':' + p2(d.getUTCMinutes()) + 'Z'; };

// 시계를 분 안의 정해진 초에 고정한다 — 이 결함은 '분 안 어디냐' 로 갈리므로, 진짜
// 시계로 돌리면 하루에 몇 번은 우연히 통과하는 시험이 된다.
const REAL = Math.floor(Date.now() / 1000);
const MIN = REAL - (REAL % 60);      // 이번 분의 0초
const T0 = MIN + 40;                 // 사람이 글을 적는 순간 (:40)
const CUT = MIN + 15;                // 컷은 25초 전 (:15) — 같은 분이다
const OLDCUT = MIN - 5 * DAY;

const BOARD = { review: {
  goals: [],
  sprints: [{ number: 59, code: '26-59', closed: false },
            { number: 58, code: '26-58', closed: true }],
  releases: [{ id: 'r2', code: '26-58', releasedAt: CUT },
             { id: 'r1', code: '26-57', releasedAt: OLDCUT }],
} };

const html = `<!doctype html><meta charset=utf-8>
<script>
(function(){
  var store = { cmMemoView: 'todo,done,block' };
  window.__ls = store;
  Object.defineProperty(window, 'localStorage', { value: {
    getItem: function(k){ return k in store ? store[k] : null; },
    setItem: function(k, v){ store[k] = String(v); },
    removeItem: function(k){ delete store[k]; },
  } });
})();
// 모듈이 읽는 시계를 :40 에 고정한다(모듈 코드는 손대지 않는다).
(function(){ window.__at = ${T0 * 1000}; Date.now = function(){ return window.__at; }; })();
</script>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
window.__saved=[];
window.__board=${JSON.stringify(BOARD)};
const _f=window.fetch;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(String(u).split('?')[0]!=='/api/memo') return Promise.resolve({json:()=>Promise.resolve({})});
    if(o && o.method==='POST'){ window.__saved.push(JSON.parse(o.body).text);
      return Promise.resolve({json:()=>Promise.resolve({ok:true})}); }
    return Promise.resolve({json:()=>Promise.resolve({text:''})});
  }
  if(String(u).indexOf('/data.json')>=0){
    return window.__board ? Promise.resolve({json:()=>Promise.resolve(window.__board)})
                          : Promise.reject(new Error('no board'));
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

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  const text = () => page.evaluate(() => CMMemo.text());
  const shown = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .filter((r) => getComputedStyle(r).display !== 'none')
      .map((r) => r.querySelector('.cmm-tx').textContent));
  const vis = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' ? '0' : '1').join(''));
  const label = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent);
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

  // 보드가 도착할 때까지 — 헤더가 지금 도는 루프를 말하면 컷 시간축도 들어와 있다.
  await page.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-59', null, { timeout: 5000 });
  eq('0. 컷이 끝나 보드는 26-59', await label(), '26-59');

  // 컷이 막 지나간 패드 — 지난 루프의 줄 하나(이틀 전)와 이어 쓸 빈 줄.
  await set(['- [ ] 지난 루프에 적은 줄', '    @생성: ' + stamp(MIN - 2 * DAY), ''].join('\n'));
  await page.waitForTimeout(50);
  eq('1. 컷 이전에 적은 줄은 묻힌다(빈 줄만 남는다)', await vis(), '01');

  // ── 컷과 같은 분에 새 줄을 적는다 ──────────────────────────────────────
  await caret(1, -1);
  await page.keyboard.type('컷 직후에 적는 줄');
  await page.waitForTimeout(50);

  check('2. 방금 친 글이 화면에 남아 있다',
    (await shown()).indexOf('컷 직후에 적는 줄') >= 0,
    'shown=' + JSON.stringify(await shown()));
  eq('3. 그 줄은 지난 루프로 묻히지 않는다',
    await page.evaluate(() => Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .filter((r) => r.querySelector('.cmm-tx').textContent === '컷 직후에 적는 줄')
      .map((r) => r.dataset.lold || '')), ['']);
  eq('4. 컷보다 확실히 이른 줄은 그대로 묻혀 있다',
    await page.evaluate(() => Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .filter((r) => r.querySelector('.cmm-tx').textContent === '지난 루프에 적은 줄')
      .map((r) => r.dataset.lold || '')), ['1']);
  check('5. 저장 텍스트에도 그대로 들어간다',
    (await text()).indexOf('컷 직후에 적는 줄') >= 0);

  // ── 디스크에 이미 있는 옛(분 단위) 스탬프 ───────────────────────────────
  // 이 결함이 나기 전에 적힌 줄은 전부 분 단위 스탬프를 달고 있다. 그 줄의 스탬프는
  // 한 점이 아니라 그 분 전체를 뜻하므로, 컷이 그 분 안에 있으면 앞뒤를 알 수 없다 —
  // 그때는 묻지 않는다. 컷보다 확실히 이른 분의 줄은 그대로 묻힌다.
  const cr = (sec) => page.evaluate((sec) => { const d = new Date(sec * 1000);
    const p = (n) => (n < 10 ? '0' : '') + n;
    return d.getUTCFullYear() + '-' + p(d.getUTCMonth() + 1) + '-' + p(d.getUTCDate())
         + 'T' + p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + 'Z'; }, sec);
  await set([
    '컷과 같은 분에 적힌 옛 줄', '    @생성: ' + await cr(MIN),
    '한 분 전에 적힌 옛 줄', '    @생성: ' + await cr(MIN - 60),
    ''].join('\n'));
  await page.waitForTimeout(50);
  eq('6. 컷과 같은 분의 분 단위 스탬프는 묻지 않는다 — 앞뒤를 알 수 없다', await vis(), '101');
  eq('7. 한 분 전의 줄은 그대로 묻힌다', await shown(), ['컷과 같은 분에 적힌 옛 줄', '']);

  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
