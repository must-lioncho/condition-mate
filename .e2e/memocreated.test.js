// E2E for 메모장 '생성 날짜' 축 — 사람이 스스로 좁힐 때만 쓰는 도구.
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 여기서 지키는 계약:
//   - 감추는 축은 루프 하나다(2026-08-29). 생성 날짜는 기본에서 아무것도 감추지 않고,
//     그 기본 상태의 이름은 '해제' 다 — 'all' 이 곧 해제이고 다섯 번째 값을 두지 않았다.
//     라디오 목록에는 좁힘 셋(오늘만·어제부터·최근 7일)만 오른다
//   - '해제' 행에는 숫자가 붙지 않는다. 체크 옆에 큰 숫자가 서 있으면 아무것도 안 감추는
//     상태인데도 '날짜가 걸려 있다' 로 읽힌다 — 이번 건이 시작된 자리다
//   - 절 소제목이 이 축의 상태를 말한다(헤더 표찰은 감추고 있는 축, 즉 루프를 말한다)
//   - 항목 옆 숫자의 약속은 '이걸 고르면 몇 줄이 보이나' 다. 그래서 루프 축이 지금 감추고
//     있는 줄(@루프로 묻힌 줄)은 세지 않는다 — 모집단은 CSS 가 쓰는 조건과 똑같다
//   - 지난 루프를 보는 중에는 이 절이 쉰다(paint 가 cx 를 안 단다) — 그러면 메뉴도 눌리지
//     않아야 한다. 눌러도 아무 일이 없는 항목은 켜져 있는 척하는 것이다
//   - 감춤은 CSS 만 — 저장 텍스트는 한 글자도 바뀌지 않는다
//   - 빈 줄은 어느 축에서도 안 감춰진다(이어 쓸 자리)
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<script>
// setContent 하네스는 origin 이 없어 진짜 localStorage 가 접근 즉시 던진다. 메모리 판으로
// 갈아 끼운다(모듈 코드는 손대지 않는다). 완료도 보이는 채로 시작한다 — 날짜 축이 상태
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
  // 날짜 절의 소제목 — 이 축이 지금 걸려 있는지 아닌지를 글로 말하는 자리.
  const crTitle = () => page.evaluate(() => {
    const e = document.querySelector('.cmmemo-menu [data-why="cr"]');
    return e ? e.textContent : null;
  });
  const menu = () => page.evaluate(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.view !== '1') return null;
    return Array.from(m.querySelectorAll('button')).map((b) => {
      const t = b.querySelector('b'), c = b.querySelector('em');
      return { label: t ? t.textContent : b.textContent, cnt: c ? c.textContent : '',
               checked: b.getAttribute('aria-checked'), disabled: b.disabled };
    });
  });
  const CR = ['해제', '오늘만', '어제부터', '최근 7일'];
  // 날짜 절 네 행만 뽑아 이름 순서 그대로. 다른 절의 버튼과 섞이지 않게 이름으로 고른다.
  const crRows = async () => {
    const m = await menu();
    return CR.map((n) => m.filter((o) => o.label === n)[0] || null);
  };
  const cnts = async () => (await crRows()).map((o) => (o ? o.cnt : null));
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
  // 낯빛만 흐린 것이 아니라 실제로 막혔는지 — disabled 검사를 건너뛰고 그대로 누른다.
  const forceClick = (prefix) => page.evaluate((prefix) => {
    const m = document.querySelector('.cmmemo-menu');
    const b = Array.from(m.querySelectorAll('button')).find((x) => {
      const t = x.querySelector('b');
      return (t ? t.textContent : x.textContent).indexOf(prefix) === 0;
    });
    if (!b) return false;
    b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    return true;
  }, prefix);

  // 보드: 컷이 두 번(26-45 는 사흘 전, 26-46 은 어제). 지금 열려 있는 루프는 26-47.
  // 컷은 그날 줄을 적고 **2분 뒤**에 일어난 것으로 둔다(2026-08-30). 그전에는 컷 시각을
  // 줄의 생성 시각과 똑같이 잡고 있었는데, 그건 실제로 있을 수 없는 배치이면서(줄을 적은
  // 바로 그 순간에 컷을 눌렀다는 뜻) 하필 이 결함의 한복판이다 — 생성 스탬프는 분 단위라
  // 그 분 안에서 줄이 컷 앞인지 뒤인지 말해 주지 않는다. 이제 패드는 그 모호한 줄을 묻지
  // 않으므로(loopOf), 시험이 재려는 것(어제 적어 어제 컷에 묻힌 줄)을 그대로 재려면
  // 컷이 생성 분보다 확실히 뒤여야 한다.
  await page.evaluate(([a, b]) => { window.__board = { review: {
    goals: [],
    sprints: [{ number: 47, code: '26-47', closed: false },
              { number: 46, code: '26-46', closed: true }],
    releases: [{ id: 'r2', code: '26-46', releasedAt: b },
               { id: 'r1', code: '26-45', releasedAt: a }],
  } }; }, [NOW - 3 * DAY + 120, NOW - DAY + 120]);

  // 메모 8줄. 루프에 묻힌 줄(@루프) 셋을 날짜별로 흩어 두는 것이 이 시험의 핵심이다 —
  // 날짜 숫자가 그 셋을 세는지 안 세는지가 판정의 전부다.
  //   1 오늘  미완료               (안 묻힘)
  //   2 오늘  완료·@루프 26-46     (묻힘)
  //   3 어제  미완료               (안 묻힘)
  //   4 어제  완료·@루프 26-46     (묻힘)
  //   5 사흘전 평문                (안 묻힘)
  //   6 사흘전 완료·@루프 26-45    (묻힘)
  //   7 '이전' — 이 기능 전부터 있던 글(언제인지 알 수 없다)
  //   8 빈 줄 — 이어 쓸 자리
  const MEMO = [
    '- [ ] 오늘 미완료', '    @생성: ' + stamp(NOW),
    '- [x] 오늘 묻은 일', '    @루프: 26-46', '    @생성: ' + stamp(NOW),
    '- [ ] 어제 미완료', '    @생성: ' + stamp(NOW - DAY),
    '- [x] 어제 묻은 일', '    @루프: 26-46', '    @생성: ' + stamp(NOW - DAY),
    '사흘 전 평문', '    @생성: ' + stamp(NOW - 3 * DAY),
    '- [x] 사흘 전 묻은 일', '    @루프: 26-45', '    @생성: ' + stamp(NOW - 3 * DAY),
    '한참 전 글', '    @생성: 이전',
    ''].join('\n');
  await set(MEMO);

  // ── 기본(보드를 아직 못 받은 상태) ─────────────────────────────────────
  // 루프 축만 감춘다 — 날짜는 아무 줄도 안 자른다. 지금 도는 루프 코드를 아직 모르므로
  // 감추는 것은 묻힌 셋(2·4·6)뿐이다. 보드가 도착하면 지난 루프의 줄도 함께 묻힌다
  // (2026-08-30) — 아래 5b·6d 가 그 상태를 본다.
  eq('보드 이전 기본: 날짜는 아무것도 감추지 않는다 (묻힌 셋만 빠진다)', await vis(), '10101011');

  await openView();                                   // 열면서 보드를 게으르게 청한다
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    return m && Array.from(m.querySelectorAll('b')).some((e) => e.textContent === '26-46');
  });

  // 1. 기본 상태에서 좁힘 셋은 아무것도 안 골라져 있고 '해제' 만 서 있다.
  eq('1) 기본은 해제 — 좁힘 셋에는 표가 서지 않는다',
    (await crRows()).map((o) => o.checked), ['true', 'false', 'false', 'false']);
  eq("'전체' 라는 다섯 번째 값은 없다",
    (await menu()).filter((o) => o.label === '전체').length, 0);
  eq('저장 키는 아직 사람이 만진 적 없다',
    await page.evaluate(() => window.__ls.cmMemoCr2), undefined);

  // 2. 소제목이 '안 걸림' 이라고 말한다 — 헤더 표찰은 감추고 있는 축(루프)을 말하므로,
  //    날짜가 걸렸는지 아닌지는 여기서만 읽힌다. 소제목은 상태만 말하고 숫자는 안 적는다
  //    (2026-08-29): 모집단을 적으면 좁힌 상태에서 거짓이 되고, 체크된 항목 옆 숫자와 겹친다.
  eq('2) 소제목이 안 걸림을 말한다', await crTitle(), '생성 날짜 — 안 걸림');
  eq('2b) 소제목에는 숫자가 하나도 없다', /[0-9]/.test(await crTitle()), false);
  eq('헤더 표찰은 그대로 지금 도는 루프를 말한다', await label(), '26-47');

  // 3. '해제' 행에는 숫자가 없다 — 이번 건이 시작된 자리.
  eq('3) 해제 옆에는 숫자가 붙지 않는다', (await crRows())[0].cnt, '');

  // 4. 좁힘 항목의 숫자는 루프 축이 감춘 줄을 세지 않는다. 보드를 받은 지금 루프 축이
  //    감추는 것은 '지난 루프의 줄' 전부다(2026-08-30): 묻힌 셋(2·4·6)에 더해, 컷보다
  //    앞서 만든 3(어제 미완료)·5(사흘 전 평문)까지 다섯 줄. 남는 것은 오늘 만든 1 과
  //    루프를 알 수 없는 7('@생성: 이전' — 날짜 축이 세지 않는다) 뿐이다.
  //    기본:                 오늘 1 · 어제부터 1 · 최근 7일 1
  //    '이전 루프 포함'(전부): 오늘 2 · 어제부터 4 · 최근 7일 6
  //    차이가 정확히 루프 축이 감춘 줄 수다.
  const cDefault = await cnts();
  eq('4a) 기본 숫자는 지난 루프의 줄을 안 센다', cDefault, ['', '1', '1', '1']);
  await menuClick('이전 루프 포함');
  const cAllLoops = await cnts();
  eq('4b) 이전 루프까지 펴면 묻힌 줄만큼 늘어난다', cAllLoops, ['', '2', '4', '6']);
  eq('4c) 늘어난 몫이 곧 루프 축이 감춘 줄 수다',
    cAllLoops.slice(1).map((v, i) => +v - +cDefault[i + 1]), [1, 3, 5]);
  // 숫자가 바뀌는 자리는 항목 오른쪽뿐이다 — 소제목은 루프 축을 펴도 글이 그대로다.
  eq('4d) 루프 축을 펴도 소제목은 그대로다', await crTitle(), '생성 날짜 — 안 걸림');
  await menuClick('현재 루프만');                      // 기본으로 되돌린다
  eq('되돌리면 숫자도 되돌아온다', await cnts(), ['', '1', '1', '1']);

  // 5. 좁혔다가 '해제' 로 푼다 — 'all' 이 곧 해제다(다섯 번째 값 없음).
  await menuClick('오늘만');
  eq('5a) 오늘만: 오늘 만든 줄과 빈 줄만 남는다', await vis(), '10000001');
  eq('좁힌 값은 새 키에 남는다',
    await page.evaluate(() => window.__ls.cmMemoCr2), '');
  // 좁힌 상태에서도 소제목은 고른 항목 이름을 말한다 — 감추고 있는 축을 숨기지 않는다.
  eq('좁히면 소제목이 고른 이름을 말한다', await crTitle(), '생성 날짜 — 오늘만');
  eq('좁힌 상태에서도 소제목에 숫자는 없다', /[0-9]/.test(await crTitle()), false);
  eq('좁혀 두면 헤더 표찰이 그 범위를 말한다', await label(), '오늘');
  eq('오늘만에 표가 서고 해제는 풀린다',
    (await crRows()).map((o) => o.checked), ['false', 'true', 'false', 'false']);
  await menuClick('해제');
  // 보드를 받은 뒤라 루프 축이 지난 루프의 줄을 전부 감추고 있다 — 날짜를 풀어도
  // 돌아오는 것은 이번 루프의 줄(1)과 루프를 모르는 줄(7), 그리고 빈 줄이다.
  eq('5b) 해제하면 날짜가 감춘 줄이 다 돌아온다', await vis(), '10000011');
  eq("5c) 해제는 다섯 번째 값이 아니라 'all' 이다",
    await page.evaluate(() => window.__ls.cmMemoCr2), 'all');
  eq('해제하면 헤더 표찰은 다시 루프로 돌아간다', await label(), '26-47');
  eq('저장 텍스트는 한 글자도 바뀌지 않는다', await text(), MEMO);

  // 6. 지난 루프를 보는 중에는 날짜 절이 쉰다 — 네 행이 전부 잠기고 소제목이 그렇게 말한다.
  await menuClick('26-46');
  eq('26-46 의 줄만 남는다(빈 줄은 이어 쓸 자리로 남는다)', await vis(), '01110001');
  eq('6a) 날짜 절 네 행이 전부 잠긴다',
    (await crRows()).map((o) => o.disabled), [true, true, true, true]);
  eq('6b) 소제목이 쉰다고 말한다', await crTitle(), '생성 날짜 — 지난 루프를 보는 중에는 쉰다');
  // 낯빛만이 아니라 실제로도 막혔다 — 잠긴 항목을 그대로 눌러도 아무 일이 없어야 한다.
  await forceClick('오늘만');
  eq('6c) 잠긴 항목은 눌러도 아무 일이 없다',
    [await vis(), await page.evaluate(() => window.__ls.cmMemoCr2)], ['01110001', 'all']);
  await menuClick('26-46');                            // 들어간 문이 곧 나오는 문
  eq('6d) 현재 루프로 돌아오면 절이 다시 깨어난다',
    (await crRows()).map((o) => o.disabled), [false, false, false, false]);
  eq('돌아온 화면은 기본 그대로', await vis(), '10000011');

  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
