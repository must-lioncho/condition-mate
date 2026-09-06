// E2E for the Slack 번역함 ⋮ 더보기 드롭다운 on a COLLAPSED row. Bound to REAL
// source: pulls the whole page HTML (CSS + JS) out of SlackTranslateContent.swift
// and drives it in a real Chromium DOM with a stubbed /api/slack/items.
//
// 회귀 대상: 접힌 행은 .item.collapsed{overflow:hidden}이라 드롭다운이 통째로
// 잘려 ⋮를 눌러도 화면엔 아무것도 안 나왔다. 이제 ⋮는 항목을 먼저 펼치고
// (재렌더 후 새 버튼을 다시 찾아) 메뉴를 연다. 아래 검증은 클래스만 보지 않고
// elementFromPoint로 메뉴가 실제로 보이는지(=잘리지 않았는지)까지 확인한다.
const { chromium } = require('playwright');
const fs = require('fs');

const SRC = fs.readFileSync(__dirname + '/../Sources/Plugins/Slack/SlackTranslateContent.swift', 'utf8');
const open = SRC.indexOf('return #"""');
if (open < 0) throw new Error('페이지 HTML 리터럴을 못 찾음');
const html = SRC.slice(open + 'return #"""'.length, SRC.indexOf('"""#', open))
  .replace('\\#(headExtraHTML())', ''); // 호스트 앱 주입분 — 페이지 자체 폴백 사용

const now = Math.floor(Date.UTC(2026, 6, 29, 6, 13) / 1000);
const item = (n, extra) => Object.assign({
  id: 'C1:' + n, channel: 'C1', channelName: '#blk-platform-support-request',
  author: 'B09KPG9FYBB', reactedAt: now - n * 600,
  textEn: 'Summary we need myip.must.company I use many for security #' + n,
  textKo: '요약 우리는 myip.must.company가 필요합니다 #' + n,
  permalink: 'https://slack.example/archives/C1/p' + n,
}, extra || {});
const PAYLOAD = {
  items: [item(1), item(2), item(3)],
  done: {}, syncErr: {}, replies: {},
  model: 'gemini-flash-lite', lang: 'ko', geminiKey: true, debugButtons: false,
};

let pass = 0, fail = 0;
const check = (n, ok, extra) => { console.log((ok ? 'PASS ' : 'FAIL ') + n + (extra ? '  ' + extra : '')); ok ? pass++ : fail++; };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
  await page.addInitScript(payload => {
    window.fetch = u => Promise.resolve({
      ok: true,
      json: () => Promise.resolve(String(u).indexOf('/api/slack/items') >= 0 ? payload : {}),
    });
  }, PAYLOAD);
  // setContent()는 about:blank 문서라 localStorage가 막혀 페이지 부팅이 죽는다.
  // 실제 앱처럼 http 오리진을 주되, 네트워크는 route로 가로채 오프라인 유지.
  await page.route('http://cm.test/**', r =>
    r.fulfill({ contentType: 'text/html; charset=utf-8', body: html }));
  await page.goto('http://cm.test/slack-translate');
  await page.waitForSelector('#list .item');

  // 목록 기본 = 전부 접힘 (한 줄 요약).
  check('기본은 접힘', await page.$eval('#list .item', e => e.classList.contains('collapsed')));

  // 접힌 행의 ⋮ 클릭 — 펼쳐지고 메뉴가 실제로 보여야 한다.
  const row = '#list .item[data-id="C1:2"]';
  await page.$eval(row + ' > .acts .menu-wrap > button', b => b.click());
  const after = await page.evaluate(sel => {
    const it = document.querySelector(sel);
    const menu = it.querySelector(':scope > .acts .menu');
    const r = menu.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + 12);
    return {
      collapsed: it.classList.contains('collapsed'),
      open: menu.classList.contains('open'),
      pinned: !!it.querySelector(':scope > .acts.pin'),
      w: Math.round(r.width), h: Math.round(r.height),
      visible: !!(hit && hit.closest('.menu') === menu),
      labels: Array.prototype.map.call(menu.children, c => c.textContent.trim()),
      caret: (it.querySelector('.caret') || {}).textContent,
    };
  }, row);
  check('⋮ 누르면 항목이 펼쳐진다', after.collapsed === false);
  check('메뉴가 open 상태', after.open === true);
  check('액션 툴바가 pin으로 남는다', after.pinned === true);
  check('메뉴가 실제로 화면에 보인다 (클리핑 없음)', after.visible === true,
    `${after.w}x${after.h}`);
  // 메뉴 = 슬랙에서 열기 · 처리완료 + "세션 추출" 구분 아래 두 갈래(단순 추출 ·
  // 컨텍스트 공유하기). 세션 추출 자체의 동작은 slackextract.test.js 가 본다.
  check('메뉴 내용이 나온다 (슬랙에서 열기 · 처리완료 · 세션 추출)',
    after.labels.length === 5 && /슬랙에서 열기/.test(after.labels[0]) && /처리완료/.test(after.labels[1])
    && after.labels[2] === '세션 추출' && after.labels[3] === '단순 추출'
    && after.labels[4] === '컨텍스트 공유하기',
    JSON.stringify(after.labels));
  check('펼침 캐럿이 ▾로 바뀐다', after.caret === '▾');

  // 다른 행은 접힌 채로 남는다 (한 항목만 펼침).
  check('다른 행은 그대로 접힘',
    await page.$eval('#list .item[data-id="C1:1"]', e => e.classList.contains('collapsed')));

  // 같은 ⋮ 재클릭 = 닫기 (펼침은 유지 — 접기는 메타 줄 클릭으로만).
  await page.$eval(row + ' > .acts .menu-wrap > button', b => b.click());
  const toggled = await page.evaluate(sel => {
    const it = document.querySelector(sel);
    return {
      open: !!it.querySelector(':scope > .acts .menu.open'),
      collapsed: it.classList.contains('collapsed'),
    };
  }, row);
  check('재클릭하면 메뉴가 닫힌다', toggled.open === false);
  check('메뉴만 닫히고 항목은 펼친 채로 유지', toggled.collapsed === false);

  // 이미 펼친 항목의 ⋮ — 기존 동작 그대로 (열고 닫기).
  await page.$eval(row + ' > .acts .menu-wrap > button', b => b.click());
  const reopened = await page.evaluate(sel => {
    const it = document.querySelector(sel);
    const menu = it.querySelector(':scope > .acts .menu');
    const r = menu.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + 12);
    return { open: menu.classList.contains('open'), visible: !!(hit && hit.closest('.menu') === menu) };
  }, row);
  check('펼친 항목에서도 메뉴가 열리고 보인다', reopened.open && reopened.visible);

  // 메뉴 바깥 클릭 → 닫힘 (기존 문서 클릭 핸들러 유지).
  await page.mouse.click(20, 700);
  check('바깥 클릭하면 닫힌다', await page.$$eval('#list .menu.open', ms => ms.length === 0));

  await browser.close();
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
