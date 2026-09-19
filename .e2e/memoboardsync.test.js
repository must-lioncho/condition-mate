// E2E for 메모장 ↔ 보드 루프 코드 동기화 — 세션 도중에 보드가 바뀌면 패드도 따라온다.
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 왜 이 시험이 있나(2026-08-29 13:56 관측):
//   보드 루프 카드는 26-51 인데 메모 패드 헤더는 26-49 였다. boardFetch() 를 부르는 자리가
//   mount 1회와 '보기' 콤보를 여는 자리뿐이라, 몇 시간씩 열려 있는 대시보드 웹뷰에서는
//   처음 받은 코드가 그대로 굳었다.
//   이것은 표찰만의 문제가 아니다 — loopEnd() 가 bgLoop.cur 를 받아 dataset.lp 로 쓰고,
//   그것이 직렬화되어 저장 텍스트에 '@루프: <code>' 로 박힌다. 패드가 26-49 로 굳은 채
//   '루프 종료' 를 누르면 두 루프 전의 코드가 디스크에 남는다.
//
// 여기서 지키는 계약:
//   - 새 타이머를 두지 않는다 — 이미 있는 갱신 경로(window focus / visibilitychange)에
//     얹는다. boardFetch 자신의 60초 스로틀은 그대로 살아 있다(창을 왔다 갔다 할 때
//     요청이 쏟아지는 것을 막는 자리)
//   - 보드 갱신은 refresh() 의 편집 가드(dirty/pending/timer)보다 **위**다. 그 가드는
//     '서버 텍스트가 타이핑을 덮는 것' 을 막는 자리이고, 보드 갱신은 텍스트를 한 글자도
//     건드리지 않는다. 가드 안에 넣으면 편집 중인 사람이 갱신을 영원히 못 받는데,
//     그 사람이 바로 곧 '루프 종료' 를 누를 사람이다
//   - 콤보를 열어 둔 채 보드가 바뀌면 메뉴의 '현재 루프만' 코드도 같이 바뀐다 —
//     헤더는 새 코드, 메뉴는 옛 코드인 한 화면이 나오면 안 된다
//   - 갱신이 감출 수 있는 것은 지난 루프의 줄뿐이다 — 컷이 일어난 것을 알게 되면 그
//     이전에 만든 줄은 그 루프에 묻히지만(2026-08-30 — 루프 하나가 메모장 한 벌),
//     이번 루프에 적은 줄은 절대 감춰지지 않는다. 그 선이 깨지면 '적었는데 사라졌다'
//     가 된다. 묻힌 줄도 '이전 루프 포함' 으로 그 자리에 그대로 있다
//   - 갱신은 저장 텍스트를 한 글자도 바꾸지 않는다
//
// 세션 도중 보드 변경을 어떻게 일으키나:
//   memoloopview.test.js 의 하네스는 window.__board 를 한 번 세팅하고 끝이라 이 결함을
//   원리적으로 못 잡는다. 여기서는 (1) window.__board 를 바꾸고 (2) 페이지의 Date.now 를
//   window.__skew 만큼 앞으로 민 뒤 (3) window.dispatchEvent(new Event('focus')) 를 쏜다.
//   시계를 미는 쪽을 고른 이유: boardFetch 의 60초 스로틀은 이번 변경에서 **일부러 그대로
//   둔 것**이라 시험이 그것을 우회하면 시험이 배송되지 않는 코드를 재는 꼴이 된다.
//   bgAt/bgMap 은 모듈 클로저 안이라 밖에서 되감을 수 없고, 첫 fetch 를 실패시키는 방법은
//   '마운트 시점의 보드가 헤더에 뜬다'(시험 1)를 아예 못 재게 만든다. 모듈이 실제로 읽는
//   시계를 미는 것이 코드를 안 건드리면서 진짜 시간 경과와 같은 경로를 타는 유일한 길이다.
const { chromium } = require('playwright');
const { PAD_HTML, PAD_JS } = require('./memosrc');

// 시각은 지금을 기준으로 만든다 — 달력의 특정 날짜에 묶으면 내일 이 시험이 깨진다.
const DAY = 86400;
const NOW = Math.floor(Date.now() / 1000);
const p2 = (n) => (n < 10 ? '0' : '') + n;
const stamp = (sec) => { const d = new Date(sec * 1000);
  return d.getUTCFullYear() + '-' + p2(d.getUTCMonth() + 1) + '-' + p2(d.getUTCDate())
       + 'T' + p2(d.getUTCHours()) + ':' + p2(d.getUTCMinutes()) + 'Z'; };

