// E2E for 메모장 '지난 루프 하나 보기' — 끝난 루프의 메모를 통째로 꺼내 본다.
// 보기 콤보의 루프 절에 지난 루프 코드가 줄 수와 함께 나열되고, 하나를 고르면 그 루프의
// 줄만 남는다. SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 여기서 지키는 계약:
//   - 어느 줄이 어느 루프인가 = 묻힌 스탬프(@루프)가 있으면 그 루프, 없으면 만든 시각
//     (@생성)이 어느 컷과 컷 사이였나 — 새 스탬프 없이 판정한다. 그래서 이 기능이 생기기
//     전에 적은 글도 그대로 루프별로 보인다
//   - 목록에는 줄이 있는 지난 루프만 오른다(현재 루프는 위의 라디오가 맡는다)
//   - 고른 루프를 다시 누르면 현재 루프로 돌아온다
//   - 감추는 축은 루프 하나다(2026-08-29) — 생성 날짜는 기본에서 아무것도 감추지 않고,
//     사람이 '오늘만' 을 직접 골랐을 때만 걸린다. 루프가 살아 있는데 날짜가 먼저 잘라
//     패드가 통째로 비어 보이던 사고를 여기서 막는다
//   - 그 기본 상태의 이름은 '해제' 다 — 'all' 이 곧 해제이고 다섯 번째 값을 두지 않았다.
//     라디오 목록에는 좁힘 셋(오늘만·어제부터·최근 7일)만 오르고, 맨 위의 '해제' 를 누르면
//     그 셋에서 풀린다(생성 날짜 축 자체의 시험은 memocreated.test.js)
//   - 지난 루프를 보는 동안에는 그 위에 날짜를 겹치지 않는다 — 고른 것 자체가 이미 '언제' 다
//   - 빈 줄은 지난 루프에서도 남는다(이어 쓸 자리)
//   - 지난 루프를 보는 중에는 '루프 종료' 가 잠긴다(눈앞에 없는 줄을 묻는 액션이므로)
//   - 감춤은 CSS 만 — 저장 텍스트는 한 글자도 바뀌지 않는다
//   - 지난 루프를 펼쳐 둔 채 글을 쓰면 현재 루프로 돌아온다 — 새 줄은 지금 루프의 것이라
//     그대로 두면 방금 친 글자가 그 자리에서 감춰진다('적었는데 사라졌다')
//   - 고른 루프는 세션 안에서만 산다 — localStorage 에는 ''/'all' 만 남는다
//   - 보드는 /data.json 의 'review' 아래에서 읽는다(진짜 앱의 모양) — 맨 위 평평한 모양도
//     계속 받는다(옛 스텁·오프라인)
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<script>
// setContent 하네스는 origin 이 없어 진짜 localStorage 가 접근 즉시 던진다. 메모리 판으로
// 갈아 끼운다(모듈 코드는 손대지 않는다). 완료도 보이는 채로 시작한다 — 루프 축이 상태
// 축과 별개임을 그대로 두고 보기 위해서.
(function(){
  var store = { cmMemoView: 'todo,done,block' };
  window.__ls = store;
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
window.__board=null;
const _f=window.fetch;
window.fetch=function(u,o){
  if(String(u).indexOf('/api/memo')>=0){
    if(o && o.method==='POST'){ window.__saved.push(JSON.parse(o.body).text); return Promise.resolve({json:()=>Promise.resolve({ok:true})}); }
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

// 시각은 지금을 기준으로 만든다 — 달력의 특정 날짜에 묶으면 내일 이 시험이 깨진다.
const DAY = 86400;
const NOW = Math.floor(Date.now() / 1000);
const p2 = (n) => (n < 10 ? '0' : '') + n;
const stamp = (sec) => { const d = new Date(sec * 1000);
  return d.getUTCFullYear() + '-' + p2(d.getUTCMonth() + 1) + '-' + p2(d.getUTCDate())
       + 'T' + p2(d.getUTCHours()) + ':' + p2(d.getUTCMinutes()) + 'Z'; };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(html);
  await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  const text = () => page.evaluate(() => CMMemo.text());
  const vis = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' ? '0' : '1').join(''));
  const label = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view-cr]').textContent);
  const openView = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view]')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })));
  const menu = () => page.evaluate(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.view !== '1') return null;
    return Array.from(m.querySelectorAll('button')).map((b) => {
      const t = b.querySelector('b'), c = b.querySelector('em');
      return { label: t ? t.textContent : b.textContent, cnt: c ? c.textContent : '',
               checked: b.getAttribute('aria-checked'), disabled: b.disabled };
    });
  });
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

  // 보드: 컷이 두 번 있었다(26-45 는 사흘 전, 26-46 은 어제). 지금 열려 있는 루프는 26-47.
  // 모양은 진짜 앱이 주는 그대로 — goals·sprints·releases 는 /data.json 의 'review' 아래에
  // 있다(AppDelegate.reviewJSON). 예전 스텁은 이것을 맨 위에 평평하게 놓아서, 패드가
  // 엉뚱한 자리를 보고 있는데도 시험만 통과하는 상태를 오래 덮고 있었다.
  await page.evaluate(([a, b]) => { window.__board = { review: {
    goals: [],
    sprints: [{ number: 47, code: '26-47', closed: false },
              { number: 46, code: '26-46', closed: true }],
    releases: [{ id: 'r2', code: '26-46', releasedAt: b },
               { id: 'r1', code: '26-45', releasedAt: a }],
  } }; }, [NOW - 3 * DAY, NOW - DAY]);

  // 메모: 이틀 전에 적은 세 줄(= 26-46 루프)과 오늘 적은 한 줄(= 진행 중 26-47).
  // 완료 줄 하나는 이미 26-46 으로 묻혀 있다.
  const MEMO = [
    '- [ ] 어제 못 끝낸 일', '    @생성: ' + stamp(NOW - 2 * DAY),
    '어제 적어 둔 평문 메모', '    @생성: ' + stamp(NOW - 2 * DAY),
    '- [x] 어제 끝낸 일', '    @루프: 26-46', '    @생성: ' + stamp(NOW - 2 * DAY),
    '- [ ] 오늘 할 일', '    @생성: ' + stamp(NOW),
    ''].join('\n');
  await set(MEMO);

  // ── 기본(보드를 아직 못 받은 상태) ─────────────────────────────────────
  // 아직 /data.json 을 청하지 않았으므로 지금 도는 루프 코드를 모른다. 그럴 때는 묻힌
  // 완료 줄(@루프 스탬프)만 감추고 나머지는 손대지 않는다 — 근거 없이 감추면 패드가
  // 통째로 비고 그건 '적었는데 사라졌다' 로 읽힌다(2026-08-30). 날짜도 여기 끼어들지
  // 않는다(2026-08-29 이전에는 '오늘만' 이 먼저 걸려 이 세 줄이 전부 사라졌다).
  // 보드가 도착한 뒤의 기본 보기는 아래 '들어간 문이 곧 나오는 문이다' 가 본다.
  eq('보드 이전 기본 보기: 묻힌 완료만 빠진다', await vis(), '11011');
  // 보드를 아직 못 받은 동안에는 숫자를 지어내지 않는다 — 표찰은 '루프' 로 남는다.
  eq('보드 이전 헤더 표찰', await label(), '루프');

  // ── 콤보에 지난 루프가 오른다 ───────────────────────────────────────────
  await openView();                                   // 열면서 보드를 게으르게 청한다
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    return m && Array.from(m.querySelectorAll('b')).some((e) => e.textContent === '26-46');
  });
  const m1 = await menu();
  eq('지난 루프 26-46 이 줄 수와 함께 오른다',
    m1.filter((o) => o.label === '26-46').map((o) => o.cnt + ':' + o.checked), ['3줄:false']);
  eq('줄이 없는 루프(26-45)는 목록에 없다', m1.filter((o) => o.label === '26-45').length, 0);
  eq('진행 중 루프(26-47)는 목록이 아니라 라디오가 맡는다',
    [m1.filter((o) => o.label === '26-47').length,
     m1.filter((o) => o.label === '현재 루프만').map((o) => o.cnt)[0]], [0, '26-47']);

  // ── 고르면 그 루프의 메모만 남는다 ──────────────────────────────────────
  await menuClick('26-46');
  eq('26-46 의 줄만 보인다 (묻힌 완료 줄도 되살아난다)', await vis(), '11101');
  eq('헤더 표찰이 고른 루프를 말한다', await label(), '26-46');
  eq('저장 텍스트는 한 글자도 바뀌지 않는다', await text(), MEMO);
  const m2 = await menu();
  eq('고른 항목에 표가 서고 현재 루프 라디오는 풀린다',
    [m2.filter((o) => o.label === '26-46').map((o) => o.checked)[0],
     m2.filter((o) => o.label === '현재 루프만').map((o) => o.checked)[0],
     m2.filter((o) => o.label === '이전 루프 포함').map((o) => o.checked)[0]],
    ['true', 'false', 'false']);
  eq('지난 루프를 보는 중에는 루프 종료가 잠긴다',
    m2.filter((o) => o.label.indexOf('루프 종료') === 0).map((o) => o.disabled + '|' + o.label),
    [true + '|루프 종료 — 지난 루프(26-46)를 보는 중']);

  // ── 생성 날짜 축 ──────────────────────────────────────────────────────
  // 기본은 '해제' — 감추는 축은 루프 하나다. 루프를 고른 것 자체가 이미 '언제' 이므로,
  // 그 위에 날짜를 또 걸면 고른 루프가 통째로 비어 버린다. 그래서 지난 루프를 보는
  // 동안에는 이 절이 통째로 잠긴다.
  const m3 = await menu();
  eq('생성 날짜의 기본은 해제 — 좁힘 셋에는 표가 서지 않는다',
    [m3.filter((o) => o.label === '해제').map((o) => o.checked)[0],
     m3.filter((o) => ['오늘만', '어제부터', '최근 7일'].indexOf(o.label) >= 0)
       .map((o) => o.checked).join(',')],
    ['true', 'false,false,false']);
  eq('지난 루프를 보는 중에는 날짜 절이 잠긴다',
    m3.filter((o) => ['해제', '오늘만', '어제부터', '최근 7일'].indexOf(o.label) >= 0)
      .map((o) => o.disabled), [true, true, true, true]);

  // ── 다시 누르면 현재 루프로 ────────────────────────────────────────────
  // 보드를 받은 뒤의 기본 보기는 '이번 루프에 적은 것' 하나다(2026-08-30) — 26-46 의
  // 컷은 어제 일어났으므로 이틀 전에 적은 세 줄은 완료든 미완료든 그 루프에 묻히고,
  // 오늘 적은 줄과 이어 쓸 빈 줄만 남는다. 위쪽 첫 검사('11011')는 보드를 아직 못 받은
  // 상태라 아무것도 감추지 않는 쪽이고, 여기는 받은 뒤라 다른 값이 나오는 것이 맞다.
  await menuClick('26-46');
  eq('들어간 문이 곧 나오는 문이다 — 현재 루프는 오늘 적은 줄뿐', await vis(), '00011');
  eq('헤더 표찰이 지금 도는 루프를 말한다', await label(), '26-47');

  // ── 영속: 고른 루프는 세션 안에서만 산다 ────────────────────────────────
  await menuClick('26-46');
  eq('고른 루프는 localStorage 에 남지 않는다',
    await page.evaluate(() => window.__ls.cmMemoLoop), '');

  // ── 이전 루프 포함으로 넘어가면 고른 루프는 풀린다 ──────────────────────
  await menuClick('이전 루프 포함');
  eq('묻힌 완료까지 전부 보인다', await vis(), '11111');
  eq('헤더 표찰은 지금 도는 루프', await label(), '26-47');
  eq("'all' 은 영속된다", await page.evaluate(() => window.__ls.cmMemoLoop), 'all');
  // 날짜 축은 사라지지 않았다 — 사람이 직접 고르면 그때부터 걸리고, 헤더가 그 사실을
  // 말한다('오늘'). 감추고 있는 축을 헤더가 숨기면 '적었는데 사라졌다' 가 된다.
  await menuClick('오늘만');
  eq('직접 좁히면 그때부터 날짜가 걸린다', await vis(), '00011');
  eq('헤더 표찰이 좁혀 둔 날짜를 말한다', await label(), '오늘');
  eq('좁힌 값은 새 키에 남는다',
    await page.evaluate(() => window.__ls.cmMemoCr2), '');
  await menuClick('해제');                            // 다시 기본으로
  eq('해제하면 다시 다 보인다', await vis(), '11111');

  // ── 쓰기 시작하면 현재 루프로 돌아온다 ──────────────────────────────────
  // 지난 루프를 펼쳐 둔 채 새 줄을 쓰면 그 줄은 '지금 루프' 의 것이라 곧바로 감춰진다.
  // 그 사고를 막으려고, 글을 쓰는 순간 오늘로 돌려보낸다(텍스트는 건드리지 않는다).
  await menuClick('26-46');
  eq('다시 지난 루프를 펼쳐 둔다', await label(), '26-46');
  await caret(4, -1);                                 // 마지막 빈 줄
  await page.keyboard.type('오늘 새로 적는 줄');
  eq('쓰기 시작하면 헤더가 지금 루프로 돌아온다', await label(), '26-47');
  check('방금 친 글이 화면에 남아 있다',
    (await page.evaluate(() => {
      const rs = Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'));
      return rs.filter((r) => getComputedStyle(r).display !== 'none')
               .map((r) => r.querySelector('.cmm-tx').textContent).join('|');
    })).indexOf('오늘 새로 적는 줄') >= 0);

  // ── 보드를 모르는 환경 — 목록은 조용히 비어 있다 ────────────────────────
  await openView();                                   // 타이핑이 콤보를 닫았으니 다시 연다
  await page.evaluate(() => { window.__board = null; });
  const m4 = await menu();
  check('보드가 사라져도 이미 받은 목록은 남고 메뉴는 살아 있다',
    !!m4 && m4.some((o) => o.label === '26-46'));

  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
