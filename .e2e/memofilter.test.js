// E2E for 메모장 필드 필터 — 헤더의 '필터 ▾' 콤보로 담당·팀·프로젝트 '값' 과
// 목표일(오늘)로 줄을 거른다. 보기(상태)와는 다른 축이다.
// SHIPPING 소스(MemoPad.swift, via memosrc)를 실제 Chromium 에 mount 해 굴린다.
//
// 여기서 지키는 계약:
//   - 후보는 지금 메모에 실제로 쓰인 값들 — 사전(서버) 호출 없이 필터가 된다
//   - 같은 칸 안 다중 선택은 OR, 칸이 다르면 AND
//   - 감춤은 CSS(data-fx)만 — 저장 텍스트와 일련번호는 그대로다
//   - 완전히 빈 줄은 거르지 않는다(필터를 걸어 둔 채로도 이어 쓸 자리)
//   - 안 걸려 있으면 숫자 칩이 안 보이고, 걸리면 개수 + 버튼 강조
//   - 목표일 '오늘' 은 화면에 보이는 그 시계(표시 타임존)의 오늘
//   - 선택은 localStorage(cmMemoFlt)에 남는다
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

  const set = (s) => page.evaluate((s) => CMMemo.setText(s), s);
  const text = () => page.evaluate(() => CMMemo.text());
  // 각 행의 표시 여부 — '1'=보임 '0'=필터로 감춤. computed display 로 CSS 까지 확인한다.
  const vis = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('[data-cmmemo-doc] .cmm-row'))
      .map((r) => getComputedStyle(r).display === 'none' && r.dataset.fx ? '0' : '1').join(''));
  const chip = () => page.evaluate(() => {
    const b = document.querySelector('[data-cmmemo-flt]');
    return { on: b.dataset.on === '1', n: b.querySelector('i').textContent,
             chipShown: getComputedStyle(b.querySelector('i')).display !== 'none' };
  });
  const openFlt = () => page.evaluate(() =>
    document.querySelector('[data-cmmemo-flt]')
      .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })));
  const menu = () => page.evaluate(() => {
    const m = document.querySelector('.cmmemo-menu');
    if (!m || m.dataset.flt !== '1') return null;
    return Array.from(m.querySelectorAll('button')).map((b) => {
      const t = b.querySelector('b'), c = b.querySelector('em');
      return { label: t ? t.textContent : b.textContent, cnt: c ? c.textContent : '',
               checked: b.getAttribute('aria-checked'),
               shown: getComputedStyle(b).display !== 'none' };
    });
  });
  const menuClick = (label) => page.evaluate((label) => {
    const m = document.querySelector('.cmmemo-menu');
    const b = Array.from(m.querySelectorAll('button')).find((x) => {
      const t = x.querySelector('b');
      return (t ? t.textContent : x.textContent) === label;
    });
    if (!b) return false;
    b.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
    return true;
  }, label);

  const MEMO = ['- [ ] 결제 붙이기', '    @담당: ismail', '    @프로젝트: NSS',
                '- [ ] 리포트 정리', '    @담당: hyun', '    @프로젝트: NSS',
                '- [x] 배포', '    @담당: ismail',
                '평문 메모', ''].join('\n');
  await set(MEMO);

  // ── 평소에는 조용하다 ────────────────────────────────────────────────────
  eq('필터가 없으면 모든 행이 보인다', await vis(), '11111');
  eq('필터가 없으면 칩도 강조도 없다', await chip(), { on: false, n: '0', chipShown: false });

  // ── 후보 = 지금 메모에 쓰인 값들 ─────────────────────────────────────────
  await openFlt();
  const m1 = await menu();
  check('필터 콤보가 열린다', !!m1);
  eq('담당 후보가 많이 쓴 순으로 나온다 (ismail 2 · hyun 1)',
    m1.filter((o) => ['ismail', 'hyun'].indexOf(o.label) >= 0).map((o) => o.label + ':' + o.cnt),
    ['ismail:2', 'hyun:1']);
  eq('프로젝트 후보도 나온다 (NSS 2)',
    m1.filter((o) => o.label === 'NSS').map((o) => o.cnt), ['2']);
  eq('팀은 값이 없으니 후보 줄이 없다', m1.some((o) => o.label === '팀'), false);
  eq('해제 버튼은 걸린 게 없으면 안 보인다',
    m1.filter((o) => o.label === '필터 해제').map((o) => o.shown), [false]);

  // ── 담당 하나 고르기 ─────────────────────────────────────────────────────
  await menuClick('ismail');
  eq('ismail 만 남는다 (평문 메모도 담당이 없으니 감춤, 빈 줄만 예외)',
    await vis(), '10101');
  eq('칩이 1 로 켜진다', await chip(), { on: true, n: '1', chipShown: true });
  eq('저장 텍스트는 한 글자도 안 변한다', await text(), MEMO);
  eq('메뉴를 열어 둔 채 체크가 되그려진다',
    (await menu()).filter((o) => o.label === 'ismail').map((o) => o.checked), ['true']);

  // ── 칸이 다르면 AND ──────────────────────────────────────────────────────
  await menuClick('NSS');
  eq('ismail AND NSS — 배포(프로젝트 없음)도 떨어진다', await vis(), '10001');
  eq('칩은 선택 개수', (await chip()).n, '2');

  // ── 같은 칸 안은 OR ──────────────────────────────────────────────────────
  await menuClick('hyun');
  eq('담당 ismail OR hyun, AND NSS', await vis(), '11001');

  // ── 해제 ─────────────────────────────────────────────────────────────────
  await menuClick('필터 해제');
  eq('해제하면 전부 돌아온다', await vis(), '11111');
  eq('칩도 꺼진다', await chip(), { on: false, n: '0', chipShown: false });

  // ── 목표일 '오늘' — 화면에 보이는 시계의 오늘 ────────────────────────────
  await page.evaluate(() => {
    const p = (n) => (n < 10 ? '0' : '') + n;
    const f = (d) => d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
    const today = f(new Date()), tomorrow = f(new Date(Date.now() + 86400000));
    CMMemo.setText(['- [ ] 오늘 일', '    @목표일: ' + today + 'T09:00',
                    '- [ ] 내일 일', '    @목표일: ' + tomorrow + 'T09:00',
                    '- [ ] 날짜 없는 일'].join('\n'));
  });
  await openFlt();                                  // 아까 목록은 낡았다 — 다시 연다
  eq('오늘까지인 줄 수가 옆에 보인다',
    (await menu()).filter((o) => o.label === '목표일 — 오늘').map((o) => o.cnt), ['1']);
  await menuClick('목표일 — 오늘');
  eq('오늘 것만 남는다', await vis(), '100');
  // 다시 그려도(외부 setText) 필터는 그대로 물려 있다.
  await page.evaluate(() => CMMemo.setText(CMMemo.text()));
  eq('다시 그려도 필터가 유지된다', await vis(), '100');
  await menuClick('필터 해제');
  eq('해제는 목표일 필터도 함께 푼다', await vis(), '111');

  // 영속 계약은 소스로 확인한다 — 이 하네스(setContent)는 origin 이 없어 localStorage 가
  // 막혀 있고, 앱 규칙상 저장소가 막혀도 필터는 동작해야 한다(메모리 상태가 진실).
  const fs = require('fs');
  const PAD = fs.readFileSync(__dirname + '/../Sources/ConditionManager/Dashboard/MemoPad.swift', 'utf8');
  eq('선택은 localStorage(cmMemoFlt)로 영속을 시도한다',
    /localStorage\.setItem\('cmMemoFlt'/.test(PAD) && /localStorage\.getItem\('cmMemoFlt'\)/.test(PAD), true);

  await browser.close();
  console.log('---');
  console.log(pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