// 보드 v1 — 지금 도는 루프는 26-49. 마운트 시점에 이미 여기 있다(html 안에서 세팅).
const BOARD1 = { review: {
  goals: [],
  sprints: [{ number: 49, code: '26-49', closed: false },
            { number: 48, code: '26-48', closed: true }],
  releases: [{ id: 'r1', code: '26-48', releasedAt: NOW - 5 * DAY }],
} };
// 보드 v2 — 루프가 한 바퀴 돌았다. 열린 스프린트가 26-51 이고 26-49 컷이 한 시간 전.
const BOARD2 = { review: {
  goals: [],
  sprints: [{ number: 51, code: '26-51', closed: false },
            { number: 49, code: '26-49', closed: true },
            { number: 48, code: '26-48', closed: true }],
  releases: [{ id: 'r2', code: '26-49', releasedAt: NOW - 3600 },
             { id: 'r1', code: '26-48', releasedAt: NOW - 5 * DAY }],
} };
// 보드 v3 — 한 바퀴 더. 콤보를 열어 둔 채로 도착시킨다.
const BOARD3 = { review: {
  goals: [],
  sprints: [{ number: 53, code: '26-53', closed: false },
            { number: 51, code: '26-51', closed: true },
            { number: 49, code: '26-49', closed: true }],
  releases: [{ id: 'r3', code: '26-51', releasedAt: NOW - 1800 },
             { id: 'r2', code: '26-49', releasedAt: NOW - 3600 },
             { id: 'r1', code: '26-48', releasedAt: NOW - 5 * DAY }],
} };

// 보드 v5 — 사람이 실제로 본 어긋남의 뒷숫자. 26-51 에서 26-52 로 한 칸 넘어간 판.
const BOARD5 = { review: {
  goals: [],
  sprints: [{ number: 52, code: '26-52', closed: false },
            { number: 51, code: '26-51', closed: true },
            { number: 49, code: '26-49', closed: true }],
  releases: [{ id: 'r3', code: '26-51', releasedAt: NOW - 1800 },
             { id: 'r2', code: '26-49', releasedAt: NOW - 3600 },
             { id: 'r1', code: '26-48', releasedAt: NOW - 5 * DAY }],
} };
// 보드 v6 — 숨어 있는 동안 도착시킬 판. 이 코드가 헤더에 뜨면 숨은 탭에서 요청이 나간 것이다.
const BOARD6 = { review: {
  goals: [],
  sprints: [{ number: 54, code: '26-54', closed: false },
            { number: 52, code: '26-52', closed: true }],
  releases: [{ id: 'r4', code: '26-52', releasedAt: NOW - 900 },
             { id: 'r3', code: '26-51', releasedAt: NOW - 1800 }],
} };

