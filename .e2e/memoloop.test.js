// E2E for 메모장 루프 — "어제 완료한 것" 을 날짜가 아니라 루프(작업 사이클) 단위로 묻는다.
// 보기 콤보의 '루프 종료' 가 완료 줄에 '@루프: N' 을 찍고, 스탬프 줄은 기본(현재 루프)
// 보기에서 사라진다. '이전 루프 포함' 으로 언제든 다시 본다.
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 여기서 지키는 계약:
//   - 저장 문법은 '@골' 과 같은 들여쓴 줄(@루프: <코드>) — 파싱→재직렬화가 항등이다
//   - 스탬프는 완료 줄에서만 스탬프다. 미완료 줄 밑의 @루프 는 상세 줄로 남는다
//     (스탬프로 읽으면 그 줄이 기본 보기에서 사라진다 — 글을 버리지 않는 쪽으로)
//   - 감춤은 CSS(data-lp)만 — 텍스트도 골번호도 그대로다
//   - '이전 루프 포함' 은 완료 체크와 다른 축 — 완료를 꺼도 이전 루프는 보인다
//   - 보기 콤보의 상태 개수는 현재 루프만 센다
//   - 루프 번호는 보드(/data.json)의 스프린트/릴리즈 코드와 한 일련번호 —
//     현재 = 열린 스프린트 코드(26-38), 이전 = 최신 릴리즈 코드(26-37).
//     보드를 모르는 환경(스텁·오프라인)에서만 숫자 스탬프 최대+1 폴백(#N)
//   - '루프 종료' 는 편집 한 단계 — ⌘Z 로 그대로 돌아온다
//   - 완료에서 상태를 되돌리면 스탬프가 떨어져 현재 루프로 복귀한다
//   - 선택은 localStorage(cmMemoLoop)에 남는다
const { chromium } = require('playwright');
const { PAD_HTML } = require('./memosrc');