const mkHtml = (board) => `<!doctype html><meta charset=utf-8>
<script>
// setContent 하네스는 origin 이 없어 진짜 localStorage 가 접근 즉시 던진다. 메모리 판으로
// 갈아 끼운다(모듈 코드는 손대지 않는다). 완료도 보이는 채로 시작한다.
(function(){
  var store = { cmMemoView: 'todo,done,block' };
  window.__ls = store;
  Object.defineProperty(window, 'localStorage', { value: {
    getItem: function(k){ return k in store ? store[k] : null; },
    setItem: function(k, v){ store[k] = String(v); },
    removeItem: function(k){ delete store[k]; },
  } });
})();
// 모듈이 읽는 시계 — 60초 스로틀을 진짜 시간 경과와 같은 경로로 넘기기 위한 유일한 손잡이.
// 모듈 코드는 매번 Date.now 를 조회하므로 여기서 갈아 끼우면 그대로 따라온다.
(function(){ var real = Date.now; window.__skew = 0;
  Date.now = function(){ return real() + window.__skew; }; })();
// 배송 코드의 30초 폴링 타이머를 가로챈다(8절). 30초를 실제로 기다리면 시험이 30초짜리가
// 되고 타이밍으로 흔들린다 — 콜백을 붙잡아 두고 손으로 한 틱씩 돌리면 결정적이고 빠르다.
// __ivals 에는 모듈이 건 **모든** 간격을 남긴다: 이것이 '내가 가로챈 것이 진짜 그 타이머인가'
// 를 시험 안에서 확인하는 자리다(MemoPad 모듈의 setInterval 은 이 하나뿐이어야 한다).
(function(){ window.__ticks=[]; window.__ivals=[];
  var si = window.setInterval;
  window.setInterval = function(fn, ms){
    window.__ivals.push(ms);
    if(ms===30000){ window.__ticks.push(fn); return 0; }   // 붙잡는다(진짜로 걸지 않는다)
    return si.apply(this, arguments);
  };
})();
</script>
<style>:root{ --panel:#141821; --line:#222a36; --fg:#e6e9ef; --mut:#8a93a3; --accent:#5b8cff }
  body{ margin:0; background:#0b0e14; color:#e6e9ef }</style>
<body><main>${PAD_HTML}</main>
<script>
window.__saved=[];
window.__dataHits=0;   // /data.json 을 실제로 몇 번 쳤나(8절의 스로틀·hidden 검사)
window.__srv=null;        // /api/memo GET 이 돌려줄 것(기본: 판번호 없는 빈 글 = 안 덮는다)
window.__hangSave=false;  // true 면 POST 가 끝나지 않는다 → dirty/pending 이 계속 선다
window.__board=${JSON.stringify(board)};   // 마운트 시점에 이미 보드가 있다
const _f=window.fetch;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    // 정확히 /api/memo 만 이 창구다. /api/memo/seq(채번)·/tidy·/tags 는 몸통에 text 가 없어
    // 같이 주우면 __saved 에 undefined 가 섞인다(그러면 저장 검사가 거짓말을 한다).
    if(String(u).split('?')[0]!=='/api/memo') return Promise.resolve({json:()=>Promise.resolve({})});
    if(o && o.method==='POST'){
      window.__saved.push(JSON.parse(o.body).text);
      if(window.__hangSave) return new Promise(function(){});
      return Promise.resolve({json:()=>Promise.resolve({ok:true})});
    }
    return Promise.resolve({json:()=>Promise.resolve(window.__srv || {text:''})});
  }
  if(String(u).indexOf('/data.json')>=0){
    window.__dataHits++;
    return window.__board ? Promise.resolve({json:()=>Promise.resolve(window.__board)})
                          : Promise.reject(new Error('no board'));
  }
  return _f.apply(this,arguments);
};
</script></body>`;
const html = mkHtml(BOARD1);

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
  const saved = () => page.evaluate(() => window.__saved.length);
  const vis = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' ? '0' : '1').join(''));
  const shown = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .filter((r) => getComputedStyle(r).display !== 'none')
      .map((r) => r.querySelector('.cmm-tx').textContent));
  const label = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent);
  const openView = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view]')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })));
  const menuCur = () => page.evaluate(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.view !== '1') return null;
    const b = Array.from(m.querySelectorAll('button'))
      .find((x) => { const t = x.querySelector('b'); return t && t.textContent === '현재 루프만'; });
    if (!b) return null;
    const c = b.querySelector('em');
    return c ? c.textContent : '';
  });
  // 콤보 안의 항목 하나를 누른다(라벨 앞머리로 찾는다). 잠긴 항목은 누르지 않는다.
  const menuClick = (prefix) => page.evaluate((prefix) => {
    const m = document.querySelector('.cmmemo-menu');
    const b = Array.from(m.querySelectorAll('button')).find((x) => {
      const t = x.querySelector('b');
      return (t ? t.textContent : x.textContent).indexOf(prefix) === 0;
    });
    if (!b || b.disabled) return false;
    b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    return true;
  }, prefix);
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
  // 세션 도중의 보드 변경 — 보드를 갈고, 시계를 스로틀 너머로 밀고, 갱신 경로를 쏜다.
  const board = (b) => page.evaluate((b) => { window.__board = b; }, b);
  const bump = (ms) => page.evaluate((ms) => { window.__skew += ms; }, ms);
  const winFocus = () => page.evaluate(() => { window.dispatchEvent(new Event('focus')); });

  // ── 1. 마운트 시점의 보드가 헤더에 뜬다 ─────────────────────────────────
  await page.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-49');
  eq('1. 마운트 시점 보드가 26-49 면 헤더가 26-49', await label(), '26-49');

  // 메모: 이월된 두 줄(이틀 전), 이미 26-48 로 묻힌 완료 한 줄, 오늘 적은 한 줄, 빈 줄.
  const MEMO = [
    '- [ ] 이월된 미완료', '    @생성: ' + stamp(NOW - 2 * DAY),
    '평문으로 적어 둔 메모', '    @생성: ' + stamp(NOW - 2 * DAY),
    '- [x] 지난 루프에 묻은 완료', '    @루프: 26-48', '    @생성: ' + stamp(NOW - 5 * DAY),
    '- [ ] 오늘 할 일', '    @생성: ' + stamp(NOW),
    ''].join('\n');
  await set(MEMO);
  await page.evaluate(() => CMMemo.flush());
  await page.waitForFunction(() => window.__saved.length > 0);
  await page.waitForFunction(() => window.__saved[window.__saved.length - 1].indexOf('이월된 미완료') >= 0);
  // setText 는 flush 와 별개로 400ms 디바운스 타이머도 세운다 — 그것까지 지나간 뒤에
  // 저장 횟수를 찍어야 아래 5b 가 타이밍으로 흔들리지 않는다.
  await page.waitForTimeout(600);

  // ── 스로틀은 그대로 살아 있다 ───────────────────────────────────────────
  // 창을 왔다 갔다 할 때 요청이 쏟아지는 것을 막는 자리다. 이번 변경은 여기에 손대지 않았다.
  await board(BOARD2);
  await winFocus();
  await page.waitForTimeout(200);
  eq('60초 스로틀은 살아 있다 — 곧바로 다시 청하지 않는다', await label(), '26-49');

  // ── 갱신 직전 상태를 찍어 둔다(판정 C·5의 기준) ─────────────────────────
  const visBefore = await vis(), shownBefore = await shown();
  const textBefore = await text(), savedBefore = await saved();
  eq('갱신 전: 묻힌 완료만 빠지고 나머지는 다 보인다', visBefore, '11011');

  // ── 2. 세션 도중 보드가 바뀌면 헤더가 따라온다 ──────────────────────────
  await bump(61000);                                  // 스로틀 너머로 시계를 민다
  await winFocus();
  await page.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-51', null, { timeout: 3000 })
    .catch(() => {});
  eq('2. 보드가 26-51 로 바뀌고 focus 가 오면 헤더도 26-51', await label(), '26-51');

  // ── 4. 갱신이 감출 수 있는 것은 지난 루프의 줄뿐이다 ────────────────────
  // 2026-08-30 이전의 계약은 '갱신은 줄을 감출 수 없다' 였다. 그때는 감춤의 조건이
  // 스탬프 하나였으니 그것이 맞았다. 이제 루프 하나가 메모장 한 벌이라, 컷이 일어난
  // 것을 알게 된 갱신은 지난 루프의 줄을 묻어야 한다 — 그게 이 기능이다.
  // 그래서 계약을 좁힌다: 감춰지는 것은 컷 이전에 만든 줄뿐이고, **이번 루프에 적은
  // 줄은 절대 감춰지지 않는다.** '적었는데 사라졌다' 를 막는 자리는 여기다.
  // BOARD2 는 26-49 컷을 한 시간 전으로 들여온다 → 이틀 전에 적은 두 줄은 26-49 로
  // 묻히고, 방금 적은 '오늘 할 일' 과 이어 쓸 빈 줄만 남는다.
  eq('4a. 감춰지는 것은 컷 이전에 만든 줄뿐이다', await vis(), '00011');
  eq('4b. 이번 루프에 적은 줄은 그대로 남는다', await shown(), ['오늘 할 일', '']);
  eq('4c. 갱신이 없던 줄을 만들어 내지도 않는다 — 남은 줄은 직전에도 보이던 줄이다',
    (await shown()).filter((t) => shownBefore.indexOf(t) < 0), []);
  // 감춘 것이지 잃은 것이 아니다 — '이전 루프 포함' 을 켜면 그대로 다 돌아오고,
  // 방금 끝난 루프 코드를 고르면 그 루프에 적은 것만 한 벌로 나온다. 사람이 컷을 누른
  // 뒤 기대하는 것이 이 둘이다: 새 루프는 빈 패드, 지난 루프는 부르면 그대로.
  await openView();
  await menuClick('이전 루프 포함');
  eq('4d. 이전 루프 포함을 켜면 감춰진 줄이 전부 돌아온다', await vis(), '11111');
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    return m && Array.from(m.querySelectorAll('b')).some((e) => e.textContent === '26-49');
  }, null, { timeout: 3000 }).catch(() => {});
  eq('4e. 방금 끝난 루프가 콤보 목록에 오른다', await menuClick('26-49'), true);
  eq('4f. 그 루프를 고르면 그때 적은 줄만 나온다', await shown(),
    ['이월된 미완료', '평문으로 적어 둔 메모', '']);
  await menuClick('26-49');                           // 들어간 문이 곧 나오는 문
  await openView();                                   // 콤보를 닫는다(같은 버튼 = 토글)
  eq('4g. 되돌리면 다시 이번 루프만', await vis(), '00011');

  // ── 5. 갱신은 저장 텍스트를 한 글자도 바꾸지 않는다 ─────────────────────
  eq('5a. 갱신 전후 저장 텍스트가 같다', await text(), textBefore);
  eq('5b. 갱신이 새 저장을 만들지 않는다', await saved(), savedBefore);

  // ── 3. 콤보를 열어 둔 채 보드가 바뀌면 메뉴도 같이 바뀐다 ───────────────
  await openView();
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    return m && m.dataset.view === '1';
  });
  eq('3a. 열린 콤보의 현재 루프는 지금 코드', await menuCur(), '26-51');
  await board(BOARD3);
  await bump(61000);
  await winFocus();
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.view !== '1') return false;
    const b = Array.from(m.querySelectorAll('button'))
      .find((x) => { const t = x.querySelector('b'); return t && t.textContent === '현재 루프만'; });
    return !!b && b.querySelector('em').textContent === '26-53';
  }, null, { timeout: 3000 }).catch(() => {});
  eq('3b. 콤보를 열어 둔 채 보드가 바뀌면 메뉴의 코드도 따라온다', await menuCur(), '26-53');
  eq('3c. 헤더와 메뉴가 같은 말을 한다', await label(), '26-53');
  await openView();                                   // 콤보를 닫는다(같은 버튼 = 토글)

  // ── 6. 편집 중에도 보드 갱신은 도착한다 ─────────────────────────────────
  // 저장을 붙들어 pending/dirty 를 세워 둔다. 그리고 GET 은 '서버가 덮어쓸 글' 을
  // 판번호와 함께 돌려준다 — 편집 가드가 살아 있지 않으면 친 글자가 이 글에 덮인다.
  await page.evaluate(() => { window.__hangSave = true;
    window.__srv = { text: '서버가 덮어쓴 글\n', rev: 99 }; });
  await caret(4, -1);                                 // 마지막 빈 줄
  await page.keyboard.type('편집 중인 글자');
  await page.waitForFunction(() => window.__saved.some((t) => t.indexOf('편집 중인 글자') >= 0));
  const BOARD4 = JSON.parse(JSON.stringify(BOARD3));
  BOARD4.review.sprints.unshift({ number: 55, code: '26-55', closed: false });
  BOARD4.review.sprints[1].closed = true;
  await board(BOARD4);
  await bump(61000);
  await winFocus();
  await page.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-55', null, { timeout: 3000 })
    .catch(() => {});
  eq('6a. 편집 중(dirty)에도 보드 갱신은 도착한다', await label(), '26-55');
  check('6b. 친 글자는 그대로 남아 있다',
    (await text()).indexOf('편집 중인 글자') >= 0, JSON.stringify(await text()));
  check('6c. 편집 가드는 살아 있다 — 서버 글이 타이핑을 덮지 않는다',
    (await text()).indexOf('서버가 덮어쓴 글') < 0);

  // ── 7. '루프 종료' 가 찍는 코드는 그때 보드에게 물어본 코드다 ────────────
  // 왜 이 절이 있나(2026-08-29): 위 1~6 은 표찰만 쟀고 '루프 종료' 를 한 번도 누르지
  // 않았다. 5a·5b 는 오히려 '갱신이 저장 텍스트를 안 바꾼다' 는 정반대를 확인한다.
  // 그래서 loopEnd() 가 낡은 bgLoop.cur 를 그대로 찍어 memo.json 에 '@루프: <code>' 로
  // **영구히** 박는 축이, 이 파일이 전부 통과하는 동안 열려 있었다. 표찰이 낡는 것은
  // 다음 focus 에 스스로 낫지만 박힌 스탬프는 안 낫는다 — 사람이 수백 줄에서 손으로
  // 찾아 지워야 한다. 되돌릴 수 없는 쪽이라 여기가 진짜 결함 자리다.
  //
  // 여기서 지키는 계약:
  //   - '루프 종료' 는 찍기 전에 보드를 **강제로** 다시 읽는다(60초 스로틀을 건너뛴다).
  //     배경 폴링이 아니라 사람이 뜻을 담아 누른 한 번이라 스로틀의 근거가 없다
  //   - 강제 조회가 실패했는데 낡은 보드 지식이 있으면 **아무것도 안 찍는다**.
  //     안 찍으면 사람이 다시 누르면 그만이고, 찍으면 디스크에 영구히 남는다
  //   - 보드 지식이 아예 없으면(스텁·오프라인) 지금처럼 숫자 폴백 — 다른 체계다
  //   - 왜 안 됐는지는 le 라벨과 disabled 로 말한다(배너 없음 — 앱 규칙)
  const pad = (pg) => ({
    set: (s) => pg.evaluate((s) => CMMemo.setText(s), s),
    text: () => pg.evaluate(() => CMMemo.text()),
    last: () => pg.evaluate(() => window.__saved[window.__saved.length - 1] || ''),
    saved: () => pg.evaluate(() => window.__saved.length),
    board: (b) => pg.evaluate((b) => { window.__board = b; }, b),
    bump: (ms) => pg.evaluate((ms) => { window.__skew += ms; }, ms),
    focus: () => pg.evaluate(() => { window.dispatchEvent(new Event('focus')); }),
    label: () => pg.evaluate(() => document.querySelector('[data-cmmemo-view-cr]').textContent),
    // 콤보를 연다(이미 열려 있으면 그대로 둔다 — 같은 버튼은 토글이라 닫혀 버린다).
    open: async () => {
      await pg.evaluate(() => {
        const m = document.querySelector('.cmmemo-menu');
        if (m && m.dataset.view === '1') return;
        document.querySelector('[data-cmmemo-view]')
          .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
      });
      await pg.waitForFunction(() => {
        const m = document.querySelector('.cmmemo-menu');
        return !!m && m.dataset.view === '1';
      });
    },
    // '루프 종료' 버튼의 지금 라벨과 잠김 여부.
    le: () => pg.evaluate(() => {
      const m = document.querySelector('.cmmemo-menu');
      if (!m || m.dataset.view !== '1') return null;
      const b = Array.from(m.querySelectorAll('button'))
        .find((x) => x.textContent.indexOf('루프 종료') === 0);
      return b ? { t: b.textContent, off: !!b.disabled } : null;
    }),
    // 진짜 사람과 같은 경로 — mousedown 핸들러가 le.disabled 를 스스로 본다.
    press: () => pg.evaluate(() => {
      const m = document.querySelector('.cmmemo-menu');
      const b = Array.from(m.querySelectorAll('button'))
        .find((x) => x.textContent.indexOf('루프 종료') === 0);
      b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    }),
  });
  // 메모를 새로 깔고, 그 판이 서버에 한 번 저장된 것까지 확인한다(그 뒤의 저장이
  // '루프 종료가 만든 저장' 임을 분명히 하기 위해).
  const seed = async (P, pg, body) => {
    await P.set(body);
    await pg.evaluate(() => CMMemo.flush());
    await pg.waitForFunction((k) => window.__saved.some((t) => t.indexOf(k) >= 0),
      body.split('\n')[0].replace(/^- \[.\] /, ''), { timeout: 4000 });
    await pg.waitForTimeout(600);          // setText 의 400ms 디바운스까지 지나 보낸다
  };
  const stamped = (t) => { const m = /@루프: (\S+)/.exec(t); return m ? m[1] : null; };

  const pg = await browser.newPage();
  await pg.setContent(html);              // 보드 v1(26-49)이 마운트 시점에 있다
  await pg.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
  const A = pad(pg);
  await pg.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-49');

  // 7a. 보드가 26-49 면 '루프 종료' 가 26-49 를 박는다
  await seed(A, pg, ['- [x] 첫 루프에서 끝낸 일', '    @생성: ' + stamp(NOW), ''].join('\n'));
  await A.open();
  eq('7a-0. 누르기 전 라벨은 평소 라벨', (await A.le()).t, '루프 종료 — 완료 1건을 이전 루프로');
  await A.press();
  await pg.waitForFunction(() => CMMemo.text().indexOf('@루프: ') >= 0, null, { timeout: 4000 })
    .catch(() => {});
  await pg.evaluate(() => CMMemo.flush());
  await pg.waitForFunction(() => (window.__saved[window.__saved.length - 1] || '').indexOf('@루프: ') >= 0,
    null, { timeout: 4000 }).catch(() => {});
  eq('7a. 보드가 26-49 면 저장 텍스트에 @루프: 26-49 가 박힌다', stamped(await A.last()), '26-49');

  // 7b. **이번 수정의 핵심** — 보드가 26-51 로 바뀌었고 focus 도 없고 스로틀 창 안이다.
  // 그래도 박히는 것은 26-51 이어야 한다. 표찰은 아직 26-49 인 채로(= 강제 조회를
  // loopEnd 가 스스로 하지 않으면 26-49 가 박힌다) 눌러 그 축만 정확히 잰다.
  await seed(A, pg, ['- [x] 다음 루프에서 끝낸 일', '    @생성: ' + stamp(NOW), ''].join('\n'));
  await A.board(BOARD2);                  // 보드는 26-51. 시계는 안 민다, focus 도 안 쏜다.
  await A.open();
  eq('7b-0. 누르기 직전 헤더 표찰은 아직 낡아 있다(스로틀 창 안)', await A.label(), '26-49');
  await A.press();
  await pg.waitForFunction(() => CMMemo.text().indexOf('@루프: ') >= 0, null, { timeout: 4000 })
    .catch(() => {});
  await pg.evaluate(() => CMMemo.flush());
  await pg.waitForFunction(() => (window.__saved[window.__saved.length - 1] || '').indexOf('@루프: ') >= 0,
    null, { timeout: 4000 }).catch(() => {});
  eq('7b. focus 없이 스로틀 창 안에서 눌러도 지금 보드 코드(26-51)가 박힌다',
     stamped(await A.last()), '26-51');
  eq('7b-1. 강제 조회가 실제로 돌았으니 헤더도 새 코드로 따라와 있다', await A.label(), '26-51');

  // 7c. 보드 조회가 실패하는데 낡은 지식은 있다 → 아무것도 안 박힌다
  await seed(A, pg, ['- [x] 못 묻을 완료', '    @생성: ' + stamp(NOW), ''].join('\n'));
  await A.board(null);                    // /data.json 이 reject 한다
  await A.open();
  eq('7c-0. 누르기 전에는 평소 라벨이고 눌린다', (await A.le()).t, '루프 종료 — 완료 1건을 이전 루프로');
  const cTxt = await A.text(), cSaved = await A.saved();
  await A.press();
  await pg.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m) return false;
    const b = Array.from(m.querySelectorAll('button'))
      .find((x) => x.textContent.indexOf('루프 종료') === 0);
    return !!b && b.textContent.indexOf('못 받았다') >= 0;
  }, null, { timeout: 4000 }).catch(() => {});
  await pg.waitForTimeout(700);           // 저장 디바운스가 돌 시간까지 준다
  eq('7c-1. 저장 텍스트가 한 글자도 안 바뀐다', await A.text(), cTxt);
  eq('7c-2. 새 저장이 하나도 안 생긴다', await A.saved(), cSaved);
  eq('7c-3. 버튼이 잠기고 라벨이 이유를 말한다', await A.le(),
     { t: '루프 종료 — 보드를 못 받았다. 다시 눌러 달라', off: true });
  // 다음 성공한 조회에서 평소 라벨로 돌아온다 — 막다른 골목을 만들지 않는다.
  await A.board(BOARD2);
  await A.bump(61000);
  await A.focus();
  await pg.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m) return false;
    const b = Array.from(m.querySelectorAll('button'))
      .find((x) => x.textContent.indexOf('루프 종료') === 0);
    return !!b && b.textContent.indexOf('못 받았다') < 0;
  }, null, { timeout: 4000 }).catch(() => {});
  eq('7c-4. 다음 성공한 조회에서 평소 라벨로 돌아온다', await A.le(),
     { t: '루프 종료 — 완료 1건을 이전 루프로', off: false });

  // 7d. 보드 지식이 아예 없으면(스텁) 지금처럼 숫자 폴백 — 기존 동작 불변
  const pgs = await browser.newPage();
  await pgs.setContent(mkHtml(null));     // 마운트 때부터 /data.json 이 reject 한다
  await pgs.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
  const S = pad(pgs);
  eq('7d-0. 보드를 모르면 헤더는 숫자를 지어내지 않는다', await S.label(), '루프');
  await seed(S, pgs, ['- [x] 스텁에서 끝낸 일', '    @생성: ' + stamp(NOW), ''].join('\n'));
  await S.open();
  await S.press();
  await pgs.waitForFunction(() => CMMemo.text().indexOf('@루프: ') >= 0, null, { timeout: 4000 })
    .catch(() => {});
  await pgs.evaluate(() => CMMemo.flush());
  await pgs.waitForFunction(() => (window.__saved[window.__saved.length - 1] || '').indexOf('@루프: ') >= 0,
    null, { timeout: 4000 }).catch(() => {});
  eq('7d. 보드 지식이 없으면 숫자 폴백으로 박힌다', stamped(await S.last()), '1');


  // ── 8. 사람 동작 없이도 보드가 따라온다 — 30초 폴링 ─────────────────────
  // 왜 이 절이 있나(2026-08-29, 사람이 같은 것을 두 번째로 봄): 보드 26-52 / 패드 헤더 26-51.
  // 1~7 절이 전부 통과하는 동안에도 이 화면이 남은 이유는, boardFetch 를 부르는 자리가
  // mount·openView·refresh(focus/visibilitychange)·loopEnd 넷뿐이고 **전부 사람 동작에
  // 매여 있어서**다. 그런데 사람은 앱 *안에서* 루프를 끝낸다 — 그 동작은 창 수준 focus 도
  // visibilitychange 도 만들지 않는다. 값을 바꾸는 바로 그 행동이, 갱신을 일으키지 않는
  // 유일한 행동이었다. 주기가 길었던 게 아니라 주기가 아예 없었다.
  //
  // 여기서 지키는 계약:
  //   - 패드를 마운트하면 30초 간격 타이머가 **정확히 하나** 걸린다(모듈의 유일한 setInterval)
  //   - 그 틱 하나가 focus 도 콤보도 없이 헤더를 새 보드로 끌고 온다 ← 이번 수정의 핵심
  //   - 60초 스로틀은 그대로다 — 30초 틱 한 번으로는 아직 못 넘는다(실제 요청 ≤ 분당 1회)
  //   - document.hidden 이면 틱은 아무 요청도 내지 않는다
  //   - 틱은 이번 루프의 줄을 감출 수 없고 저장 텍스트를 한 글자도 안 바꾼다
//     (4·5 절의 계약을 폴링에도)
  //   - 패드가 없는 페이지에서는 타이머 자체가 안 걸린다
  //
  // 30초를 실제로 기다리지 않는다 — 하네스가 setInterval 을 가로채 콜백을 붙잡아 두고,
  // 여기서 손으로 한 틱씩 돌린다. 시간은 다른 절과 같은 손잡이(__skew)로 민다.
  const pgP = await browser.newPage();
  await pgP.setContent(mkHtml(BOARD2));            // 마운트 시점 보드 = 26-51
  await pgP.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);
  const B = pad(pgP);
  const tick = () => pgP.evaluate(() => { window.__ticks.forEach((f) => f()); });
  const hits = () => pgP.evaluate(() => window.__dataHits);
  const bvis = () => pgP.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' ? '0' : '1').join(''));
  const bshown = () => pgP.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .filter((r) => getComputedStyle(r).display !== 'none')
      .map((r) => r.querySelector('.cmm-tx').textContent));

  // 가로챈 것이 진짜 배송 타이머인지 — 모듈이 건 간격을 전부 남겨 두고 확인한다.
  // MemoPad 모듈의 setInterval 은 이 하나뿐이라, 목록이 [30000] 이면 붙잡은 콜백이
  // 곧 배송 코드의 그 타이머다(동작은 8b 가 다시 확인한다 — 틱이 /data.json 을 친다).
  eq('8-0a. 모듈이 건 간격은 30초 하나뿐이다', await pgP.evaluate(() => window.__ivals), [30000]);
  eq('8-0b. 붙잡은 콜백은 정확히 하나', await pgP.evaluate(() => window.__ticks.length), 1);

  // 8-1. 마운트 시점 보드가 26-51 이면 헤더도 26-51
  await pgP.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-51');
  eq('8-1. 마운트 보드가 26-51 이면 헤더 26-51', await B.label(), '26-51');

  // 4·5 절과 같은 메모를 깔아 둔다. 마운트 보드가 이미 26-51 이고 26-49 컷이 한 시간
  // 전이라, 이틀 전에 적은 두 줄은 그 루프에 묻혀 있다(묻힌 완료 한 줄까지 = vis 00011).
  // 이 절이 재는 것은 '틱이 이 화면을 바꾸는가' 이므로 출발선이 무엇이든 상관없다.
  await seed(B, pgP, MEMO);
  const pVis = await bvis(), pShown = await bshown();
  const pText = await B.text(), pSaved = await B.saved();
  eq('8-1b. 틱 전: 이번 루프의 줄만 보인다', pVis, '00011');

  // 8-2. 보드를 26-52 로 갈고 **focus 도 안 쏘고 콤보도 안 열고** 틱만 돌린다.
  await B.board(BOARD5);
  const h0 = await hits();
  await B.bump(30000);                             // 틱 한 번 = 30초. 아직 스로틀 안이다.
  await tick();
  await pgP.waitForTimeout(250);
  eq('8-2a. 30초 틱 한 번은 60초 스로틀을 못 넘는다 — 요청이 안 나간다', await hits(), h0);
  eq('8-2b. 그래서 헤더도 아직 26-51', await B.label(), '26-51');
  await B.bump(31000);                             // 두 번째 틱 = 61초. 이제 넘는다.
  await tick();
  await pgP.waitForFunction(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent === '26-52', null, { timeout: 3000 })
    .catch(() => {});
  eq('8-2. focus 없이·콤보 안 열고 틱만 돌려도 헤더가 26-52 로 따라온다', await B.label(), '26-52');
  check('8-2c. 그 틱이 실제로 /data.json 을 쳤다', (await hits()) === h0 + 1,
        'hits=' + (await hits()) + ' h0=' + h0);

  // 8-3. 숨어 있는 동안의 틱은 아무 요청도 내지 않는다.
  //      (돌아오는 순간 visibilitychange 가 이미 refresh() 를 부르므로 손해가 없다.)
  await pgP.evaluate(() => { Object.defineProperty(document, 'hidden',
    { get: function(){ return true; }, configurable: true }); });
  await B.board(BOARD6);                           // 보드는 26-54 로 또 넘어갔다
  await B.bump(61000);                             // 스로틀은 넘었다 — 막는 것은 hidden 뿐
  const h1 = await hits();
  await tick();
  await pgP.waitForTimeout(300);
  eq('8-3a. document.hidden 이면 틱이 요청을 내지 않는다', await hits(), h1);
  eq('8-3b. 그래서 보드를 갈아도 헤더가 안 변한다', await B.label(), '26-52');
  await pgP.evaluate(() => { Object.defineProperty(document, 'hidden',
    { get: function(){ return false; }, configurable: true }); });

  // 8-4. 폴링은 줄을 감출 수 없고 저장 텍스트를 건드리지 않는다(4·5 절의 계약 그대로).
  eq('8-4a. 틱 전후로 어느 줄의 가시성도 변하지 않는다', await bvis(), pVis);
  eq('8-4b. 보이는 줄 문자열이 틱 직전과 정확히 같다', await bshown(), pShown);
  eq('8-4c. 틱 전후 저장 텍스트가 한 글자도 안 바뀐다', await B.text(), pText);
  eq('8-4d. 틱이 새 저장을 만들지 않는다', await B.saved(), pSaved);

  // 8-5. 패드가 없는 페이지에서는 타이머를 걸지 않는다(boot 의 pads.length 가드).
  //      아무도 안 보는 화면을 위해 /data.json 을 30초마다 치면 안 된다.
  const pgZ = await browser.newPage();
  await pgZ.setContent('<!doctype html><meta charset=utf-8>'
    + '<script>'
    + '(function(){ var st={}; Object.defineProperty(window,"localStorage",{ value:{'
    + '  getItem:function(k){ return k in st ? st[k] : null; },'
    + '  setItem:function(k,v){ st[k]=String(v); },'
    + '  removeItem:function(k){ delete st[k]; } } }); })();'
    + '(function(){ window.__ticks=[]; window.__ivals=[]; var si=window.setInterval;'
    + '  window.setInterval=function(fn,ms){ window.__ivals.push(ms);'
    + '    if(ms===30000){ window.__ticks.push(fn); return 0; } return si.apply(this,arguments); }; })();'
    + 'window.__dataHits=0;'
    + 'window.fetch=function(u){ if(String(u).indexOf("/data.json")>=0) window.__dataHits++;'
    + '  return Promise.resolve({json:function(){ return Promise.resolve({}); }}); };'
    + '</scr'+'ipt>'
    + '<body><script>' + PAD_JS + '</scr'+'ipt></body>');   // 마크업 없음 = 마운트할 패드가 없다
  await pgZ.waitForFunction(() => !!window.CMMemo);
  eq('8-5a. 패드가 없으면 모듈은 아무 타이머도 안 건다', await pgZ.evaluate(() => window.__ivals), []);
  eq('8-5b. 패드가 없으면 마운트 조회도 없다', await pgZ.evaluate(() => window.__dataHits), 0);
  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