const html = `<!doctype html><meta charset=utf-8>
<script>
// setContent 하네스는 origin 이 없어 진짜 localStorage 가 접근 즉시 던진다. 완료 보기를
// 켠 채 시작해야 루프 축이 상태 축과 별개임을 확인할 수 있으니, 모듈이 뜨기 전에
// 메모리 판으로 갈아 끼운다(모듈 코드는 손대지 않는다).
(function(){
  var store = { cmMemoView: 'todo,done,block' };
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
// /api/memo 를 메모리로 — 저장이 화면 동작에 영향을 주지 않도록 조용히 성공시킨다.
window.__saved=[];
// /data.json 은 시험 단계가 정한다 — null 이면 실패(보드 없는 환경 = 숫자 폴백),
// 값을 넣으면 그 보드(스프린트/릴리즈 코드)로 응답한다.
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

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent(html);
  await page.waitForFunction(() => window.CMMemo && CMMemo.count() > 0);

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  const text = () => page.evaluate(() => CMMemo.text());
  // 각 행의 표시 여부 — '1'=보임 '0'=감춤. computed display 로 CSS 까지 확인한다.
  const vis = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' ? '0' : '1').join(''));
  const lps = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => r.dataset.lp || '-').join('|'));
  const openView = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-view]')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })));
  const menu = () => page.evaluate(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.view !== '1') return null;
    return { title: Array.from(m.querySelectorAll('.cmm-vt')).map((t) => t.textContent),
             items: Array.from(m.querySelectorAll('button')).map((b) => {
               const t = b.querySelector('b'), c = b.querySelector('em');
               return { label: t ? t.textContent : b.textContent, cnt: c ? c.textContent : '',
                        checked: b.getAttribute('aria-checked'), disabled: b.disabled };
             }) };
  });
  // 라벨 앞부분으로 찾는다 — '루프 종료 — 완료 N건…' 은 개수가 라벨에 살아 있다.
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
  const row = (i, sel) => page.evaluate(([i, sel]) => {
    const r = document.querySelectorAll('[data-cmmemo-doc] .cmm-row')[i];
    r.querySelector(sel).dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }, [i, sel]);

  const MEMO = ['- [ ] 진행 중 일',
                '- [x] 이번 루프에 끝낸 일',
                '- [!] 막힌 일',
                '- [x] 지난 루프에 끝낸 일', '    @루프: 1',
                '평문 메모', ''].join('\n');
  await set(MEMO);

  // ── 저장 문법: 항등 왕복 + 스탬프는 행 데이터로 ─────────────────────────
  eq('스탬프 줄이 있어도 파싱→재직렬화는 항등이다', await text(), MEMO);
  eq('스탬프가 행에 실린다 (지난 루프 줄만 lp=1)', await lps(), '-|-|-|1|-|-');

  // ── 기본 = 현재 루프만 ──────────────────────────────────────────────────
  eq('이전 루프 줄만 감춰진다 (완료 보기가 켜져 있어도)', await vis(), '111011');

  // ── 보기 콤보: 개수와 루프 절 ───────────────────────────────────────────
  await openView();
  const m1 = await menu();
  check('보기 콤보가 열린다', !!m1);
  eq('상태 개수는 현재 루프만 센다 (완료 1 — 묻힌 완료는 빠진다)',
    m1.items.filter((o) => ['미완료', '완료', '바틀넥'].indexOf(o.label) >= 0).map((o) => o.label + ':' + o.cnt),
    ['미완료:1', '완료:1', '바틀넥:1']);
  eq('현재 루프만이 기본으로 체크되고 진행 중 번호가 붙는다 (스탬프 최대+1)',
    m1.items.filter((o) => o.label === '현재 루프만').map((o) => o.cnt + ':' + o.checked), ['#2:true']);
  eq('이전 루프 포함 옆에 직전 루프 번호가 보인다 (현재-1)',
    m1.items.filter((o) => o.label === '이전 루프 포함').map((o) => o.cnt + ':' + o.checked), ['#1:false']);
  eq('루프 종료 버튼이 완료 건수와 함께 살아 있다',
    m1.items.filter((o) => o.label.indexOf('루프 종료') === 0).map((o) => o.label + ':' + o.disabled),
    ['루프 종료 — 완료 1건을 이전 루프로:false']);

  // ── 이전 루프 포함 — 상태 축과 다른 축 ──────────────────────────────────
  await menuClick('이전 루프 포함');
  eq('이전 루프 줄이 돌아온다', await vis(), '111111');
  eq('라디오가 넘어간다 (메뉴는 열린 채 되그려진다)',
    (await menu()).items.filter((o) => o.label === '이전 루프 포함').map((o) => o.checked), ['true']);
  await menuClick('완료');                       // 완료 보기 끄기
  eq('완료를 꺼도 이전 루프 줄은 남는다 (이번 루프 완료만 사라진다)', await vis(), '101111');
  await menuClick('완료');                       // 되돌리기
  await menuClick('현재 루프만');
  eq('현재 루프만으로 돌아오면 다시 묻힌다', await vis(), '111011');

  // ── 루프 종료 (보드 없음 = 숫자 폴백) ──────────────────────────────────
  await menuClick('루프 종료');
  eq('완료 줄에 진행 중 루프 번호가 찍힌다', await lps(), '-|2|-|1|-|-');
  eq('저장 텍스트에 @루프 줄이 들어간다',
    (await text()).indexOf('- [x] 이번 루프에 끝낸 일\n    @루프: 2') >= 0, true);
  eq('찍힌 줄은 그 자리에서 묻힌다', await vis(), '101011');
  const m2 = await menu();
  eq('종료 뒤 완료는 0, 이전 루프 번호는 #2, 버튼은 잠긴다',
    [m2.items.filter((o) => o.label === '완료').map((o) => o.cnt)[0],
     m2.items.filter((o) => o.label === '이전 루프 포함').map((o) => o.cnt)[0],
     m2.items.filter((o) => o.label.indexOf('루프 종료') === 0).map((o) => o.disabled)[0]],
    ['0', '#2', true]);
  eq('다음 루프 번호로 넘어간다',
    m2.items.filter((o) => o.label === '현재 루프만').map((o) => o.cnt), ['#3']);
  await page.waitForFunction(() => window.__saved.some((t) => t.indexOf('@루프: 2') >= 0));
  check('스탬프가 서버로 저장된다', true);

  // ── 되돌리기 — 종료도 편집 한 단계 ──────────────────────────────────────
  await page.evaluate(() => CMMemo.undo());
  eq('⌘Z 한 번으로 종료 전으로 돌아온다', await text(), MEMO);
  eq('줄도 돌아온다', await vis(), '111011');

  // ── 완료에서 벗어나면 스탬프가 떨어진다 ─────────────────────────────────
  await set(['- [x] 끝', '    @루프: 1', ''].join('\n'));
  await openView(); await menuClick('이전 루프 포함');   // 눌러 볼 수 있게 꺼내 놓고
  await row(0, '.cmm-ck');                               // done → block
  eq('상태를 되돌리면 스탬프가 떨어진다 (텍스트에서도)', await text(), ['- [!] 끝', ''].join('\n'));
  await openView(); await menuClick('현재 루프만');
  eq('현재 루프로 복귀해 보인다', await vis(), '11');

  // ── 미완료 줄 밑의 @루프 는 스탬프가 아니라 상세다 ──────────────────────
  const ODD = ['- [ ] 미완료 일', '    @루프: 3', ''].join('\n');
  await set(ODD);
  eq('미완료 줄의 @루프 는 상세로 남아 왕복된다', await text(), ODD);
  // 상세로 접혔으니 행은 둘(제목 + 빈 줄)이고, 둘 다 보인다 — 글이 사라지지 않는다.
  eq('스탬프가 아니므로 감춰지지 않는다', await vis(), '11');

  // ── 보드 연동 — 루프 번호는 보드 스프린트/릴리즈 코드와 한 일련번호 ─────
  await page.evaluate(() => { window.__board = {
    goals: [],
    sprints: [{ number: 38, code: '26-38', closed: false }, { number: 37, code: '26-37', closed: true }],
    releases: [{ id: 'r1', code: '26-37' }],
  }; });
  const CODED = ['- [ ] 진행 중 일', '- [x] 이번 루프에 끝낸 일',
                 '- [x] 지난 루프에 끝낸 일', '    @루프: 26-37', ''].join('\n');
  await set(CODED);
  eq('코드 스탬프(26-37)도 왕복 항등', await text(), CODED);
  eq('코드 스탬프가 행에 실린다', await lps(), '-|-|26-37|-');
  eq('코드 스탬프 줄도 기본에서 묻힌다', await vis(), '1101');
  await openView();                                 // 열면서 보드를 게으르게 청한다
  await page.waitForFunction(() => {
    const m = document.querySelector('.cmmemo-menu');
    return m && Array.from(m.querySelectorAll('em')).some((e) => e.textContent === '26-38');
  });
  const m3 = await menu();
  eq('현재 루프 번호 = 열린 스프린트 코드', m3.items.filter((o) => o.label === '현재 루프만').map((o) => o.cnt), ['26-38']);
  eq('이전 루프 번호 = 최신 릴리즈 코드', m3.items.filter((o) => o.label === '이전 루프 포함').map((o) => o.cnt), ['26-37']);
  await menuClick('루프 종료');
  eq('종료는 보드 루프 코드로 찍는다',
    (await text()).indexOf('- [x] 이번 루프에 끝낸 일\n    @루프: 26-38') >= 0, true);
  eq('찍힌 줄은 묻히고 지난 루프 줄과 나란히 남는다', await lps(), '-|26-38|26-37|-');

  // 영속 계약은 소스로 확인한다 — 메모리 상태(loopState)가 진실이고 localStorage 는
  // best-effort 라는 필드 필터의 원칙을 루프도 그대로 따른다.
  const fs = require('fs');
  const PAD = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/MemoPad.swift', 'utf8');
  eq('선택은 localStorage(cmMemoLoop)로 영속을 시도한다',
    /localStorage\.setItem\('cmMemoLoop'/.test(PAD) && /localStorage\.getItem\('cmMemoLoop'\)/.test(PAD), true);

  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
